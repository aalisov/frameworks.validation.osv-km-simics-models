#!/usr/bin/env bash
# KM osbv SMP+SVE — USB3.1 device mode + Variant S USBIP bridge hook.
#
# Guest: overlay + UDC + km-usb-gadget-setup.sh (no usbipd in guest).
# Host:  ./scripts/host/km-usbip-attach.sh once the Simics USBIP bridge listens.
#
# Ctrl-C: same as run-osbv-smp.sh — stops to simics> (does not exit).
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

export USBIP_TCP_PORT="${USBIP_TCP_PORT:-3240}"
export REQUIRE_USBIP_BRIDGE="${REQUIRE_USBIP_BRIDGE:-0}"

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

echo "run-osbv-smp-usb31-usbip: USBIP_TCP_PORT=$USBIP_TCP_PORT REQUIRE_USBIP_BRIDGE=$REQUIRE_USBIP_BRIDGE"
echo "  GUEST_ETH_IP=$GUEST_ETH_IP HOST_SSH_PORT=$HOST_SSH_PORT HOST_BIND_IP=$HOST_BIND_IP"
echo "  Ctrl-C -> simics> (pause); run to continue; quit to exit"
echo "  (USBIP bridge model may be missing — see docs/KM-SIMICS-USBIP.md)"

km_simics_register $$ usb31-usbip || true

exec "$ROOT/simics" scripts/boot-to-osbv-smp-usb31-usbip.simics \
  artifacts_dir="$ART" \
  "${extra[@]}" \
  "$@"
