#!/system/bin/sh
#
# 模块卸载脚本
#
# 关键：卸载时把控制节点【交回系统】，然后只杀进程、清文件。
#
# ★★ v3577 更正：原来这里写着「千万别写 0」，该结论已【作废】★★
#   · 旧结论（2026-09-25）：写 0 会让输入功率从 41~52W 暴跌到 13W。
#   · 新结论（v3530 现场实测复核）：本机 fchg_fcc_ma 的 0 是
#     【不参与申请】，不是「申请 0mA」。出厂静止态本来就是 0，
#     effective 仍是 FCHG_DEFAULT_EVENT v=14100 —— 写 0 才是正确交回。
#   · 旧实现错在【写非 0 推算值】（DT 表算出 5950 = 238 x 25，那个
#     x25 是 iQOO13 的标定系数）：会变成 DEBUG_FORCE_CLIENT，优先级
#     比出厂态更高，等于把系统钉死在模块算出来的值上。
#   · 现状：vfcs_boost 的 restore_to_system() 就是写 0，两者一致。
#     详见 vfcs_boost 第 3922~3972 行的现场实测记录。
#
# 【卸载时的交回策略】
#   fchg_fcc_ma 是只进不出的节点，驱动没有自动恢复机制，
#   所以卸载必须显式交还。按顺序尝试：
#     ① DT 档位表    —— 按当前 vbat 读出厂商原厂分段电流
#     ② 原始值备份   —— 模块首次写入前存下的原值
#     ③ 9720         —— 兜底常量（K80 Ultra 标定值，仅保底）
#
#   且 DT 表本身就是"原厂值"的定义）。下面第 ① 步直接读 DT。
#
# 注意区分两个节点：
#   cms_class/debug_chg_cur   <- 历史节点，本模块已不再使用，不去碰它
#

# ★ v3530 修：MODPATH 可能不存在。
#   旧写法直接 `BOOST="$MODPATH/system/bin/vfcs_boost"`，一旦 MODPATH 为空
#   （手动执行 sh uninstall.sh、或某些管理器不导出该变量），
#   BOOST 就变成 "/system/bin/vfcs_boost" —— 那根本不存在，
#   于是 `[ -x "$BOOST" ]` 判定失败，最关键的「复用模块 restore 对称还原」
#   整条链被跳过，只能落到兜底链。现在补一条「按脚本自身位置推算」的退路。
_UF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[ -n "$_UF_DIR" ] || _UF_DIR=${0%/*}
if [ -n "$MODPATH" ] && [ -x "$MODPATH/system/bin/vfcs_boost" ]; then
	BOOST="$MODPATH/system/bin/vfcs_boost"
elif [ -n "$_UF_DIR" ] && [ -x "$_UF_DIR/system/bin/vfcs_boost" ]; then
	BOOST="$_UF_DIR/system/bin/vfcs_boost"
else
	BOOST="/data/adb/modules/v2507a_charge_boost/system/bin/vfcs_boost"
fi
NODE="/sys/class/vfcs_class/fchg_fcc_ma"
ORIG_FILE="/data/adb/v2507a_charge_boost.orig"

# DT 档位表
#
#   旧版写死天玑路径 + 天玑单位，骁龙机卸载时会读不到表 ->
#   一路退到兜底常量 9720 -> 卸载后限速没解除。
#
#   实测三台机型布局全不同：
#     X200 Pro(天玑) .../devicetree/base/vfcs_cms/vivo,normal-tc-data-N
#     V2463A  (骁龙) .../base/soc/qcom,pmic_glink/cms_v5/vivo,normal-tc-data-N
#     iQOO 13 (骁龙) .../cms_v5/single_charger_board/vivo,aging-normal-tc-data-N
#   所以这里同样改成运行时探测（逻辑与 vfcs_boost 的 dt_probe 对齐）。
#
# 单值 vbat（mV），失败输出空
#
#   旧实现按"值 > 30000 就当 µV"判口径，这条线只在
#   X200 Pro / iQOO13 的实测值上成立：
#     µV 口径  4200000 (7 位) / mV 口径 4200 (4 位)
#   但有的骁龙 fuel gauge 直接吐 mV，且存在 5 位数落在
#   30000 以下的组合会被漏除 1000。
#   改按【位数】判：≤5 位必然是 mV，≥6 位必然是 µV。
#   4 位与 7 位相差 3 个数量级，中间没有模糊地带。
#   这与 vfcs_boost 的 read_vbat() 口径完全一致
#   （卸载时若口径与运行时不一致，会写回错误的原厂档值）。
read_vbat_mv() {
	local f v
	for f in /sys/class/power_supply/battery/voltage_now \
	         /sys/class/power_supply/bms/voltage_now; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null)
		case "$v" in ''|*[!0-9]*) continue ;; esac
		[ "$v" -le 0 ] && continue
		if [ ${#v} -ge 6 ]; then
			v=$((v / 1000))      # 6-8 digits = uV
		fi
		echo "$v"; return 0
	done
	echo ""
	return 1
}

# ---- 读 DT 文件里第 idx 个 big-endian uint32 ----
dt_u32_at() {
	local f=$1 idx=$2
	[ -r "$f" ] || { echo ""; return 1; }
	od -An -tu1 -v "$f" 2>/dev/null | awk -v n="$idx" '
		{ for (i = 1; i <= NF; i++) b[++c] = $i }
		END {
			p = n * 4 + 1
			if (c < p + 3) { print ""; exit }
			printf "%d\n", b[p]*16777216 + b[p+1]*65536 + b[p+2]*256 + b[p+3]
		}'
}

# ---- 读电池老化档（表编号）----
read_aging_stage() {
	local v f stage="" cyc derived

	# ---- ① 直读节点（最快路径）----
	#   实测 iQOO 13 的 power_supply/battery/aging_stage 读 0，
	#   而驱动 cms_v5 的 dmesg 打印 aging_stage=5
	#   （cms_check_batt_aging: Update: cycle[646->646] stage[5->5]）。
	#   旧版读到 0 就 return，导致卸载时用"未老化档"的值恢复，
	#   与驱动的实际裁定不符。现改为 0 时继续交叉验证。
	#
	#   【与 vfcs_boost 的 read_aging_stage 必须逐字一致】
	#     否则会出现"装的时候按档5、卸的时候按档0"的不对称行为。
	for f in /sys/class/vfcs_class/aging_stage \
	         /sys/class/cms_class/aging_stage \
	         /sys/class/power_supply/battery/aging_stage \
	         /sys/class/power_supply/bms/aging_stage; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null)
		case "$v" in ''|*[!0-9]*) continue ;; esac
		[ "$v" -lt 0 ] && continue
		[ "$v" -gt 10 ] && continue
		if [ "$v" -gt 0 ]; then echo "$v"; return 0; fi
		[ -z "$stage" ] && stage="0"
	done

	# ---- ② 定向找 ----
	#  ★ v3534：原为 `find /sys -name aging_stage`，遍历整棵 /sys 树，
	#  实测 4495 ms。卸载流程本来就要还原一堆节点，再白烧 4.5 秒
	#  会让「卸载」这个动作明显更久。改为只在已知会出现该节点的
	#  三个子树里搜，限深 2，覆盖面不变、代价降到几十毫秒。
	if [ -z "$stage" ] || [ "$stage" = "0" ]; then
		f=$(find /sys/class/power_supply /sys/class/cms_class /sys/class/vfcs_class \
			-maxdepth 2 -name aging_stage -type f 2>/dev/null | head -n 1)
		if [ -n "$f" ] && [ -r "$f" ]; then
			v=$(cat "$f" 2>/dev/null)
			case "$v" in
				''|*[!0-9]*) ;;
				*)
					[ "$v" -le 10 ] && [ "$v" -ge 0 ] && {
						if [ "$v" -gt 0 ]; then echo "$v"; return 0; fi
						stage="0"
					}
					;;
			esac
		fi
	fi

	# ---- ③ 节点报 0 时，按本机 DT 边界表查 cycle -> 档位 ----
	#   中 dt_aging_stage_by_cycle 上方的实机事实链）。
	if [ "$stage" = "0" ]; then
		cyc=$(read_aging_cycle 2>/dev/null)
		case "$cyc" in ''|*[!0-9]*) cyc="" ;; esac
		if [ -n "$cyc" ]; then
			derived=$(dt_aging_stage_by_cycle "$cyc" 2>/dev/null)
			case "$derived" in ''|*[!0-9]*) derived="" ;; esac
			if [ -n "$derived" ]; then
				echo "$derived"
				return 0
			fi
		fi
	fi

	[ -n "$stage" ] && { echo "$stage"; return 0; }
	echo 0
}

# ---- 读电池循环次数 ----
read_aging_cycle() {
	local f v
	for f in /sys/class/power_supply/battery/cycle_count \
	         /sys/class/cms_class/battery_health_cyclecount \
	         /sys/class/power_supply/bms/cycle_count; do
		[ -r "$f" ] || continue
		v=$(cat "$f" 2>/dev/null)
		case "$v" in ''|*[!0-9]*) continue ;; esac
		echo "$v"; return 0
	done
	echo ""
	return 1
}

# ---- 取指定 SOC 档的字段（白名单定位）----
# $1=文件 $2=SOC下界 $3=字段序号(0=I1,1=V1,2=I2,...)
dt_seg_field() {
	local f=$1 want=$2 fi=$3
	[ -r "$f" ] || return 1
	# want/fi 均为纯十进制数字，-v 传参安全（切勿改成 "A=x od ... | awk" 形式）
	od -An -tu1 -v "$f" 2>/dev/null | awk -v want="$want" -v fi="$fi" '
		BEGIN {
			PL[1]=450; PH[1]=549
			PL[2]=400; PH[2]=449
			PL[3]=350; PH[3]=399
			PL[4]=250; PH[4]=349
			# ★ V2352A 本机适配：本机 DT 分段是 200:349（单段覆盖 250~349
			#   与 200~249）。不补这条，卸载时定位 SOC 档会全部失败，
			#   交回值只能退回兜底常量，与本机口径不符。
			PL[5]=200; PH[5]=349
			PL[6]=200; PH[6]=249
			PL[7]=150; PH[7]=199
			PL[8]=100; PH[8]=149
			PL[9]=0;   PH[9]=99
			NP=9
		}
		function isb(a,b2,  q){ for(q=1;q<=NP;q++) if(a==PL[q]&&b2==PH[q]) return 1; return 0 }
		{ for (i = 1; i <= NF; i++) b[++c] = $i }
		END {
			n = int(c/4)
			for (k=0;k<n;k++){ p=k*4+1; v[k+1]=b[p]*16777216+b[p+1]*65536+b[p+2]*256+b[p+3] }
			i = 12
			while (i <= n-1) {
				if (isb(v[i], v[i+1])) {
					if (v[i] == want) { print v[i+2+fi]; exit }
					j = i+2
					while (j <= n-1 && !isb(v[j], v[j+1])) j++
					i = j
				} else i++
			}
			print ""
		}'
}

# 读本机的【老化档边界表】，按 cycle 做分段查找得到档位号。
# 成功输出档位号（0-based，0..10）；失败输出空。
#
# ============================================================
# ============================================================
#
# 【旧实现错在哪】
#   旧版把 vivo,bat-aging-cycle-range 当成【等距档宽表】，
#   取相邻差的众数当"每档多少圈"，再用 cycle ÷ 档宽 得档位。
#   iQOO13 实测数据证明这是【错的模型】：
#
#     DT 数组 = 20 100 200 300 500 800 1000 1500 2000 2500
#     相邻差  =  80 100 100 200 300 200 500  500  500
#                                         ^^^^^^^^^^^^^
#     众数 = 500，但前段间隔是 80/100/200/300 —— 【根本不是等距】
#
#   旧注释里那句"646/128=5.05 -> 档5，与 dmesg 吻合"是【巧合】：
#   结果碰对了，方法完全错。换个循环数就会偏。
#
# 【正确模型】
#   这个数组是【分段的边界值】，语义为"第 n 档的循环数下界"：
#     cycle <  r[0]         -> 档 0
#     r[0] <=  cycle < r[1] -> 档 1
#     r[1] <=  cycle < r[2] -> 档 2
#     ...
#     r[8] <=  cycle < r[9] -> 档 9
#     cycle >= r[9]         -> 档 10
#
# 【实机交叉验证（iQOO13 / V2408A）】
#   DT 数组  = 20 100 200 300 500 800 1000 1500 2000 2500
#   cms_class/soh_test 里驱动自己打印的权威表:
#     old:[cap_loss, cycle] = 10,20  14,100 20,200 31,300 45,500
#                             60,800 60,1000 104,1500 155,2000
#                             222,2500  310,8888
#   两者的 cycle 列【逐项完全对齐】—— 证明 DT 数组就是这张表的
#   边界列，而不是什么"档宽"。
#
#   cycle_count = 646
#     旧法: 646 / 128  = 5.05  -> 5     （结果对，方法错）
#     新法: 查段 500 <= 646 < 800 -> 档 4 （0-based）
#   驱动 dmesg 报 stage[5->5]，1-based -> 0-based 正是 4。✓
#
# 【与驱动 stage 编号的换算】
#   DT 查找得到的是 0-based（0..10）。
#   驱动 dmesg / 原厂 DT 表用的是 1-based（1..11）。
#   故对外输出统一为【1-based】，与 normal-tc-data-N 的 N 直接对应。
#
# 【为什么不再需要 FALLBACK_AGING_STEP】
#   旧的 128 兜底已经被证明是错的（iQOO13 真实首段宽度只有 80）。
#   新版完全依赖本机 DT；DT 读不到时【返回空】，
#   由调用方决定退到什么，而不是硬塞一个可能错的数。
#   —— 这符合用户明确要求："要在他们自己的机型上读取，而不是写死"。
AGING_STAGE_TABLE=""       # Cache: DT cycle boundaries, space-separated

dt_aging_boundaries() {
	[ -n "$AGING_STAGE_TABLE" ] && { echo "$AGING_STAGE_TABLE"; return 0; }
	local dir n f sz cnt i v acc=""
	for dir in $(dt_candidate_dirs); do
		for n in \
			"vivo,bat-aging-cycle-range" \
			"vivo,batt-aging-cycle-range"
		do
			f="$dir/$n"
			[ -r "$f" ] || continue
			sz=$(wc -c < "$f" 2>/dev/null)
			case "$sz" in ''|*[!0-9]*) continue ;; esac
			cnt=$((sz / 4))
			# 至少要有 2 个边界才有分段意义
			[ "$cnt" -lt 2 ] && continue
			acc=""
			i=0
			while [ "$i" -lt "$cnt" ]; do
				v=$(dt_u32_at "$f" "$i")
				i=$((i + 1))
				case "$v" in ''|*[!0-9]*) continue ;; esac
				acc="$acc $v"
			done
			# 去掉前导空格
			acc=${acc# }
			[ -n "$acc" ] || continue
			AGING_STAGE_TABLE="$acc"
			echo "$acc"
			return 0
		done
	done
	echo ""
	return 1
}

# 按 cycle 落在哪个区间得出老化档号（= 驱动 dmesg 的 stage）。
# 输出 0..11；DT 不可读或参数非法时输出空。
#
# ============================================================
#  ★ 公式的由来：只用实机锚点，不做任何"看着合理"的推导 ★
# ============================================================
#
# 【实机事实链（iQOO13 / V2408A）】
#   1) cms_class/soh_test 打印:
#        cycle=646 --> cap_loss=(A3+B3)=60
#   2) 同节点打印的驱动权威表 old:[cap_loss, cycle]:
#        行1   10   20      行7   60   1000
#        行2   14   100     行8  104   1500
#        行3   20   200     行9  155   2000
#        行4   31   300     行10 222   2500
#        行5   45   500     行11 310   8888
#        行6   60   800
#      cap_loss=60 首次出现于【行6, cycle=800】—— 与 1) 对得上。
#   3) dmesg: cms_check_batt_aging: Update: cycle[646->646] stage[5->5]
#
#   => 646 对应 stage=5，而 stage=5 指向"上界 800 的那一段"。
#   => 800 在 DT 数组里的下标恰好是 5。
#
#   ∴  stage = 【第一个满足 cycle < DT[k] 的 k】（0-based）
#
# 【逐点映射（由上式推出，与驱动表行号完全吻合）】
#     cycle 区间          stage
#     [   0,  20)           0
#     [  20, 100)           1
#     [ 100, 200)           2
#     [ 200, 300)           3
#     [ 300, 500)           4
#     [ 500, 800)           5     <-- 646 在此，与 dmesg 一致 ✓
#     [ 800,1000)           6
#     [1000,1500)           7
#     [1500,2000)           8
#     [2000,2500)           9
#     [2500,  ∞ )          11     <-- 见下
#
# 【为什么末段直接给 11 而不是 10】
#   DT 数组只有 10 个元素，表达不了"行10/行11"这两档的边界
#   （行11 的下界 8888 是驱动内部哨兵，不烧进 DT）。
#   cycle 一旦越过 DT 末元素，我们已无法在本机数据上区分 10 与 11，
#   此时【取更大的档号】是安全方向：档号越大，加载的原厂电流曲线越保守。
#   超龄电池本就该限流，宁可偏保守。
dt_aging_stage_by_cycle() {
	local cyc="$1" tbl r k i n last
	case "$cyc" in ''|*[!0-9]*) echo ""; return 1 ;; esac

	tbl=$(dt_aging_boundaries 2>/dev/null)
	[ -n "$tbl" ] || { echo ""; return 1; }

	# k = 第一个满足 cyc < DT[k] 的下标
	# 同时记录 last = 最大有效下标（用于判断是否越过整个表）
	k=""; i=0; last=""
	for r in $tbl; do
		case "$r" in ''|*[!0-9]*) i=$((i + 1)); continue ;; esac
		last=$i
		if [ -z "$k" ] && [ "$cyc" -lt "$r" ]; then k=$i; fi
		i=$((i + 1))
	done
	[ -z "$last" ] && { echo ""; return 1; }

	# 越过整张表 -> 最保守
	[ -z "$k" ] && { echo 11; return 0; }

	n=$k
	[ "$n" -lt 0 ] && n=0
	[ "$n" -gt 11 ] && n=11
	echo "$n"
	return 0
}


# ---- 候选目录（可被 SIMROOT 覆盖，便于离线测试；真机走默认 /sys）----
dt_candidate_dirs() {
	local root=${DT_ROOT:-/sys/firmware/devicetree/base}
	echo "$root/vfcs_cms"
	echo "$root/soc/qcom,pmic_glink/cms_v5/single_charger_board"
	echo "$root/soc/qcom,pmic_glink/cms_v5"
}

# ---- 探测本机的表（目录 x 表名 两级扫描）----
# 成功: 输出文件路径；失败: 输出空
#
#   先只匹配本老化档的表名；全部未命中才退回 -0 表。
#   退回时打告警——那意味着恢复值用的是"未老化档口径"，可能偏高。
dt_probe() {
	local stage=$1 dir name f sz
	[ -z "$stage" ] && stage=0

	# 第一轮：精确匹配本老化档
	for dir in $(dt_candidate_dirs); do
		[ -d "$dir" ] || continue
		for name in \
			"vivo,aging-normal-tc-data-$stage" \
			"vivo,aging1-normal-tc-data-$stage" \
			"vivo,normal-tc-data-$stage"
		do
			f="$dir/$name"
			[ -r "$f" ] || continue
			sz=$(wc -c < "$f" 2>/dev/null)
			[ "$sz" = "440" ] && { echo "$f"; return 0; }
		done
	done

	# 第二轮：退回档 0 / 无编号表（告警）
	for dir in $(dt_candidate_dirs); do
		[ -d "$dir" ] || continue
		for name in \
			"vivo,aging-normal-tc-data-0" \
			"vivo,aging1-normal-tc-data-0" \
			"vivo,normal-tc-data-0" \
			"vivo,normal-tc-data"
		do
			f="$dir/$name"
			[ -r "$f" ] || continue
			sz=$(wc -c < "$f" 2>/dev/null)
			[ "$sz" = "440" ] || continue
			# 老化档非 0 却命中 -0 表 -> 明确告警
			if [ "$stage" != "0" ]; then
				echo "WARN: table for aging stage ${stage} missing; falling back to ${name} (unaged baseline)" >&2
			fi
			echo "$f"; return 0
		done
	done

	# 第三轮：全盘兜底
	f=$(find "$(dirname "$(dirname "$(dt_candidate_dirs | head -n 1)")")" \
			-type f -name 'vivo,*normal-tc-data*' \
			-size -441c -size +439c 2>/dev/null | head -n 1)
	[ -n "$f" ] && { echo "$f"; return 0; }
	echo ""
	return 1
}

# ---- 判定电压单位："mv" 或 "uv" ----
dt_detect_unit() {
	local f=$1 v1 mx
	[ -r "$f" ] || { echo "mv"; return; }
	v1=$(dt_seg_field "$f" 400 1)
	case "$v1" in ''|*[!0-9]*) v1=0 ;; esac
	if [ "$v1" -ge 100000 ]; then echo "uv"; return; fi
	if [ "$v1" -gt 0 ]; then echo "mv"; return; fi
	mx=$(od -An -tu1 -v "$f" 2>/dev/null | awk '
		{ for(i=1;i<=NF;i++) b[++c]=$i }
		END { n=int(c/4); mx=0
			for(k=0;k<n;k++){ p=k*4+1
				v=b[p]*16777216+b[p+1]*65536+b[p+2]*256+b[p+3]
				if(v==4294967295) continue
				if(v>mx) mx=v }
			print mx }')
	if [ "$mx" -ge 1000000 ]; then echo "uv"; else echo "mv"; fi
}

# ---- 读全局电流上限（mA），失败输出空 ----
#   三条路径的由来：天玑在 base/vfcs/，骁龙在 base/soc/vfcs/，
#   另有部分机型直接放 base/ 根下。少任何一条都会让该类机型读不到上限。
dt_cur_max() {
	local f v
	for f in \
		/sys/firmware/devicetree/base/vfcs/vivo,fchg-curr-max-ma \
		/sys/firmware/devicetree/base/soc/vfcs/vivo,fchg-curr-max-ma \
		/sys/firmware/devicetree/base/vivo,fchg-curr-max-ma
	do
		[ -r "$f" ] || continue
		v=$(dt_u32_at "$f" 0 2>/dev/null)
		case "$v" in ''|*[!0-9]*|0) continue ;; esac
		echo "$v"; return 0
	done
	echo ""
	return 1
}

# ---- 电流单位换算 --------------------------------------------
# 【2026-10-01 实机标定】iQOO 13 (V2408A) 实测：
#     表 I1=389  vs  vfcs_class/fchg_fcc_ma = 9720   ->  389 × 25 = 9725  (0.05%)
#     表 I2=321  vs  dmesg parallel current_ma=8000   ->  321 × 25 = 8025  (0.31%)
#   系数 = 25（不是 10/20）。其余机型（电压 mV 体系）系数 = 1。
#   必须与 vfcs_boost 的 dt_cur_scale 保持逐字一致。
dt_cur_scale() {
	local raw=$1 unit=$2 f=$3
	local cap k_auto k_use

	case "$raw" in ''|*[!0-9]*) echo ""; return ;; esac

	# ★ v3.5.11 补零值守卫：与 vfcs_boost 的同名函数保持逐字一致。
	#   表里读到 0 时若继续走 k_auto 反算会除零（mksh 下 $((x/0)) 直接报错），
	#   且 0 本身就是非法额度（写 0 = 掐死充电），必须原样判空返回。
	[ "$raw" -eq 0 ] && { echo 0; return; }

	# 定值：按电压体系判机型流派
	if [ "$unit" = "uv" ] && [ "$raw" -lt 2000 ]; then
		k_use=25
	else
		k_use=1
	fi

	# 旁证：反算系数，偏差过大只告警不改值
	cap=$(dt_cur_max)
	case "$cap" in ''|*[!0-9]*) cap="" ;; esac
	if [ -n "$cap" ] && [ "$cap" -gt 0 ]; then
		k_auto=$(( (cap + raw / 2) / raw ))
		if [ "$k_auto" -gt 0 ] && [ "$k_use" -gt 0 ]; then
			if [ $(( (k_auto - k_use) * 100 / k_use )) -gt 40 ] || \
			   [ $(( (k_use - k_auto) * 100 / k_use )) -gt 40 ]; then
				echo "WARN: current scale: raw=${raw} x${k_use} vs max ${cap}mA k=${k_auto} mismatch" >&2
			fi
		fi
	fi

	echo $((raw * k_use))
}

# ---- 按老化档取恢复值（与天玑逻辑一致：老化档N -> 表-N -> SOC200~249 档 I1）----
# 输出电流值（同节点单位）；失败输出空
dt_restore_value() {
	local stage f raw unit
	stage=$(read_aging_stage)
	f=$(dt_probe "$stage") || return 1
	[ -n "$f" ] || return 1

	# 优先 SOC 200~249 档（日常快充主区间），取不到退 400~449 档
	raw=$(dt_seg_field "$f" 200 0)
	case "$raw" in ''|*[!0-9]*|0) raw=$(dt_seg_field "$f" 400 0) ;; esac
	case "$raw" in ''|*[!0-9]*|0) return 1 ;; esac
	unit=$(dt_detect_unit "$f")
	dt_cur_scale "$raw" "$unit" "$f"
	return 0
}

# ============================================================
# ★ 顺序（v3.5.11 修正）
#   ① 停看门狗（service.sh）—— 否则它在下面整个卸载过程里
#      每 15 秒就会 start 一次，把刚停掉的守护重新拉起来。
#      旧版只清 __daemon 守护进程、不动看门狗，.profile 又到很
#      后才删，窗口期足够它复活一次，卸载后仍在注入。
#   ② 交回系统（优先调用模块自己的 restore —— 它是唯一与守护
#      对称的实现：档位写 3、停守护、vot_release、restore_to_system、
#      safe_guard_restore 一条龙）
#   ③ 本文件内的兜底链（仅当 ② 不可用时）
#   ④ 解除判决层注入
#   ⑤ 还原防掉档压制
#   ⑥ 删配置/台账
#   ⑦ 终局清扫（再杀一次守护 + 看门狗）
# ============================================================

# ---- ① 停看门狗 ----
# service.sh 是个 while+sleep 的循环，只能按进程特征匹配。
# 判据：命令行里同时含本模块的 service.sh 路径特征与 WATCH_IV 轮询痕迹。
_stop_watchdog() {
	for p in $(ps -A -o pid,args 2>/dev/null | awk '
		($0 ~ /v2507a_charge_boost/ || $0 ~ /v2352a_charge_boost/) && $0 ~ /service\.sh/ && $0 !~ /awk/ {print $1}'); do
		case "$p" in ''|*[!0-9]*) continue ;; esac
		kill -9 "$p" 2>/dev/null
	done
	# 兜底：有些 ROM 的 ps 不带完整 args，用 /proc/<pid>/cmdline 再扫一遍
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		case "$p" in ''|*[!0-9]*) continue ;; esac
		[ "$p" = "$$" ] && continue
		c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
		case "$c" in
			*v2507a_charge_boost*service.sh*|*v2352a_charge_boost*service.sh*) kill -9 "$p" 2>/dev/null ;;
		esac
	done
	return 0
}
_stop_watchdog

# ---- ② 优先走模块自己的 restore（与守护严格对称的那条链）----
#   旧版注释声称"与 restore_to_system 保持一致"，其实顺序完全不同
#   （uninstall 是 DT→orig→兜底，restore 是 orig→DT(vbat)→DT(老化档)→兜底），
#   结果是"切原厂档"和"卸载"可能留下不同的节点值。
#   现在直接复用模块实现，从根上消除两条链的分叉。
UNINST_RESTORE_BY=""
if [ -x "$BOOST" ]; then
	_r=$("$BOOST" restore 2>/dev/null)
	case "$_r" in
		*Restored\ stock*|*Handed\ back*)
			UNINST_RESTORE_BY="module restore: $(echo "$_r" | grep -m1 -E 'Method:' 2>/dev/null)"
			;;
		*)
			UNINST_RESTORE_BY=""
			;;
	esac
fi

# 兜底：按 pidfile 再杀一次守护
if [ -f /data/adb/v2507a_charge_boost.pid ]; then
	kill "$(cat /data/adb/v2507a_charge_boost.pid)" 2>/dev/null
	rm -f /data/adb/v2507a_charge_boost.pid
fi

# 兜底：按真实进程清扫所有遗留守护实例
#   改为「同时含 vfcs_boost/vb.sh 与 __daemon」的精确判定。
for p in $(ps -A -o pid,args 2>/dev/null | awk '
	$0 ~ /__daemon/ && ($0 ~ /vfcs_boost/ || $0 ~ /vb\.sh/) && $0 !~ /awk/ {print $1}'); do
	case "$p" in ''|*[!0-9]*) continue ;; esac
	kill -9 "$p" 2>/dev/null
done
rm -rf /data/adb/v2507a_charge_boost.lock

# ---- ③ 兜底链（与 restore_to_system 同序：orig → DT → 兜底）----
# 【为什么不能只写 9720】那是 K80 Ultra 的标定值，
#   换机型若系统默认更高，写 9720 反而是限速。
#
# ★★ v3.5.11：先判断"模块到底写没写过"，没写过就【一个字都不改】★★
#   旧版无条件往 fchg_fcc_ma 写一个推算值。于是在"从没注入过"的机器上
#   （比如刚装就卸载、或注入全程被温控撒手挡住），卸载反而把驱动
#   自己设的值改成了 DT 表推算值 —— 卸载变成了"改写"。
#   判据（任一成立即认为写过）：
#     a) 有原值备份 ORIG_FILE        —— 写过才可能备份成功
#     b) 会话标记写着本次开机写过节点
#     c) 节点当前值命中模块指纹（profile 里的 I_*/VOTE_IBAT 阶梯值）
DONE=""
WROTE_NODE=0
_cur_node=$(cat "$NODE" 2>/dev/null)
case "$_cur_node" in ''|*[!0-9]*) _cur_node="" ;; esac

[ -s "$ORIG_FILE" ] && WROTE_NODE=1

# b) 会话标记
#   ★ v3530 修：旧正则写的是 `*:written`，但实际文件内容格式是
#       boot_id=xxx
#       wrote=1
#   完全匹配不上 —— 这个判据从来没生效过，等于白写。
#   现在两种格式都认（wrote=1 / :written），并额外校验 boot_id 是否本次开机。
_sf=/data/adb/v2507a_charge_boost.session
if [ -s "$_sf" ]; then
	_sf_c=$(cat "$_sf" 2>/dev/null)
	case "$_sf_c" in
		*wrote=1*|*:written*) WROTE_NODE=1 ;;
	esac
fi

# c) 指纹：把 profile 里的分段电流/总闸收集成一个候选集
#    （必须在删 profile 之前读）
_pf0="/data/adb/v2507a_charge_boost.profile"
FP_LIST=""
if [ -f "$_pf0" ]; then
	while IFS='=' read -r _k _v; do
		case "$_k" in
			I_LOW|I_MID|I_PEAK|I_MID2|I_LOW2|VOTE_IBAT)
				case "$_v" in ''|*[!0-9]*) continue ;; esac
				FP_LIST="$FP_LIST $_v"
				;;
		esac
	done < "$_pf0" 2>/dev/null
fi
if [ -n "$_cur_node" ]; then
	for _f in $FP_LIST; do
		[ "$_cur_node" = "$_f" ] && { WROTE_NODE=1; break; }
	done
fi

# ============================================================
# ★★ v3530 修（演练 CASE 4 实测）：本机没有"模块未写入就不动"这条路径 ★★
# ------------------------------------------------------------
#  原判据是为「fchg_fcc_ma 是只进不出的申请额度」的机型设计的：
#  那些机器上，节点非 0 是驱动自己设的，模块没写过就不该动它。
#
#  本机语义完全不同：
#    出厂静止态 = 0（不参与申请）
#    非 0      = DEBUG_FORCE_CLIENT 接管（不管是模块写的还是别处写的）
#  所以本机只要节点非 0，就已经偏离出厂态，必须收回 0。
#  演练 CASE 4 实测：节点 9000、无任何台账 -> 旧逻辑保持 9000 不动，
#  卸载后系统被钉在 9000mA 申请额度上 —— 这就是"卸不干净"。
#
#  判据改为：本机（DEV 恒定 V2352A / 节点是 vfcs_class/fchg_fcc_ma）
#    节点 == 0 -> 已交回，不动
#    节点 != 0 -> 无论有没有台账，一律写 0
# ============================================================
if [ "$WROTE_NODE" = "0" ] && [ -n "$_cur_node" ] && [ "$_cur_node" != "0" ]; then
	WROTE_NODE=1
	FP_NOTE="(no state file but node=${_cur_node} != 0; scheduled to reset)"
fi

if [ "$WROTE_NODE" = "0" ]; then
	DONE="node already 0 (stock idle state, nothing to change)"
elif [ -z "$UNINST_RESTORE_BY" ]; then
	if [ -e "$NODE" ]; then
		echo 0 > "$NODE" 2>/dev/null
		if [ "$(cat "$NODE" 2>/dev/null)" = "0" ]; then
			DONE="reset to 0 (stock idle; previous ${_cur_node:-unknown} cleared)"
		fi
	fi
	if [ -z "$DONE" ] && [ -s "$ORIG_FILE" ]; then
		ORIG=$(cat "$ORIG_FILE" 2>/dev/null)
		case "$ORIG" in
			''|*[!0-9]*) ;;
			*)
				if [ -e "$NODE" ]; then
					echo "$ORIG" > "$NODE" 2>/dev/null
					[ "$(cat "$NODE" 2>/dev/null)" = "$ORIG" ] && \
						DONE="original value ${ORIG} (fallback after reset-to-0 failed)"
				fi
				;;
		esac
	fi
fi
[ -n "$UNINST_RESTORE_BY" ] && DONE="module restore (symmetric) | $UNINST_RESTORE_BY"

# 最后兜底：仍不行才用常量（绝不写 0！）
#
# ============================================================
# ============================================================
# 【用户实测症状】iQOO13：恢复原厂 / 卸载 / 冷重启后「失效」
#
#   "4600 是骁龙全系表里最保守档的公共下界"。这个判断是错的：
#     · 4600 不是"下界"，它是【很低的限速值】——
#       fchg_fcc_ma 是【申请额度】，写越低系统能申请的电流天花板越低。
#     · 本机实测（见上方 dt_cur_scale 注释）：iQOO13 原厂值就是 9720。
#       写 4600 = 直接砍到原厂的一半不到，用户当然判定为"失效"。
#
# 【为什么兜底会经常被走到】iQOO13 的 DT 表在
#   .../cms_v5/single_charger_board/ 这种长路径下，dt_probe 未必命中；
#   而卸载时 ORIG_FILE 也可能已被清理 —— 于是频繁落到兜底这条路。
#   一条经常被走到的路，其值绝对不能是"赌一个低值"。
#
# 【新策略：三级兜底，取值从高到低，宁可偏高不可偏低】
#   ① 本机全局上限 dt_cur_max（DT 里 vivo,fchg-curr-max-ma）——
#      这是本机型【系统自己声明】的电流天花板，最贴近"交回系统"语义，
#      且跨平台可读（天玑与骁龙三条路径都试）。
#   ② RESTORE_FALLBACK_MA（9720，与 vfcs_boost 的 RESTORE_MA 一致）——
#      本模块长期使用的兜底值，iQOO13/K80 Ultra 实测均为原厂水平。
#   ③ 若是 0 或读不到，才写 9720 常量。
#
# 【为什么不担心"写高了有危险"】
#   该节点是【申请额度】不是【强制电流】：最终给多少由 SOC/温度二次裁定
#   （脚本别处注释已反复说明这一点）。额度偏高时系统会自己限住；
#   额度偏低（如 4600）则是硬限速、没有任何自动补救 —— 两害相权取其轻。
RESTORE_FALLBACK_MA=0    # V2507A: fallback resets to 0 (release VFCS_CLASS_EVENT)

# ============================================================
#  ★★★ V2352A 本机适配：兜底值从 9720 改为 0 ★★★
# ------------------------------------------------------------
#  原逻辑假设 fchg_fcc_ma 是「只进不出的申请额度」，必须写一个正数
#  才能交回 —— 这在 iQOO13/K80 Ultra 上成立，在【本机不成立】。
#
#  本机实测（V2352A）：
#     出厂静止态：cat fchg_fcc_ma = 0
#                 DCHG_FCC effective = FCHG_DEFAULT_EVENT  v=14100
#     echo 9000 > fchg_fcc_ma
#                 -> effective = DEBUG_FORCE_CLIENT v=9000   ← 被钉住
#     echo 0    > fchg_fcc_ma
#                 -> effective = FCHG_DEFAULT_EVENT  v=14100 ← 交回系统
#
#  所以本机的「原厂」就是 0（= 不参与申请，系统自己按 DT/协议裁定）。
#  卸载时写 9720 反而是把一个外来值钉进判决层，比不装还差；
#  这正是"卸载后限速没解除/充电反而不如原厂"在本机的真正成因。
#
#  只有当节点当前确实非 0（= 模块或历史遗留写过）时才需要写回，
#  此时优先走上面的 ORIG / DT 两条链，最后兜底也回到 0。
# ============================================================

if [ -z "$DONE" ]; then
	# ============================================================
	#  ★★ v3530 修：整段兜底改为「无条件写 0」★★
	# ------------------------------------------------------------
	#  旧逻辑：
	#    ⓪ 当前是 0 -> 不动
	#    ① 读 DT 上限 dt_cur_max（本机 14100）-> RV=14100 -> 写进去
	#    ② 读不到 -> RV=RESTORE_FALLBACK_MA
	#  ① 这一支在本机【是错的】：写 14100 会让 DCHG_FCC 的 effective
	#  从 FCHG_DEFAULT_EVENT 变成 DEBUG_FORCE_CLIENT v=14100 ——
	#  数值看起来和出厂一样，但【优先级被抬高了】，系统自己的
	#  SOC/温度降额被这条 force 压住。等于"卸载后模块还在"。
	#
	#  本机正确做法只有一条：写 0。
	#  写 0 -> effective 回到 FCHG_DEFAULT_EVENT -> 完全出厂行为。
	# ============================================================
	if [ -e "$NODE" ]; then
		echo 0 > "$NODE" 2>/dev/null
		if [ "$(cat "$NODE" 2>/dev/null)" = "0" ]; then
			DONE="fallback reset to 0 (released to system control)"
		else
			DONE="fallback write 0 failed (node=$(cat "$NODE" 2>/dev/null))"
		fi
	else
		DONE="node missing; nothing to restore"
	fi
fi

echo "v2507a_charge_boost: uninstalled, restore method = ${DONE}" >> /data/adb/v2507a_charge_boost.log 2>/dev/null

# =============================================================================
# =============================================================================
#
#  【为什么"删除模块"必须自己把状态改回来】
#   本模块写入的两类状态全都【不会随卸载自动消失】：
#     ① 判决层注入 force_active=1 —— 持续生效，卸载后充电 IC 仍按旧值裁定
#     ② fchg_fcc_ma 是只进不出的申请额度 —— 不写回就一直卡在模块值上
#   所以卸载脚本必须与守护的 restore_to_system() 严格对称地把它们撤回，
#
#  【恢复顺序很重要】
#   先停守护（否则它还会继续写节点）-> 再解除判决层 -> 再交回申请层 ->
#   最后才删配置/台账。顺序颠倒会出现"刚交回又被守护写回去"。

# ---- 1. 解除判决层注入（voter force_active）----
#   force_val=0 在部分驱动上被解释为"强制 0mA"= 掐死充电，
#   所以只写 force_active=0（干净的撤销），绝不写 force_val=0。
#   必须在删 profile 之前读，因为"注入目标是哪个"记在 profile 里。
VOTE_ROOT="/sys/kernel/debug/pmic-votable"
_vote_release() {
	_vt="$1"
	_d="$VOTE_ROOT/$_vt"
	[ -d "$_d" ] || return 0
	if [ -f "$_d/force_active" ]; then
		_cur=$(cat "$_d/force_active" 2>/dev/null)
		if [ "$_cur" = "1" ]; then
			echo 0 > "$_d/force_active" 2>/dev/null \
				&& echo "v2507a_charge_boost: voter $_vt force_active released" \
				     >> /data/adb/v2507a_charge_boost.log 2>/dev/null
		fi
	fi
	return 0
}

# 优先按 profile 记录的目标解除；profile 可能已被删，所以已知目标全扫一遍。
#
# ★ v3.5.11 两处修正：
#   ① 键名是 VOTE_TARGETS（复数），旧代码读 VOTE_TARGET（单数）——
#      这个分支从来没匹配上，是纯死代码。现在两个键名都认。
#   ② 漏了 USER_IBUS。默认注入目标是 USER_IBAT + USER_IBUS 两路，
#      只放 USER_IBAT 会让 IBUS 的 force_active=1 残留。
#      （正常路径下开头的 "$BOOST restore" 已覆盖，这里是 stop 失败时的兜底。）
_pf="/data/adb/v2507a_charge_boost.profile"
if [ -f "$_pf" ]; then
	while IFS='=' read -r _k _v; do
		case "$_k" in
			VOTE_TARGETS|VOTE_TARGET)
				[ -n "$_v" ] || continue
				for _vt in $_v; do _vote_release "$_vt"; done
				;;
		esac
	done < "$_pf" 2>/dev/null
fi
# 全表扫干净（与 vfcs_boost 的 VOTE_TARGETS_KNOWN 保持一致）
_vote_release "DCHG_FCC"
_vote_release "USER_IBAT"
_vote_release "USER_INPUT"
_vote_release "USER_IBUS"

# ---- 1.5 防掉档还原：场景节点回 1、vivo 属性群回原值 ----
#   防掉档期间把 7 个 scene_ctrl 节点压成 0、并改了 5 个 persist.vivo.*
#   属性。不还原的话，卸载后系统仍处在"被压制"的状态（属性是 persist，
#   重启也不消失），等于卸载没卸干净。
#
# ★ v3.5.11：台账缺失时【什么都不写】——
#   旧实现无条件把 7 个场景节点写 1、5 个属性写 0、htccc_enable 强写 1。
#   但模块默认 CMS_GATES="" 根本不碰 htccc_enable，属性也只在
#   safe_props_apply 跑过之后才被改。从没生效过的机器上卸载，
#   这些写入纯属【把用户自己设的状态改掉】—— 卸载变成了改写。
#   现在只在台账里确实记过该项时才还原。
_g_orig=/data/adb/v2507a_charge_boost.guard_orig
_g_cms=/sys/class/cms_class
_g_get(){
	[ -f "$_g_orig" ] || { echo ""; return; }
	grep -m1 "^$1=" "$_g_orig" 2>/dev/null | sed 's/^[^=]*=//'
}
if [ -f "$_g_orig" ]; then
	# ★ v3530 修：原来这里无条件把 scene_ctrl/* 写 1、factory_mode_state 写 1。
	#   本机 /sys/class/cms_class/scene_ctrl/ 目录根本不存在（实测 No such file），
	#   所以 [ -w ... ] 全 false，实际不写 —— 但如果哪天 ROM 加上了这个目录，
	#   卸载就会把用户自己的场景开成 1。改为：只在台账里记过该项时才还原。
	for _s in factory_mode exhibition carlife calling weixin system_update pkg_pro; do
		_sv=$(_g_get "scene.$_s")
		[ -n "$_sv" ] || continue
		[ -w "$_g_cms/scene_ctrl/$_s" ] && echo "$_sv" > "$_g_cms/scene_ctrl/$_s" 2>/dev/null
	done
	_fm=$(_g_get "cms.factory_mode_state")
	if [ -n "$_fm" ] && [ -w "$_g_cms/factory_mode_state" ]; then
		echo "$_fm" > "$_g_cms/factory_mode_state" 2>/dev/null
	fi
# 注意：_g_cms/scene 不能写 —— V2405DA 实测它是"[名称]: 值"的文本列表节点，
#   写 0/1 会破坏格式，充电服务读取时可能异常。压制改由 htccc_enable + 属性群承担。
	# 温控投票：只在台账里记过时才还原（旧版无条件强写 1）
	_g_gate=$(_g_get "cms.htccc_enable")
	if [ -n "$_g_gate" ] && [ -f "$_g_cms/htccc_enable" ]; then
		echo "$_g_gate" > "$_g_cms/htccc_enable" 2>/dev/null
		echo "v2507a_charge_boost: restored htccc_enable=$_g_gate" \
			>> /data/adb/v2507a_charge_boost.log 2>/dev/null
	fi
else
	echo "v2507a_charge_boost: no guard backup; skipping scene/prop/htccc restore" \
		>> /data/adb/v2507a_charge_boost.log 2>/dev/null
fi
for _k in battery_charge_limit all_bypass_charge_support game_bypass_charge_flag \
          ai_charge_rate_support disable_intell_charge; do
	_o=$(_g_get "prop.$_k")
	# ★ 台账里没有这一项 = 模块从未改过它（safe_props_apply 才会写台账）
	#   旧实现缺省按 0 写回去，等于替用户"关掉充电限制"。
	if [ -z "$_o" ]; then
		continue
	fi
	setprop "persist.vivo.$_k" "$_o" 2>/dev/null
	echo "v2507a_charge_boost: restored persist.vivo.$_k=$_o" \
		>> /data/adb/v2507a_charge_boost.log 2>/dev/null
done
rm -f "$_g_orig" 2>/dev/null

# ---- 2. 清理所有运行时状态 ----
#   【为什么要连 status.json 一起删】
#   存着上一轮完整的 emit_json 快照（含节点值/温度/开关）。若卸载不清，
#   下次安装后 WebUI 在守护启动前会先读到这份过期快照，
#   显示的是"上一次安装的旧状态"，看起来像"装了没生效"。
rm -f /data/adb/v2507a_charge_boost.profile
rm -f /data/adb/v2507a_charge_boost.orig
rm -f /data/adb/v2507a_charge_boost.session
# voter 台账与会话标记：同清（台账存的是"注入前的 force 原值"，
#   留旧值会在下次安装时把过时值当成"当前原值"交回，写错）
rm -f /data/adb/v2507a_charge_boost.vot_orig
rm -f /data/adb/v2507a_charge_boost.vot_session
# ★ v3.5.11 补：votset 手动钉住目标的标记。
#   旧版漏清 → 卸载后重装，守护一启动就沿用上次钉的目标，
#   表现为"重装后行为与卸载前不一样"，且没有任何提示。
rm -f /data/adb/v2507a_charge_boost.vot_target
# 高压体系标记：卸载即清，下次安装重新观察本机
rm -f /data/adb/v2507a_charge_boost.highv
rm -f /data/adb/v2507a_charge_boost.keys.tmp
# 「临时解除加速」标记：卸载必清。
#   【为什么要清】留着的話，用户卸载后重装，守护一启动就看到该标记 →
#   撤掉干预后空转，表现为"装上就不工作"，极难排查。
rm -f /data/adb/v2507a_charge_boost.paused
# 守护缓存（见上方说明）
rm -f /data/adb/v2507a_charge_boost.status.json
rm -f /data/adb/v2507a_charge_boost.status.json.tmp
# ★ v3534：DT 表探测缓存。不清的话卸载后会在 /data/adb 留一个孤儿文件。
rm -f /data/adb/v2507a_charge_boost.dtcache
rm -f /data/adb/v2507a_charge_boost.dtcache.tmp
# 进程残留
rm -f /data/adb/v2507a_charge_boost.pid
rm -rf /data/adb/v2507a_charge_boost.lock
rm -f /data/adb/v2507a_charge_boost.baseline
rm -f /data/adb/v2507a_charge_boost.capture
rm -f /data/adb/v2507a_charge_boost.baseline.tmp.*

# ★ v3528 补：日志文件本身与轮转备份。
#   旧版只往 .log 里追加卸载记录，从不删除 —— 卸载后 /data/adb 会留下
#   一份几十 KB 的孤儿日志（实测已积累 92KB），重装后还会接着写，
#   日志里的"上一次安装"记录与本次混在一起，排查时极易误判。
rm -f /data/adb/v2507a_charge_boost.log
rm -f /data/adb/v2507a_charge_boost.log.1
rm -f /data/adb/v2507a_charge_boost.log.old

# ---- 3. 终局清扫：再杀一次守护与看门狗 ----
#   【为什么开头杀过还要再杀】开头清扫与"解除注入/还原属性"之间隔着
#   十几秒，看门狗只要有一个 15 秒窗口没被打断，就能把守护重新拉起来，
#   而新守护会看到刚删掉的 profile 已不存在 → 走默认值 → 再次注入。
#   收尾再清一次，保证"卸载返回之后"没有进程能复活干预。
_stop_watchdog
for p in $(ps -A -o pid,args 2>/dev/null | awk '
	$0 ~ /__daemon/ && ($0 ~ /vfcs_boost/ || $0 ~ /vb\.sh/) && $0 !~ /awk/ {print $1}'); do
	case "$p" in ''|*[!0-9]*) continue ;; esac
	kill -9 "$p" 2>/dev/null
done
rm -rf /data/adb/v2507a_charge_boost.lock

# ---- 4. 最终校验：节点是否真的交回了 ----
#   ★ v3530 修：原来这两行是 echo >> .log，但第 913 行刚刚才 rm -f 掉 .log，
#   于是「最终校验」和「卸载完成」这两条最关键记录写完即孤立，
#   下次重装后日志里根本没有「上一次是怎么卸的」——
#   这正是排查「卸载后快充异常」时最缺的一条证据。
#   现在改成先写，再重新落一份极简收尾日志（只留卸载结论，不保留历史噪音）。
_TAIL_LOG="/data/adb/v2507a_charge_boost.uninstall.log"
{
	echo "==== $(date '+%Y-%m-%d %H:%M:%S') module uninstall ===="
	echo "fchg_fcc_ma final value = $(cat "$NODE" 2>/dev/null)"
	echo "restore method = ${DONE}"
	echo "residual voter check:"
	for _t in DCHG_FCC USER_IBAT USER_INPUT USER_IBUS USB_ICL; do
		_dd="/sys/kernel/debug/pmic-votable/$_t"
		[ -d "$_dd" ] || continue
		echo "  $_t fa=$(cat "$_dd/force_active" 2>/dev/null) fv=$(cat "$_dd/force_val" 2>/dev/null)"
	done
	echo "remaining runtime files:"
	ls /data/adb/v2507a_charge_boost.* 2>/dev/null | sed 's/^/  /'
	echo "(should be empty or contain only this log)"
} > "$_TAIL_LOG" 2>/dev/null

exit 0
