#!/usr/bin/env bash
# Stage KM boot binaries into ~/km-hps/images/{emul|osbv} from a Yocto
# collected-binaries (or deploy) directory.
#
#   ./scripts/stage-artifact.sh emul
#   ./scripts/stage-artifact.sh osbv
#   ./scripts/stage-artifact.sh emul --deploy ~/WORK/KM/yocto/build/collected-binaries/emul
#   ./scripts/stage-artifact.sh osbv --deploy /path/to/osbv_sdmmc --out ~/km-hps/images/osbv
#   ./scripts/stage-artifact.sh osbv --from http://alisubun1.sj.altera.com/share/KM --date latest
#   ./scripts/stage-artifact.sh emul --from /var/www/html/share/KM --date 2026-08-21
#
# Does NOT mkimage-repack u-boot.itb (/incbin/ breaks SPL→U-Boot).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "$*"; }

usage() {
  cat <<EOF
Usage: $0 {emul|osbv} [--deploy DIR | --from URL_OR_PATH [--date DATE|latest]]
                    [--out DIR] [--initrd {sve|nosve|both}] [--fix-initrd] [--keep-initrd]

  emul | osbv     Which flavor to stage into \$KM_HPS/images/<flavor>
  --deploy DIR    Local source directory (collected-binaries or fetch cache)
  --from URL|PATH Fetch from HTTP or local/NFS share root, then stage
  --date DATE     With --from: YYYY-MM-DD or latest (default: latest)
  --out DIR       Destination (default: \$KM_HPS/images/{emul|osbv})
  --initrd sve|nosve|both   emul initrd selection (default: both)
  --fix-initrd / --no-fix-initrd / --keep-initrd   emul initrd options

Default --deploy search order:
  \$COLLECTED
  \$HOME/WORK/KM/yocto/build/collected-binaries/{emul|osbv_sdmmc}
  \$HOME/WORK/KM/yocto/collected-binaries/{emul|osbv_sdmmc}

KM_HPS defaults to \$HOME/km-hps (or \$ROOT if scripts live there).
EOF
  exit 1
}

# --- args ---
FLAVOR="${1:-}"
[[ -n "$FLAVOR" ]] || usage
case "$FLAVOR" in
  -h|--help) usage ;;
esac
shift || true

DEPLOY=""
FROM=""
FROM_DATE="latest"
OUT=""
FIX_INITRD=-1   # -1 = auto (fix only if /init lacks shebang), 0 = off, 1 = on
KEEP_INITRD=0
INITRD_MODE="both"   # sve | nosve | both (emul only)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy) DEPLOY="${2:?}"; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --date) FROM_DATE="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --fix-initrd) FIX_INITRD=1; shift ;;
    --no-fix-initrd) FIX_INITRD=0; shift ;;
    --keep-initrd) KEEP_INITRD=1; shift ;;
    --initrd)
      INITRD_MODE="${2:?sve|nosve|both}"
      case "$INITRD_MODE" in sve|nosve|both) shift 2 ;;
      *) die "--initrd must be sve, nosve, or both" ;;
      esac
      ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

case "$FLAVOR" in
  emul) COLLECT_SUB="emul"; OUT_SUB="emul" ;;
  osbv|osbv_sdmmc)
    FLAVOR="osbv"
    COLLECT_SUB="osbv_sdmmc"
    OUT_SUB="osbv"
    ;;
  *) die "flavor must be emul or osbv (got: $FLAVOR)" ;;
esac

KM_HPS="${KM_HPS:-}"
if [[ -z "$KM_HPS" ]]; then
  if [[ -d "$ROOT/images" ]]; then
    KM_HPS="$ROOT"
  else
    KM_HPS="$HOME/km-hps"
  fi
fi
[[ -z "$OUT" ]] && OUT="$KM_HPS/images/$OUT_SUB"

default_deploy() {
  local sub="$1"
  if [[ -n "${COLLECTED:-}" ]]; then
    if [[ -d "$COLLECTED/$sub" ]]; then
      echo "$COLLECTED/$sub"
      return
    fi
    if [[ -d "$COLLECTED" ]]; then
      echo "$COLLECTED"
      return
    fi
  fi
  local c
  for c in \
    "$HOME/WORK/KM/yocto/build/collected-binaries/$sub" \
    "$HOME/WORK/KM/yocto/collected-binaries/$sub"
  do
    if [[ -d "$c" ]]; then
      echo "$c"
      return
    fi
  done
  return 1
}

find_fetch_script() {
  local c
  for c in \
    "$SCRIPT_DIR/../artifacts/fetch-km-artifacts.sh" \
    "$SCRIPT_DIR/fetch-km-artifacts.sh" \
    "$KM_HPS/scripts/fetch-km-artifacts.sh"
  do
    if [[ -x "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

if [[ -n "$FROM" ]]; then
  [[ -z "$DEPLOY" ]] || die "use either --from or --deploy, not both"
  FETCH_SH="$(find_fetch_script)" \
    || die "fetch-km-artifacts.sh not found (sync scripts or run from framework tree)"
  fetch_out="$("$FETCH_SH" "$FLAVOR" --from "$FROM" --date "$FROM_DATE" | tee /dev/stderr | sed -n 's/^FETCHED=//p' | tail -1)"
  [[ -n "$fetch_out" && -d "$fetch_out" ]] || die "fetch did not report FETCHED= dir"
  DEPLOY="$fetch_out"
fi

if [[ -z "$DEPLOY" ]]; then
  DEPLOY="$(default_deploy "$COLLECT_SUB")" \
    || die "no --deploy/--from and no default collect dir for $COLLECT_SUB"
fi
[[ -d "$DEPLOY" ]] || die "deploy dir missing: $DEPLOY"

mkdir -p "$OUT"

# --- helpers ---
copy_one() {
  # copy_one SRC_NAME [DST_NAME]
  local src_name="$1" dst_name="${2:-$1}" src
  src="$DEPLOY/$src_name"
  [[ -e "$src" ]] || return 1
  cp -aL "$src" "$OUT/$dst_name"
  info "  + $dst_name  ($(du -h "$OUT/$dst_name" | awk '{print $1}'))"
  return 0
}

find_first() {
  # print first existing path among names under DEPLOY
  local n
  for n in "$@"; do
    if [[ -e "$DEPLOY/$n" ]]; then
      echo "$DEPLOY/$n"
      return 0
    fi
  done
  return 1
}

stage_spl() {
  local src bin="$OUT/u-boot-spl-dtb.bin"
  if src="$(find_first u-boot-spl-dtb.bin)"; then
    cp -aL "$src" "$bin"
    info "  + u-boot-spl-dtb.bin  ($(du -h "$bin" | awk '{print $1}'))"
  elif src="$(find_first u-boot-spl-dtb.hex u-boot-spl-dtb.hex-km_emu u-boot-spl-dtb.hex-km_emul u-boot-spl-dtb.hex-km_osbv_sdmmc)"; then
    command -v objcopy >/dev/null || die "objcopy needed to convert $(basename "$src")"
    objcopy -I ihex -O binary "$src" "$bin"
    info "  + u-boot-spl-dtb.bin  (from $(basename "$src"))"
  else
    die "u-boot-spl-dtb.bin/.hex not found under $DEPLOY"
  fi
}

stage_itb() {
  local src
  src="$(find_first u-boot.itb u-boot-km_emul.itb u-boot-km_osbv_sdmmc.itb)" \
    || die "u-boot.itb not found under $DEPLOY"
  cp -aL "$src" "$OUT/u-boot.itb"
  info "  + u-boot.itb  ($(du -h "$OUT/u-boot.itb" | awk '{print $1}'))"
}

stage_bl31() {
  copy_one bl31-sve.bin || true
  copy_one bl31-nosve.bin || true
  if [[ -e "$DEPLOY/bl31.bin" ]]; then
    copy_one bl31.bin || true
  elif [[ -e "$OUT/bl31-sve.bin" ]]; then
    cp -a "$OUT/bl31-sve.bin" "$OUT/bl31.bin"
    info "  + bl31.bin  (← bl31-sve.bin)"
  elif [[ -e "$OUT/bl31-nosve.bin" ]]; then
    cp -a "$OUT/bl31-nosve.bin" "$OUT/bl31.bin"
    info "  + bl31.bin  (← bl31-nosve.bin)"
  fi
}

fit_contains_file() {
  local itb="$1" blob="$2"
  python3 - "$itb" "$blob" <<'PY'
import pathlib, sys
itb = pathlib.Path(sys.argv[1]).read_bytes()
blob = pathlib.Path(sys.argv[2]).read_bytes()
sys.exit(0 if blob in itb else 1)
PY
}

fix_emul_initrd() {
  local uboot="$1"
  local tmp work
  tmp="$(mktemp -d)"
  work="$tmp/rootfs.ext2"
  dd if="$uboot" of="$work" bs=1 skip=64 status=none
  cat >"$tmp/init.new" <<'EOF'
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
mount -t devtmpfs none /dev 2>/dev/null || true
echo ""
echo "KM emul init OK"
echo ""
exec /bin/sh
EOF
  chmod 755 "$tmp/init.new"
  debugfs -w "$work" <<EOF >/dev/null 2>&1 || true
mkdir /dev
EOF
  debugfs -w "$work" <<EOF
rm /init
write $tmp/init.new /init
sif /init mode 0x81ed
quit
EOF
  mkimage -A arm64 -O linux -T ramdisk -C none \
    -a 0x90000000 -e 0x90000000 -n "Root file system" \
    -d "$work" "$uboot"
  rm -rf "$tmp"
  info "  patched initrd /init + /dev"
}

initrd_needs_fix() {
  local uboot="$1"
  local tmp work first
  tmp="$(mktemp -d)"
  work="$tmp/rootfs.ext2"
  dd if="$uboot" of="$work" bs=1 skip=64 status=none 2>/dev/null || { rm -rf "$tmp"; return 1; }
  first="$(debugfs -R 'cat /init' "$work" 2>/dev/null | head -1 || true)"
  rm -rf "$tmp"
  [[ "$first" != \#!/* ]]
}

initrd_kind() {
  # sve if < 10MiB (typical ~8MiB SVE busybox), else nosve
  local sz="$1"
  (( sz < 10000000 )) && echo sve || echo nosve
}

stage_emul_initrd_copy() {
  # stage_emul_initrd_copy SRC_BASENAME DST_BASENAME
  local src_name="$1" dst_name="$2"
  local src="$DEPLOY/$src_name"
  [[ -e "$src" ]] || return 1
  if [[ "$KEEP_INITRD" == "1" && -f "$OUT/$dst_name" ]]; then
    info "  keep existing $dst_name ($(du -h "$OUT/$dst_name" | awk '{print $1}'))"
    return 0
  fi
  cp -aL "$src" "$OUT/$dst_name"
  local sz kind
  sz="$(stat -c%s "$OUT/$dst_name")"
  kind="$(initrd_kind "$sz")"
  info "  + $dst_name  ($(du -h "$OUT/$dst_name" | awk '{print $1}'), $kind busybox)"
  return 0
}

maybe_fix_initrd() {
  local uboot="$1"
  local do_fix=0
  if [[ "$FIX_INITRD" == "1" ]]; then
    do_fix=1
  elif [[ "$FIX_INITRD" == "-1" ]] && initrd_needs_fix "$uboot"; then
    do_fix=1
    warn "$(basename "$uboot"): /init lacks shebang — patching (rebuild km-emul-initrd to avoid)"
  fi
  if [[ "$do_fix" == "1" ]]; then
    cp -a "$uboot" "${uboot}.bak-pre-fix"
    fix_emul_initrd "$uboot"
  fi
}

stage_emul_initrds() {
  local have_sve=0 have_nosve=0

  case "$INITRD_MODE" in
    sve)
      stage_emul_initrd_copy initrd_emul.uboot initrd_emul.uboot && have_sve=1 \
        || die "initrd_emul.uboot not found under $DEPLOY"
      ;;
    nosve)
      if stage_emul_initrd_copy initrd_emul_nosve.uboot initrd_emul_nosve.uboot; then
        have_nosve=1
        cp -a "$OUT/initrd_emul_nosve.uboot" "$OUT/initrd_emul.uboot"
        info "  + initrd_emul.uboot  (← initrd_emul_nosve.uboot for nosve boot)"
      elif stage_emul_initrd_copy initrd_emul.uboot initrd_emul.uboot; then
        have_nosve=1
        warn "initrd_emul_nosve.uboot missing — using large initrd_emul.uboot as nosve"
      else
        die "no initrd under $DEPLOY (need initrd_emul_nosve.uboot or nosve initrd_emul.uboot)"
      fi
      ;;
    both)
      stage_emul_initrd_copy initrd_emul.uboot initrd_emul.uboot && have_sve=1 \
        || warn "initrd_emul.uboot (SVE) not found under $DEPLOY"
      if stage_emul_initrd_copy initrd_emul_nosve.uboot initrd_emul_nosve.uboot; then
        have_nosve=1
      else
        warn "initrd_emul_nosve.uboot not found — EMUL_NOSVE=1 needs bitbake km-emul-initrd-nosve"
      fi
      [[ "$have_sve" == "1" || "$have_nosve" == "1" ]] \
        || die "no initrd artifacts under $DEPLOY"
      ;;
  esac

  [[ -f "$OUT/initrd_emul.uboot" ]] && maybe_fix_initrd "$OUT/initrd_emul.uboot"
  [[ -f "$OUT/initrd_emul_nosve.uboot" ]] && maybe_fix_initrd "$OUT/initrd_emul_nosve.uboot"
  ln -sfn initrd_emul.uboot "$OUT/initrd135.uboot"
}

# --- stage by flavor ---
info "stage-artifact: $FLAVOR"
info "  deploy = $DEPLOY"
info "  out    = $OUT"

stage_spl
stage_itb
stage_bl31

copy_one Image || die "Image not found under $DEPLOY"

case "$FLAVOR" in
  emul)
    stage_emul_initrds

    # DTB often not in collect — keep existing or copy if present
    if copy_one socfpga_km.dtb \
      || copy_one socfpga_km_emul.dtb socfpga_km.dtb; then
      :
    elif [[ -f "$OUT/socfpga_km.dtb" ]]; then
      info "  keep existing socfpga_km.dtb"
    else
      warn "socfpga_km.dtb missing in deploy and out — boot scripts need it"
    fi
    ;;
  osbv)
    dtb="$(find_first socfpga_km_OSbV_sdmmc.dtb)" \
      || die "socfpga_km_OSbV_sdmmc.dtb not found under $DEPLOY"
    cp -aL "$dtb" "$OUT/socfpga_km_OSbV_sdmmc.dtb"
    info "  + socfpga_km_OSbV_sdmmc.dtb"

    wic="$(find_first \
      core-image-full-cmdline-km_osbv_sdmmc.wic \
      core-image-full-cmdline-km_osbv_sdmmc.rootfs.wic)" \
      || die "WIC not found under $DEPLOY"
    cp -aL "$wic" "$OUT/core-image-full-cmdline-km_osbv_sdmmc.wic"
    info "  + core-image-full-cmdline-km_osbv_sdmmc.wic  ($(du -h "$OUT/core-image-full-cmdline-km_osbv_sdmmc.wic" | awk '{print $1}'))"
    ;;
esac

# FIT / ATF sanity (do not repack)
if [[ -f "$OUT/u-boot.itb" ]]; then
  if command -v dumpimage >/dev/null 2>&1; then
    info ""
    info "FIT ATF slot:"
    dumpimage -l "$OUT/u-boot.itb" | sed -n '/Image 1 (atf)/,/Image 2/p' | head -12 || true
  fi
  if [[ -f "$OUT/bl31-sve.bin" ]] && fit_contains_file "$OUT/u-boot.itb" "$OUT/bl31-sve.bin"; then
    info "OK: u-boot.itb embeds bl31-sve"
  elif [[ -f "$OUT/bl31-nosve.bin" ]] && fit_contains_file "$OUT/u-boot.itb" "$OUT/bl31-nosve.bin"; then
    if [[ "$FLAVOR" == "emul" ]]; then
      warn "emul FIT embeds bl31-nosve — main SMP+SVE needs ATF_SVE_DEFAULT:km_emul=sve rebuild or USE_HAMZA_ITB=1"
    else
      info "OK: u-boot.itb embeds bl31-nosve"
    fi
  else
    warn "could not match bl31-sve/nosve bytes inside FIT (external-data ITB is OK)"
  fi
fi

info ""
info "Staged → $OUT"
if [[ "$FLAVOR" == "emul" ]]; then
  info "Next (intel-fpga-main — default SMP+SVE):"
  info "  source $KM_HPS/set_simics_env_main.sh && $KM_HPS/scripts/run-emul-smp.sh"
  info "  options: EMUL_NOSMP=1  EMUL_NOSVE=1  (uses initrd_emul_nosve.uboot if staged)"
else
  info "Next (intel-fpga-main — default SMP+SVE):"
  info "  source $KM_HPS/set_simics_env_main.sh && $KM_HPS/scripts/run-osbv-smp.sh"
fi
