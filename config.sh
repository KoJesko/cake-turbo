# cake-turbo config — bash syntax, sourced by cake-turbo.sh. Rates are kbit/s.
# install.sh fills the first block in from the existing cake-autorate / SQM config.

# --- link -------------------------------------------------------------------
DL_IF="ifb4wan"        # interface carrying the DOWNLOAD cake qdisc (SQM: ifb4<wan>)
UL_IF="wan"            # interface carrying the UPLOAD cake qdisc
DL_BASE_KBPS=""        # plan download rate (what the ISP sells)
UL_BASE_KBPS=""        # plan upload rate

DL_OVERPROV_PCT=200    # download ceiling = base * 200% -> up to 2x the plan
UL_OVERPROV_PCT=200    # upload ceiling; set 100 if the ISP gives exactly the plan
MIN_PCT=60             # floor   = base * 60%   (fixed link: never needs to go lower)

# --- latency probe ----------------------------------------------------------
REFLECTORS="1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112"
PING_PERIOD_MS=300     # per reflector; 6 reflectors -> 20 RTT samples/s
DELAY_THR_MS=15        # RTT above baseline that counts as a "bloated" sample
BLOAT_WINDOW=6         # look at the last N samples...
BLOAT_THR=3            # ...and call it bufferbloat when this many are bloated

# --- control law ------------------------------------------------------------
TICK_MS=200            # how often throughput is measured and rates are raised
HIGH_LOAD_PCT=75       # traffic >= 75% of the shaper rate -> link is busy, push up
IDLE_LOAD_PCT=40       # traffic <  40% -> idle, park at the learned-good rate
BLOAT_LOAD_PCT=50      # only cut a direction that is at least this busy

FAST_STEP_PCT=20       # below the learned-good rate: +20% of current per tick
PROBE_FAST_PCT=4       # above it, no recent bloat: +4% of base per tick (1x->2x in ~5 s)
PROBE_SLOW_PCT=1       # above it, bloat in the last SLOW_PROBE_S: +1% of base per tick
SLOW_PROBE_S=30

CUT_PCT=90             # on bloat: rate = min(rate, measured throughput) * 90%
GOOD_AFTER_CUT_PCT=95  # learned-good rate = min(rate, throughput) * 95%
IDLE_HOLD_PCT=95       # idle: park at learned-good * 95%

CUT_REFRACTORY_MS=300  # min gap between two cuts (lets the ISP queue drain)
INC_HOLDOFF_MS=600     # no increases this soon after a cut
STALL_MS=3000          # no RTT samples this long -> fall back to base rates
APPLY_DEADBAND_PCT=1   # skip tc calls for changes smaller than this
REAPPLY_S=30           # re-push rates periodically (survives SQM restarting the qdisc)
LOG_EVERY_S=60         # syslog summary interval (only when something happened)
