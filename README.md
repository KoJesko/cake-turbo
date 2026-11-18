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

## Test without a router

`python3 sim.py` runs the real controller for 62 s against a simulated line
(fake tc, fake /sys counters, fake fping with ISP-queue RTT) and prints a per-phase table.
