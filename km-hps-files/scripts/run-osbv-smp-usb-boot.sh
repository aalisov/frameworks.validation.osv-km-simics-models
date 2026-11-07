#!/usr/bin/env bash
# KM osbv: boot from USB mass-storage using the same .wic as SDMMC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
unset SIMICS_BASE SIMICS_BASE_PACKAGE SIMICS_FPGA_ROOT SIMICS_PYTHON_PACKAGE SIMICS_PYTHON
# shellcheck disable=SC1091
source "$ROOT/set_simics_env_main.sh"

ART="${ARTIFACTS_DIR:-$ROOT/images/osbv}"
[[ -d "$ART" ]] || { echo "ERROR: missing $ART" >&2; exit 1; }

case "${SIMICS_BASE}" in
  *intel-fpga-main*|*intel-fpga_main*) ;;
  *)
    echo "ERROR: run-osbv-smp-usb-boot.sh requires intel-fpga-main; got SIMICS_BASE=$SIMICS_BASE" >&2
    exit 1
    ;;
esac

extra=()
if [[ -n "${SDM_HMOD_FW:-}" && -f "${SDM_HMOD_FW}" ]]; then
  extra+=(sdm_hmod_fw_image_filename="$SDM_HMOD_FW")
fi
if [[ -n "${TELNET_PORT:-}" ]]; then
  extra+=(console_telnet_port="$TELNET_PORT")
fi
# Env shortcuts (CLI args still win when passed explicitly).
if [[ -n "${STOP_AT_UBOOT:-}" ]]; then
  extra+=(stop_at_uboot="${STOP_AT_UBOOT}")
fi
if [[ -n "${UBOOT_MENU:-}" ]]; then
  extra+=(uboot_menu="${UBOOT_MENU}")
fi

echo "run-osbv-smp-usb-boot: WIC → usb3_disk"
echo "  default: auto boot_usb; stop_at_uboot=TRUE | uboot_menu=TRUE to stay in U-Boot"
exec "$ROOT/simics" scripts/boot-to-osbv-smp-usb-boot.simics \
  artifacts_dir="$ART" \
  "${extra[@]}" \
  "$@"
