
MODDIR="${0%/*}"
BOOST="$MODDIR/system/bin/vfcs_boost"
# 模块可能装在非标准路径，回退到模块目录
[ -x "$BOOST" ] || BOOST="/data/adb/modules/v2507a_charge_boost/system/bin/vfcs_boost"

NODE="/sys/class/vfcs_class/fchg_fcc_ma"
PROFILE_FILE="/data/adb/v2507a_charge_boost.profile"
PIDFILE="/data/adb/v2507a_charge_boost.pid"
KEYFILE="/data/adb/v2507a_charge_boost.keys.tmp"
RESTORE_MA=0

READ_TIMEOUT=15     # Menu inactivity timeout (seconds)
COMBO_MS=400        # Simultaneous Vol+ & Vol- threshold (ms)
STAYON_MS=600000    # Temporary screen timeout during menu (10 min)

# Screen timeout backup state (restored on exit)
ORIG_TIMEOUT=""     # Original screen_off_timeout
SCREEN_CHANGED=0    # Whether screen timeout was modified

# ============================================================
#  熄屏控制（菜单期间保持亮屏）
# ============================================================
#
# 【为什么要做这个】
#   菜单要用户看着屏幕操作，如果中途熄屏就完全没法用了。
#   默认熄屏超时通常 30 秒~1 分钟，而我们的菜单最长要等 15 秒，
#   期间还要多次按键，很容易超时。
#
# 【做法】两层，都会在退出时恢复：
#   1. svc power stayon true      -> 插着充电器时保持常亮
#   2. screen_off_timeout 拉长     -> 兜底
#
# 【注意】只改 system 数据库的 screen_off_timeout（用户级设置），
#   不动任何分区、不改系统文件，退出时写回原值。

screen_keepon() {
	# 记录原始熄屏超时
	ORIG_TIMEOUT=$(settings get system screen_off_timeout 2>/dev/null)
	case "$ORIG_TIMEOUT" in
		''|*[!0-9-]*) ORIG_TIMEOUT="" ;;   # Ignore if unreadable
	esac

	# 清理函数只设一次。
	# ★ v3.5.11：把 stop_keyreader 也挂进 trap。
	#   旧版 trap 只有 restore_screen —— 脚本被 Ctrl-C、被管理器杀掉、
	#   或 read_key 里 sleep 被打断时退出，getevent 会成为孤儿继续
	#   持有 /dev/input/event*（音量键被这个进程吃掉，用户按音量没反应）。
	#   退出清理必须【两个都做】，且顺序为先停按键读取、后恢复熄屏。
	trap '_cleanup_all' EXIT INT TERM HUP

	# 1) 充电时常亮
	if command -v svc >/dev/null 2>&1; then
		svc power stayon true 2>/dev/null
		SCREEN_CHANGED=1
	fi

	# 2) 拉长熄屏超时
	if command -v settings >/dev/null 2>&1 && [ -n "$ORIG_TIMEOUT" ]; then
		settings put system screen_off_timeout "$STAYON_MS" 2>/dev/null \
			&& SCREEN_CHANGED=1
	fi
}

# 恢复熄屏设置（退出时必调）
restore_screen() {
	[ "$SCREEN_CHANGED" = "1" ] || return 0
	SCREEN_CHANGED=0

	# 恢复熄屏超时（只在原来成功读到值时恢复）
	if [ -n "$ORIG_TIMEOUT" ]; then
		settings put system screen_off_timeout "$ORIG_TIMEOUT" 2>/dev/null
	fi

	if command -v svc >/dev/null 2>&1; then
		svc power stayon false 2>/dev/null
	fi
}

# ============================================================
#  音量键读取
# ============================================================
# 【实现要点】getevent 会独占消费按键事件（正好避免改系统音量），
# 但不能用"管道 + read 超时"——shell 没有内建超时，
# 而 timeout 命令在部分 ROM 上缺失。
# 所以用：后台 getevent 追加写临时文件 + 前台轮询读取。

KEY_PID=""
KEY_GETEVENT_PID=""

start_keyreader() {
	# 先探测能力，再动文件——这样失败原因清晰（是没工具还是没权限）
	command -v getevent >/dev/null 2>&1 || return 1
	ls /dev/input/event* >/dev/null 2>&1 || return 1

	# 临时文件放在 /data/adb（与模块其他运行时文件同目录）
	rm -f "$KEYFILE" 2>/dev/null
	: > "$KEYFILE" 2>/dev/null || return 1

	(
		getevent -l 2>/dev/null | while read -r line; do
			case "$line" in
				*KEY_VOLUMEUP*DOWN*)
					echo "up $(now_ms)"   >> "$KEYFILE" ;;
				*KEY_VOLUMEDOWN*DOWN*)
					echo "down $(now_ms)" >> "$KEYFILE" ;;
			esac
		done
	) &
	KEY_PID=$!

	# ★ v3.5.11：把 getevent 自己的 pid【精确】抓出来（按父子关系认领）。
	#   管道里 getevent 是 while 循环的子进程，kill 掉子 shell（KEY_PID）
	#   并不会连带杀掉它 —— 它会继续持有 /dev/input/event* ，其他需要
	#   按键的应用（游戏、输入法、手势）就读不到音量键了。
	#   【为什么按 PPID 认领而不是按命令行搜 "getevent"】
	#     系统里可能还有别的进程也在跑 getevent（录屏/无障碍服务），
	#     按名字抓会抓错别人。KEY_PID 是我们那个子 shell，
	#     它的直接子进程里那个 getevent 才是我们的。
	#     注：这里不按"名字"匹配，而是列出 KEY_PID 的子进程，
	#     命令行里含 getevent 即认为是我们的。
	_sleep=0
	while [ "$_sleep" -lt 10 ]; do
		_ge=""
		for d in /proc/[0-9]*; do
			p=${d#/proc/}
			case "$p" in ''|*[!0-9]*) continue ;; esac
			_ppid=$(sed -n 's/^[0-9]* (.*) [A-Z] \([0-9]*\).*/\1/p' "$d/stat" 2>/dev/null)
			[ "$_ppid" = "$KEY_PID" ] || continue
			c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
			case "$c" in
				*getevent*) _ge="$p"; break ;;
			esac
		done
		case "$_ge" in
			''|*[!0-9]*) ;;
			*) KEY_GETEVENT_PID="$_ge"; break ;;
		esac
		sleep 1
		_sleep=$((_sleep + 1))
	done
	unset _sleep _ge _p _ppid c d

	return 0
}

stop_keyreader() {
	[ -n "$KEY_PID" ] && kill "$KEY_PID" 2>/dev/null

	# ★ v3.5.11：不再 pkill -f "getevent"（全局杀）。
	#   旧写法会连带杀掉【别的进程】的 getevent：某些应用/脚本/输入法
	#   也常驻 getevent（比如录屏、无障碍服务），在菜单退出的一瞬间
	#   把它们一起干掉，症状是"用完这个模块之后别的应用读不到按键了"。
	#   现在只杀自己拉起的那一个。
	if [ -n "$KEY_GETEVENT_PID" ]; then
		kill "$KEY_GETEVENT_PID" 2>/dev/null
	fi

	# 兜底：KEY_PID 的子进程里若还有 getevent（PID 认领失败），
	#   按【父子关系】再扫一次 —— 绝不按进程名全局杀。
	for d in /proc/[0-9]*; do
		p=${d#/proc/}
		case "$p" in ''|*[!0-9]*) continue ;; esac
		[ -n "$KEY_PID" ] || continue
		_ppid=$(sed -n 's/^[0-9]* (.*) [A-Z] \([0-9]*\).*/\1/p' "$d/stat" 2>/dev/null)
		[ "$_ppid" = "$KEY_PID" ] || continue
		c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
		case "$c" in
			*getevent*) kill -9 "$p" 2>/dev/null ;;
		esac
	done

	rm -f "$KEYFILE" "${KEYFILE}.x" 2>/dev/null
	KEY_PID=""
	KEY_GETEVENT_PID=""
}

# 统一退出清理：先停按键读取（别再吃掉音量键），再恢复熄屏设置。
# 幂等 —— 重复调用安全（stop_keyreader / restore_screen 都会清自己的标志）。
_cleanup_all() {
	stop_keyreader
	restore_screen
}

# 取当前时间的毫秒数
# 优先 date +%s%3N（toybox 支持），不支持时退回秒×1000。
#
# ★ v3.5.11：退化时【明确放弃组合键判定】，而不是拿秒级时间戳去比 400ms。
#   秒级时间戳下，同一秒内按下的上/下两键 diff 恒为 0 <= 400 → 必判 confirm。
#   于是菜单会随机把"先按上再按下"当成确认，直接切档。
#   现在置 MS_OK=0，调用方据此关闭组合键（只认单键），行为可预期。
MS_OK=1
now_ms() {
	local ms
	ms=$(date +%s%3N 2>/dev/null)
	case "$ms" in
		''|*[!0-9]*)
			MS_OK=0
			ms=$(date +%s 2>/dev/null)
			case "$ms" in ''|*[!0-9]*) ms=0 ;; esac
			echo $((ms * 1000))
			;;
		*) echo "$ms" ;;
	esac
}

# 读一个按键，识别"上+下同时按"组合键
# 参数: $1 = 超时秒数   $2 = 是否清空历史(1=清空)
# 输出: up / down / confirm / ""(超时)
#
# 【组合键判定逻辑】
#   读取队列里的按键，每个带时间戳。判定规则：
#     · 若 up 和 down 的时间戳相差 <= COMBO_MS  -> confirm
#     · 否则按先到的那个当作单键（up / down）
#     · 队列里剩余的按键留给下一次调用（不清空）
#
# 【为什么要带时间戳】
#   上+下同时按在硬件上必然有先后（几十毫秒级），
#   不能用"同一个轮询周期内出现两个事件"来判断——
#   那样会因为队列刷新时机不同而漏判。
#   用时间戳差 <= 400ms 才是可靠的判据。
read_key() {
	local timeout=$1 clear=$2 t=0
	local line1 k1 t1 line2 k2 t2 diff
	local maxiter=$((timeout * 10))

	[ "$clear" = "1" ] && : > "$KEYFILE" 2>/dev/null

	while [ "$t" -lt "$maxiter" ]; do
		if [ -s "$KEYFILE" ]; then
			line1=$(head -n 1 "$KEYFILE" 2>/dev/null)
			if [ -n "$line1" ]; then
				k1=${line1%% *}
				t1=${line1##* }
				case "$t1" in ''|*[!0-9]*) t1=0 ;; esac

				# 消费掉这一行
				tail -n +2 "$KEYFILE" > "${KEYFILE}.x" 2>/dev/null &&
					mv -f "${KEYFILE}.x" "$KEYFILE" 2>/dev/null

				# 再等一下，看有没有配对的另一个键（组合键）
				line2=""
				t=0
				while [ "$t" -lt 8 ]; do          # Wait up to 800ms
					line2=$(head -n 1 "$KEYFILE" 2>/dev/null)
					[ -n "$line2" ] && break
					sleep 0.1 2>/dev/null || sleep 1
					t=$((t + 1))
				done

				if [ -n "$line2" ]; then
					k2=${line2%% *}
					t2=${line2##* }
					case "$t2" in ''|*[!0-9]*) t2=0 ;; esac

					# 两个键不同向，且时间够近 -> 组合键确认
					# ★ v3.5.11：毫秒时钟不可用时（MS_OK=0）不做组合键判定。
					#   秒级时间戳会让同一秒内的上/下两键 diff=0 → 必判 confirm，
					#   菜单就会把"先上后下"误判成确认并直接切档（随机行为）。
					#   此时宁可要求用户真正同时按，也比随机切档安全。
					if [ "$k1" != "$k2" ] && [ "$MS_OK" = "1" ]; then
						if [ "$t1" -le "$t2" ]; then
							diff=$((t2 - t1))
						else
							diff=$((t1 - t2))
						fi
						if [ "$diff" -le "$COMBO_MS" ]; then
							# 消费掉第二个
							tail -n +2 "$KEYFILE" > "${KEYFILE}.x" 2>/dev/null &&
								mv -f "${KEYFILE}.x" "$KEYFILE" 2>/dev/null
							echo "confirm"
							return 0
						fi
					fi
					# 不是组合键：第二个键留着给下次调用
				fi

				echo "$k1"
				return 0
			fi
		fi
		sleep 0.1 2>/dev/null || sleep 1
		t=$((t + 1))
	done
	echo ""
	return 1
}

# ============================================================
#  状态查询
# ============================================================
cur_active() {
	local a=1 k v
	if [ -f "$PROFILE_FILE" ]; then
		while IFS='=' read -r k v; do
			case "$k" in
				ACTIVE)
					case "$v" in
						1|2|3) a="$v" ;;
					esac
					;;
			esac
		done < "$PROFILE_FILE" 2>/dev/null
	fi
	echo "$a"
}

# 档位号 -> 显示名
profile_label() {
	case "$1" in
		1) echo "Aggressive" ;;
		2) echo "Balanced" ;;
		3) echo "Stock" ;;
		*) echo "Unknown" ;;
	esac
}

daemon_running() {
	[ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

# ============================================================
#  Menu rendering
# ============================================================
draw_menu() {
	local cur=$1 active name mark

	active=$(cur_active)

	echo ""
	echo "========================================"
	echo "  iQOO Z10 Turbo+ Charge Boost (V2507A)"
	echo "  iQOO Z10 Turbo+ · Native V2507A Build"
	echo "========================================"
	echo ""
	echo "  Vol Up / Vol Down       Select profile"
	echo "  Vol Up + Down (both)    Confirm"
	echo ""
	echo "----------------------------------------"
	local n
	for n in 1 2 3; do
		name=$(profile_label "$n")
		mark=""
		[ "$n" = "$active" ] && mark="  <- Active"
		if [ "$n" = "$cur" ]; then
			printf " ==>  %d. %s%s\n" "$n" "$name" "$mark"
		else
			printf "      %d. %s%s\n" "$n" "$name" "$mark"
		fi
	done
	echo "----------------------------------------"
	if daemon_running; then
		echo "  Boost service: Running"
	else
		echo "  Boost service: Stopped"
	fi
	echo "========================================"
	echo ""
}

# ============================================================
#  应用档位
# ============================================================
apply_profile() {
	local a=$1

	if [ "$a" = "3" ]; then
		# ---- 原厂档：停止干预 ----
		#     ① 按 DT 档位表写回本机原厂分段电流
		#     ② 写回原始值备份  ③ 9720 兜底
		#   并且会全量清扫守护实例。所以这里【不需要】再手工写节点 ——
		#   手工写 RESTORE_MA 反而会把 ①② 两条更好的路径覆盖掉，
		#   等于强行降级成兜底常量。
		"$BOOST" profile write 3 >/dev/null 2>&1
		"$BOOST" stop >/dev/null 2>&1
		rm -f "$PIDFILE" 2>/dev/null
		return 0
	fi

	# ---- 激进 / 温和：写配置 + 热重载 ----
	"$BOOST" profile write "$a" >/dev/null 2>&1

	if daemon_running; then
		# 守护进程会在 2 秒内检测到 mtime 变化并热重载，不重启进程。
		# 这样节点值不会跳变（重启会先写 9720 再跳到新值）。
		:
	else
		# 之前是原厂档（守护未运行），需要重新拉起
		"$BOOST" start >/dev/null 2>&1
	fi
	return 0
}

# 应用后的结果描述
after_apply() {
	local a=$1
	case "$a" in
		1) echo "Switched to: Aggressive (Default)" ;;
		2) echo "Switched to: Balanced" ;;
		3) echo "Switched to: Stock" ;;
	esac
	if daemon_running; then
		echo "  Boost service: Running"
	else
		echo "  Boost service: Stopped"
	fi
	echo ""
	echo "  Charge in a cool environment and avoid heavy gaming while charging,"
	echo "  as high device temperature triggers earlier system throttling."
	echo ""
	echo "  Tap the Action button again anytime to switch profiles."
	echo "  If issues occur, uninstall the module, reboot, and reinstall."
}

# ============================================================
#  Fallback exit
# ============================================================
fallback_exit() {
	echo ""
	echo "========================================"
	echo "  Unable to read volume keys"
	echo "========================================"
	echo ""
	echo "  Volume key input is unsupported in this environment."
	echo "  No settings were modified."
	echo ""
	echo "  Current profile: $(profile_label "$(cur_active)")"
	echo ""
	echo "  Try uninstalling, rebooting, and reinstalling the module,"
	echo "  or switch profiles via the WebUI instead."
	echo ""
	echo "========================================"
	echo ""
	sleep 12
	exit 0
}

# ============================================================
#  主流程
# ============================================================
main() {
	# ============================================================
	#  ★ 调试版：参数直达日志导出 ★
	# ------------------------------------------------------------
	#  `sh action.sh logs`  -> 直接导出调试日志包，不进音量键菜单。
	#  给 WebUI 按钮 / 命令行 / 桌面快捷方式调用。
	#  全程只读，只往 /sdcard 写一个包。
	# ============================================================
	case "$1" in
		logs|logdump|dump)
			echo ""
			echo "========================================"
			echo "  iQOO Z10 Turbo+ Charge Boost · Debug Export"
			echo "========================================"
			echo ""
			DUMP_SH="$MODDIR/logdump.sh"
			[ -x "$DUMP_SH" ] || DUMP_SH="/data/adb/modules/v2507a_charge_boost/logdump.sh"
			if [ ! -f "$DUMP_SH" ]; then
				echo "!! logdump.sh not found"
				echo "   Expected path: $DUMP_SH"
				echo ""
				sleep 8
				exit 1
			fi
			sh "$DUMP_SH"
			RC=$?
			echo ""
			if [ "$RC" = "0" ]; then
				echo "  Note: archive saved to /sdcard/Download,"
				echo "  named like v2507a_dbg_DATE_TIME.tar.gz"
			fi
			echo ""
			echo "  Exiting shortly…"
			sleep 10
			exit 0
			;;
	esac

	# Keep screen awake during menu (restored on exit)
	screen_keepon

	# Wake screen if possible
	command -v input >/dev/null 2>&1 && input keyevent 224 2>/dev/null

	# Missing node means module did not initialize cleanly
	if [ ! -e "$NODE" ]; then
		echo ""
		echo "!! Boost service not ready. Ensure module is installed and rebooted."
		echo ""
		sleep 8
		exit 1
	fi

	if ! start_keyreader; then
		fallback_exit
	fi

	# ★ v3.5.11: detect millisecond clock in main process.
	now_ms >/dev/null 2>&1
	if [ "$MS_OK" != "1" ]; then
		echo "  Note: date lacks millisecond precision; combo detection disabled"
		echo "  (Press Vol+ and Vol- truly together, or use the WebUI instead)"
		echo ""
	fi

	local cur key
	cur=$(cur_active)

	while true; do
		draw_menu "$cur"

		key=$(read_key "$READ_TIMEOUT" 1)

		case "$key" in
			"")
				echo "  Timed out; cancelled with no changes."
				echo ""
				break
				;;
			confirm)
				echo "  Applying..."
				echo ""
				apply_profile "$cur"
				after_apply "$cur"
				break
				;;
			up)
				if [ "$cur" -gt 1 ]; then
					cur=$((cur - 1))
				else
					echo "  Already at top item"
				fi
				;;
			down)
				if [ "$cur" -lt 3 ]; then
					cur=$((cur + 1))
				else
					echo "  Already at bottom item"
				fi
				;;
		esac
	done

	stop_keyreader
	exit 0
}

main "$@"