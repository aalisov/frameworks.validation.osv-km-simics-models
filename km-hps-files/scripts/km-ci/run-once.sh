#!/usr/bin/env bash
# One-shot KM CI cycle (concept v2):
#   lock → poll → (if new|force) stop → stage → smoke → publish/email smoke
#   → long sims unless BLOCKED → always publish/email runs (all|some|none)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

mkdir -p "$KM_CI_VAR" "$KM_CI_RESULTS"

ts() { date -Iseconds; }
log() { echo "$(ts) [run-once] $*"; }
# Mirror stdout/stderr into agent.log without hiding the terminal
exec > >(tee -a "$KM_CI_AGENT_LOG") 2>&1

publish_runs_always() {
  log "publish runs status (all/some/none)"
  if [[ "${KM_CI_PUBLISH_WEB:-1}" == "1" ]]; then
    PUBLISH_ARGS=(--url "${KM_SIMICS_RUNS_URL:-${SHARE_ROOT}/simics-runs/}")
    if [[ -n "${KM_SIMICS_WEB_GIT:-}${KM_SIMICS_RUNS_GIT:-}${KM_SIMICS_RUNS_DEST:-}" ]]; then
      PUBLISH_ARGS+=(--publish)
      [[ -n "${KM_SIMICS_RUNS_DEST:-}" ]] && PUBLISH_ARGS+=(--dest "$KM_SIMICS_RUNS_DEST")
      [[ -n "${KM_SIMICS_RUNS_GIT:-}" ]] && PUBLISH_ARGS+=(--git "$KM_SIMICS_RUNS_GIT")
    fi
    "$KM_HPS/scripts/host/km-simics-instances-publish.sh" "${PUBLISH_ARGS[@]}" || \
      log "WARN: instances-publish failed (non-fatal)"
  fi
  local st="none" up=0 total=0
  if [[ -f "$KM_CI_VAR/last-long-status.txt" ]]; then
    # shellcheck disable=SC1090
    st="$(awk -F= '/^status=/{print $2; exit}' "$KM_CI_VAR/last-long-status.txt" 2>/dev/null || echo none)"
    up="$(awk -F= '/^up=/{print $2; exit}' "$KM_CI_VAR/last-long-status.txt" 2>/dev/null || echo 0)"
    total="$(awk -F= '/^total=/{print $2; exit}' "$KM_CI_VAR/last-long-status.txt" 2>/dev/null || echo 0)"
  fi
  case "$st" in
    all) "$SCRIPT_DIR/notify.sh" runs-up "long sims up $up/$total — ${KM_SIMICS_RUNS_URL:-}" ;;
    partial) "$SCRIPT_DIR/notify.sh" runs-partial "long sims partial $up/$total — ${KM_SIMICS_RUNS_URL:-}" ;;
    *) "$SCRIPT_DIR/notify.sh" runs-none "long sims none up ($up/$total) — ${KM_SIMICS_RUNS_URL:-}" ;;
  esac
}

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
set +e
"$SCRIPT_DIR/stop-simics.sh"
stop_rc=$?
set -e
if [[ $stop_rc -ne 0 ]]; then
  log "stop-simics exited $stop_rc (continuing)"
fi

log "stage latest"
if ! "$SCRIPT_DIR/stage-latest.sh" "$KM_CI_FLAVOR"; then
  log "stage FAILED — BLOCKED"
  printf 'BLOCKED\n' >"$KM_CI_VAR/last-gate-overall.txt"
  "$SCRIPT_DIR/notify.sh" blocked "stage failed — see $KM_CI_AGENT_LOG"
  # Prior sims were killed; publish empty/down runs table
  : >"$KM_CI_LONG_PIDS"
  printf 'total=0\nup=0\ndown=0\nstatus=none\n' >"$KM_CI_VAR/last-long-status.txt"
  publish_runs_always
  exit 1
fi

log "run gate (smoke)"
set +e
"$SCRIPT_DIR/run-gate.sh"
gate_rc=$?
set -e
OVERALL="$(cat "$KM_CI_VAR/last-gate-overall.txt" 2>/dev/null || echo BLOCKED)"
log "smoke overall=$OVERALL (rc=$gate_rc)"

case "$OVERALL" in
  PASS)
    "$SCRIPT_DIR/notify.sh" pass "smoke PASS — ${KM_SIMICS_STATUS_URL:-} — $KM_CI_RESULTS"
    ;;
  FAIL)
    "$SCRIPT_DIR/notify.sh" fail "smoke FAIL — ${KM_SIMICS_STATUS_URL:-} — $KM_CI_RESULTS"
    ;;
  *)
    OVERALL=BLOCKED
    "$SCRIPT_DIR/notify.sh" blocked "smoke BLOCKED — ${KM_SIMICS_STATUS_URL:-} — $KM_CI_RESULTS"
    ;;
esac

if [[ "$OVERALL" == "BLOCKED" ]]; then
  log "smoke BLOCKED — skip long sims; publish runs (none)"
  : >"$KM_CI_LONG_PIDS"
  printf 'total=0\nup=0\ndown=0\nstatus=none\n' >"$KM_CI_VAR/last-long-status.txt"
  publish_runs_always
  log "=== done (blocked) ==="
  exit 2
fi

if [[ "${KM_CI_SKIP_LONG:-0}" == "1" ]]; then
  log "KM_CI_SKIP_LONG=1 — skip long sims; publish runs"
  printf 'total=0\nup=0\ndown=0\nstatus=none\n' >"$KM_CI_VAR/last-long-status.txt"
  publish_runs_always
else
  log "launch long sims (selection=${KM_CI_LONG_SCRIPTS:-all})"
  set +e
  "$SCRIPT_DIR/launch-long-sims.sh"
  long_rc=$?
  set -e
  if [[ $long_rc -ne 0 ]]; then
    log "long sims script exited $long_rc (still publishing runs)"
    if [[ ! -f "$KM_CI_VAR/last-long-status.txt" ]]; then
      printf 'total=0\nup=0\ndown=0\nstatus=none\n' >"$KM_CI_VAR/last-long-status.txt"
    fi
  fi
  # launch-long-sims already publishes when DEST set; still email runs status
  local_st="$(awk -F= '/^status=/{print $2; exit}' "$KM_CI_VAR/last-long-status.txt" 2>/dev/null || echo none)"
  local_up="$(awk -F= '/^up=/{print $2; exit}' "$KM_CI_VAR/last-long-status.txt" 2>/dev/null || echo 0)"
  local_total="$(awk -F= '/^total=/{print $2; exit}' "$KM_CI_VAR/last-long-status.txt" 2>/dev/null || echo 0)"
  case "$local_st" in
    all) "$SCRIPT_DIR/notify.sh" runs-up "long sims up $local_up/$local_total — ${KM_SIMICS_RUNS_URL:-}" ;;
    partial) "$SCRIPT_DIR/notify.sh" runs-partial "long sims partial $local_up/$local_total — ${KM_SIMICS_RUNS_URL:-}" ;;
    *) "$SCRIPT_DIR/notify.sh" runs-none "long sims none up ($local_up/$local_total) — ${KM_SIMICS_RUNS_URL:-}" ;;
  esac
fi

log "=== success (smoke=$OVERALL) ==="
exit 0
