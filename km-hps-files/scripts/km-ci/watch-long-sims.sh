#!/usr/bin/env bash
# Watchdog for KM long-sim instances (concept v2).
#
# For each catalog ID currently expected to be up:
#   - probe telnet + console health
#   - on DOWN/UNHEALTHY: stop that instance, restart (up to KM_CI_WATCH_MAX_RETRIES)
#   - if still failing: mark UNAVAILABLE, notify, publish runs
#
# Usage:
#   ./scripts/km-ci/watch-long-sims.sh              # one tick
#   ./scripts/km-ci/watch-long-sims.sh --loop        # forever
#   KM_CI_WATCH_IDS=A,C ./scripts/km-ci/watch-long-sims.sh
#
# Timer example:
#   */5 * * * *  $HOME/km-hps/scripts/km-ci/watch-long-sims.sh >>$HOME/km-hps/var/watch-long.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

LOOP=0
ONCE_IDS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --loop|-l) LOOP=1; shift ;;
    --ids) ONCE_IDS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

WATCH_DIR="${KM_CI_WATCH_DIR}"
mkdir -p "$WATCH_DIR" "$KM_CI_VAR"
PROBE_PY="$SCRIPT_DIR/probe-long-console.py"
EXPECT_PY="$SCRIPT_DIR/km_uboot_expect.py"
LOCK_FD=8
eval "exec ${LOCK_FD}>\"$KM_CI_WATCH_LOCK\""
if ! flock -n "$LOCK_FD"; then
  echo "[watch] another watch holds $KM_CI_WATCH_LOCK — exit"
  exit 0
fi

log() { echo "$(date -Iseconds) [watch] $*"; }

# Skip while run-once / gate owns the agent lock
agent_busy() {
  local fd=9
  eval "exec ${fd}>\"$KM_CI_LOCK\""
  if flock -n "$fd"; then
    eval "exec ${fd}>&-"
    return 1
  fi
  eval "exec ${fd}>&-"
  return 0
}

port_listening() {
  local port="$1"
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
    return 0
  fi
  fuser "${port}/tcp" >/dev/null 2>&1
}

kill_instance() {
  local id="$1" telnet="$2" pidfile="$3"
  local pid="" pids=()
  [[ -f "$pidfile" ]] && pid="$(cat "$pidfile" 2>/dev/null || true)"
  [[ -n "$pid" ]] && pids+=("$pid")
  # Also honor long-sims.pids and any listener on the telnet port
  if [[ -f "$KM_CI_LONG_PIDS" ]]; then
    local line
    line="$(grep "^${id}_PID=" "$KM_CI_LONG_PIDS" 2>/dev/null || true)"
    [[ -n "$line" ]] && pids+=("${line#*=}")
  fi
  local p
  for p in "${pids[@]}"; do
    [[ -n "$p" ]] || continue
    if kill -0 "$p" 2>/dev/null; then
      log "$id: SIGTERM pid=$p"
      kill -TERM "$p" 2>/dev/null || true
    fi
  done
  sleep 2
  for p in "${pids[@]}"; do
    [[ -n "$p" ]] || continue
    if kill -0 "$p" 2>/dev/null; then
      log "$id: SIGKILL pid=$p"
      kill -KILL "$p" 2>/dev/null || true
    fi
  done
  # Free UART telnet (and any orphaned Simics holding it)
  fuser -k "${telnet}/tcp" 2>/dev/null || true
  # Drop registry entry for this instance if present
  local reg="${KM_SIMICS_REG_DIR:-${XDG_RUNTIME_DIR:-/tmp}/km-simics/instances}"
  if [[ -d "$reg" ]]; then
    local f
    for f in "$reg"/*.env; do
      [[ -f "$f" ]] || continue
      if grep -q "TELNET=${telnet}" "$f" 2>/dev/null; then
        # shellcheck disable=SC1090
        source "$f"
        [[ -n "${PID:-}" ]] && kill -TERM "$PID" 2>/dev/null || true
        rm -f "$f"
      fi
    done
  fi
  rm -f "$pidfile"
  sleep 1
}

update_pids_file() {
  # Rewrite long-sims.pids from live pidfiles for catalog IDs
  local tmp
  tmp="$(mktemp)"
  local id pidfile pid
  for id in "${IDS[@]}"; do
    pidfile="$BASE/${id}.pid"
    if [[ -f "$pidfile" ]]; then
      pid="$(cat "$pidfile" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        echo "${id}_PID=$pid" >>"$tmp"
      fi
    fi
  done
  mv -f "$tmp" "$KM_CI_LONG_PIDS"
}

publish_runs() {
  if [[ "${KM_CI_PUBLISH_WEB:-1}" != "1" ]]; then
    return 0
  fi
  local args=(--url "${KM_SIMICS_RUNS_URL:-${SHARE_ROOT}/simics-runs/}")
  if [[ -n "${KM_SIMICS_WEB_GIT:-}${KM_SIMICS_RUNS_GIT:-}${KM_SIMICS_RUNS_DEST:-}" ]]; then
    args+=(--publish)
    [[ -n "${KM_SIMICS_RUNS_DEST:-}" ]] && args+=(--dest "$KM_SIMICS_RUNS_DEST")
    [[ -n "${KM_SIMICS_RUNS_GIT:-}" ]] && args+=(--git "$KM_SIMICS_RUNS_GIT")
  fi
  "$KM_HPS/scripts/host/km-simics-instances-publish.sh" "${args[@]}" 2>/dev/null \
    || log "WARN: instances-publish failed"
}

start_one() {
  local id="$1" inst="$2" telnet="$3" logfile="$4"
  shift 4
  local pidfile="$BASE/${id}.pid"
  local ssh_port=$((4022 + 100 * inst))
  mkdir -p "$BASE/$id"
  log "$id: starting instance=$inst telnet=$telnet → $*"
  (
    exec 9>&- 2>/dev/null || true
    exec 8>&- 2>/dev/null || true
    cd "$KM_HPS"
    export SIMICS_INSTANCE="$inst"
    export TELNET_PORT="$telnet"
    export GUEST_ETH_IP="${KM_CI_GUEST_ETH_IP}"
    export HOST_SSH_PORT="$ssh_port"
    export HOST_BIND_IP="${HOST_BIND_IP:-0.0.0.0}"
    # shellcheck disable=SC1091
    source ./set_simics_env_main.sh
    exec "$@"
  ) >"$logfile" 2>&1 &
  local pid=$!
  echo "$pid" >"$pidfile"
  log "$id: PID=$pid log=$logfile"
  # merge into pids file
  if [[ -f "$KM_CI_LONG_PIDS" ]] && grep -q "^${id}_PID=" "$KM_CI_LONG_PIDS" 2>/dev/null; then
    sed -i "/^${id}_PID=/d" "$KM_CI_LONG_PIDS"
  fi
  echo "${id}_PID=$pid" >>"$KM_CI_LONG_PIDS"
}

setup_guest_eth_bg() {
  local id="$1" telnet="$2"
  [[ "${KM_CI_LONG_SETUP_ETH:-1}" == "1" ]] || return 0
  [[ "${ID_GUEST_ETH[$id]:-0}" == "1" ]] || return 0
  local eth_log="$BASE/${id}/guest-eth.log"
  log "$id: guest-eth setup in background"
  (
    python3 "$EXPECT_PY" \
      --host 127.0.0.1 --port "$telnet" --log "$eth_log" \
      guest-eth \
      --boot-timeout "$KM_CI_LINUX_BOOT_TIMEOUT" \
      --timeout "$KM_CI_LINUX_CMD_TIMEOUT" \
      --login-re "$KM_CI_LINUX_LOGIN" \
      --shell-re "$KM_CI_LINUX_SHELL_RE" \
      --user "$KM_CI_LINUX_USER" \
      --setup-cmd "$KM_CI_GUEST_ETH_SETUP" \
      --gateway "$KM_CI_GUEST_GW" \
      --guest-ip "$KM_CI_GUEST_ETH_IP" \
      || log "$id: WARN guest-eth failed (see $eth_log)"
  ) &
}

expect_mode_for() {
  local id="$1"
  local args="${ID_ARGS[$id]:-}"
  if [[ "$args" == *stop_at_uboot=TRUE* || "$args" == *stop_at_uboot=true* ]]; then
    echo uboot
  else
    echo linux
  fi
}

retries_get() {
  local id="$1" f="$WATCH_DIR/${id}.retries"
  [[ -f "$f" ]] && cat "$f" || echo 0
}

retries_set() {
  local id="$1" n="$2"
  echo "$n" >"$WATCH_DIR/${id}.retries"
}

state_set() {
  local id="$1" st="$2" reason="${3:-}"
  echo "$st" >"$WATCH_DIR/${id}.state"
  printf '%s\n' "$reason" >"$WATCH_DIR/${id}.reason"
  date -Iseconds >"$WATCH_DIR/${id}.checked"
}

in_boot_grace() {
  local id="$1"
  local started_f="$WATCH_DIR/${id}.started"
  [[ -f "$started_f" ]] || return 1
  local started now age
  started="$(cat "$started_f")"
  now="$(date +%s)"
  # started file holds epoch
  age=$((now - started))
  [[ "$age" -lt "${KM_CI_WATCH_BOOT_GRACE}" ]]
}

probe_id() {
  local id="$1"
  local telnet="${ID_TELNET[$id]}"
  local expect mode grace_args=()
  expect="$(expect_mode_for "$id")"
  if [[ "$expect" == "linux" ]] && in_boot_grace "$id"; then
    grace_args=(--grace-ok)
  fi
  if ! port_listening "$telnet"; then
    echo "DOWN port=$telnet reason=not listening"
    return 2
  fi
  local out rc=0
  set +e
  out="$(python3 "$PROBE_PY" --host 127.0.0.1 --port "$telnet" \
      --expect "$expect" --seconds "${KM_CI_WATCH_PROBE_SECS}" --poke \
      "${grace_args[@]}" 2>/dev/null)"
  rc=$?
  set -e
  echo "$out"
  return "$rc"
}

restart_id() {
  local id="$1"
  local inst="${ID_INSTANCE[$id]}"
  local telnet="${ID_TELNET[$id]}"
  local script="${ID_SCRIPT[$id]}"
  local args="${ID_ARGS[$id]}"
  local pidfile="$BASE/${id}.pid"
  local logfile="$BASE/${id}/simics.log"
  local attempt
  attempt="$(retries_get "$id")"
  attempt=$((attempt + 1))
  echo "$attempt" >"$WATCH_DIR/${id}.retries"

  if [[ "$attempt" -gt "${KM_CI_WATCH_MAX_RETRIES}" ]]; then
    state_set "$id" UNAVAILABLE "exhausted ${KM_CI_WATCH_MAX_RETRIES} restarts"
    log "$id: UNAVAILABLE after ${KM_CI_WATCH_MAX_RETRIES} restarts (telnet=$telnet)"
    "$SCRIPT_DIR/notify.sh" error \
      "long-sim $id UNAVAILABLE telnet=$telnet after ${KM_CI_WATCH_MAX_RETRIES} restarts — ${KM_SIMICS_RUNS_URL:-}" \
      || true
    publish_runs
    return 1
  fi

  state_set "$id" RESTARTING "attempt $attempt/${KM_CI_WATCH_MAX_RETRIES}"
  log "$id: restart attempt $attempt/${KM_CI_WATCH_MAX_RETRIES}"
  kill_instance "$id" "$telnet" "$pidfile"

  # rotate log
  if [[ -f "$logfile" ]]; then
    mv -f "$logfile" "${logfile}.bak.$(date +%Y%m%d%H%M%S)" || true
  fi

  # shellcheck disable=SC2086
  start_one "$id" "$inst" "$telnet" "$logfile" \
    "./scripts/$script" $args

  date +%s >"$WATCH_DIR/${id}.started"
  setup_guest_eth_bg "$id" "$telnet"
  "$SCRIPT_DIR/notify.sh" info \
    "long-sim $id restart attempt $attempt/${KM_CI_WATCH_MAX_RETRIES} telnet=$telnet" \
    || true
  return 0
}

load_catalog() {
  IDS=()
  declare -gA ID_TELNET=() ID_GUEST_ETH=() ID_INSTANCE=() ID_SCRIPT=() ID_ARGS=()

  local want_filter="${ONCE_IDS:-${KM_CI_WATCH_IDS:-${KM_CI_LONG_SCRIPTS:-}}}"
  declare -A WANT=()
  if [[ -n "$want_filter" ]]; then
    local x
    IFS=',' read -r -a _ids <<<"$want_filter"
    for x in "${_ids[@]}"; do
      x="$(echo "$x" | tr -d '[:space:]')"
      [[ -n "$x" ]] && WANT["$x"]=1
    done
  fi

  LIST_FILE="${KM_CI_LONG_LIST}"
  [[ -f "$LIST_FILE" ]] || { log "ERROR: missing $LIST_FILE"; return 1; }

  PUBLISH_DATE="unknown"
  if [[ -f "$KM_CI_LAST_MANIFEST" ]]; then
    PUBLISH_DATE="$(awk -F': *' '/^date:/{print $2; exit}' "$KM_CI_LAST_MANIFEST" || echo unknown)"
  fi
  BASE="${KM_CI_RESULTS}/${PUBLISH_DATE:-unknown}/long"
  mkdir -p "$BASE"

  local line id inst telnet guest_eth script
  while read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # shellcheck disable=SC2086
    set -- $line
    id="$1" inst="$2" telnet="$3" guest_eth="$4" script="$5"
    shift 5
    if [[ ${#WANT[@]} -gt 0 && -z "${WANT[$id]:-}" ]]; then
      continue
    fi
    IDS+=("$id")
    ID_TELNET["$id"]="$telnet"
    ID_GUEST_ETH["$id"]="$guest_eth"
    ID_INSTANCE["$id"]="$inst"
    ID_SCRIPT["$id"]="$script"
    ID_ARGS["$id"]="$*"
  done <"$LIST_FILE"
}

tick() {
  if agent_busy; then
    log "agent.lock held (run-once/gate) — skip tick"
    return 0
  fi

  load_catalog
  if [[ ${#IDS[@]} -eq 0 ]]; then
    log "no catalog IDs selected — nothing to watch"
    return 0
  fi

  log "tick ids=${IDS[*]} max_retries=${KM_CI_WATCH_MAX_RETRIES}"

  local id out rc st reason
  local any_action=0
  for id in "${IDS[@]}"; do
    st="$(cat "$WATCH_DIR/${id}.state" 2>/dev/null || echo UNKNOWN)"
    # Still watch UNAVAILABLE periodically? Only if KM_CI_WATCH_RETRY_UNAVAILABLE=1
    if [[ "$st" == "UNAVAILABLE" && "${KM_CI_WATCH_RETRY_UNAVAILABLE:-0}" != "1" ]]; then
      log "$id: still UNAVAILABLE — skip (set KM_CI_WATCH_RETRY_UNAVAILABLE=1 to retry)"
      continue
    fi

    set +e
    out="$(probe_id "$id")"
    rc=$?
    set -e
    log "$id: $out"

    if [[ $rc -eq 0 ]]; then
      echo 0 >"$WATCH_DIR/${id}.retries"
      state_set "$id" OK "${out#*reason=}"
      continue
    fi

    # DOWN or UNHEALTHY
    any_action=1
    reason="${out:-rc=$rc}"
    state_set "$id" FAILING "$reason"
    restart_id "$id" || true
  done

  update_pids_file
  if [[ $any_action -eq 1 ]]; then
    publish_runs
  fi
}

# LAN bind for SSH publish on restart (best-effort)
if [[ -z "${HOST_BIND_IP:-}" || "${HOST_BIND_IP}" == "0.0.0.0" ]]; then
  _def_if="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
  if [[ -n "${_def_if:-}" ]]; then
    HOST_BIND_IP="$(ip -4 -o addr show dev "$_def_if" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1 || true)"
  fi
  : "${HOST_BIND_IP:=0.0.0.0}"
  export HOST_BIND_IP
fi

if [[ $LOOP -eq 1 ]]; then
  log "loop every ${KM_CI_WATCH_INTERVAL}s"
  while true; do
    tick || log "WARN: tick failed rc=$?"
    sleep "${KM_CI_WATCH_INTERVAL}"
  done
else
  tick
fi
