# KM share-poll Simics auto-test agent (`km-ci`)

Concept v2 validation flow on **ghrdbld1** (`~/km-hps`):

1. **Poll** `SHARE_ROOT` (period = systemd timer) for a new osbv drop, or run when `KM_CI_FORCE=1`.
   Fingerprint: `latest/MANIFEST.txt` if present, else `latest/osbv_sdmmc/SHA256SUMS` (+ `SOURCES.txt`)
2. **Stop → stage → smoke** (U-Boot `km-tests/*.scr` + Linux via `run boot_mmc`)
3. **Publish + email smoke** as **PASS / FAIL / BLOCKED**
4. **Long sims** from a parameterized list — only if smoke is **not** BLOCKED
5. **Always publish + email runs** (all / some / none up), because prior sims were killed at stop

## Install into `~/km-hps`

From the models repo:

```bash
cd ~/osbv-simics/frameworks.validation.osv-km-simics-models   # or your clone path
./setup-into-simics-project.sh -p ~/km-hps --scripts-only --force
```

Runtime state (not in git):

| Path | Purpose |
|------|---------|
| `~/km-hps/var/` | lock, last MANIFEST, long-sim PIDs, last smoke/runs status, `agent.log` |
| `~/km-hps/test-results/<date>/` | gate SUMMARY + console logs + long-{IDs} |

## Manual one-shot

```bash
cd ~/km-hps
./scripts/km-ci/run-once.sh

# Force re-stage + smoke even if MANIFEST unchanged:
KM_CI_FORCE=1 ./scripts/km-ci/run-once.sh

# Smoke only (still publishes/emails runs as none):
KM_CI_SKIP_LONG=1 ./scripts/km-ci/run-once.sh
```

Individual steps:

```bash
./scripts/km-ci/poll-share.sh          # exit 0=new, 10=same
./scripts/km-ci/stop-simics.sh
./scripts/km-ci/stage-latest.sh osbv
./scripts/km-ci/run-gate.sh            # exit 0=PASS, 1=FAIL, 2=BLOCKED
./scripts/km-ci/launch-long-sims.sh
./scripts/km-ci/notify.sh pass "test"
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

## Smoke (gate)

One Simics session (`stop_at_uboot` + eth):

1. For each script on the SDMMC FAT partition (`km-tests/`):
   `fatload mmc ${mmcdev}:1 ${scriptaddr} km-tests/<name>.scr` then
   `source ${scriptaddr}` — expect `KM_TEST: <stem> PASS`
   (default set: `fdt.scr,i2c.scr,i3c.scr,usb.scr,eth.scr`)
2. `run boot_mmc` (SDMMC Linux — not host `booti`)
3. Linux smoke (login, `nproc`, eth/ping)

| Overall | Meaning | Long sims |
|---------|---------|-----------|
| **PASS** | Prompt reached; all checks passed | Launch |
| **FAIL** | Suite finished; one or more checks failed | Launch |
| **BLOCKED** | Incomplete (no U-Boot prompt / Simics died / stage failed) | Skip (still publish runs) |

Results: `test-results/<MANIFEST-date>/gate/gate-SUMMARY.md`  
Also: `var/last-gate-overall.txt`

## Long sims (parameterized)

Catalog: [`long-sims.list`](long-sims.list) — columns  
`id  instance  telnet  guest_eth  script  [args...]`

Select IDs with `KM_CI_LONG_SCRIPTS` (comma list). Empty = all catalog rows.

Default catalog (same as former A/B/C):

| ID | Script | Role | Telnet |
|----|--------|------|--------|
| A | `run-osbv-smp.sh` + `stop_at_uboot=TRUE` | U-Boot | 9123 |
| B | `run-osbv-smp.sh` | SDMMC Linux | 9124 |
| C | `run-osbv-smp-usb31-usbip.sh` | USBIP | 9125 |

```bash
# Only U-Boot + SDMMC Linux:
KM_CI_LONG_SCRIPTS=A,B ./scripts/km-ci/launch-long-sims.sh
```

Attach: `telnet 127.0.0.1 <port>`. Stop: `./scripts/km-ci/stop-simics.sh`.

After Linux instances (`guest_eth=1`) reach login, launch runs
`${KM_CI_GUEST_ETH_SETUP}` (default `/usr/local/pve-hps/bin/setup-simics-eth.sh`).
Skip with `KM_CI_LONG_SETUP_ETH=0`.

Launcher always probes PID+telnet and records `var/last-long-status.txt`
(`status=all|partial|none`). Web publish runs whether all, some, or none are up.

USBIP (C) needs host-side vudc — see `docs/KM-SIMICS-USBIP.md`.

## Email

[`notify.sh`](notify.sh) sends via Altera SMTP (`smtp.altera.com:587`):

```bash
```bash
# Native path (s-nail is installed on ghrdbld1):
echo "haha" | s-nail -S mta="smtp://smtp.altera.com:587" -s "Status..." andrey.lisov@altera.com

./scripts/km-ci/notify.sh info "manual test"
```

| Variable | Default |
|----------|---------|
| `KM_CI_MAIL_ENABLE` | `1` |
| `KM_CI_MAIL_MTA` | `smtp://smtp.altera.com:587` |
| `KM_CI_MAIL_TO` | `andrey.lisov@altera.com` |
| `KM_CI_MAIL_SUBJECT_PREFIX` | `[KM-CI <host>]` |
| `KM_CI_MAIL_FROM` | empty |
| `KM_CI_MAILX` | `s-nail` |
| `KM_CI_NOTIFY_CMD` | optional extra hook |

Disable mail: `KM_CI_MAIL_ENABLE=0`. If `s-nail` is missing, notify falls back to python3 smtplib (`/usr/bin/mailx` is still bsd-mailx).

## Status / runs publish — GitHub (preferred)

Agents push generated pages into one repo (no alisubun1 SSH on Simics hosts):

[altera-sandbox/frameworks.validation.osv-auto.km-simics-web](https://github.com/altera-sandbox/frameworks.validation.osv-auto.km-simics-web)

```
simics-status/   ← smoke SUMMARY (publish-gate-status.sh)
simics-runs/     ← live instance table (km-simics-instances-publish.sh)
```

Defaults in `config.env`:

```bash
KM_SIMICS_WEB_GIT=https://github.com/altera-sandbox/frameworks.validation.osv-auto.km-simics-web.git
KM_SIMICS_STATUS_URL=https://altera-sandbox.github.io/frameworks.validation.osv-auto.km-simics-web/simics-status/
KM_SIMICS_RUNS_URL=https://altera-sandbox.github.io/frameworks.validation.osv-auto.km-simics-web/simics-runs/
```

```bash
# Generate + push (credential helper, deploy key, or KM_CI_GITHUB_TOKEN / GH_TOKEN):
./scripts/km-ci/publish-gate-status.sh --publish
./scripts/host/km-simics-instances-publish.sh --publish
```

Enable GitHub Pages once: repo **Settings → Pages → Deploy from branch `main` / root**.

### Mirror onto alisubun1 Apache (optional)

Agents do **not** SSH to alisubun1. On alisubun1, run a periodic pull:

[`alisubun1/sync-simics-web-from-github.sh`](alisubun1/sync-simics-web-from-github.sh)  
→ git pull GitHub → rsync into `/DISK1/nfs/webdata/osbv-yo/KM/simics-{status,runs}/`.

GitHub **rejects passwords** over HTTPS. Pick one:

1. **Make the repo public** (simplest for a status mirror), or  
2. **Read-only PAT** (Contents: Read) on alisubun1:
   ```bash
   mkdir -p ~/.config
   echo 'ghp_YOUR_TOKEN' > ~/.config/km-simics-web.token
   chmod 600 ~/.config/km-simics-web.token
   ```
3. **Deploy key** + `KM_SIMICS_WEB_GIT=git@github.com:altera-sandbox/frameworks.validation.osv-auto.km-simics-web.git`

```bash
scp ~/km-hps/scripts/km-ci/alisubun1/sync-simics-web-from-github.sh alisov@alisubun1:~/bin/
# cron (as the user that can write webdata — not necessarily root):
*/5 * * * *  $HOME/bin/sync-simics-web-from-github.sh >>$HOME/var/km-simics-web-sync.log 2>&1
```

## Config

Defaults live in [`config.env`](config.env). Override with environment variables
(`SHARE_ROOT`, `KM_HPS`, `KM_CI_SKIP_LONG`, `KM_CI_FORCE`, `KM_CI_LONG_SCRIPTS`,
timeouts, ports, mail, `KM_SIMICS_WEB_GIT`, `KM_CI_GITHUB_TOKEN`).

## v1 scope

- Flavor: **osbv** first (emul uses the same poll/stage paths; gate/long matrix later).
- Driver: bash + systemd.
