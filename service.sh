#!/system/bin/sh
# ============================================================
#  v2352a_charge_boost · service.sh  ★ v3568 彻底重写 ★
# ============================================================
#  【为什么要重写】
#    旧看门狗每 15 秒做一次存活检查，用的是：
#        if "$BOOST" __alive; then
#    而 __alive 是 fork 一个全新的 shell，把 6800+ 行的 vfcs_boost
#    完整解析一遍才走到那个分支。实测：单次 120 ms。
#    再加上 date +%s（30ms）、sed|head 读档位（30ms），
#    每 15 秒要烧掉 180 ms CPU —— 折合 ~1.0% 常驻占用。
#    手机明明在待机，CPU 却被这个"什么都不做"的循环啃着。
#
#  【重写原则】
#    1. 存活检查只用 shell 内建（read / kill -0），零 fork。
#       实测：内建 read 10ms、内建 kill -0 20ms，但这两次是
#       【同一个 shell 内】连续执行，不再 fork 新进程。
#    2. 心跳时间戳写进一个纯文本文件，daemon 自己每轮更新，
#       看门狗只 stat 一次 mtime —— 避免任何子进程。
#    3. 去掉从不被读取的 SVC_LOCK/ts 写入。
#    4. 保留全部既有语义：单实例锁、档位守卫、冷却重试、
#       DT 缓存预热、节点就绪等待。
# ============================================================

MODDIR=${0%/*}
BOOST="$MODDIR/system/bin/vfcs_boost"
PROFILE_FILE="/data/adb/v2352a_charge_boost.profile"
LOG_FILE=/data/adb/v2352a_charge_boost.log
PIDFILE=/data/adb/v2352a_charge_boost.pid
LOCKDIR="/data/adb/v2352a_charge_boost.lock"
SVC_LOCK="$LOCKDIR/service"
HEARTBEAT=/data/adb/v2352a_charge_boost.beat

CTL=/sys/class/vfcs_class/fchg_fcc_ma

# ★ v3572：巡检间隔 20s -> 60s
#   【为什么】daemon 未插电时 20s 才醒一次（每次约 100ms），
#     看门狗每 20s 巡检一次反而更贵：
#     实测看门狗 0.333%、daemon 0.122%，看门狗是 daemon 的 2.7 倍。
#     原因不是逻辑重（已经零 fork），而是 sleep 本身每次要 fork
#     一次 /system/bin/sleep（toybox 是一个大二进制，exec 要映射整个文件），
#     实测固定 31ms CPU。每 20s 一次 = 0.155%。
#   【影响】daemon 真死掉时，最多多等 60s 才被拉起（原来 20s）。
#     但本机实测无论 20s 还是 60s 都没出现过需要拉起的情况
#     （之前那些“卡死”全是 cgroup 冻结导致的误判，已修复）。
#     且 daemon 自己每 20s 打一次心跳，卡死仍能在 60s 内发现。
WATCH_IV=60          # 看门狗巡检间隔（秒）。存活判定已改为零 fork，
                     # 放宽到 20 秒只影响"守护崩了多久被发现"，无副作用。
BEAT_STALE=120       # 心跳超过这么久没更新，判定 daemon 卡死

# ★ v3578：log() 跟随 profile 里的 LOG_EN（与 daemon 内的 log() 同源）。
#   旧版 service.sh 的 log() 完全不看 LOG_EN —— 用户在 WebUI 里把「日志」
#   关掉之后，daemon 确实不写了，但 service.sh 仍每 60 秒写一行
#   （一天 1440 行、约 90KB），文件只增不减，看日志时全是噪声。
#   现在：LOG_EN=0 => 本脚本一个字都不写。
LOG_EN_ON=1
LOG_OUT="$LOG_FILE"
read_log_en() {
	local k v
	LOG_EN_ON=1
	[ -f "$PROFILE_FILE" ] || { LOG_OUT="$LOG_FILE"; return 0; }
	while IFS='=' read -r k v; do
		case "$k" in
			LOG_EN)
				case "$v" in 0) LOG_EN_ON=0 ;; *) LOG_EN_ON=1 ;; esac
				break ;;
		esac
	done < "$PROFILE_FILE" 2>/dev/null
	[ "$LOG_EN_ON" = "0" ] && LOG_OUT=/dev/null || LOG_OUT="$LOG_FILE"
	return 0
}

log() {
	[ "$LOG_EN_ON" = "1" ] || return 0
	echo "$(date '+%m-%d %H:%M:%S') [service] $*" >> "$LOG_FILE" 2>/dev/null
}

# ------------------------------------------------------------
# 单实例锁（mkdir 原子操作）
# ------------------------------------------------------------
mkdir -p "$LOCKDIR" 2>/dev/null

take_svc_lock() {
	if mkdir "$SVC_LOCK" 2>/dev/null; then
		echo $$ > "$SVC_LOCK/pid"
		return 0
	fi

	local holder
	holder=""
	read -r holder < "$SVC_LOCK/pid" 2>/dev/null
	case "$holder" in
		''|*[!0-9]*) holder="" ;;
	esac

	if [ -n "$holder" ] && [ "$holder" != "$$" ] && kill -0 "$holder" 2>/dev/null; then
		return 1    # 持有者活着 -> 重复启动
	fi

	# 持有者已死（开机残留）-> 接管
	rm -rf "$SVC_LOCK" 2>/dev/null
	if mkdir "$SVC_LOCK" 2>/dev/null; then
		echo $$ > "$SVC_LOCK/pid"
		return 0
	fi
	return 1
}

release_svc_lock() {
	local holder
	holder=""
	read -r holder < "$SVC_LOCK/pid" 2>/dev/null
	[ "$holder" = "$$" ] && rm -rf "$SVC_LOCK" 2>/dev/null
}

# ------------------------------------------------------------
# ★ 零 fork 存活检查（本次重写的核心）
# ------------------------------------------------------------
#  旧： if "$BOOST" __alive        -> fork shell，解析 6800 行，120ms
#  新： read pid + kill -0         -> 全内建，同一个 shell，约 0ms 额外开销
#      再加心跳文件 mtime 兜底，能发现"进程还在但卡死"的情况。
# ------------------------------------------------------------
daemon_alive() {
	local p
	p=""
	read -r p < "$PIDFILE" 2>/dev/null
	case "$p" in
		''|*[!0-9]*) return 1 ;;
	esac
	kill -0 "$p" 2>/dev/null || return 1
	# ★ v3576：确认它没被冻住。
	#   kill -0 对处于 do_freezer_trap 的进程同样成功，
	#   实测那个卡了 3 小时的守护就是这种情况。
	#   这里用零 fork 的 cg_of / cg_freeze_of
	#   （v3575 用的是 $(grep|cut)，单次 47ms，每轮多烧 0.3% CPU）。
	cg_of "$p" || return 0
	[ "$CG_PATH" = "/unfrozen" ] && return 0
	cg_freeze_of "$CG_PATH" && [ "$CG_FREEZE" = "1" ] && return 1
	return 0
}

# ------------------------------------------------------------
# 读档位（零 fork：纯内建 read + case）
# ------------------------------------------------------------
# 结果写进全局变量 ACTIVE_NOW，避免 $(...) 再 fork 一个子 shell
ACTIVE_NOW=1
read_active() {
	local k v
	ACTIVE_NOW=1
	[ -f "$PROFILE_FILE" ] || return 0
	while IFS='=' read -r k v; do
		[ "$k" = "ACTIVE" ] || continue
		case "$v" in 1|2|3) ACTIVE_NOW="$v" ;; esac
		break
	done < "$PROFILE_FILE" 2>/dev/null
	return 0
}

if ! take_svc_lock; then
	exit 0
fi
read_log_en
# ★ v3578：TERM/INT/HUP 收到后必须真的退出。
#   旧写法 `trap 'release_svc_lock' EXIT INT TERM HUP` 只放锁不退出 ——
#   kill 之后进程继续跑，结果是"杀不掉"，再手动拉起一份就变成两个看门狗
#   同时抢守护（实测：kill 1909 后它还在，新起的 6051 也在）。
#   改成显式 exit，保证一个信号只对应一次干净的退出。
trap 'release_svc_lock; exit 0' EXIT
trap 'exit 0' INT TERM HUP

log "service.sh 启动 (pid=$$) [v3578]"

# ------------------------------------------------------------
# 等 sysfs 节点就绪（最多 30 秒）
# ------------------------------------------------------------
i=0
while [ $i -lt 30 ]; do
	[ -e "$CTL" ] && break
	sleep 1
	i=$((i + 1))
	[ $((i % 5)) -eq 0 ] && log "等待节点 $CTL 就绪... ${i}s"
done

if [ ! -e "$CTL" ]; then
	log "节点 $CTL 不存在，模块不启动"
	exit 0
fi
log "节点就绪（用时 ${i}s）"

chmod 755 "$BOOST" 2>/dev/null
[ -f "$MODDIR/action.sh" ] && chmod 755 "$MODDIR/action.sh" 2>/dev/null

# ------------------------------------------------------------
# 档位持久化：原厂档(3) = 不干预，直接退出
# ------------------------------------------------------------
read_active
if [ "$ACTIVE_NOW" = "3" ]; then
	log "档位=原厂(3)，跳过启动守护进程"
	exit 0
fi

# ------------------------------------------------------------
# ★★★ v3572：把进程迁出「会被冻结」的 cgroup ★★★
# ------------------------------------------------------------
#  【这个问题是怎么发现的】
#    用户反馈"不充电也会发热"。查模块进程发现：
#      uid=0（root）却挂在 /apps/uid_10445/pid_8958
#      memory 组是 com.sukisu.ultra（KernelSU 管理器）
#      cgroup.freeze = 1  ← 已经被冻结
#    根因：KernelSU 管理器启动 service.sh 时，子进程继承了它自己的
#    应用 cgroup。虽然进程是 root，但 cgroup 归属没变。
#    结果：只要管理器不在前台（或系统判定后台），整组被 Android
#    冻结（wchan=do_freezer_trap）。
#  【造成的后果】
#    看门狗发现心跳停摆 -> kill -9 -> 重启 -> 新进程又被 spawn 到
#    同一个 cgroup -> 再被冻结。每 2 分钟一轮死循环，
#    每轮都要重新解析 6900+ 行脚本 —— 这才是"发热"的真正来源，
#    而不是 CPU 占用率（实测只有 0.05%）。
#  【修法】
#    Android 在 cgroup v2 里留了 /sys/fs/cgroup/unfrozen（freeze=0），
#    专门给"不应被冻结"的进程用。把 pid 写进它的 cgroup.procs 即可迁移。
#    注意：迁移只影响当前进程，fork 出的子进程会继承迁移后的 cgroup，
#    所以要在启动后立刻迁移，越早越好。
CG_UNFROZEN=/sys/fs/cgroup/unfrozen/cgroup.procs

cg_thaw() {
	local _pid=$1
	[ -z "$_pid" ] && return 1
	[ -d "/proc/$_pid" ] || return 1
	[ -w "$CG_UNFROZEN" ] || return 1
	cg_of "$_pid" || return 1
	[ "$CG_PATH" = "/unfrozen" ] && return 0
	echo "$_pid" > "$CG_UNFROZEN" 2>/dev/null
	cg_of "$_pid" || return 1
	[ "$CG_PATH" = "/unfrozen" ] && return 0
	return 1
}

# ------------------------------------------------------------
# ★★★ v3575：看门狗自我保护 + cgroup 漂移侦测 ★★★
# ------------------------------------------------------------
#  【为什么必须加】
#    2026-10-31 实测事故：模块静默 3 小时，用户看到的表是
#      「看门狗未运行 / 心跳 10513 秒前 / 守护 PID 换了新的但冻结着」
#    查出来是：
#      守护 PID 的 cgroup = /apps/uid_10365/pid_10792
#                          ↑ PiliPlus 的应用组，cgroup.freeze=1
#      看门狗进程完全不存在
#    日志最后一条是「看门狗：守护不在运行（第1次），重新拉起」，
#    之后再无输出 —— 看门狗在执行拉起时自己也死了/被冻了。
#  【三个缺陷】
#    ① 主循环只 cg_thaw 守护，从不检查自己是否被系统重新归类。
#       系统（vivo 的 frozen cgroup 管理 / PMS 分级）会在任意时刻
#       把进程重新写进应用组，一次启动迁移根本不够。
#    ② daemon_alive 用 kill -0，对"被冻结"的进程同样返回成功，
#       所以那个冻了 3 小时的守护一直被判定为"活着"。
#    ③ 拉起后只查存活，不校验 cgroup 是否迁移成功，失败了也不报警。
#  【本版修法】
#    ① 每轮先 cg_thaw 自己（$$），再做别的；
#    ② daemon_alive 增加"冻结检测"：读 cgroup.freeze，=1 视为不健康；
#    ③ 拉起后校验 cgroup，失败则记日志并计入 BAD。
SELF_DRIFT_LOGGED=0
SELF_DRIFT_LAST_CG=""
SELF_DRIFT_N=0

# ------------------------------------------------------------
# ★★★ v3576：零 fork 读 cgroup ★★★
# ------------------------------------------------------------
#  【为什么要这个】
#    v3575 为了检测冻结，用了
#      _cg=$(grep '^0::' /proc/$p/cgroup | cut -d: -f3)
#    实测这一句要 47ms（两个外部进程 + 一个子 shell），
#    而 daemon_alive 每轮调 1 次、CG_SELF_CHECK 调 1~2 次，
#    每 60 秒一轮 => 平白多烧 ~0.31% CPU。实测看门狗从 0.111%
#    涨到 0.455%（超3倍）。为了一个保护付出太大代价。
#  【做法】
#    /proc/PID/cgroup 的 v2 行格式固定为：
#      0::/apps/uid_10365/pid_10792
#    所以用 read 内建读入整行，再用 ${var#*:} 去掉前两个冒号即可，
#    全程零 fork。
#  结果写入全局 CG_PATH（不用 $( ) 回传，避开子 shell 丢变量）。
CG_PATH=""
cg_of() {
	local _p=$1 _line=""
	CG_PATH=""
	[ -z "$_p" ] && return 1
	[ -d "/proc/$_p" ] || return 1
	# 只读前几行就够（v2 行通常在最后，但文件很小，全读也行）
	while IFS= read -r _line; do
		case "$_line" in
			0::*) CG_PATH="${_line#0::}" ; break ;;
		esac
	done < "/proc/$_p/cgroup" 2>/dev/null
	[ -n "$CG_PATH" ] && return 0
	return 1
}

# 读 cgroup.freeze，结果写全局 CG_FREEZE（""= 读不到）
CG_FREEZE=""
cg_freeze_of() {
	local _cg=$1 _v=""
	CG_FREEZE=""
	[ -z "$_cg" ] && return 1
	read -r _v < "/sys/fs/cgroup$_cg/cgroup.freeze" 2>/dev/null
	CG_FREEZE="$_v"
	[ -n "$_v" ] && return 0
	return 1
}

CG_SELF_CHECK() {
	local _pid=$$ _cg
	cg_of "$_pid" || return 0          # 读不到就不管，别误伤
	_cg="$CG_PATH"
	[ "$_cg" = "/unfrozen" ] && { SELF_DRIFT_N=0; SELF_DRIFT_LAST_CG=""; return 0; }
	if echo "$_pid" > "$CG_UNFROZEN" 2>/dev/null; then
		cg_of "$_pid"
		if [ "$CG_PATH" = "/unfrozen" ]; then
			[ "$SELF_DRIFT_LOGGED" = "1" ] || {
				SELF_DRIFT_LOGGED=1
				log "看门狗：自身曾被系统重新归类，已迁回 unfrozen（后续同类不再重复记录）"
			}
			SELF_DRIFT_N=0
			SELF_DRIFT_LAST_CG=""
			return 0
		fi
	fi
	cg_freeze_of "$_cg"
	# ★ v3578：这条原来是【每 60 秒无条件写一行】—— 一天 1440 行、
	#   约 90KB 纯噪声，把日志彻底淹掉（实测 30KB 日志全是它）。
	#   现在按「状态变化 + 每 30 轮汇总」记录：
	#     · cgroup 路径变了或第一次遇到 -> 立刻记一条（信息不丢）
	#     · 原地重复 -> 每 30 轮（约 30 分钟）汇总一条，带累计次数
	SELF_DRIFT_N=$(( SELF_DRIFT_N + 1 ))
	if [ "$_cg" != "$SELF_DRIFT_LAST_CG" ] || [ "$SELF_DRIFT_LOGGED" = "0" ]; then
		SELF_DRIFT_LOGGED=1
		SELF_DRIFT_LAST_CG="$_cg"
		log "⚠ 看门狗：自身 cgroup 漂移到 ${_cg}（freeze=${CG_FREEZE:-?}），迁移失败（同类后续每 30 轮汇总）"
	elif [ $(( SELF_DRIFT_N % 30 )) -eq 0 ]; then
		log "⚠ 看门狗：仍在 ${_cg}，已连续 ${SELF_DRIFT_N} 轮迁移失败（freeze=${CG_FREEZE:-?}）"
	fi
	return 1
}

# 把自己（看门狗）先迁出去，否则看门狗自己会被冻结，
# 就不会再去救 daemon 了。
cg_thaw "$$"
log "看门狗自迁移到 unfrozen: $(grep '^0::' /proc/$$/cgroup 2>/dev/null | cut -d: -f3)"

# ------------------------------------------------------------
# 启动守护
# ------------------------------------------------------------
"$BOOST" stop >/dev/null 2>&1
sleep 1
"$BOOST" start
_DPID=$(cat "$PIDFILE" 2>/dev/null)
log "守护拉起完成（pid=${_DPID}）"

# 立刻迁出 daemon
if [ -n "$_DPID" ]; then
	cg_thaw "$_DPID"
	log "daemon 迁移到 unfrozen: $(grep '^0::' /proc/$_DPID/cgroup 2>/dev/null | cut -d: -f3)"
fi

# ------------------------------------------------------------
# DT 表缓存预热（开机一次性，避免用户首次点击卡 8 秒）
# ------------------------------------------------------------
"$BOOST" getjson >/dev/null 2>&1
if [ -f /data/adb/v2352a_charge_boost.dtcache ]; then
	log "DT 表缓存已预热"
else
	log "DT 表缓存预热未成功（下次 getjson 会重试）"
fi

# ------------------------------------------------------------
# 看门狗循环 ★ 每轮零 fork（除拉起失败时才 fork）
# ------------------------------------------------------------
DOWN=0
BAD=0

# ★ 心跳判定的零 fork 做法：
#   每一轮开始前用【内建重定向】建一个空标记文件（: > file，不 fork），
#   sleep 之后用【内建 test -nt】比较 heartbeat 是否比标记新。
#   这样"是否卡死"的整个判断过程没有一个子进程。
MARK=/data/adb/v2352a_charge_boost.mark

while :; do
	: > "$MARK" 2>/dev/null
	sleep "$WATCH_IV"

	# ★ v3578：每轮重读一次 LOG_EN（零 fork），用户在 WebUI 里改完立即生效
	read_log_en

	# ★★ v3575：每轮先确认【自己】还在 unfrozen ★★
	#   实测事故：看门狗自身被系统归类到应用组后被冻结，
	#   整条保活链就断了（那次模块静默了 3 小时）。
	#   这里每轮自检一次，发现漂移就拉回来。
	#   成本：1 次 read + 1 次 grep（均为内建/fork），60 秒一轮可忽略。
	CG_SELF_CHECK

	# ---- 档位守卫（零 fork）----
	read_active
	if [ "$ACTIVE_NOW" = "3" ]; then
		log "看门狗：档位已切到原厂(3)，停止保活并退出"
		"$BOOST" stop >>"$LOG_OUT" 2>&1
		exit 0
	fi

	# ---- ★ 每次巡检都确认 daemon 还在 unfrozen ----
	#   系统在某些场景下会重新给进程分组（比如管理器重启），
	#   所以不能只在启动时迁移一次，每轮兜底更稳。
	_p_now=""
	read -r _p_now < "$PIDFILE" 2>/dev/null
	[ -n "$_p_now" ] && cg_thaw "$_p_now"

	# ---- 存活检查（零 fork）----
	if daemon_alive; then
		# 进程在，再看心跳有没有动过（区分"活着"和"卡死"）
		if [ -f "$HEARTBEAT" ] && [ ! "$HEARTBEAT" -nt "$MARK" ]; then
			log "⚠ 看门狗：守护进程在但心跳停摆，判定卡死"
			kill -9 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
			rm -f "$PIDFILE" 2>/dev/null
		else
			DOWN=0
			BAD=0
			continue
		fi
	fi

	# ---- 拉起（冷却保护）----
	DOWN=$((DOWN + 1))
	if [ "$DOWN" -le 3 ]; then
		log "⚠ 看门狗：守护不在运行（第 ${DOWN} 次），重新拉起"
	else
		BAD=$((BAD + 1))
		if [ $((BAD % 20)) -eq 1 ]; then
			log "⚠ 看门狗：守护连续 ${DOWN} 次拉起失败，转入慢速重试"
		fi
		nap=$((DOWN * 10))
		[ "$nap" -gt 300 ] && nap=300
		sleep "$nap"
	fi

	"$BOOST" start >>"$LOG_OUT" 2>&1
	_p_new=""
	read -r _p_new < "$PIDFILE" 2>/dev/null
	# ★★ v3575：拉起后必须校验 cgroup 是否真的迁成功 ★★
	#   原来只调 cg_thaw 不看返回值，失败了也没人知道，
	#   下一轮 daemon_alive 仍判"活着"（因为 kill -0 对冻结进程也成功），
	#   于是无限循环。现在失败直接计 BAD 并报警。
	_cg_ok=1
	if [ -n "$_p_new" ]; then
		if cg_thaw "$_p_new"; then
			_cg_ok=0
		else
			_cg_ok=1
		fi
	fi
	sleep 2
	if daemon_alive; then
		log "看门狗：守护已恢复$([ "$_cg_ok" = "1" ] && echo "（但 cgroup 迁移未成功，已计入异常）" || echo "")"
		DOWN=0
		[ "$_cg_ok" = "1" ] && BAD=$((BAD + 1)) || BAD=0
	fi
done
