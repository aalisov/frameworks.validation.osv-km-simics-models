# KM share-poll Simics auto-test agent (`km-ci`)

Polls `http://alisubun1.sj.altera.com/osbv-yo/KM/latest/MANIFEST.txt` for new
**osbv_sdmmc** drops, stages into `~/km-hps`, runs U-Boot + Linux gate tests,
and on PASS launches three long-lived network-enabled Simics sessions.

## Install into `~/km-hps`

From the models repo:

```bash
cd ~/osbv-simics/frameworks.validation.osv-km-simics-models   # or your clone path
./setup-into-simics-project.sh -p ~/km-hps --scripts-only --force
```

Runtime state (not in git):

| Path | Purpose |
|------|---------|
| `~/km-hps/var/` | lock, last MANIFEST fingerprint, long-sim PIDs, `agent.log` |
| `~/km-hps/test-results/<date>/` | gate SUMMARY + console logs + long-{A,B,C} |

## Manual one-shot

```bash
cd ~/km-hps
./scripts/km-ci/run-once.sh

# Force re-stage + gate even if MANIFEST unchanged:
KM_CI_FORCE=1 ./scripts/km-ci/run-once.sh

# Gate only (no long sims):
KM_CI_SKIP_LONG=1 ./scripts/km-ci/run-once.sh
```

Individual steps:

```bash
./scripts/km-ci/poll-share.sh          # exit 0=new, 10=same
./scripts/km-ci/stop-simics.sh
./scripts/km-ci/stage-latest.sh osbv
./scripts/km-ci/run-gate.sh
./scripts/km-ci/launch-long-sims.sh
```

## systemd user timer (ghrdbld1)

```bash
mkdir -p ~/.config/systemd/user
cp ~/km-hps/scripts/km-ci/systemd/km-ci-agent.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now km-ci-agent.timer
systemctl --user list-timers | grep km-ci
journalctl --user -u km-ci-agent.service -f
# also: ~/km-hps/var/agent.log
```

Linger (so the timer runs without an interactive login):

```bash
loginctl enable-linger "$USER"
```

## Gate tests

One Simics session (`stop_at_uboot` + eth):

1. For each script on the SDMMC FAT partition (`km-tests/`):
   `fatload mmc ${mmcdev}:1 ${scriptaddr} km-tests/<name>.scr` then
   `source ${scriptaddr}` — expect `KM_TEST: <stem> PASS`
   (default set: `fdt.scr,i2c.scr,i3c.scr,usb.scr,eth.scr`; image also has `spi.scr`)
2. `run boot_mmc` (SDMMC Linux — not host `booti`, which stalls in CI)
3. Linux smoke (login, `nproc`, eth/ping)

Override: `KM_CI_UBOOT_SCR_MODE=paste` uses host `uboot-scr/*.scr` line-by-line
(legacy). Results: `test-results/<MANIFEST-date>/gate/gate-SUMMARY.md`

## Long sims (after gate PASS)

| ID | Command | Telnet |
|----|---------|--------|
| A | `run-osbv-smp.sh … stop_at_uboot=TRUE` | 9123 |
| B | `run-osbv-smp.sh …` (SDMMC → Linux) | 9124 |
| C | `run-osbv-smp-usb31-usbip.sh …` | 9125 |

Attach: `telnet 127.0.0.1 <port>`. Stop: `./scripts/km-ci/stop-simics.sh`.

After B/C reach Linux login, launch waits on UART, logs in as `root`, and runs
`${KM_CI_GUEST_ETH_SETUP}` (default `./setup-simics-eth0.sh`), then pings the
Simics gateway. Skip with `KM_CI_LONG_SETUP_ETH=0`. Logs: `test-results/.../long/{B,C}/guest-eth.log`.

USBIP (C) needs host-side vudc setup — see `docs/KM-SIMICS-USBIP.md`.

## Apache publish (alisubun1)

Under `/DISK1/nfs/webdata/osbv-yo/KM/`:

| Folder | Content | Script |
|--------|---------|--------|
| `simics-status/` | latest gate smoke SUMMARY | `publish-gate-status.sh` |
| `simics-runs/` | live instance table (SSH/telnet) | `../host/km-simics-instances-publish.sh` |

```bash
# One-shot local generate + push (NFS mount or scp):
KM_SIMICS_RUNS_DEST=/DISK1/nfs/webdata/osbv-yo/KM/simics-runs \
  ./scripts/host/km-simics-instances-publish.sh --publish

KM_SIMICS_STATUS_DEST=/DISK1/nfs/webdata/osbv-yo/KM/simics-status \
  ./scripts/km-ci/publish-gate-status.sh --publish

# Or remote:
KM_SIMICS_RUNS_DEST='alisov@alisubun1:/DISK1/nfs/webdata/osbv-yo/KM/simics-runs' \
KM_SIMICS_STATUS_DEST='alisov@alisubun1:/DISK1/nfs/webdata/osbv-yo/KM/simics-status' \
  ./scripts/km-ci/run-once.sh   # auto-publishes when DEST set (KM_CI_PUBLISH_WEB=1)
```

URLs: `${SHARE_ROOT}/simics-status/` and `${SHARE_ROOT}/simics-runs/`.

## Config

Defaults live in [`config.env`](config.env). Override with environment variables
(`SHARE_ROOT`, `KM_HPS`, `KM_CI_SKIP_LONG`, `KM_CI_FORCE`, timeouts, ports,
`KM_SIMICS_RUNS_DEST`, `KM_SIMICS_STATUS_DEST`).

Notifications: stub [`notify.sh`](notify.sh); set `KM_CI_NOTIFY_CMD` for a custom hook.

## v1 scope

- Flavor: **osbv** first (emul uses the same poll/stage paths; gate/long matrix later).
- Driver: bash + systemd (Cursor Automation can wrap reporting later).
