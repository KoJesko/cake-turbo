# cake-turbo

Aggressive CAKE autorate for **fixed-rate links the ISP overprovisions** (shaper
ranges from 60% up to 200% of the plan rate). Replaces cake-autorate on the router;
SQM's cake qdiscs stay, this only moves their `bandwidth`.

How it differs from stock cake-autorate:

| | cake-autorate | cake-turbo |
|---|---|---|
| ceiling | `max_*_shaper_rate_kbps` | base × `DL_OVERPROV_PCT` / `UL_OVERPROV_PCT` (default 200%; set upload to 100% if it is never overprovisioned) |
| idle | decays to base | parks at the learned-good rate (constant link) |
| ramp | fixed step | +20%/tick back to learned-good, then +4% of base/tick probing (+1% for 30 s after a bloat) |
| on bloat | cut to throughput × factor | same, and remembers 95% of it as learned-good |
| both directions busy | cut both | only cut the one that was probing |

## Profiles

`PROFILE` in `config.sh` sets how much ping you trade for speed:

| `PROFILE` | under load | floor | reacts to |
|---|---|---|---|
| `balanced` (default) | the knobs in `config.sh` (+15 ms RTT threshold) | `MIN_PCT` of plan | RTT rise or probe loss |
| `throughput` | idle ping < 30 ms may rise 27.5 ms, capped at 50 ms; higher pings may rise 1.5x | plan rate (if overprovisioned) | RTT nearing that budget (per reflector), or loss |
| `fibre-throughput` | same as `throughput`, but loaded ping capped at 20 ms (`FIBRE_MAX_PING_MS`); reacts at 35% of the budget | plan rate (if overprovisioned) | RTT nearing that budget, or loss |
| `extra` | ping ignored; runs at the ceiling when busy | plan rate (if overprovisioned) | probe loss only (ISP buffer overflowing) |

The `throughput` budget is set by `THROUGHPUT_LOW_PING_MS`, `THROUGHPUT_LOW_EXTRA_MS`,
`THROUGHPUT_MAX_PING_MS` and `THROUGHPUT_PCT`; it reacts at 55% of the budget so the
overshoot after a cut stays inside it. Where the cap leaves less room than
`THROUGHPUT_PCT` (an idle ping already near the cap), the % rule applies instead.

`throughput` and `extra` floor each overprovisioned direction at the plan rate and override
the bloat threshold and the cut/probe knobs. A direction capped at 100% (e.g. upload with
`UL_OVERPROV_PCT=100`) keeps its `MIN_PCT` floor so it can still back off.
For any other mix, stay on `balanced` and set the knobs yourself; `DELAY_THR_PCT`
(relative threshold) and `IGNORE_DELAY=1` work there too.

## Deploy (over WireGuard)

```sh
./deploy.sh root@<router-wg-ip>              # install / update (keeps router's config.sh)
./deploy.sh root@<router-wg-ip> --rollback   # back to cake-autorate
```

To manage the config from your PC instead (e.g. a private repo per site):

```sh
SITE_CONFIG=sites/home/config.sh ./deploy.sh root@<router-ip>   # router's old config -> config.sh.bak
```

Otherwise the first install imports interfaces and plan rates from `/root/cake-autorate/config.primary.sh`
(or SQM uci). Check that `DL_BASE_KBPS`/`UL_BASE_KBPS` are the **plan** rates.

## On the router

```sh
bash /root/cake-turbo/cake-turbo.sh status   # live rates / learned-good / load
logread -e cake-turbo                        # once-a-minute summaries when it cut
vi /root/cake-turbo/config.sh && /etc/init.d/cake-turbo restart
```

## LuCI

If LuCI is installed, `install.sh` adds **Network → CAKE Turbo**: live rates (refreshed every 2 s),
profile and plan/ceiling/budget settings (saved to `/root/cake-turbo/config.sh`, then the
service restarts), start/stop/boot buttons and the recent log. It is a JS view plus an rpcd
plugin (`/usr/libexec/rpcd/cake-turbo`, ubus object `cake-turbo`). A later
`SITE_CONFIG=... ./deploy.sh` overwrites settings changed in LuCI.

## Test without a router

`python3 sim.py` runs the real controller for 62 s against a simulated line
(fake tc, fake /sys counters, fake fping with ISP-queue RTT) and prints a per-phase table.
