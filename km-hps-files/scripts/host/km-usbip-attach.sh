#!/usr/bin/env bash
# Host PC / test bench: attach KM Simics USBIP bridge (Variant S) via VHCI.
#
# Prerequisites:
#   - ./scripts/run-osbv-smp-usb31-usbip.sh running
#   - Simics USBIP bridge model listening (TCP, default 3240)
#   - Guest: km-usb31-gadget overlay + km-usb-gadget-setup.sh (UDC bound)
#
# Usage:
#   ./scripts/host/km-usbip-attach.sh [host] [busid]
#   USBIP_HOST=127.0.0.1 USBIP_BUSID=1-1 ./scripts/host/km-usbip-attach.sh
set -euo pipefail

HOST="${1:-${USBIP_HOST:-127.0.0.1}}"
BUSID="${2:-${USBIP_BUSID:-}}"

if [[ "$(id -u)" -ne 0 ]]; then
  SUDO=sudo
else
  SUDO=
fi

echo "=== KM USBIP host attach (Variant S) ==="
echo "server=$HOST busid=${BUSID:-<list>}"

$SUDO modprobe vhci-hcd

if ! command -v usbip >/dev/null 2>&1; then
  echo "ERROR: usbip client tools missing (linux-tools / usbip package)" >&2
  exit 1
fi

echo "--- exported devices ---"
usbip list -r "$HOST" || {
  echo "ERROR: cannot list $HOST — is the Simics USBIP bridge listening?" >&2
  echo "  Bridge model is required (docs/KM-SIMICS-USBIP.md). Guest usbipd is NOT used." >&2
  exit 1
}

if [[ -z "$BUSID" ]]; then
  echo
  echo "Re-run with bus id from the list above:"
  echo "  $0 $HOST <busid>"
  exit 0
fi

$SUDO usbip attach -r "$HOST" -b "$BUSID"
echo "OK: attached $HOST/$BUSID — check lsusb / dmesg / /dev/sd*"
lsusb || true
