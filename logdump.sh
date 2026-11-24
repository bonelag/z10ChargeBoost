#!/system/bin/sh
#
# vivo V2507A 充电加速 · 日志导出（调试版）
#
# 触发方式：
#   1) 模块管理器里点【操作】按钮        (action.sh -> logs)
#   2) WebUI 里点「导出调试日志」
#   3) 命令行: su -c 'sh /data/adb/modules/v2507a_charge_boost/logdump.sh'
#
# 安全：全程只读。只往 /sdcard 写一个包，不动任何节点、
#       不改任何配置、不碰任何分区、不启停守护。
#
# 打包：本机无 zip 命令，用 toybox tar + gzip 生成 .tar.gz
# ------------------------------------------------------------------

MODDIR="${0%/*}"
# 模块目录三重探测：脚本可能被拷到别处执行（WebUI 调起等）
if [ ! -f "$MODDIR/module.prop" ]; then
	for _c in /data/adb/modules/v2507a_charge_boost /data/adb/modules_update/v2507a_charge_boost; do
		[ -f "$_c/module.prop" ] && { MODDIR="$_c"; break; }
	done
fi

BOOST="$MODDIR/system/bin/vfcs_boost"
[ -x "$BOOST" ] || BOOST="/system/bin/vfcs_boost"

LOG=/data/adb/v2507a_charge_boost.log
STAMP=$(date '+%Y%m%d_%H%M%S' 2>/dev/null)
[ -n "$STAMP" ] || STAMP=$(date '+%s' 2>/dev/null)

OUTDIR=/sdcard/Download
mkdir -p "$OUTDIR" 2>/dev/null
if ! : > "$OUTDIR/.wtest_v2507a" 2>/dev/null; then
	OUTDIR=/data/local/tmp
else
	rm -f "$OUTDIR/.wtest_v2507a" 2>/dev/null
fi

NAME="v2507a_dbg_$STAMP"
WORK="/data/local/tmp/$NAME"
OUT="$OUTDIR/$NAME.tar.gz"

mkdir -p "$WORK" 2>/dev/null || exit 1

say() { echo "$*"; }

# ------------------------------------------------------------------
# 0. Overview
# ------------------------------------------------------------------
{
	echo "vivo V2507A Charge Boost · Debug Log Bundle"
	echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
	echo "Module dir: $MODDIR"
	echo ""
	echo "Contents:"
	echo "  00_README.txt          This file"
	echo "  01_module_prop.txt     module.prop"
	echo "  02_debugdump.txt       vfcs_boost debugdump full snapshot"
	echo "  03_daemon.log          Daemon log (incl. .1 rotated backup)"
	echo "  04_config.txt          Current config + all runtime ledgers"
	echo "  05_votable.txt         All voter targets + full status"
	echo "  06_dt_tables.txt       DT table raw byte decode"
	echo "  07_sysfs_snapshot.txt  Current values of key sysfs nodes"
	echo "  08_dmesg.txt           Relevant dmesg lines"
	echo "  09_getprop.txt         Relevant properties"
	echo "  10_processes.txt       Related processes + daemon liveness check"
	echo "  11_logcat.txt          Module-related logcat (if any)"
	echo "  12_meta.txt            Version/model/kernel"
	echo ""
	echo "Send the entire bundle archive."
} > "$WORK/00_README.txt" 2>/dev/null

if [ -f "$MODDIR/module.prop" ]; then
	cp -f "$MODDIR/module.prop" "$WORK/01_module_prop.txt" 2>/dev/null
else
	echo "module.prop not found" > "$WORK/01_module_prop.txt"
fi

# ------------------------------------------------------------------
# 1. Main snapshot
# ------------------------------------------------------------------
if [ -x "$BOOST" ]; then
	"$BOOST" debugdump > "$WORK/02_debugdump.txt" 2>&1
else
	echo "vfcs_boost missing or not executable: $BOOST" > "$WORK/02_debugdump.txt"
fi

# ------------------------------------------------------------------
# 2. Daemon log
# ------------------------------------------------------------------
if [ -f "$LOG" ]; then
	cp -f "$LOG" "$WORK/03_daemon.log" 2>/dev/null
	[ -f "$LOG.1" ] && cat "$LOG.1" >> "$WORK/03_daemon.log" 2>/dev/null
else
	echo "(No log file $LOG)" > "$WORK/03_daemon.log"
fi

# ------------------------------------------------------------------
# 3. Config + runtime ledgers
# ------------------------------------------------------------------
{
	echo "===== profile ====="
	if [ -f /data/adb/v2507a_charge_boost.profile ]; then
		cat /data/adb/v2507a_charge_boost.profile 2>/dev/null
	else
		echo "(No profile, using defaults)"
	fi
	echo ""
	echo "===== Runtime ledger files ====="
	for f in /data/adb/v2507a_charge_boost.*; do
		[ -f "$f" ] || continue
		case "$f" in
			*.status.json)
				echo "--- $f ($(wc -c < "$f" 2>/dev/null) bytes, content in 02_debugdump.txt)"
				continue ;;
			esac
		echo "--- $f ($(wc -c < "$f" 2>/dev/null) bytes)"
		sed 's/^/    /' "$f" 2>/dev/null | head -80
	done
} > "$WORK/04_config.txt" 2>&1

# ------------------------------------------------------------------
# 4. Voter layer / VFCS channel state
# ------------------------------------------------------------------
{
	echo "===== vfcs_class direct-control mapping (DCHG_FCC / VFCS_CLASS_EVENT) ====="
	for n in fchg_fcc_ma fchg_disable debug_main_sm chg_protocol_support debug_chg_protocol_support; do
		f="/sys/class/vfcs_class/$n"
		[ -e "$f" ] && printf '%-28s = %s\n' "$n" "$(cat "$f" 2>/dev/null)"
	done
	echo ""
	V=/sys/kernel/debug/pmic-votable
	[ -d "$V" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
	if [ -d "$V" ]; then
		echo "Root dir: $V"
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
		echo "pmic-votable missing or empty (Dimensity MT6991 uses vfcs_class/fchg_fcc_ma channel)"
	fi
} > "$WORK/05_votable.txt" 2>&1

# ------------------------------------------------------------------
# 5. Raw DT table decoding
# ------------------------------------------------------------------
{
	echo "===== Raw Device Tree table dump (big-endian uint32) ====="
	for D in \
		/sys/firmware/devicetree/base/vfcs_cms \
		/sys/firmware/devicetree/base/soc/qcom,pmic_glink/cms_v5 \
		/sys/firmware/devicetree/base/soc/qcom,pmic_glink/cms_v5/single_charger_board; do
		[ -d "$D" ] || continue
		echo "Dir: $D"
		for f in "$D"/vivo,aging-normal-tc-data-* "$D"/vivo,aging1-normal-tc-data-* "$D"/vivo,normal-tc-data-* "$D"/vivo,normal-tc-data "$D"/vivo,sp-primary-fbon-tc-data "$D"/vivo,sp-primary-fboff-tc-data "$D"/vivo,bat-aging-cycle-range "$D"/vivo,batt-aging-cycle-range "$D"/vivo,soh-cycle-table; do
			[ -r "$f" ] || continue
			echo "---------- ${f##*/}  ($(wc -c < "$f" 2>/dev/null) bytes) ----------"
			od -An -tu1 -v "$f" 2>/dev/null | awk '{ for(i=1;i<=NF;i++) b[++c]=$i } END { n=int(c/4); for(k=0;k<n;k++){ p=k*4+1; v=b[p]*16777216+b[p+1]*65536+b[p+2]*256+b[p+3]; printf "%s ", v; if((k+1)%11==0) printf "\n" } printf "\n" }'
			echo ""
		done
	done
	echo "===== Global limit & protocol DT nodes ====="
	for f in \
		/sys/firmware/devicetree/base/vfcs/vivo,fchg-curr-max-ma \
		/sys/firmware/devicetree/base/vfcs/vivo,pps-fchg-curr-max-ma \
		/sys/firmware/devicetree/base/vfcs/vivo,ufcs-fchg-curr-max-ma \
		/sys/firmware/devicetree/base/vfcs/vivo,fchg-vbus-max-mv \
		/sys/firmware/devicetree/base/vfcs/vivo,fchg-ibus-max-ma \
		/sys/firmware/devicetree/base/vfcs/vivo,fchg-vfloat-max-mv \
		/sys/firmware/devicetree/base/vfcs_cms/vivo,max-power-current-limit-ma \
		/sys/firmware/devicetree/base/vfcs_cms/vivo,bat-vfloat-mv \
		/sys/firmware/devicetree/base/soc/vfcs/vivo,fchg-curr-max-ma \
		/sys/firmware/devicetree/base/vivo,fchg-curr-max-ma; do
		[ -r "$f" ] || continue
		echo "$f = $(od -An -tu1 -v "$f" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')"
	done
} > "$WORK/06_dt_tables.txt" 2>&1

# ------------------------------------------------------------------
# 6. sysfs snapshot
# ------------------------------------------------------------------
{
	echo "===== /sys/class/vfcs_class ====="
	for f in /sys/class/vfcs_class/*; do
		[ -f "$f" ] || continue
		printf '%-24s = %s\n' "${f##*/}" "$(cat "$f" 2>/dev/null | head -c 200 | tr '\n' '|')"
	done
	echo ""
	echo "===== battery key fields ====="
	for n in status present capacity voltage_now current_now current_avg temp health charge_counter charge_full charge_full_design cycle_count chg_voltage charger_voltage chg_type charging_speed voltage_max soc_decimal power_now; do
		f="/sys/class/power_supply/battery/$n"
		[ -e "$f" ] || continue
		printf '%-24s = %s\n' "$n" "$(cat "$f" 2>/dev/null)"
	done
	echo ""
	echo "===== usb & primary_chg ====="
	for n in online present voltage_now current_now voltage_max usb_type type; do
		f="/sys/class/power_supply/usb/$n"
		[ -e "$f" ] || continue
		printf '%-24s = %s\n' "usb/$n" "$(cat "$f" 2>/dev/null)"
	done
	for n in constant_charge_current input_current_limit usb_type status; do
		f="/sys/class/power_supply/primary_chg/$n"
		[ -e "$f" ] || continue
		printf '%-24s = %s\n' "primary_chg/$n" "$(cat "$f" 2>/dev/null)"
	done
	echo ""
	echo "===== cms_class key fields ====="
	for n in htccc_enable factory_mode_state scene scene_mode scene_level scene_disable fastchg_current_now fastchg_is_ok adapter_power vfloat_voltage charging_technology charging_speed chg_voltage ibus chg_type debug_chg_cur ai_charge_rate_mode primary_board_temp bat_therm vir_shell_temp main_batt_temp sub_batt_temp bat_btb_therm chg_pmos_temp battery_health_cyclecount battery_health_learning_soh cms_enable disable_charge; do
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
	echo "===== Charging / aging / voter (last 500 lines) ====="
	dmesg 2>/dev/null | grep -iE 'cms_v5|cms_check|aging|vfcs|voter|fchg_fcc|force_active|USER_FCC' | tail -n 500
} > "$WORK/08_dmesg.txt" 2>&1

# ------------------------------------------------------------------
# 8. Properties
# ------------------------------------------------------------------
{
	getprop 2>/dev/null | grep -iE 'vivo|bbk|charge|batt|ro.product.model|build.version|board.platform'
} > "$WORK/09_getprop.txt" 2>&1

# ------------------------------------------------------------------
# 9. Processes
# ------------------------------------------------------------------
{
	echo "===== Module processes ====="
	ps -A -o pid,ppid,args 2>/dev/null | grep -iE 'vfcs_boost|v2507a|__daemon' | grep -v grep
	echo ""
	echo "===== Daemon liveness ====="
	if [ -f /data/adb/v2507a_charge_boost.pid ]; then
		p=$(cat /data/adb/v2507a_charge_boost.pid 2>/dev/null)
		echo "pidfile = $p"
		if kill -0 "$p" 2>/dev/null; then echo "alive: yes"; else echo "alive: no (stale pidfile)"; fi
	else
		echo "no pidfile (daemon not started or on Stock profile)"
	fi
} > "$WORK/10_processes.txt" 2>&1

# ------------------------------------------------------------------
# 10. logcat
# ------------------------------------------------------------------
if command -v logcat >/dev/null 2>&1; then
	logcat -d -t 800 2>/dev/null | grep -iE 'vivo.*charg|vfcs|cms_v5|batt' | tail -n 400 > "$WORK/11_logcat.txt" 2>/dev/null
fi
[ -s "$WORK/11_logcat.txt" ] || echo "(no relevant logcat entries or unavailable)" > "$WORK/11_logcat.txt"

# ------------------------------------------------------------------
# 11. Metadata
# ------------------------------------------------------------------
{
	echo "===== Module ====="
	echo "name        : $(sed -n 's/^name=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo "version     : $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo "versionCode : $(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo ""
	echo "===== Device ====="
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
# 12. Archive (toybox tar + gzip)
# ------------------------------------------------------------------
PARENT=$(dirname "$WORK")
BASE=$(basename "$WORK")
OUT="$OUTDIR/$BASE.tar.gz"

tar -czf "$OUT" -C "$PARENT" "$BASE" 2>/dev/null
RC=$?

if [ "$RC" = "0" ] && [ -s "$OUT" ]; then
	SZ=$(wc -c < "$OUT" 2>/dev/null)
	say "=================================================="
	say " Debug log bundle generated"
	say "=================================================="
	say ""
	say " File: $OUT"
	say " Size: $SZ bytes"
	say " Raw : $WORK"
	say ""
	say " Share the archive file directly (standard .tar.gz)."
	say " You may delete the temporary raw folder if unneeded."
	say "=================================================="
	RESULT_PATH="$OUT"
else
	say "!! Archive failed (rc=$RC). Raw files kept at: $WORK"
	say "   You can inspect files directly from that folder."
	RESULT_PATH="$WORK"
fi

# 供 WebUI / action.sh 解析的一行标记
echo "DUMP_PATH=$RESULT_PATH"

exit 0
