#!/usr/bin/env bash
# One-shot KM CI cycle: lock → poll → (if new) stop → stage → gate → long → unlock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

mkdir -p "$KM_CI_VAR" "$KM_CI_RESULTS"

ts() { date -Iseconds; }
log() { echo "$(ts) [run-once] $*"; }
# Mirror stdout/stderr into agent.log without hiding the terminal
exec > >(tee -a "$KM_CI_AGENT_LOG") 2>&1

# flock so timer ticks never overlap (WIC stage can take many minutes)
LOCK_FD=9
eval "exec ${LOCK_FD}>\"$KM_CI_LOCK\""
if ! flock -n "$LOCK_FD"; then
  log "another agent run holds $KM_CI_LOCK — exit"
  exit 0
fi

log "=== begin flavor=$KM_CI_FLAVOR force=${KM_CI_FORCE:-0} skip_long=${KM_CI_SKIP_LONG:-0} ==="

set +e
"$SCRIPT_DIR/poll-share.sh" --flavor "$KM_CI_FLAVOR"
poll_rc=$?
set -e
if [[ $poll_rc -eq 10 ]]; then
  log "no new drop — done"
  exit 0
fi
if [[ $poll_rc -ne 0 ]]; then
  log "poll failed rc=$poll_rc"
  "$SCRIPT_DIR/notify.sh" error "poll failed rc=$poll_rc"
  exit "$poll_rc"
fi

log "new drop — stop simics"
# stop must not abort the agent (old bug: stop matched its own cmdline)
set +e
"$SCRIPT_DIR/stop-simics.sh"
stop_rc=$?
set -e
if [[ $stop_rc -ne 0 ]]; then
  log "stop-simics exited $stop_rc (continuing)"
fi

log "stage latest"
if ! "$SCRIPT_DIR/stage-latest.sh" "$KM_CI_FLAVOR"; then
  log "stage FAILED"
  "$SCRIPT_DIR/notify.sh" error "stage failed"
  exit 1
fi

log "run gate"
if ! "$SCRIPT_DIR/run-gate.sh"; then
  log "gate FAILED — not launching long sims"
  "$SCRIPT_DIR/notify.sh" fail "gate FAILED — see $KM_CI_RESULTS"
  exit 1
fi

log "gate PASS"
"$SCRIPT_DIR/notify.sh" pass "gate PASS"

if [[ "${KM_CI_SKIP_LONG:-0}" == "1" ]]; then
  log "KM_CI_SKIP_LONG=1 — skip long sims"
else
  log "launch long sims A/B/C"
  if ! "$SCRIPT_DIR/launch-long-sims.sh"; then
    log "long sims launch FAILED"
    "$SCRIPT_DIR/notify.sh" error "long sims launch failed"
    exit 1
  fi
fi

log "=== success ==="
exit 0
