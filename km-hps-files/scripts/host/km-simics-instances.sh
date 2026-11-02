#!/usr/bin/env bash
# Track concurrent KM Simics runs on this host: PID, instance #, SSH/telnet ports.
#
# CLI:
#   ./scripts/host/km-simics-instances.sh status          # table of live instances
#   ./scripts/host/km-simics-instances.sh unregister N    # drop registry entry
#   ./scripts/host/km-simics-instances.sh prune           # remove dead PIDs
#
# From a run script (sourced):
#   source ./scripts/host/km-simics-instances.sh
#   km_simics_watch_and_register usb31-device -- "$ROOT/simics" script.simics ...
#   # registers PID, prints one-line report, waits; unregisters on exit
#
# Registry: ${XDG_RUNTIME_DIR:-/tmp}/km-simics/instances/<N>.env
set -euo pipefail

KM_SIMICS_REG_DIR="${KM_SIMICS_REG_DIR:-${XDG_RUNTIME_DIR:-/tmp}/km-simics/instances}"

_km_simics_reg_dir() {
  mkdir -p "$KM_SIMICS_REG_DIR"
  echo "$KM_SIMICS_REG_DIR"
}

_km_simics_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Write registry for instance; fails if another live PID owns the same instance
# (override with KM_SIMICS_FORCE=1).
km_simics_register() {
  local pid="$1"
  local label="${2:-simics}"
  local inst="${SIMICS_INSTANCE:-0}"
  local dir path
  dir="$(_km_simics_reg_dir)"
  path="${dir}/${inst}.env"

  if [[ -f "$path" ]]; then
    # shellcheck disable=SC1090
    source "$path"
    if _km_simics_pid_alive "${PID:-}" && [[ "${PID}" != "$pid" ]]; then
      if [[ "${KM_SIMICS_FORCE:-0}" != "1" ]]; then
        echo "ERROR: instance $inst already live (PID=$PID SSH=${HOST_SSH_PORT:-?}). Use KM_SIMICS_FORCE=1 or another --instance." >&2
        return 1
      fi
      echo "WARN: replacing live instance $inst (old PID=$PID)" >&2
    fi
  fi

  local lan_hint="${HOST_LAN_HINT:-}"
  if [[ -z "$lan_hint" || "$lan_hint" == "0.0.0.0" ]]; then
    lan_hint="${HOST_BIND_IP:-0.0.0.0}"
  fi

  umask 077
  cat >"$path" <<EOF
PID=$pid
SIMICS_INSTANCE=$inst
HOST_SSH_PORT=${HOST_SSH_PORT:-$((4022 + 100 * inst))}
TELNET_PORT=${TELNET_PORT:-$((9123 + inst))}
GUEST_ETH_IP=${GUEST_ETH_IP:-10.10.0.100}
HOST_BIND_IP=${HOST_BIND_IP:-0.0.0.0}
HOST_IFACE=${HOST_IFACE:-}
HOST_LAN_HINT=$lan_hint
LABEL=$label
STARTED=$(date -Iseconds 2>/dev/null || date)
EOF

  km_simics_report_one "$path"
}

km_simics_unregister_instance() {
  local inst="${1:-${SIMICS_INSTANCE:-0}}"
  rm -f "$KM_SIMICS_REG_DIR/${inst}.env"
}

km_simics_unregister_pid() {
  local pid="$1"
  local f
  [[ -d "$KM_SIMICS_REG_DIR" ]] || return 0
  for f in "$KM_SIMICS_REG_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    if [[ "${PID:-}" == "$pid" ]]; then
      rm -f "$f"
    fi
  done
}

km_simics_report_one() {
  local path="$1"
  # shellcheck disable=SC1090
  source "$path"
  local bind="${HOST_BIND_IP:-0.0.0.0}"
  local lan="${HOST_LAN_HINT:-$bind}"
  if [[ "$lan" == "0.0.0.0" || -z "$lan" ]]; then
    lan="<host-LAN-IP>"
  fi
  local ssh_hint="ssh -p ${HOST_SSH_PORT} root@${lan}"
  echo "=== KM Simics instance ${SIMICS_INSTANCE} ==="
  echo "  PID=$PID  LABEL=${LABEL:-}"
  echo "  HOST_SSH_PORT=${HOST_SSH_PORT}  TELNET_PORT=${TELNET_PORT}"
  echo "  GUEST_ETH_IP=${GUEST_ETH_IP}  HOST_BIND_IP=${bind}"
  [[ -n "${HOST_IFACE:-}" ]] && echo "  HOST_IFACE=${HOST_IFACE}"
  echo "  STARTED=${STARTED:-}"
  echo "  Remote: $ssh_hint"
  echo "  Local:  ssh -p ${HOST_SSH_PORT} root@127.0.0.1"
  echo "  UART:   telnet 127.0.0.1 ${TELNET_PORT}"
}

km_simics_prune() {
  local f pid
  [[ -d "$KM_SIMICS_REG_DIR" ]] || return 0
  for f in "$KM_SIMICS_REG_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    pid="${PID:-}"
    if ! _km_simics_pid_alive "$pid"; then
      rm -f "$f"
    fi
  done
}

km_simics_status() {
  km_simics_prune
  local f
  if [[ ! -d "$KM_SIMICS_REG_DIR" ]] || ! compgen -G "$KM_SIMICS_REG_DIR/*.env" >/dev/null; then
    echo "No live KM Simics instances (registry: $KM_SIMICS_REG_DIR)"
    return 0
  fi
  printf "%-8s %-8s %-8s %-8s %-16s %-16s %-20s %s\n" \
    "INSTANCE" "PID" "SSH" "TELNET" "BIND_IP" "LAN_HINT" "STARTED" "LABEL"
  for f in "$KM_SIMICS_REG_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    printf "%-8s %-8s %-8s %-8s %-16s %-16s %-20s %s\n" \
      "${SIMICS_INSTANCE}" "${PID}" "${HOST_SSH_PORT}" "${TELNET_PORT}" \
      "${HOST_BIND_IP:-}" "${HOST_LAN_HINT:-}" "${STARTED:-}" "${LABEL:-}"
  done
  echo
  echo "Registry: $KM_SIMICS_REG_DIR"
  echo "SSH via host NIC: source scripts/host/km-simics-ssh-publish.sh --auto --firewall"
  echo "Docs: docs/KM-SIMICS-ETH.md"
}

# Run Simics, register PID, wait until it really exits.
# Ctrl-C is forwarded as SIGINT → Simics *stops* (pause), does NOT quit.
# Type `run` / `c` at simics> to continue; `quit` to exit.
# Usage: km_simics_watch_and_register <label> -- <command...>
km_simics_watch_and_register() {
  local label="$1"
  shift
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  if [[ $# -lt 1 ]]; then
    echo "USAGE: km_simics_watch_and_register LABEL -- command..." >&2
    return 2
  fi

  : "${SIMICS_INSTANCE:=0}"
  : "${GUEST_ETH_IP:=10.10.0.100}"
  : "${HOST_SSH_PORT:=$((4022 + 100 * SIMICS_INSTANCE))}"
  : "${HOST_BIND_IP:=0.0.0.0}"
  : "${TELNET_PORT:=$((9123 + SIMICS_INSTANCE))}"
  export SIMICS_INSTANCE GUEST_ETH_IP HOST_SSH_PORT HOST_BIND_IP TELNET_PORT

  local sim_pid=""
  _km_simics_on_exit() {
    if [[ -n "${sim_pid:-}" ]]; then
      km_simics_unregister_pid "$sim_pid" || true
    else
      km_simics_unregister_instance "${SIMICS_INSTANCE}" || true
    fi
  }
  # SIGTERM (window kill): tear down Simics. SIGINT: pause only (below).
  _km_simics_on_term() {
    trap - EXIT INT TERM
    if [[ -n "${sim_pid:-}" ]] && _km_simics_pid_alive "$sim_pid"; then
      kill "$sim_pid" 2>/dev/null || true
      wait "$sim_pid" 2>/dev/null || true
    fi
    _km_simics_on_exit
    exit 143
  }
  _km_simics_on_int() {
    # Forward Ctrl-C to Simics so it returns to simics> (stop), keep session.
    if [[ -n "${sim_pid:-}" ]] && _km_simics_pid_alive "$sim_pid"; then
      kill -INT "$sim_pid" 2>/dev/null || true
    fi
  }
  trap _km_simics_on_exit EXIT
  trap _km_simics_on_int INT
  trap _km_simics_on_term TERM

  "$@" &
  sim_pid=$!
  km_simics_register "$sim_pid" "$label"

  local ec=0
  while _km_simics_pid_alive "$sim_pid"; do
    set +e
    wait "$sim_pid"
    ec=$?
    set -e
    # wait interrupted by our INT handler while Simics still at prompt
    if _km_simics_pid_alive "$sim_pid"; then
      continue
    fi
    break
  done

  km_simics_unregister_pid "$sim_pid" || true
  trap - EXIT INT TERM
  return "$ec"
}

# --- CLI when executed (not sourced) ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-status}"
  shift || true
  case "$cmd" in
    status|list) km_simics_status ;;
    prune) km_simics_prune; echo "Pruned dead entries under $KM_SIMICS_REG_DIR" ;;
    unregister)
      km_simics_unregister_instance "${1:?instance number}"
      echo "Unregistered instance $1"
      ;;
    register)
      # manual: PID LABEL
      km_simics_register "${1:?pid}" "${2:-simics}"
      ;;
    -h|--help|help)
      sed -n '2,16p' "$0" | sed 's/^# \?//'
      ;;
    *)
      echo "Unknown command: $cmd (try: status|prune|unregister|register)" >&2
      exit 1
      ;;
  esac
fi
