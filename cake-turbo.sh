#!/bin/bash
# cake-turbo — aggressive CAKE autorate for fixed-rate links that the ISP overprovisions.
#
# Model: the line has a stable real capacity somewhere between the plan rate and
# OVERPROV_PCT of it. When the link is busy and RTT is clean, push the shaper up;
# when RTT bloats, cut to just under the throughput actually achieved and remember
# that as the "learned-good" rate. Idle links park near learned-good instead of
# decaying to base, so the next burst starts fast.
#
# Hot loop uses only bash builtins (regex, $EPOCHREALTIME, read < /sys/...); the
# only forks are tc when a rate actually changes and logger once a minute.
#
# usage: cake-turbo.sh          run the controller (procd does this)
#        cake-turbo.sh status   print live state

set -u
SELF_DIR=${0%/*}; [[ $SELF_DIR == "$0" ]] && SELF_DIR=.
CONFIG=${CAKE_TURBO_CONFIG:-$SELF_DIR/config.sh}
STATUS_FILE=${CAKE_TURBO_STATUS:-/tmp/cake-turbo.status}

if [[ ${1:-} == status ]]; then
	cat "$STATUS_FILE" 2>/dev/null || echo "cake-turbo: not running"
	exit 0
fi

# test hooks (sim.py uses these; leave unset on the router)
TC=${TC:-tc}
PING_CMD=${PING_CMD:-}
STATS_DIR=${STATS_DIR:-/sys/class/net}
LOG_STDERR=${LOG_STDERR:-0}

log() {
	if (( LOG_STDERR )); then echo "cake-turbo: $*" >&2
	else logger -t cake-turbo -- "$*" 2>/dev/null || echo "cake-turbo: $*" >&2; fi
}
die() { log "fatal: $*"; exit 1; }

[[ -n ${EPOCHREALTIME:-} ]] || die "needs bash >= 5 (EPOCHREALTIME)"
[[ -r $CONFIG ]] || die "missing config $CONFIG"
# shellcheck source=config.sh
. "$CONFIG"

# PROFILE trades ping for speed; it overrides the knobs it sets.
#   balanced    the values in config.sh
#   throughput  per-reflector ping budget: idle < THROUGHPUT_LOW_PING_MS may
#               rise THROUGHPUT_LOW_EXTRA_MS but stay <= THROUGHPUT_MAX_PING_MS;
#               higher idle pings may rise THROUGHPUT_PCT% (1.5x). Cuts gently,
#               recovers fast, never shapes an overprovisioned direction below plan
#   extra       ignores ping completely: runs at the ceiling whenever busy and
#               only backs off on probe loss (ISP buffer overflowing)
PROFILE=${PROFILE:-balanced}
case $PROFILE in
	balanced) ;;
	throughput)
		FLOOR_AT_PLAN=1 HIGH_LOAD_PCT=70
		BUDGET_MODE=1
		CUT_PCT=95 GOOD_AFTER_CUT_PCT=97
		PROBE_SLOW_PCT=2 SLOW_PROBE_S=10 ;;
	extra)
		FLOOR_AT_PLAN=1 HIGH_LOAD_PCT=60 IGNORE_DELAY=1
		PROBE_FAST_PCT=8 CUT_PCT=95 GOOD_AFTER_CUT_PCT=97
		PROBE_SLOW_PCT=4 SLOW_PROBE_S=5 ;;
	*) die "PROFILE must be balanced, throughput or extra (got '$PROFILE')" ;;
esac
DELAY_THR_PCT=${DELAY_THR_PCT:-0}   # >0: bloat = RTT above baseline * (1 + PCT/100), per reflector
BUDGET_MODE=${BUDGET_MODE:-0}       # 1: bloat = RTT above the throughput ping budget (below)
IGNORE_DELAY=${IGNORE_DELAY:-0}     # 1: RTT never counts as bloat, only timeouts do
FLOOR_AT_PLAN=${FLOOR_AT_PLAN:-0}   # 1: an overprovisioned direction never goes below plan
                                    #    (one capped at 100% keeps MIN_PCT so it can still back off)

for v in DL_IF UL_IF; do [[ -n ${!v} ]] || die "$v not set in $CONFIG"; done
for v in DL_BASE_KBPS UL_BASE_KBPS; do
	[[ ${!v} =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || die "$v not set in $CONFIG"
done

# --- derived constants (microseconds / per-direction arrays; 0 = dl, 1 = ul) --
TICK_US=$(( TICK_MS * 1000 ))
DELAY_THR_US=$(( DELAY_THR_MS * 1000 ))
CUT_REFRACTORY_US=$(( CUT_REFRACTORY_MS * 1000 ))
INC_HOLDOFF_US=$(( INC_HOLDOFF_MS * 1000 ))
STALL_US=$(( STALL_MS * 1000 ))
SLOW_PROBE_US=$(( SLOW_PROBE_S * 1000000 ))
REAPPLY_US=$(( REAPPLY_S * 1000000 ))
LOG_EVERY_US=$(( LOG_EVERY_S * 1000000 ))
REFLECTOR_ALIVE_US=2000000
WIN_MASK=$(( (1 << BLOAT_WINDOW) - 1 ))

ms_to_x() {   # "27.5" ms -> RTT units used below (microseconds * 1000)
	local v=$1 i f=""
	i=${v%%.*}; [[ $v == *.* ]] && f=${v#*.}; f="${f}000"
	REPLY=$(( (10#${i:-0} * 1000 + 10#${f:0:3}) * 1000 ))
}
ms_to_x "${THROUGHPUT_LOW_PING_MS:-30}";    LOW_PING_X=$REPLY
ms_to_x "${THROUGHPUT_LOW_EXTRA_MS:-27.5}"; LOW_EXTRA_X=$REPLY
ms_to_x "${THROUGHPUT_MAX_PING_MS:-50}";    MAX_PING_X=$REPLY
TP_PCT=${THROUGHPUT_PCT:-50}
TP_TRIGGER_PCT=${THROUGHPUT_TRIGGER_PCT:-55}   # react at this share of the budget (overshoot headroom)

NAME=(dl ul)
IFACE=("$DL_IF" "$UL_IF")
BASE=("$DL_BASE_KBPS" "$UL_BASE_KBPS")
OVERPROV=("${DL_OVERPROV_PCT:-${OVERPROV_PCT:-200}}" "${UL_OVERPROV_PCT:-${OVERPROV_PCT:-200}}")
declare -a MIN MAX RATE GOOD APPLIED ACH LOAD PREV_BYTES LAST_CUT CUTS
for d in 0 1; do
	MIN[d]=$(( BASE[d] * MIN_PCT / 100 ))
	(( FLOOR_AT_PLAN && OVERPROV[d] > 100 )) && MIN[d]=${BASE[d]}
	MAX[d]=$(( BASE[d] * OVERPROV[d] / 100 ))
	RATE[d]=${BASE[d]}; GOOD[d]=${BASE[d]}
	APPLIED[d]=0; ACH[d]=0; LOAD[d]=0; LAST_CUT[d]=0; CUTS[d]=0
done

declare -A BASELINE_X LAST_OK   # per-reflector baseline RTT (us*1000) / last reply time
BLOAT_WIN=0 BLOAT_CNT=0
TC_FAILS=0
NOW=0

now() { NOW=${EPOCHREALTIME//[.,]/}; }

# --- shaper I/O ---------------------------------------------------------------
apply() {   # apply <dir> <force>
	local d=$1 r=${RATE[$1]} a=${APPLIED[$1]} diff
	if (( ! $2 )); then
		(( r == a )) && return
		diff=$(( r > a ? r - a : a - r ))
		(( a > 0 && diff * 100 < a * APPLY_DEADBAND_PCT )) && return
	fi
	if "$TC" qdisc change root dev "${IFACE[d]}" cake bandwidth "${r}Kbit" 2>/dev/null; then
		APPLIED[d]=$r; TC_FAILS=0
	else
		(( ++TC_FAILS >= 10 )) && die "tc keeps failing on ${IFACE[d]} (qdisc gone?)"
	fi
}

read_bytes() {   # cake is egress on both ifaces, so tx_bytes = traffic through the shaper
	local v
	{ read -r v < "$STATS_DIR/${IFACE[$1]}/statistics/tx_bytes"; } 2>/dev/null || v=${PREV_BYTES[$1]:-0}
	REPLY=$v
}

wait_for_cake() {
	local d said=0
	for d in 0 1; do
		until "$TC" qdisc show dev "${IFACE[d]}" 2>/dev/null | grep -q 'qdisc cake'; do
			(( said++ )) || log "waiting for cake qdisc on ${IFACE[d]} (is SQM up?)"
			sleep 5
		done
	done
}

# --- control law --------------------------------------------------------------
adjust() {   # called every tick per direction; raises / parks the rate
	local d=$1 r=${RATE[$1]} g=${GOOD[$1]} step

	if (( NOW - LAST_SAMPLE > STALL_US )); then   # pinger blind -> play safe
		RATE[d]=${BASE[d]}; return
	fi

	if (( LOAD[d] >= HIGH_LOAD_PCT )); then
		(( NOW - LAST_CUT[d] < INC_HOLDOFF_US )) && return
		(( BLOAT_CNT > 1 )) && return
		if (( r < g )); then
			r=$(( r + r * FAST_STEP_PCT / 100 )); (( r > g )) && r=$g
		else
			# held this rate under load with a clean RTT window -> it's good
			(( BLOAT_CNT == 0 && r > g )) && g=$r
			if (( NOW - LAST_CUT[d] < SLOW_PROBE_US )); then step=$PROBE_SLOW_PCT
			else step=$PROBE_FAST_PCT; fi
			r=$(( r + BASE[d] * step / 100 ))
		fi
	elif (( LOAD[d] < IDLE_LOAD_PCT )); then
		r=$(( g * IDLE_HOLD_PCT / 100 ))
	fi

	(( r > MAX[d] )) && r=${MAX[d]}; (( r < MIN[d] )) && r=${MIN[d]}
	(( g > MAX[d] )) && g=${MAX[d]}; (( g < MIN[d] )) && g=${MIN[d]}
	RATE[d]=$r; GOOD[d]=$g
}

on_bloat() {   # called on the sample that pushes the window over BLOAT_THR
	local d r a cap g cut=0 only=-1
	# RTT can't say which direction's queue grew. If both are busy but only one
	# is probing above its learned-good rate, that one caused it — spare the other.
	if (( LOAD[0] >= BLOAT_LOAD_PCT && LOAD[1] >= BLOAT_LOAD_PCT )); then
		if (( RATE[0] > GOOD[0] && RATE[1] <= GOOD[1] )); then only=0
		elif (( RATE[1] > GOOD[1] && RATE[0] <= GOOD[0] )); then only=1; fi
	fi
	for d in 0 1; do
		(( only >= 0 && d != only )) && continue
		(( LOAD[d] < BLOAT_LOAD_PCT )) && continue          # not our queue
		(( NOW - LAST_CUT[d] < CUT_REFRACTORY_US )) && continue
		r=${RATE[d]}; a=${ACH[d]}
		cap=$(( a > 0 && a < r ? a : r ))                   # real capacity <= what got through
		RATE[d]=$(( cap * CUT_PCT / 100 ))
		(( RATE[d] < MIN[d] )) && RATE[d]=${MIN[d]}
		g=$(( cap * GOOD_AFTER_CUT_PCT / 100 ))
		(( g < GOOD[d] )) && GOOD[d]=$g
		(( GOOD[d] < MIN[d] )) && GOOD[d]=${MIN[d]}
		LAST_CUT[d]=$NOW; (( CUTS[d]++ )); cut=1
		apply "$d" 0
	done
	(( cut )) && { BLOAT_WIN=0; BLOAT_CNT=0; }   # judge the new rate on fresh samples
}

push_sample() {   # push_sample <bloated 0|1>
	local oldest=$(( (BLOAT_WIN >> (BLOAT_WINDOW - 1)) & 1 ))
	BLOAT_WIN=$(( ((BLOAT_WIN << 1) | $1) & WIN_MASK ))
	BLOAT_CNT=$(( BLOAT_CNT + $1 - oldest ))
	(( BLOAT_CNT >= BLOAT_THR )) && on_bloat
}

RE_REPLY='^([0-9.]+) +: \[[0-9]+\], [0-9]+ bytes, ([0-9]+)\.?([0-9]*) ms'
RE_TIMEOUT='^([0-9.]+) +: \[[0-9]+\], timed out'

handle_line() {
	local ip us frac rx bx thr
	if [[ $1 =~ $RE_REPLY ]]; then
		ip=${BASH_REMATCH[1]}
		frac="${BASH_REMATCH[3]}000"
		us=$(( BASH_REMATCH[2] * 1000 + 10#${frac:0:3} ))
		rx=$(( us * 1000 ))
		bx=${BASELINE_X[$ip]:-$rx}
		LAST_SAMPLE=$NOW; LAST_OK[$ip]=$NOW
		if (( BUDGET_MODE )); then
			if (( bx < LOW_PING_X )); then
				thr=$LOW_EXTRA_X; (( MAX_PING_X - bx < thr )) && thr=$(( MAX_PING_X - bx ))
			else
				thr=$(( bx * TP_PCT / 100 ))
			fi
			thr=$(( thr * TP_TRIGGER_PCT / 100 ))
		elif (( DELAY_THR_PCT > 0 )); then thr=$(( bx * DELAY_THR_PCT / 100 ))
		else thr=$(( DELAY_THR_US * 1000 )); fi
		if (( ! IGNORE_DELAY && rx - bx > thr )); then
			push_sample 1
		else
			push_sample 0
			# baseline: drop fast toward a lower RTT, rise very slowly (~minutes)
			if (( rx < bx )); then bx=$(( bx + (rx - bx) * 9 / 10 ))
			else bx=$(( bx + (rx - bx) / 1000 )); fi
		fi
		BASELINE_X[$ip]=$bx
	elif [[ $1 =~ $RE_TIMEOUT ]]; then
		# a reflector that answered recently and now doesn't = drop under load.
		# a dead reflector stops counting after REFLECTOR_ALIVE_US.
		ip=${BASH_REMATCH[1]}
		(( NOW - ${LAST_OK[$ip]:-0} < REFLECTOR_ALIVE_US )) && push_sample 1
	fi
}

write_status() {
	printf 'updated=%s profile=%s\nbloat_window=%s/%s\n' "${EPOCHREALTIME%.*}" "$PROFILE" "$BLOAT_CNT" "$BLOAT_WINDOW" > "$STATUS_FILE"
	local d
	for d in 0 1; do
		printf '%s(%s): rate=%s good=%s throughput=%s load=%s%% base=%s max=%s cuts=%s kbit/s\n' \
			"${NAME[d]}" "${IFACE[d]}" "${APPLIED[d]}" "${GOOD[d]}" "${ACH[d]}" "${LOAD[d]}" \
			"${BASE[d]}" "${MAX[d]}" "${CUTS[d]}" >> "$STATUS_FILE"
	done
}

tick() {
	local d dt=$(( NOW - LAST_TICK )) den
	(( dt < TICK_US )) && return
	for d in 0 1; do
		read_bytes "$d"
		ACH[d]=$(( (REPLY - PREV_BYTES[d]) * 8000 / dt ))
		(( ACH[d] < 0 )) && ACH[d]=0                      # counter reset (iface bounce)
		PREV_BYTES[d]=$REPLY
		den=$(( APPLIED[d] > 0 ? APPLIED[d] : RATE[d] ))
		LOAD[d]=$(( ACH[d] * 100 / den ))
		adjust "$d"
		apply "$d" $(( NOW - LAST_APPLY >= REAPPLY_US ))
	done
	(( NOW - LAST_APPLY >= REAPPLY_US )) && LAST_APPLY=$NOW
	LAST_TICK=$NOW
	write_status
	if (( NOW - LAST_LOG >= LOG_EVERY_US )); then
		if (( CUTS[0] != LOGGED_CUTS0 || CUTS[1] != LOGGED_CUTS1 )); then
			log "dl ${APPLIED[0]} (good ${GOOD[0]}, +$(( CUTS[0] - LOGGED_CUTS0 )) cuts)" \
			    "ul ${APPLIED[1]} (good ${GOOD[1]}, +$(( CUTS[1] - LOGGED_CUTS1 )) cuts)"
			LOGGED_CUTS0=${CUTS[0]}; LOGGED_CUTS1=${CUTS[1]}
		fi
		LAST_LOG=$NOW
	fi
}

cleanup() {
	trap - EXIT INT TERM
	[[ -n ${PING_PID:-} ]] && kill "$PING_PID" 2>/dev/null
	local d   # leave the line shaped at plan rate, not wherever we were
	for d in 0 1; do
		"$TC" qdisc change root dev "${IFACE[d]}" cake bandwidth "${BASE[d]}Kbit" 2>/dev/null
	done
	rm -f "$STATUS_FILE"
	log "stopped; shaper reset to base"
	exit 0
}

# --- main ---------------------------------------------------------------------
wait_for_cake
trap cleanup EXIT INT TERM

if [[ -n $PING_CMD ]]; then
	exec {PFD}< <(eval "exec $PING_CMD")
else
	command -v fping >/dev/null || die "fping not installed"
	# shellcheck disable=SC2086  # word-split the reflector list on purpose
	exec {PFD}< <(exec fping -l -p "$PING_PERIOD_MS" $REFLECTORS 2>/dev/null)
fi
PING_PID=$!

now
LAST_TICK=$NOW LAST_SAMPLE=$NOW LAST_APPLY=$NOW LAST_LOG=$NOW LOGGED_CUTS0=0 LOGGED_CUTS1=0
for d in 0 1; do read_bytes "$d"; PREV_BYTES[d]=$REPLY; apply "$d" 1; done
log "started ($PROFILE): dl ${IFACE[0]} ${BASE[0]}..${MAX[0]} kbit, ul ${IFACE[1]} ${BASE[1]}..${MAX[1]} kbit"

while :; do
	if read -r -t 1 -u "$PFD" line; then
		now; handle_line "$line"
	else
		(( $? <= 128 )) && die "pinger exited"   # EOF; >128 is just the read timeout
		now
	fi
	tick
done
