#!/usr/bin/env bash
# Launch three detached network-enabled Simics sessions after gate PASS.
#
#   A — stop_at_uboot (interactive U-Boot)
#   B — SDMMC → Linux
#   C — usb31-usbip (+ host vudc/USBIP; see docs/KM-SIMICS-USBIP.md)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

if [[ "${KM_CI_SKIP_LONG:-0}" == "1" ]]; then
  echo "[long] KM_CI_SKIP_LONG=1 — not launching"
  exit 0
fi

PUBLISH_DATE="unknown"
if [[ -f "$KM_CI_LAST_MANIFEST" ]]; then
  PUBLISH_DATE="$(awk -F': *' '/^date:/{print $2; exit}' "$KM_CI_LAST_MANIFEST" || echo unknown)"
fi
BASE="${KM_CI_RESULTS}/${PUBLISH_DATE:-unknown}/long"
mkdir -p "$BASE/A" "$BASE/B" "$BASE/C"

# Ensure prior long sims are down
"$SCRIPT_DIR/stop-simics.sh" || true
sleep 1

# LAN bind IP so SSH port-in is reachable off-box (0.0.0.0 also works if fw open).
if [[ -z "${HOST_BIND_IP:-}" || "${HOST_BIND_IP}" == "0.0.0.0" ]]; then
  _def_if="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
  if [[ -n "$_def_if" ]]; then
    HOST_BIND_IP="$(ip -4 -o addr show dev "$_def_if" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1)"
  fi
  : "${HOST_BIND_IP:=0.0.0.0}"
  export HOST_BIND_IP
  echo "[long] HOST_BIND_IP=$HOST_BIND_IP" >&2
fi

# Optional: open host firewall for the three SSH ports (needs passwordless sudo).
if [[ "${KM_CI_SSH_FIREWALL:-0}" == "1" ]]; then
  for inst in "$KM_CI_LONG_A_INSTANCE" "$KM_CI_LONG_B_INSTANCE" "$KM_CI_LONG_C_INSTANCE"; do
    # shellcheck disable=SC1091
    source "$KM_HPS/scripts/host/km-simics-ssh-publish.sh" --instance "$inst" --bind-ip "$HOST_BIND_IP" --firewall || true
  done
fi

start_one() {
  local id="$1" inst="$2" telnet="$3" logfile="$4"
  shift 4
  local pidfile="$BASE/${id}.pid"
  local ssh_port=$((4022 + 100 * inst))
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
# TELNET_PORT is exported inside start_one → runners add console_telnet_port once
EXPECT_PY="$SCRIPT_DIR/km_uboot_expect.py"

start_one A "$KM_CI_LONG_A_INSTANCE" "$KM_CI_LONG_A_TELNET" "$BASE/A/simics.log" \
  ./scripts/run-osbv-smp.sh \
    create_hps_eth0_network=TRUE \
    stop_at_uboot=TRUE

start_one B "$KM_CI_LONG_B_INSTANCE" "$KM_CI_LONG_B_TELNET" "$BASE/B/simics.log" \
  ./scripts/run-osbv-smp.sh \
    create_hps_eth0_network=TRUE

start_one C "$KM_CI_LONG_C_INSTANCE" "$KM_CI_LONG_C_TELNET" "$BASE/C/simics.log" \
  ./scripts/run-osbv-smp-usb31-usbip.sh \
    create_hps_eth0_network=TRUE

# After Linux boots on B/C: login as root and run guest eth setup on UART.
# A stays at U-Boot — skipped. Failures are non-fatal (sessions keep running).
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
      --gateway "$KM_CI_GUEST_GW"; then
    echo "[long] $id: guest eth OK (log=$eth_log)" >&2
  else
    echo "[long] WARN: $id guest eth setup failed — see $eth_log (non-fatal)" >&2
  fi
}

if [[ "${KM_CI_LONG_SETUP_ETH:-1}" == "1" ]]; then
  # Parallel: B and C boot independently
  setup_guest_eth B "$KM_CI_LONG_B_TELNET" &
  pid_b_eth=$!
  setup_guest_eth C "$KM_CI_LONG_C_TELNET" &
  pid_c_eth=$!
  wait "$pid_b_eth" || true
  wait "$pid_c_eth" || true
else
  echo "[long] KM_CI_LONG_SETUP_ETH=0 — skip guest eth setup" >&2
fi

{
  echo "# Long sims — $PUBLISH_DATE"
  echo
  echo "| ID | Role | Instance | Telnet | SSH (host) | Attach |"
  echo "|----|------|----------|--------|------------|--------|"
  echo "| A | U-Boot stop | $KM_CI_LONG_A_INSTANCE | $KM_CI_LONG_A_TELNET | $((4022+100*KM_CI_LONG_A_INSTANCE)) | \`telnet 127.0.0.1 $KM_CI_LONG_A_TELNET\` (no Linux SSH) |"
  echo "| B | SDMMC Linux | $KM_CI_LONG_B_INSTANCE | $KM_CI_LONG_B_TELNET | $((4022+100*KM_CI_LONG_B_INSTANCE)) | \`ssh -p $((4022+100*KM_CI_LONG_B_INSTANCE)) root@${HOST_BIND_IP}\` |"
  echo "| C | USB31 USBIP | $KM_CI_LONG_C_INSTANCE | $KM_CI_LONG_C_TELNET | $((4022+100*KM_CI_LONG_C_INSTANCE)) | \`ssh -p $((4022+100*KM_CI_LONG_C_INSTANCE)) root@${HOST_BIND_IP}\` |"
  echo
  echo "PIDs: \`$KM_CI_LONG_PIDS\`"
  echo
  echo "Guest eth (B/C, auto): \`${KM_CI_GUEST_ETH_SETUP}\` after login (disable with \`KM_CI_LONG_SETUP_ETH=0\`)"
  echo
  echo "USBIP (C): after bridge listens, host attach via \`./scripts/host/km-usbip-attach.sh\` — see docs/KM-SIMICS-USBIP.md"
  echo
  echo "Firewall (once): \`KM_CI_SSH_FIREWALL=1\` on launch, or"
  echo "\`source scripts/host/km-simics-ssh-publish.sh --instance N --auto --firewall\`"
  echo
  echo "Stop all: \`./scripts/km-ci/stop-simics.sh\`"
} >"$BASE/README.md"

echo "[long] wrote $BASE/README.md"
cat "$KM_CI_LONG_PIDS"

if [[ "${KM_CI_PUBLISH_WEB:-1}" == "1" ]]; then
  PUBLISH_ARGS=(--url "${KM_SIMICS_RUNS_URL:-${SHARE_ROOT}/simics-runs/}")
  if [[ -n "${KM_SIMICS_RUNS_DEST:-}" ]]; then
    PUBLISH_ARGS+=(--publish --dest "$KM_SIMICS_RUNS_DEST")
  fi
  "$KM_HPS/scripts/host/km-simics-instances-publish.sh" "${PUBLISH_ARGS[@]}" || \
    echo "[long] WARN: instances-publish failed (non-fatal)" >&2
fi
