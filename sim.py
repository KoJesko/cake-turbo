#!/usr/bin/env python3
"""Closed-loop simulator for cake-turbo.sh — no router needed.

    python3 sim.py            run the 60 s scenario and print a per-phase report

The real controller runs unmodified; only its three test hooks are swapped:
  TC        -> fake tc that writes the requested rate to <sim>/<iface>.rate
  STATS_DIR -> fake /sys/class/net with tx_bytes we advance
  PING_CMD  -> this file in "pinger" mode, printing fping -l style lines whose
               RTT = base + ISP queue delay. The ISP queue grows whenever the
               shaper lets more through than the line's real capacity.
"""
import os, random, shutil, signal, subprocess, sys, tempfile, time

# Scenario knobs (env): SIM_DL_BASE / SIM_UL_BASE = plan kbit/s,
# SIM_DL_LINE / SIM_UL_LINE / SIM_DL_EVENING = real line as a multiple of plan,
# SIM_CFG = extra config.sh lines (e.g. "UL_OVERPROV_PCT=100").
E = os.environ.get
BASE = {"dl": int(E("SIM_DL_BASE", 300_000)), "ul": int(E("SIM_UL_BASE", 30_000))}
DLX, ULX, EVE = float(E("SIM_DL_LINE", 1.7)), float(E("SIM_UL_LINE", 1.5)), float(E("SIM_DL_EVENING", 1.2))
IFACE = {"dl": "ifb4wan", "ul": "wan"}
BUF_S = 0.25                                    # ISP buffer depth (seconds of line rate)
REFL = ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112"]
REFL_RTT = [12.0, 12.5, 18.0, 18.2, 22.0, 22.4]

# (start_s, end_s, label, dl_busy, ul_busy, dl_capacity_x, ul_capacity_x)
PHASES = [
    (0, 4, "idle", 0, 0, DLX, ULX),
    (4, 22, f"dl saturated, line = {DLX}x plan", 1, 0, DLX, ULX),
    (22, 26, "idle", 0, 0, DLX, ULX),
    (26, 36, f"ul saturated, line = {ULX}x plan", 0, 1, DLX, ULX),
    (36, 46, "dl+ul saturated", 1, 1, DLX, ULX),
    (46, 49, "idle", 0, 0, DLX, ULX),
    (49, 62, f"dl saturated, evening: line = {EVE}x", 1, 0, EVE, ULX),
]
DURATION = PHASES[-1][1]


def phase_at(t):
    for p in PHASES:
        if p[0] <= t < p[1]:
            return p
    return PHASES[-1]


def pinger(sim):
    t0 = float(open(f"{sim}/t0").read())
    q = {"dl": 0.0, "ul": 0.0}                  # ISP queue, kbit
    txb = {"dl": 0.0, "ul": 0.0}
    seq = [0] * len(REFL)
    trace = open(f"{sim}/trace.csv", "w")
    last, i, next_ping, next_trace = time.time(), 0, 0.0, 0.0
    out = sys.stdout
    while True:
        time.sleep(0.005)
        now = time.time(); dt = now - last; last = now
        t = now - t0
        _, _, _, dlb, ulb, dlx, ulx = phase_at(t)
        busy = {"dl": dlb, "ul": ulb}
        cap = {"dl": BASE["dl"] * dlx, "ul": BASE["ul"] * ulx}
        for d in ("dl", "ul"):
            try:
                rate = float(open(f"{sim}/{IFACE[d]}.rate").read())
            except (OSError, ValueError):
                rate = BASE[d]
            # TCP fills whichever is slower; if the shaper is faster than the
            # line, the excess piles up in the ISP buffer (that's the bloat).
            offered = rate if busy[d] else 0.02 * BASE[d]
            q[d] = min(max(q[d] + (offered - cap[d]) * dt, 0.0), cap[d] * BUF_S)
            delivered = min(offered, cap[d])
            txb[d] += delivered * dt * 1000 / 8
            with open(f"{sim}/net/{IFACE[d]}/statistics/tx_bytes", "w") as f:
                f.write(f"{int(txb[d])}\n")
        qdelay = sum(q[d] / cap[d] for d in q) * 1000   # ms
        if t >= next_ping:                       # 6 reflectors x 300 ms period
            next_ping = t + 0.05
            k = i % len(REFL); i += 1
            rtt = REFL_RTT[k] + qdelay + random.uniform(-1.5, 1.5)
            if rtt > 300:
                out.write(f"{REFL[k]} : [{seq[k]}], timed out (0.0 avg, 1% loss)\n")
            else:
                out.write(f"{REFL[k]} : [{seq[k]}], 64 bytes, {rtt:.2f} ms ({rtt:.2f} avg, 0% loss)\n")
            seq[k] += 1
            out.flush()
        if t >= next_trace:
            next_trace = t + 0.1
            r = {}
            for d in ("dl", "ul"):
                try: r[d] = float(open(f"{sim}/{IFACE[d]}.rate").read())
                except (OSError, ValueError): r[d] = BASE[d]
            trace.write(f"{t:.2f},{r['dl']:.0f},{cap['dl']:.0f},{r['ul']:.0f},{cap['ul']:.0f},{qdelay:.2f}\n")
            trace.flush()


FAKE_TC = """#!/bin/bash
[[ $2 == show ]] && { echo "qdisc cake 8001: root refcnt 2"; exit 0; }
echo "${8%Kbit}" > "$SIM_DIR/$5.rate"
"""


def run():
    here = os.path.dirname(os.path.abspath(__file__))
    sim = tempfile.mkdtemp(prefix="cake-turbo-sim.")
    for d in IFACE.values():
        os.makedirs(f"{sim}/net/{d}/statistics")
        open(f"{sim}/net/{d}/statistics/tx_bytes", "w").write("0\n")
    open(f"{sim}/tc", "w").write(FAKE_TC); os.chmod(f"{sim}/tc", 0o755)
    cfg = open(f"{here}/config.sh").read()
    cfg = cfg.replace('DL_BASE_KBPS=""', f'DL_BASE_KBPS="{BASE["dl"]}"')
    cfg = cfg.replace('UL_BASE_KBPS=""', f'UL_BASE_KBPS="{BASE["ul"]}"')
    cfg = cfg.replace('DL_IF=""', 'DL_IF="ifb4wan"').replace('UL_IF=""', 'UL_IF="wan"')
    cfg += "\n" + E("SIM_CFG", "").replace(";", "\n") + "\n"
    open(f"{sim}/config.sh", "w").write(cfg)
    open(f"{sim}/t0", "w").write(str(time.time()))
    env = dict(os.environ, SIM_DIR=sim, TC=f"{sim}/tc", STATS_DIR=f"{sim}/net",
               CAKE_TURBO_CONFIG=f"{sim}/config.sh", CAKE_TURBO_STATUS=f"{sim}/status",
               PING_CMD=f"python3 -I {os.path.abspath(__file__)} pinger {sim}", LOG_STDERR="1")
    print(f"simulating {DURATION}s (sim dir {sim}) ...", flush=True)
    p = subprocess.Popen(["bash", f"{here}/cake-turbo.sh"], env=env)
    time.sleep(DURATION)
    print("--- final status ---"); print(open(f"{sim}/status").read())
    p.send_signal(signal.SIGTERM); p.wait(timeout=5)
    report(sim)
    shutil.rmtree(sim)


def report(sim):
    rows = [list(map(float, l.split(","))) for l in open(f"{sim}/trace.csv")]
    print(f"{'phase':44} {'dl rate/line':>12} {'ul rate/line':>12} {'+RTT p50':>9} {'p95':>6} {'max':>6}")
    for s, e, label, dlb, ulb, *_ in PHASES:
        seg = [r for r in rows if s + 1 <= r[0] < e]     # skip the first second of each phase
        if not seg: continue
        dl = sum(r[1] / r[2] for r in seg) / len(seg)
        ul = sum(r[3] / r[4] for r in seg) / len(seg)
        qd = sorted(r[5] for r in seg)
        print(f"{label:44} {dl:11.0%} {ul:12.0%} {qd[len(qd)//2]:8.1f}ms {qd[int(len(qd)*.95)]:5.1f} {qd[-1]:5.1f}")
    print("rate/line = shaper rate vs the line's real capacity (aim: just under 100% when busy)")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "pinger":
        try: pinger(sys.argv[2])
        except (BrokenPipeError, KeyboardInterrupt): pass
    else:
        run()
