#!/usr/bin/env bash
# Stop KM Simics sessions owned by this project (tracked long-sim PIDs + leftovers).
# Never kills the km-ci agent itself (self/parent / km-ci scripts).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

log() { echo "[stop-simics] $*"; }

SELF_PID=$$
PARENT_PID=$PPID

is_protected() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  [[ "$pid" == "$SELF_PID" || "$pid" == "$PARENT_PID" ]] && return 0
  # Walk parents up a few levels — do not kill agent tree
  local p="$pid" i
  for i in 1 2 3 4 5; do
    [[ -z "$p" || "$p" == "1" ]] && break
    if [[ "$p" == "$SELF_PID" || "$p" == "$PARENT_PID" ]]; then
      return 0
    fi
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)"
  done
  return 1
}

# True if cmdline looks like a Simics *simulation* (not km-ci helper scripts).
is_simics_target() {
  local cmd="$1"
  # Explicit excludes: agent / helpers whose paths contain the substring "simics"
  case "$cmd" in
    *km-ci*|*stop-simics*|*run-once.sh*|*agent.log*|*km_uboot_expect*)
      return 1
      ;;
  esac
  # Launchers / binary
  case "$cmd" in
    */simics\ *|*/simics|*/simics\t*|*" $KM_HPS/simics"*|*"$KM_HPS/simics "*)
      return 0
      ;;
    *run-osbv-smp.sh*|*run-osbv-smp-usb*|*/bin/simics*|*/intel-fpga*/simics*)
      return 0
      ;;
  esac
  # Standalone word "simics" as argv0 path ending (avoid matching stop-simics)
  if [[ "$cmd" =~ (^|[[:space:]])([^[:space:]]*/)?simics([[:space:]]|$) ]]; then
    return 0
  fi
  return 1
}

kill_pid() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  if is_protected "$pid"; then
    log "skip protected PID $pid"
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  local cmd
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  if [[ -n "$cmd" ]] && ! is_simics_target "$cmd"; then
    # Allow explicit kills from long-sims.pids / registry even if cmdline odd
    if [[ "${2:-}" != "force" ]]; then
      log "skip non-simics PID $pid ($cmd)"
      return 0
    fi
  fi
  log "SIGTERM $pid (${cmd:0:80})"
  kill -TERM "$pid" 2>/dev/null || true
}

# 1) Tracked long-sim PIDs (force — we recorded them)
if [[ -f "$KM_CI_LONG_PIDS" ]]; then
  while IFS='=' read -r key val || [[ -n "${key:-}" ]]; do
    [[ "$key" =~ ^[ABC]_PID$ ]] || continue
    kill_pid "$val" force
  done <"$KM_CI_LONG_PIDS"
fi

# 2) Instance registry under XDG_RUNTIME_DIR
REG_DIR="${KM_SIMICS_REG_DIR:-${XDG_RUNTIME_DIR:-/tmp}/km-simics/instances}"
if [[ -d "$REG_DIR" ]]; then
  for f in "$REG_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    kill_pid "${PID:-}" force
  done
fi

# 3) Project leftovers by cmdline
# shellcheck disable=SC2009
while read -r pid; do
  [[ -n "$pid" ]] || continue
  kill_pid "$pid"
done < <(
  ps -eo pid=,args= 2>/dev/null | while read -r pid args; do
    [[ -n "$pid" ]] || continue
    if is_simics_target "$args" && [[ "$args" == *"$KM_HPS"* || "$args" == *run-osbv-smp* ]]; then
      echo "$pid"
    fi
  done || true
)

# 4) Processes with cwd under KM_HPS whose cmdline is a real simics target
for pid_dir in /proc/[0-9]*; do
  pid="${pid_dir##*/}"
  cwd="$(readlink "$pid_dir/cwd" 2>/dev/null || true)"
  [[ "$cwd" == "$KM_HPS"* ]] || continue
  cmdline="$(tr '\0' ' ' <"$pid_dir/cmdline" 2>/dev/null || true)"
  if is_simics_target "$cmdline"; then
    kill_pid "$pid"
  fi
done

sleep 2
# Escalate stubborn tracked PIDs only
if [[ -f "$KM_CI_LONG_PIDS" ]]; then
  while IFS='=' read -r key val || [[ -n "${key:-}" ]]; do
    [[ "$key" =~ ^[ABC]_PID$ ]] || continue
    if is_protected "$val"; then
      continue
    fi
    if kill -0 "$val" 2>/dev/null; then
      log "SIGKILL $val"
      kill -KILL "$val" 2>/dev/null || true
    fi
  done <"$KM_CI_LONG_PIDS"
fi

# Wait for telnet ports to free (do not fuser-kill blindly if agent somehow bound — it is not)
for port in "$KM_CI_GATE_TELNET" "$KM_CI_LONG_A_TELNET" "$KM_CI_LONG_B_TELNET" "$KM_CI_LONG_C_TELNET"; do
  deadline=$((SECONDS + KM_CI_STOP_WAIT))
  while (( SECONDS < deadline )); do
    if ! ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port"; then
      break
    fi
    # Kill only listeners on that port (simics telnet)
    fuser -k "${port}/tcp" 2>/dev/null || true
    sleep 1
  done
done

: >"$KM_CI_LONG_PIDS"
log "done"
