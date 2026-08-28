#!/usr/bin/env bash
# KM emul on intel-fpga-main: SMP + SVE on by default.
#
#   source ~/km-hps/set_simics_env_main.sh
#   ./scripts/run-emul-smp.sh              # maxcpus=4, SVE userspace
#   EMUL_NOSMP=1 ./scripts/run-emul-smp.sh # nosmp (debug)
#   EMUL_NOSVE=1 ./scripts/run-emul-smp.sh # arm64.nosve + ~14MiB nosve initrd
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
unset SIMICS_BASE SIMICS_BASE_PACKAGE SIMICS_FPGA_ROOT SIMICS_PYTHON_PACKAGE SIMICS_PYTHON
# shellcheck disable=SC1091
source "$ROOT/set_simics_env_main.sh"

ART="${ARTIFACTS_DIR:-$ROOT/images/emul}"
[[ -d "$ART" ]] || { echo "ERROR: missing $ART" >&2; exit 1; }

case "${SIMICS_BASE}" in
  *intel-fpga-main*|*intel-fpga_main*) ;;
  *)
    echo "ERROR: run-emul-smp.sh requires intel-fpga-main; got SIMICS_BASE=$SIMICS_BASE" >&2
    exit 1
    ;;
esac

INITRD="$ART/initrd_emul.uboot"
ITB="$ART/u-boot.itb"
[[ -f "$INITRD" ]] || { echo "ERROR: missing $INITRD" >&2; exit 1; }
[[ -f "$ITB" ]] || { echo "ERROR: missing $ITB" >&2; exit 1; }

initrd_sz="$(stat -c%s "$INITRD")"
EMUL_NOSMP="${EMUL_NOSMP:-0}"
EMUL_NOSVE="${EMUL_NOSVE:-0}"

fit_has_blob() {
  local blob="$1"
  [[ -f "$blob" ]] || return 1
  python3 - "$ITB" "$blob" <<'PY'
import pathlib, sys
sys.exit(0 if pathlib.Path(sys.argv[2]).read_bytes() in pathlib.Path(sys.argv[1]).read_bytes() else 1)
PY
}

cpu_arg="maxcpus=4"
[[ "$EMUL_NOSMP" == "1" ]] && cpu_arg="nosmp"

sve_prefix=""
[[ "$EMUL_NOSVE" == "1" ]] && sve_prefix="arm64.nosve "

bootargs="earlycon ${sve_prefix}console=ttyS0,115200n8 root=/dev/ram0 rw init=/init ramdisk_size=1000000 ${cpu_arg}"

if [[ "$EMUL_NOSVE" == "1" ]]; then
  echo "mode: SMP=$([[ "$EMUL_NOSMP" == "1" ]] && echo off || echo on) SVE=off (arm64.nosve)"
  if (( initrd_sz < 10000000 )); then
    echo "ERROR: EMUL_NOSVE=1 needs ~14MiB nosve initrd; staged initrd is $(du -h "$INITRD" | awk '{print $1}')." >&2
    echo "  Restore: cp $ART/bak-stage-*/initrd_emul.uboot $INITRD" >&2
    exit 1
  fi
else
  echo "mode: SMP=$([[ "$EMUL_NOSMP" == "1" ]] && echo off || echo on) SVE=on (default mainline)"
  if (( initrd_sz >= 10000000 )); then
    echo "ERROR: SVE-on expects ~8MiB Yocto SVE initrd; staged initrd is $(du -h "$INITRD" | awk '{print $1}')." >&2
    echo "  Stage: ./scripts/stage-artifact.sh emul --deploy ~/WORK/KM/yocto/build/collected-binaries/emul" >&2
    echo "  Or:    EMUL_NOSVE=1 $0" >&2
    exit 1
  fi
  if [[ -f "$ART/bl31-nosve.bin" ]] && fit_has_blob "$ART/bl31-nosve.bin"; then
    if [[ -f "$ART/bl31-sve.bin" ]] && fit_has_blob "$ART/bl31-sve.bin"; then
      :
    else
      echo "ERROR: u-boot.itb embeds bl31-nosve — emul SMP+SVE needs bl31-sve in FIT." >&2
      echo "  Yocto: set ATF_SVE_DEFAULT:km_emul = \"sve\" in local.conf, then:" >&2
      echo "    bitbake mc:km_emul:u-boot-socfpga && recollect + restage emul" >&2
      echo "  Or:    USE_HAMZA_ITB=1 ./scripts/stage-artifact.sh emul" >&2
      echo "  Debug nosve only: EMUL_NOSVE=1 $0" >&2
      exit 1
    fi
  fi
fi

extra=(bootargs="$bootargs")
if [[ -n "${SDM_HMOD_FW:-}" && -f "${SDM_HMOD_FW}" ]]; then
  extra+=(sdm_hmod_fw_image_filename="$SDM_HMOD_FW")
fi
if [[ -n "${TELNET_PORT:-}" ]]; then
  extra+=(console_telnet_port="$TELNET_PORT")
fi

exec "$ROOT/simics" scripts/boot-to-linux-smp.simics \
  artifacts_dir="$ART" \
  "${extra[@]}" \
  "$@"
