#!/usr/bin/env bash
# KM osbv SMP+SVE with USB3.1 device mode (no host-port mass-storage).
# Guest: osvloaddtoverlay km-usb31-gadget && km-usb31-gadget-check.sh
#
# Eth / SSH (NAPT port-in on host NIC — see docs/KM-SIMICS-ETH.md):
#   source ./scripts/host/km-simics-ssh-publish.sh --auto --firewall
#   ./scripts/run-osbv-smp-usb31-device.sh create_hps_eth0_network=TRUE
#   # guest: setup-simics-eth.sh
#   # remote: ssh -p $HOST_SSH_PORT root@$HOST_LAN_HINT
#
# Or one-shot publish from this launcher:
#   KM_SIMICS_PUBLISH_SSH=1 ./scripts/run-osbv-smp-usb31-device.sh
#   KM_SIMICS_PUBLISH_SSH=1 KM_SIMICS_SSH_IFACE=eno3 ./scripts/run-osbv-smp-usb31-device.sh
#
# Ctrl-C: same as run-osbv-smp.sh — stops to simics> (does not exit).
# Type 'run' to continue, 'quit'/'exit' to leave Simics.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
unset SIMICS_BASE SIMICS_BASE_PACKAGE SIMICS_FPGA_ROOT SIMICS_PYTHON_PACKAGE SIMICS_PYTHON
# shellcheck disable=SC1091
source "$ROOT/set_simics_env_main.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/host/km-simics-instances.sh"

ART="${ARTIFACTS_DIR:-$ROOT/images/osbv}"
[[ -d "$ART" ]] || { echo "ERROR: missing $ART" >&2; exit 1; }

case "${SIMICS_BASE}" in
  *intel-fpga-main*|*intel-fpga_main*) ;;
  *)
    echo "ERROR: requires intel-fpga-main; got SIMICS_BASE=$SIMICS_BASE" >&2
    exit 1
    ;;
esac

# Optional: publish SSH on host NIC before launch
if [[ "${KM_SIMICS_PUBLISH_SSH:-0}" == "1" ]]; then
  # shellcheck disable=SC1091
  if [[ -n "${KM_SIMICS_SSH_IFACE:-}" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/scripts/host/km-simics-ssh-publish.sh" \
      --instance "${SIMICS_INSTANCE:-0}" \
      --iface "$KM_SIMICS_SSH_IFACE" \
      ${KM_SIMICS_SSH_FIREWALL:+--firewall}
  else
    # shellcheck disable=SC1091
    source "$ROOT/scripts/host/km-simics-ssh-publish.sh" \
      --instance "${SIMICS_INSTANCE:-0}" \
      --auto \
      ${KM_SIMICS_SSH_FIREWALL:+--firewall}
  fi
fi

extra=()
if [[ -n "${SDM_HMOD_FW:-}" && -f "${SDM_HMOD_FW}" ]]; then
  extra+=(sdm_hmod_fw_image_filename="$SDM_HMOD_FW")
fi
if [[ -n "${TELNET_PORT:-}" ]]; then
  extra+=(console_telnet_port="$TELNET_PORT")
fi

: "${SIMICS_INSTANCE:=0}"
: "${GUEST_ETH_IP:=10.10.0.100}"
: "${HOST_SSH_PORT:=$((4022 + 100 * SIMICS_INSTANCE))}"
: "${HOST_BIND_IP:=0.0.0.0}"
: "${TELNET_PORT:=$((9123 + SIMICS_INSTANCE))}"
export SIMICS_INSTANCE GUEST_ETH_IP HOST_SSH_PORT HOST_BIND_IP TELNET_PORT
[[ -n "${HOST_IFACE:-}" ]] && export HOST_IFACE
[[ -n "${HOST_LAN_HINT:-}" ]] && export HOST_LAN_HINT

echo "run-osbv-smp-usb31-device: GUEST_ETH_IP=$GUEST_ETH_IP HOST_SSH_PORT=$HOST_SSH_PORT HOST_BIND_IP=$HOST_BIND_IP"
[[ -n "${HOST_LAN_HINT:-}" ]] && echo "  LAN SSH: ssh -p $HOST_SSH_PORT root@$HOST_LAN_HINT"
echo "  Ctrl-C -> simics> (pause); run to continue; quit to exit"
echo "  status: ./scripts/host/km-simics-instances.sh status"
echo "  eth doc: docs/KM-SIMICS-ETH.md"

# exec keeps this PID as Simics — Ctrl-C goes to Simics (like run-osbv-smp.sh)
km_simics_register $$ usb31-device || true

exec "$ROOT/simics" scripts/boot-to-osbv-smp-usb31-device.simics \
  artifacts_dir="$ART" \
  "${extra[@]}" \
  "$@"
