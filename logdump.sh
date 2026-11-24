#!/system/bin/sh
#
# vivo V2352A 充电加速 · 日志导出（调试版）
#
# 触发方式：
#   1) 模块管理器里点【操作】按钮        (action.sh -> logs)
#   2) WebUI 里点「导出调试日志」
#   3) 命令行: su -c 'sh /data/adb/modules/v2352a_charge_boost/logdump.sh'
#
# 安全：全程只读。只往 /sdcard 写一个包，不动任何节点、
#       不改任何配置、不碰任何分区、不启停守护。
#
# 打包：本机无 zip 命令，用 toybox tar + gzip 生成 .tar.gz
# ------------------------------------------------------------------

MODDIR="${0%/*}"
# 模块目录三重探测：脚本可能被拷到别处执行（WebUI 调起等）
if [ ! -f "$MODDIR/module.prop" ]; then
	for _c in /data/adb/modules/v2352a_charge_boost /data/adb/modules_update/v2352a_charge_boost; do
		[ -f "$_c/module.prop" ] && { MODDIR="$_c"; break; }
	done
fi

BOOST="$MODDIR/system/bin/vfcs_boost"
[ -x "$BOOST" ] || BOOST="/system/bin/vfcs_boost"

LOG=/data/adb/v2352a_charge_boost.log
STAMP=$(date '+%Y%m%d_%H%M%S' 2>/dev/null)
[ -n "$STAMP" ] || STAMP=$(date '+%s' 2>/dev/null)

OUTDIR=/sdcard/Download
mkdir -p "$OUTDIR" 2>/dev/null
if ! : > "$OUTDIR/.wtest_v2352a" 2>/dev/null; then
	OUTDIR=/data/local/tmp
else
	rm -f "$OUTDIR/.wtest_v2352a" 2>/dev/null
fi

NAME="v2352a_dbg_$STAMP"
WORK="/data/local/tmp/$NAME"
OUT="$OUTDIR/$NAME.tar.gz"

mkdir -p "$WORK" 2>/dev/null || exit 1

say() { echo "$*"; }

# ------------------------------------------------------------------
# 0. 说明
# ------------------------------------------------------------------
{
	echo "vivo V2352A 充电加速 · 调试日志包"
	echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
	echo "模块目录: $MODDIR"
	echo ""
	echo "内容清单："
	echo "  00_README.txt          本文件"
	echo "  01_module_prop.txt     module.prop"
	echo "  02_debugdump.txt       vfcs_boost debugdump 完整快照"
	echo "  03_daemon.log          守护进程日志（含 .1 轮转备份）"
	echo "  04_config.txt          当前配置 + 全部运行时台账"
	echo "  05_votable.txt         判决层全部目标 + status 全量"
	echo "  06_dt_tables.txt       DT 表原始字节解码"
	echo "  07_sysfs_snapshot.txt  sysfs 关键节点当前值"
	echo "  08_dmesg.txt           dmesg 相关行"
	echo "  09_getprop.txt         相关属性"
	echo "  10_processes.txt       相关进程 + 守护存活判定"
	echo "  11_logcat.txt          与模块相关的 logcat（若有）"
	echo "  12_meta.txt            版本/机型/内核"
	echo ""
	echo "把整个包发出来即可。"
} > "$WORK/00_README.txt" 2>/dev/null

if [ -f "$MODDIR/module.prop" ]; then
	cp -f "$MODDIR/module.prop" "$WORK/01_module_prop.txt" 2>/dev/null
else
	echo "module.prop 不存在" > "$WORK/01_module_prop.txt"
fi

# ------------------------------------------------------------------
# 1. 主快照（最强的一块）
# ------------------------------------------------------------------
if [ -x "$BOOST" ]; then
	"$BOOST" debugdump > "$WORK/02_debugdump.txt" 2>&1
else
	echo "vfcs_boost 不存在或不可执行: $BOOST" > "$WORK/02_debugdump.txt"
fi

# ------------------------------------------------------------------
# 2. 守护日志
# ------------------------------------------------------------------
if [ -f "$LOG" ]; then
	cp -f "$LOG" "$WORK/03_daemon.log" 2>/dev/null
	[ -f "$LOG.1" ] && cat "$LOG.1" >> "$WORK/03_daemon.log" 2>/dev/null
else
	echo "（无日志文件 $LOG）" > "$WORK/03_daemon.log"
fi

# ------------------------------------------------------------------
# 3. 配置 + 运行时台账
# ------------------------------------------------------------------
{
	echo "===== profile ====="
	if [ -f /data/adb/v2352a_charge_boost.profile ]; then
		cat /data/adb/v2352a_charge_boost.profile 2>/dev/null
	else
		echo "（无 profile，走默认值）"
	fi
	echo ""
	echo "===== 运行时台账文件 ====="
	for f in /data/adb/v2352a_charge_boost.*; do
		[ -f "$f" ] || continue
		case "$f" in
			*.status.json)
				echo "--- $f ($(wc -c < "$f" 2>/dev/null) bytes，内容见 02_debugdump.txt)"
				continue ;;
			esac
		echo "--- $f ($(wc -c < "$f" 2>/dev/null) bytes)"
		sed 's/^/    /' "$f" 2>/dev/null | head -80
	done
} > "$WORK/04_config.txt" 2>&1

# ------------------------------------------------------------------
# 4. 判决层全量
# ------------------------------------------------------------------
{
	V=/sys/kernel/debug/pmic-votable
	[ -d "$V" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
	if [ -d "$V" ]; then
		echo "根目录: $V"
		for d in "$V"/*; do
			[ -d "$d" ] || continue
			n=${d##*/}
			echo ""
			echo "================ [$n] ================"
			echo "force_active = $(cat "$d/force_active" 2>/dev/null)"
			echo "force_val    = $(cat "$d/force_val" 2>/dev/null)"
			echo "--- status ---"
			cat "$d/status" 2>/dev/null
		done
	else
		echo "pmic-votable 不存在（debugfs 未挂载或无该通道）"
	fi
} > "$WORK/05_votable.txt" 2>&1

# ------------------------------------------------------------------
# 5. DT 表原始解码
# ------------------------------------------------------------------
{
	B=/sys/firmware/devicetree/base/soc/qcom,pmic_glink/cms_v5
	echo "===== 本机 DT 表原始解码（big-endian uint32）====="
	echo "路径: $B"
	echo ""
	for sub in "" "/single_charger_board"; do
		D="$B$sub"
		[ -d "$D" ] || continue
		for f in "$D"/vivo,aging-normal-tc-data-* "$D"/vivo,normal-tc-data "$D"/vivo,batt-aging-cycle-range "$D"/vivo,soh-cycle-table; do
			[ -r "$f" ] || continue
			echo "---------- ${f##*/}  ($(wc -c < "$f" 2>/dev/null) bytes) ----------"
			od -An -tu1 -v "$f" 2>/dev/null | awk '{ for(i=1;i<=NF;i++) b[++c]=$i } END { n=int(c/4); for(k=0;k<n;k++){ p=k*4+1; v=b[p]*16777216+b[p+1]*65536+b[p+2]*256+b[p+3]; printf "%s ", v; if((k+1)%11==0) printf "\n" } printf "\n" }'
			echo ""
		done
	done
	echo "===== 全局上限节点 ====="
	for f in /sys/firmware/devicetree/base/soc/vfcs/vivo,fchg-curr-max-ma /sys/firmware/devicetree/base/vfcs/vivo,fchg-curr-max-ma /sys/firmware/devicetree/base/vivo,fchg-curr-max-ma; do
		[ -r "$f" ] || continue
		echo "$f = $(od -An -tu1 -v "$f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')"
	done
} > "$WORK/06_dt_tables.txt" 2>&1

# ------------------------------------------------------------------
# 6. sysfs 快照
# ------------------------------------------------------------------
{
	echo "===== /sys/class/vfcs_class ====="
	for f in /sys/class/vfcs_class/*; do
		[ -f "$f" ] || continue
		printf '%-24s = %s\n' "${f##*/}" "$(cat "$f" 2>/dev/null | head -c 200 | tr '\n' '|')"
	done
	echo ""
	echo "===== battery 关键项 ====="
	for n in status present capacity voltage_now current_now current_avg temp health charge_counter charge_full charge_full_design cycle_count chg_voltage charger_voltage chg_type charging_speed voltage_max soc_decimal power_now; do
		f="/sys/class/power_supply/battery/$n"
		[ -e "$f" ] || continue
		printf '%-24s = %s\n' "$n" "$(cat "$f" 2>/dev/null)"
	done
	echo ""
	echo "===== usb ====="
	for n in online present voltage_now current_now voltage_max usb_type type; do
		f="/sys/class/power_supply/usb/$n"
		[ -e "$f" ] || continue
		printf '%-24s = %s\n' "usb/$n" "$(cat "$f" 2>/dev/null)"
	done
	echo ""
	echo "===== cms_class 关键项 ====="
	for n in htccc_enable factory_mode_state scene_mode scene_level scene_disable fastchg_current_now fastchg_is_ok adapter_power vfloat_voltage charging_technology charging_speed primary_board_temp main_batt_temp sub_batt_temp bat_btb_therm chg_pmos_temp battery_health_cyclecount battery_health_learning_soh cms_enable disable_charge; do
		f="/sys/class/cms_class/$n"
		[ -e "$f" ] || continue
		printf '%-24s = %s\n' "$n" "$(cat "$f" 2>/dev/null | head -c 300 | tr '\n' '|')"
	done
	echo ""
	echo "===== thermal_zone ====="
	for z in /sys/class/thermal/thermal_zone*; do
		[ -d "$z" ] || continue
		t=$(cat "$z/type" 2>/dev/null)
		v=$(cat "$z/temp" 2>/dev/null)
		[ -n "$t" ] && printf '%-10s %-26s %s\n' "${z##*/}" "$t" "$v"
	done
} > "$WORK/07_sysfs_snapshot.txt" 2>&1

# ------------------------------------------------------------------
# 7. dmesg
# ------------------------------------------------------------------
{
	echo "===== 充电 / 老化 / voter（最近 500 条）====="
	dmesg 2>/dev/null | grep -iE 'cms_v5|cms_check|aging|vfcs|voter|fchg_fcc|force_active|USER_FCC' | tail -n 500
} > "$WORK/08_dmesg.txt" 2>&1

# ------------------------------------------------------------------
# 8. 属性
# ------------------------------------------------------------------
{
	getprop 2>/dev/null | grep -iE 'vivo|bbk|charge|batt|ro.product.model|build.version|board.platform'
} > "$WORK/09_getprop.txt" 2>&1

# ------------------------------------------------------------------
# 9. 进程
# ------------------------------------------------------------------
{
	echo "===== 模块相关进程 ====="
	ps -A -o pid,ppid,args 2>/dev/null | grep -iE 'vfcs_boost|v2352a|__daemon' | grep -v grep
	echo ""
	echo "===== 守护存活判定 ====="
	if [ -f /data/adb/v2352a_charge_boost.pid ]; then
		p=$(cat /data/adb/v2352a_charge_boost.pid 2>/dev/null)
		echo "pidfile = $p"
		if kill -0 "$p" 2>/dev/null; then echo "存活: 是"; else echo "存活: 否（僵尸 pidfile）"; fi
	else
		echo "无 pidfile（守护未启动或在原厂档）"
	fi
} > "$WORK/10_processes.txt" 2>&1

# ------------------------------------------------------------------
# 10. logcat（尽力而为，可能为空）
# ------------------------------------------------------------------
if command -v logcat >/dev/null 2>&1; then
	logcat -d -t 800 2>/dev/null | grep -iE 'vivo.*charg|vfcs|cms_v5|batt' | tail -n 400 > "$WORK/11_logcat.txt" 2>/dev/null
fi
[ -s "$WORK/11_logcat.txt" ] || echo "（logcat 无相关行或不可用）" > "$WORK/11_logcat.txt"

# ------------------------------------------------------------------
# 11. 元信息
# ------------------------------------------------------------------
{
	echo "===== 模块 ====="
	echo "name        : $(sed -n 's/^name=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo "version     : $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo "versionCode : $(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo ""
	echo "===== 设备 ====="
	echo "ro.product.model        = $(getprop ro.product.model)"
	echo "ro.product.model.bbk    = $(getprop ro.product.model.bbk)"
	echo "ro.product.vendor.model = $(getprop ro.product.vendor.model)"
	echo "ro.build.version.release= $(getprop ro.build.version.release)"
	echo "ro.build.version.sdk    = $(getprop ro.build.version.sdk)"
	echo "ro.build.display.id     = $(getprop ro.build.display.id)"
	echo "ro.board.platform       = $(getprop ro.board.platform)"
	echo "ro.build.fingerprint    = $(getprop ro.build.fingerprint)"
	echo ""
	uname -a 2>/dev/null
	echo ""
	echo "boot_id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
	echo "uptime : $(uptime 2>/dev/null)"
} > "$WORK/12_meta.txt" 2>&1

# ------------------------------------------------------------------
# 12. 打包（toybox tar + gzip）
# ------------------------------------------------------------------
PARENT=$(dirname "$WORK")
BASE=$(basename "$WORK")
OUT="$OUTDIR/$BASE.tar.gz"

tar -czf "$OUT" -C "$PARENT" "$BASE" 2>/dev/null
RC=$?

if [ "$RC" = "0" ] && [ -s "$OUT" ]; then
	SZ=$(wc -c < "$OUT" 2>/dev/null)
	say "=================================================="
	say " 调试日志包已生成"
	say "=================================================="
	say ""
	say " 文件: $OUT"
	say " 大小: $SZ 字节"
	say " 原始: $WORK"
	say ""
	say " 把这个文件发出去即可（手机任意解压工具可开）"
	say " 不需要原始目录时可手动删除。"
	say "=================================================="
	RESULT_PATH="$OUT"
else
	say "!! 打包失败（rc=$RC）。原始文件在：$WORK"
	say "   可直接从该目录逐个取用。"
	RESULT_PATH="$WORK"
fi

# 供 WebUI / action.sh 解析的一行标记
echo "DUMP_PATH=$RESULT_PATH"

exit 0
