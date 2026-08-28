#!/usr/bin/env bash
# Run km_generic.simics on intel-fpga-main (SMP + SVE).
#
# Examples:
#   ./scripts/run-km-generic-main.sh emul DUMP_CPUINFO=TRUE
#   ./scripts/run-km-generic-main.sh osbv BOOT_METHOD=sd
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
unset SIMICS_BASE SIMICS_BASE_PACKAGE SIMICS_FPGA_ROOT SIMICS_PYTHON_PACKAGE SIMICS_PYTHON
# shellcheck disable=SC1091
source "$ROOT/set_simics_env_main.sh"

FLAVOR="${1:-emul}"
shift || true

KM_GENERIC="${KM_GENERIC:-$ROOT/scripts/km_generic.simics}"
[[ -f "$KM_GENERIC" ]] || KM_GENERIC="$HOME/hamza/km_generic.simics"
[[ -f "$KM_GENERIC" ]] || {
  echo "ERROR: km_generic.simics not found" >&2
  exit 1
}

YOCTO_BUILD="${YOCTO_BUILD:-$HOME/WORK/KM/yocto/build}"

link_debug_symbols() {
  local art="$1" mc="$2"
  local work="$YOCTO_BUILD/tmp-${mc}/work/${mc}-poky-linux"
  local bl31="$work/arm-trusted-firmware/v2.14/git/build/km/release/bl31/bl31.elf"
  local uboot_dir="$work/u-boot-socfpga/v2026.01+git/build/socfpga_km_emu_defconfig"
  link_one() {
    local src="$1" dst="$2"
    if [[ -f "$src" && ! -e "$dst" ]]; then
      ln -sf "$src" "$dst"
      echo "Linked debug symbol: $(basename "$dst")"
    fi
  }
  link_one "$bl31" "$art/bl31.elf"
  link_one "$uboot_dir/u-boot" "$art/u-boot"
  link_one "$uboot_dir/spl/u-boot-spl" "$art/u-boot-spl"
}

case "$FLAVOR" in
  emul)
    ART="$ROOT/images/emul"
    MC=km_emul
    DTB_NAME=socfpga_km.dtb
    BOOT_MEDIA=ram
    BOOT_METHOD=backdoor
    if [[ -f "$ART/initrd_emul.uboot" && ! -e "$ART/initrd135.uboot" ]]; then
      ln -sfn initrd_emul.uboot "$ART/initrd135.uboot"
    fi
    ;;
  osbv)
    ART="$ROOT/images/osbv"
    MC=km_osbv_sdmmc
    DTB_NAME=socfpga_km_OSbV_sdmmc.dtb
    BOOT_MEDIA=ram
    BOOT_METHOD=sd
    WIC="$ART/core-image-full-cmdline-km_osbv_sdmmc.wic"
    [[ -f "$WIC" ]] || { echo "ERROR: missing WIC: $WIC" >&2; exit 1; }
    if [[ ! -e "$ART/gsrd-console-image-agilex5_lok.wic" ]]; then
      ln -sf "$(basename "$WIC")" "$ART/gsrd-console-image-agilex5_lok.wic"
    fi
    ;;
  *)
    echo "Usage: $0 {emul|osbv} [km_generic overrides...]" >&2
    exit 1
    ;;
esac

[[ -d "$ART" ]] || { echo "ERROR: missing artifacts dir: $ART" >&2; exit 1; }

if [[ "${ENABLE_DEBUG_SYMBOLS:-0}" == "1" ]]; then
  link_debug_symbols "$ART" "$MC"
  extra=(TARGET=universal BOOT_MEDIA="$BOOT_MEDIA" BOOT_METHOD="$BOOT_METHOD" SKIP_DEBUG_SYMBOLS=FALSE)
else
  extra=(TARGET=universal BOOT_MEDIA="$BOOT_MEDIA" BOOT_METHOD="$BOOT_METHOD" SKIP_DEBUG_SYMBOLS=TRUE)
fi
extra+=(UBOOT_DIR="$ART" IMG_DIR="$ART" DTB_NAME="$DTB_NAME")

exec "$ROOT/simics" "$KM_GENERIC" "${extra[@]}" "$@"
