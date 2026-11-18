# cake-turbo config — bash syntax, sourced by cake-turbo.sh. Rates are kbit/s.
# install.sh fills any "" in the first block from the old config, cake-autorate or SQM.

# --- link -------------------------------------------------------------------
DL_IF=""               # DOWNLOAD cake iface (SQM: ifb4<wan>); "" = import on install
UL_IF=""               # UPLOAD cake iface; "" = import on install
DL_BASE_KBPS=""        # plan download rate (what the ISP sells)
UL_BASE_KBPS=""        # plan upload rate

DL_OVERPROV_PCT=200    # download ceiling = base * 200% -> up to 2x the plan
UL_OVERPROV_PCT=200    # upload ceiling; set 100 if the ISP gives exactly the plan
MIN_PCT=60             # floor   = base * 60%   (fixed link: never needs to go lower)

# --- profile ----------------------------------------------------------------
PROFILE="balanced"     # balanced   = the values below
                       # throughput = idle ping < 30 ms may rise 27.5 ms (cap 50 ms), else 1.5x;
                       #              never below plan when overprovisioned
                       # fibre-throughput = throughput with a 20 ms cap (FIBRE_MAX_PING_MS)
                       # extra      = ignore ping, run at the ceiling, back off only on loss
                       # (throughput/extra floor overprovisioned directions at plan and
                       #  override the bloat and cut/probe knobs; MIN_PCT still applies
                       #  to a direction capped at 100%)
# throughput ping budget, per reflector:
THROUGHPUT_LOW_PING_MS=30    # idle ping below this...
THROUGHPUT_LOW_EXTRA_MS=27.5 # ...may rise this much under load...
THROUGHPUT_MAX_PING_MS=50    # ...but never past this
THROUGHPUT_PCT=50            # idle ping >= LOW_PING: may rise this % (50 = 1.5x);
                             # also the minimum allowance when the cap is tighter
FIBRE_MAX_PING_MS=20         # fibre-throughput: cap instead of THROUGHPUT_MAX_PING_MS

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
