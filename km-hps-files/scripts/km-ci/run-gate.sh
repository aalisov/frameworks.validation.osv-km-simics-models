#!/usr/bin/env bash
# Gate: one Simics (stop_at_uboot+eth) → U-Boot FAT km-tests/*.scr + `run boot_mmc` Linux smoke.
# Default: fatload mmc ${mmcdev}:1 ${scriptaddr} km-tests/<name>.scr && source ${scriptaddr}
# Host-side booti is intentionally NOT used (stalls mid-echo in CI).
#
# Exit 0 = all PASS; non-zero = FAIL (long sims must not launch).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

EXPECT_PY="$SCRIPT_DIR/km_uboot_expect.py"
SCR_DIR="$SCRIPT_DIR/uboot-scr"
RUN_OSBV="$KM_HPS/scripts/run-osbv-smp.sh"
[[ -x "$RUN_OSBV" ]] || { echo "ERROR: missing $RUN_OSBV" >&2; exit 1; }
[[ -f "$EXPECT_PY" ]] || { echo "ERROR: missing $EXPECT_PY" >&2; exit 1; }

PUBLISH_DATE="unknown"
if [[ -f "$KM_CI_LAST_MANIFEST" ]]; then
  PUBLISH_DATE="$(awk -F': *' '/^date:/{print $2; exit}' "$KM_CI_LAST_MANIFEST" || echo unknown)"
fi
PUBLISH_DATE="${PUBLISH_DATE:-unknown}"
RESULT_DIR="${KM_CI_RESULTS}/${PUBLISH_DATE}/gate"
mkdir -p "$RESULT_DIR"

SUMMARY_MD="$RESULT_DIR/gate-SUMMARY.md"
SUMMARY_JSON="$RESULT_DIR/gate-SUMMARY.json"
SESSION_JSON="$RESULT_DIR/gate-session.json"
CONSOLE_LOG="$RESULT_DIR/console.log"
SIMICS_LOG="$RESULT_DIR/simics-gate.log"

# Image FAT has fdt.scr (plan "dt.scr"), plus i2c/i3c/usb/eth; spi.scr also present.
IFS=',' read -r -a SCRIPTS <<<"${KM_CI_UBOOT_SCRS}"
SCRS_CSV=$(IFS=,; echo "${SCRIPTS[*]}")
SCR_MODE="${KM_CI_UBOOT_SCR_MODE:-fatload}"

log() { echo "[gate] $*"; echo "[gate] $*" >>"$RESULT_DIR/gate.log"; }

cleanup_gate_sim() {
  if [[ -n "${GATE_PID:-}" ]] && kill -0 "$GATE_PID" 2>/dev/null; then
    log "stopping gate Simics PID=$GATE_PID"
    kill -TERM "$GATE_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$GATE_PID" 2>/dev/null || true
  fi
  fuser -k "${KM_CI_GATE_TELNET}/tcp" 2>/dev/null || true
}
trap cleanup_gate_sim EXIT

export TELNET_PORT="$KM_CI_GATE_TELNET"
export SIMICS_INSTANCE=0
: >"$CONSOLE_LOG"
: >"$SIMICS_LOG"
: >"$RESULT_DIR/gate.log"

log "starting gate Simics (stop_at_uboot + eth) on telnet $KM_CI_GATE_TELNET"
(
  cd "$KM_HPS"
  # shellcheck disable=SC1091
  source ./set_simics_env_main.sh
  exec ./scripts/run-osbv-smp.sh \
    create_hps_eth0_network=TRUE \
    stop_at_uboot=TRUE
) >"$SIMICS_LOG" 2>&1 &
GATE_PID=$!
log "gate Simics PID=$GATE_PID"
sleep 3
if ! kill -0 "$GATE_PID" 2>/dev/null; then
  log "ERROR: gate Simics exited early — see $SIMICS_LOG"
  tail -40 "$SIMICS_LOG" >&2 || true
  exit 1
fi

log "gate-session: U-Boot ${SCR_MODE} scrs + run boot_mmc + Linux smoke"
set +e
GATE_ARGS=(
  --host 127.0.0.1 --port "$KM_CI_GATE_TELNET"
  --prompt "$KM_CI_UBOOT_PROMPT" --log "$CONSOLE_LOG"
  gate-session
  --scr-mode "$SCR_MODE"
  --scrs "$SCRS_CSV"
  --fat-dir "${KM_CI_UBOOT_FAT_DIR}"
  --mmc-spec "${KM_CI_UBOOT_MMC_SPEC}"
  --scriptaddr "${KM_CI_UBOOT_SCRIPTADDR}"
  --boot-cmd "run boot_mmc"
  --uboot-boot-timeout "$KM_CI_UBOOT_BOOT_TIMEOUT"
  --scr-timeout "$KM_CI_SCR_CMD_TIMEOUT"
  --boot-timeout "$KM_CI_LINUX_BOOT_TIMEOUT"
  --timeout "$KM_CI_LINUX_CMD_TIMEOUT"
  --login-re "$KM_CI_LINUX_LOGIN"
  --shell-re "$KM_CI_LINUX_SHELL_RE"
  --user "$KM_CI_LINUX_USER"
  --gateway "$KM_CI_GUEST_GW"
  --guest-ip "$KM_CI_GUEST_ETH_IP"
  --eth
  --results-json "$SESSION_JSON"
)
if [[ "$SCR_MODE" == "paste" ]]; then
  GATE_ARGS+=(--scr-dir "$SCR_DIR")
fi
python3 "$EXPECT_PY" "${GATE_ARGS[@]}"
SESSION_RC=$?
set -e

OVERALL="$(
python3 - "$SESSION_JSON" "$SUMMARY_MD" "$SUMMARY_JSON" "$PUBLISH_DATE" "$SHARE_ROOT" "$SESSION_RC" "$SCRS_CSV" "$SCR_MODE" <<'PY'
import json, sys, socket, datetime
from pathlib import Path

session_path, md_path, js_path, pub, share, rc, scrs_csv, scr_mode = sys.argv[1:9]
scrs = [s.strip() for s in scrs_csv.split(",") if s.strip()]
d = {}
if Path(session_path).is_file():
    d = json.loads(Path(session_path).read_text(encoding="utf-8"))
uboot = d.get("uboot") or {s: "FAIL" for s in scrs}
linux = d.get("linux_smoke", "FAIL")
overall = d.get("overall", "FAIL")
if rc != "0":
    overall = "FAIL"
host = socket.getfqdn()
when = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
how = (
    "fatload mmc ${mmcdev}:1 ${scriptaddr} km-tests/<scr> && source ${scriptaddr}"
    if scr_mode == "fatload"
    else "host paste uboot-scr/<scr>"
)
lines = [
    f"# KM gate SUMMARY — {pub}",
    "",
    f"- Overall: **{overall}**",
    f"- Share: `{share}`",
    f"- Host: {host}",
    f"- When: {when}",
    f"- U-Boot scripts: `{scr_mode}` — {how}",
    "- Linux boot: `run boot_mmc` (SDMMC; not host booti)",
    "",
    "## U-Boot scripts",
    "",
    "| Script | Result |",
    "|--------|--------|",
]
for s in scrs:
    lines.append(f"| `{s}` | {uboot.get(s, 'SKIP')} |")
lines += [
    "",
    "## Linux smoke",
    "",
    "| Check | Result |",
    "|-------|--------|",
    f"| linux-smoke (boot_mmc, login, nproc, eth) | {linux} |",
    "",
    "## Artifacts",
    "",
    f"- `{Path(md_path).parent}`",
    "",
]
Path(md_path).write_text("\n".join(lines), encoding="utf-8")
out = {
    "overall": overall,
    "date": pub,
    "share": share,
    "when": when,
    "scr_mode": scr_mode,
    "boot_cmd": "run boot_mmc",
    "uboot": {s: uboot.get(s, "SKIP") for s in scrs},
    "linux_smoke": linux,
}
Path(js_path).write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
print(overall)
PY
)"

log "SUMMARY → $SUMMARY_MD ($OVERALL)"

if [[ "${KM_CI_PUBLISH_WEB:-1}" == "1" ]]; then
  PUBLISH_ARGS=()
  if [[ -n "${KM_SIMICS_STATUS_DEST:-}" ]]; then
    PUBLISH_ARGS+=(--publish)
  fi
  "$SCRIPT_DIR/publish-gate-status.sh" "${PUBLISH_ARGS[@]}" || \
    log "WARN: publish-gate-status failed (non-fatal)"
fi

cleanup_gate_sim
trap - EXIT

[[ "$OVERALL" == "PASS" ]]
