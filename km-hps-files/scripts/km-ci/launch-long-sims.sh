#!/usr/bin/env bash
# Launch parameterized long-lived Simics sessions (concept v2).
#
# Catalog: $KM_CI_LONG_LIST (default scripts/km-ci/long-sims.list)
# Selection: $KM_CI_LONG_SCRIPTS (comma IDs; empty = all catalog rows)
#
# Always probes up/down and publishes simics-runs when configured.
# Exit 0 even on partial/none up (orchestrator always emails runs status).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

if [[ "${KM_CI_SKIP_LONG:-0}" == "1" ]]; then
  echo "[long] KM_CI_SKIP_LONG=1 — not launching"
  exit 0
fi

LIST_FILE="${KM_CI_LONG_LIST}"
if [[ ! -f "$LIST_FILE" ]]; then
  echo "[long] ERROR: missing catalog $LIST_FILE" >&2
  exit 1
fi

PUBLISH_DATE="unknown"
if [[ -f "$KM_CI_LAST_MANIFEST" ]]; then
  PUBLISH_DATE="$(awk -F': *' '/^date:/{print $2; exit}' "$KM_CI_LAST_MANIFEST" || echo unknown)"
fi
BASE="${KM_CI_RESULTS}/${PUBLISH_DATE:-unknown}/long"
mkdir -p "$BASE"

# Ensure prior long sims are down
"$SCRIPT_DIR/stop-simics.sh" || true
sleep 1

# LAN bind IP so SSH port-in is reachable off-box
if [[ -z "${HOST_BIND_IP:-}" || "${HOST_BIND_IP}" == "0.0.0.0" ]]; then
  _def_if="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
  if [[ -n "$_def_if" ]]; then
    HOST_BIND_IP="$(ip -4 -o addr show dev "$_def_if" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1)"
  fi
  : "${HOST_BIND_IP:=0.0.0.0}"
  export HOST_BIND_IP
  echo "[long] HOST_BIND_IP=$HOST_BIND_IP" >&2
fi

# Parse selection
declare -A WANT=()
if [[ -n "${KM_CI_LONG_SCRIPTS:-}" ]]; then
  IFS=',' read -r -a _ids <<<"${KM_CI_LONG_SCRIPTS}"
  for id in "${_ids[@]}"; do
    id="$(echo "$id" | tr -d '[:space:]')"
    [[ -n "$id" ]] && WANT["$id"]=1
  done
fi

# Load catalog rows into arrays
ROWS=()
while read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  ROWS+=("$line")
done <"$LIST_FILE"

if [[ ${#ROWS[@]} -eq 0 ]]; then
  echo "[long] ERROR: no entries in $LIST_FILE" >&2
  exit 1
fi

SELECTED=()
for row in "${ROWS[@]}"; do
  # shellcheck disable=SC2086
  set -- $row
  id="$1"
  if [[ ${#WANT[@]} -gt 0 && -z "${WANT[$id]:-}" ]]; then
    continue
  fi
  SELECTED+=("$row")
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "[long] ERROR: KM_CI_LONG_SCRIPTS matched no catalog rows" >&2
  exit 1
fi

# Optional firewall for selected instances
if [[ "${KM_CI_SSH_FIREWALL:-0}" == "1" ]]; then
  for row in "${SELECTED[@]}"; do
    # shellcheck disable=SC2086
    set -- $row
    inst="$2"
    # shellcheck disable=SC1091
    source "$KM_HPS/scripts/host/km-simics-ssh-publish.sh" --instance "$inst" --bind-ip "$HOST_BIND_IP" --firewall || true
  done
fi

start_one() {
  local id="$1" inst="$2" telnet="$3" logfile="$4"
  shift 4
  local pidfile="$BASE/${id}.pid"
  local ssh_port=$((4022 + 100 * inst))
  mkdir -p "$BASE/$id"
  echo "[long] starting $id instance=$inst telnet=$telnet ssh=$ssh_port → $*" >&2
  (
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
  echo "[long] $id PID=$pid log=$logfile" >&2
  echo "${id}_PID=$pid" >>"$KM_CI_LONG_PIDS"
}

: >"$KM_CI_LONG_PIDS"
EXPECT_PY="$SCRIPT_DIR/km_uboot_expect.py"

# id -> guest_eth / telnet for later eth + probe
declare -A ID_TELNET=()
declare -A ID_GUEST_ETH=()
declare -A ID_INSTANCE=()
declare -A ID_SCRIPT=()

for row in "${SELECTED[@]}"; do
  # shellcheck disable=SC2086
  set -- $row
  id="$1" inst="$2" telnet="$3" guest_eth="$4" script="$5"
  shift 5
  args=("$@")
  ID_TELNET["$id"]="$telnet"
  ID_GUEST_ETH["$id"]="$guest_eth"
  ID_INSTANCE["$id"]="$inst"
  ID_SCRIPT["$id"]="$script"
  runner="$KM_HPS/scripts/$script"
  if [[ ! -x "$runner" ]]; then
    echo "[long] WARN: missing executable $runner — skip $id" >&2
    continue
  fi
  start_one "$id" "$inst" "$telnet" "$BASE/$id/simics.log" \
    "./scripts/$script" "${args[@]}"
done

setup_guest_eth() {
  local id="$1" telnet="$2"
  local eth_log="$BASE/${id}/guest-eth.log"
  echo "[long] $id: wait Linux login on :$telnet then ${KM_CI_GUEST_ETH_SETUP}" >&2
  if python3 "$EXPECT_PY" \
      --host 127.0.0.1 --port "$telnet" --log "$eth_log" \
      guest-eth \
      --boot-timeout "$KM_CI_LINUX_BOOT_TIMEOUT" \
      --timeout "$KM_CI_LINUX_CMD_TIMEOUT" \
      --login-re "$KM_CI_LINUX_LOGIN" \
      --shell-re "$KM_CI_LINUX_SHELL_RE" \
      --user "$KM_CI_LINUX_USER" \
      --setup-cmd "$KM_CI_GUEST_ETH_SETUP" \
      --gateway "$KM_CI_GUEST_GW" \
      --guest-ip "$KM_CI_GUEST_ETH_IP"; then
    echo "[long] $id: guest eth OK (log=$eth_log)" >&2
  else
    echo "[long] WARN: $id guest eth setup failed — see $eth_log (non-fatal)" >&2
  fi
}

if [[ "${KM_CI_LONG_SETUP_ETH:-1}" == "1" ]]; then
  eth_pids=()
  for id in "${!ID_GUEST_ETH[@]}"; do
    if [[ "${ID_GUEST_ETH[$id]}" == "1" ]]; then
      setup_guest_eth "$id" "${ID_TELNET[$id]}" &
      eth_pids+=($!)
    fi
  done
  if [[ ${#eth_pids[@]} -gt 0 ]]; then
    for p in "${eth_pids[@]}"; do
      wait "$p" || true
    done
  fi
else
  echo "[long] KM_CI_LONG_SETUP_ETH=0 — skip guest eth setup" >&2
fi

sleep "${KM_CI_LONG_UP_WAIT:-8}"

# Probe which instances are up (PID alive + telnet port listening)
UP=0
DOWN=0
TOTAL=0
STATUS_LINES=()
for id in $(printf '%s\n' "${!ID_TELNET[@]}" | sort); do
  TOTAL=$((TOTAL + 1))
  telnet="${ID_TELNET[$id]}"
  inst="${ID_INSTANCE[$id]}"
  ssh_port=$((4022 + 100 * inst))
  pidfile="$BASE/${id}.pid"
  pid=""
  [[ -f "$pidfile" ]] && pid="$(cat "$pidfile" 2>/dev/null || true)"
  alive=0
  listening=0
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && alive=1
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${telnet}\$"; then
    listening=1
  elif fuser "${telnet}/tcp" >/dev/null 2>&1; then
    listening=1
  fi
  if [[ $alive -eq 1 && $listening -eq 1 ]]; then
    state=UP
    UP=$((UP + 1))
  else
    state=DOWN
    DOWN=$((DOWN + 1))
  fi
  STATUS_LINES+=("| $id | ${ID_SCRIPT[$id]} | $inst | $telnet | $ssh_port | $pid | $state |")
  echo "[long] $id state=$state pid=$pid telnet=$telnet" >&2
done

mkdir -p "$KM_CI_VAR"
{
  echo "total=$TOTAL"
  echo "up=$UP"
  echo "down=$DOWN"
  if [[ $TOTAL -eq 0 ]]; then
    echo "status=none"
  elif [[ $UP -eq 0 ]]; then
    echo "status=none"
  elif [[ $DOWN -eq 0 ]]; then
    echo "status=all"
  else
    echo "status=partial"
  fi
} >"$KM_CI_VAR/last-long-status.txt"

{
  echo "# Long sims — $PUBLISH_DATE"
  echo
  echo "Catalog: \`$LIST_FILE\`  Selection: \`${KM_CI_LONG_SCRIPTS:-all}\`"
  echo
  echo "Up: **$UP** / $TOTAL   Down: **$DOWN**"
  echo
  echo "| ID | Script | Instance | Telnet | SSH | PID | State |"
  echo "|----|--------|----------|--------|-----|-----|-------|"
  for line in "${STATUS_LINES[@]}"; do
    echo "$line"
  done
  echo
  echo "PIDs: \`$KM_CI_LONG_PIDS\`"
  echo
  echo "Guest eth (auto when guest_eth=1): \`${KM_CI_GUEST_ETH_SETUP}\` (disable with \`KM_CI_LONG_SETUP_ETH=0\`)"
  echo
  echo "Stop all: \`./scripts/km-ci/stop-simics.sh\`"
} >"$BASE/README.md"

echo "[long] wrote $BASE/README.md (up=$UP/$TOTAL)"
cat "$KM_CI_LONG_PIDS" || true

if [[ "${KM_CI_PUBLISH_WEB:-1}" == "1" ]]; then
  PUBLISH_ARGS=(--url "${KM_SIMICS_RUNS_URL:-${SHARE_ROOT}/simics-runs/}")
  if [[ -n "${KM_SIMICS_WEB_GIT:-}${KM_SIMICS_RUNS_GIT:-}${KM_SIMICS_RUNS_DEST:-}" ]]; then
    PUBLISH_ARGS+=(--publish)
    [[ -n "${KM_SIMICS_RUNS_DEST:-}" ]] && PUBLISH_ARGS+=(--dest "$KM_SIMICS_RUNS_DEST")
    [[ -n "${KM_SIMICS_RUNS_GIT:-}" ]] && PUBLISH_ARGS+=(--git "$KM_SIMICS_RUNS_GIT")
  fi
  "$KM_HPS/scripts/host/km-simics-instances-publish.sh" "${PUBLISH_ARGS[@]}" || \
    echo "[long] WARN: instances-publish failed (non-fatal)" >&2
fi

# Non-fatal for orchestrator — always exit 0 after publish attempt
exit 0
