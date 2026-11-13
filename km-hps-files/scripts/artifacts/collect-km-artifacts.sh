#!/usr/bin/env bash
# Collect KM Simics boot artifacts. Merges NEWEST of each file across TMPDIRs
# and previous collect. Logs: + UPDATED | = UNCHANGED/KEPT | ! MISSING
#
#   ./scripts/artifacts/collect-km-artifacts.sh osbv_sdmmc
#   ~/km-hps/scripts/stage-artifact.sh osbv --deploy $YOCTO_BUILD/collected-binaries/osbv_sdmmc
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK="$(cd "$HERE/../.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }
warn() { echo "WARNING: $*" >&2; }
usage() {
  cat <<USAGE
Usage: $0 {emul|osbv_sdmmc|both} [--out DIR] [--yocto-build DIR]
USAGE
  exit 1
}
FLAVOR="${1:-}"; [[ -n "$FLAVOR" ]] || usage; shift || true
OUT_ROOT=""; YOCTO_BUILD="${YOCTO_BUILD:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_ROOT="${2:?}"; shift 2 ;;
    --yocto-build) YOCTO_BUILD="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1" ;;
  esac
done
if [[ -z "$YOCTO_BUILD" ]]; then
  if [[ -d "$FRAMEWORK/../build" ]]; then YOCTO_BUILD="$(cd "$FRAMEWORK/../build" && pwd)"
  else YOCTO_BUILD="$HOME/WORK/KM/yocto/build"; fi
fi
[[ -z "$OUT_ROOT" ]] && OUT_ROOT="$YOCTO_BUILD/collected-binaries"

file_md5() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

deploy_dirs_for() {
  local machine="$1" d
  for d in \
    "$YOCTO_BUILD/tmp-${machine}/deploy/images/${machine}" \
    "$YOCTO_BUILD/tmp/deploy/images/${machine}"
  do [[ -d "$d" ]] && printf '%s\n' "$d"; done
}

pick_newest() {
  local newest="" newest_m=0 root cand path m real
  local -a roots=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do roots+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] || die "pick_newest: need --"; shift
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    for cand in "$@"; do
      # shellcheck disable=SC2086
      for path in "$root"/$cand; do
        [[ -e "$path" ]] || continue
        [[ -f "$path" || -L "$path" ]] || continue
        real="$(readlink -f "$path" 2>/dev/null || echo "$path")"
        m=$(stat -c %Y "$real")
        if [[ -z "$newest" || "$m" -gt "$newest_m" ]]; then
          newest="$path"; newest_m=$m
        fi
      done
    done
  done
  [[ -n "$newest" ]] || return 1
  printf '%s\n' "$newest"
}

install_picked() {
  local out_dir="$1" dst_name="$2" src="$3" prev_dir="${4:-}"
  local dst="$out_dir/$dst_name" new old tag src_label src_real prev_real
  mkdir -p "$out_dir"
  src_real="$(readlink -f "$src")"
  new="$(file_md5 "$src_real")"
  src_label="$(basename "$(dirname "$src")")/$(basename "$src")"
  old=""; tag="UPDATED"
  if [[ -n "$prev_dir" && -e "$prev_dir/$dst_name" ]]; then
    prev_real="$(readlink -f "$prev_dir/$dst_name")"
    old="$(file_md5 "$prev_real")"
    if [[ "$src_real" == "$prev_real" ]]; then tag="KEPT"
    elif [[ "$old" == "$new" ]]; then tag="UNCHANGED"
    fi
  fi
  cp -aL "$src" "$dst"
  local mark="+"; [[ "$tag" == "UPDATED" ]] || mark="="
  info "  $mark $dst_name  $tag  ($(du -h "$dst" | awk '{print $1}') md5=${new:0:12}… ← $src_label)"
}

require_pick() {
  local out_dir="$1" dst_name="$2" prev_dir="$3"; shift 3
  local -a roots=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do roots+=("$1"); shift; done
  shift
  local src
  if src="$(pick_newest "${roots[@]}" -- "$@")"; then
    install_picked "$out_dir" "$dst_name" "$src" "$prev_dir"; return 0
  fi
  warn "  ! $dst_name  MISSING  (looked for: $*)"; return 1
}
optional_pick() { require_pick "$@" || true; }

write_manifest() {
  local out_dir="$1" 
  local manifest="$out_dir/collected-files.txt" 
  local sums="$out_dir/SHA256SUMS"
  : >"$manifest"; : >"$sums"
  local f base
  for f in "$out_dir"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in collected-files.txt|SHA256SUMS|SOURCES.txt) continue ;; esac
    echo "$base" >>"$manifest"
    (cd "$out_dir" && sha256sum "$base" >>"$sums")
  done
  sort -o "$manifest" "$manifest"
  {
    echo "# collected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# yocto_build=$YOCTO_BUILD"
    for f in "$out_dir"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      case "$base" in collected-files.txt|SHA256SUMS|SOURCES.txt) continue ;; esac
      printf '%s  %s  md5=%s\n' "$(stat -c '%y' "$f" | cut -d. -f1)" "$base" "$(file_md5 "$f")"
    done
  } >"$out_dir/SOURCES.txt"
  info "  manifest: $manifest"
  info "  sources:  $out_dir/SOURCES.txt"
}


# In prepare_out, change the info line to stderr:
prepare_out() {
  local out="$1"
  local prev=""
  if [[ -d "$out" ]] && compgen -G "$out/*" >/dev/null 2>&1; then
    prev="$(mktemp -d "${TMPDIR:-/tmp}/km-collect-prev.XXXXXX")"
    find "$out" -mindepth 1 -maxdepth 1 -exec mv {} "$prev/" \;
    info "  previous collect stashed for merge: $prev" >&2 >&2
  fi
  mkdir -p "$out"
  printf '%s\n' "$prev"
}

cleanup_prev() { [[ -n "${1:-}" && -d "$1" ]] && rm -rf "$1"; }

collect_emul() {
  local machine=km_emul out="$OUT_ROOT/emul" missing=0 prev=""
  local -a roots=()
  mapfile -t roots < <(deploy_dirs_for "$machine")
  [[ ${#roots[@]} -gt 0 ]] || die "no emul deploy under $YOCTO_BUILD"
  info "collect emul"; info "  yocto_build = $YOCTO_BUILD"
  local r; for r in "${roots[@]}"; do info "    - $r"; done
  info "  out = $out"
  prev="$(prepare_out "$out")"; [[ -n "$prev" ]] && roots+=("$prev")
  require_pick "$out" Image "$prev" "${roots[@]}" -- Image Image-km_emul.bin 'Image--*.bin' || missing=1
  require_pick "$out" u-boot.itb "$prev" "${roots[@]}" -- u-boot.itb u-boot-km_emul.itb || missing=1
  require_pick "$out" u-boot-spl-dtb.hex "$prev" "${roots[@]}" -- \
    u-boot-spl-dtb.hex u-boot-spl-dtb.hex-km_emul u-boot-spl-dtb.hex-km_emu || missing=1
  if ! require_pick "$out" socfpga_km.dtb "$prev" "${roots[@]}" -- socfpga_km.dtb socfpga_km_emul.dtb; then
    km_hps="${KM_HPS:-$HOME/km-hps}"
    if [[ -f "$km_hps/images/emul/socfpga_km.dtb" ]]; then
      install_picked "$out" socfpga_km.dtb "$km_hps/images/emul/socfpga_km.dtb" "$prev"
    else missing=1; fi
  fi
  require_pick "$out" initrd_emul.uboot "$prev" "${roots[@]}" -- initrd_emul.uboot || missing=1
  optional_pick "$out" initrd_emul_nosve.uboot "$prev" "${roots[@]}" -- initrd_emul_nosve.uboot
  require_pick "$out" bl31-sve.bin "$prev" "${roots[@]}" -- bl31-sve.bin || missing=1
  optional_pick "$out" bl31-nosve.bin "$prev" "${roots[@]}" -- bl31-nosve.bin
  if ! require_pick "$out" bl31.bin "$prev" "${roots[@]}" -- bl31.bin; then
    if [[ -f "$out/bl31-sve.bin" ]]; then cp -aL "$out/bl31-sve.bin" "$out/bl31.bin"; info "  + bl31.bin  UPDATED  (← bl31-sve.bin)"
    elif [[ -f "$out/bl31-nosve.bin" ]]; then cp -aL "$out/bl31-nosve.bin" "$out/bl31.bin"; info "  + bl31.bin  UPDATED  (← bl31-nosve.bin)"
    else missing=1; fi
  fi
  write_manifest "$out"; cleanup_prev "$prev"
  info "Collected emul → $out"
  [[ "$missing" -eq 0 ]] || die "emul collect incomplete"
}

collect_osbv() {
  local machine=km_osbv_sdmmc out="$OUT_ROOT/osbv_sdmmc" missing=0 prev=""
  local -a roots=()
  mapfile -t roots < <(deploy_dirs_for "$machine")
  [[ ${#roots[@]} -gt 0 ]] || die "no osbv deploy under $YOCTO_BUILD"
  info "collect osbv_sdmmc"; info "  yocto_build = $YOCTO_BUILD"
  local r; for r in "${roots[@]}"; do info "    - $r"; done
  info "  out = $out"
  prev="$(prepare_out "$out")"; [[ -n "$prev" ]] && roots+=("$prev")

  require_pick "$out" Image "$prev" "${roots[@]}" -- Image Image-km_osbv_sdmmc.bin 'Image--*.bin' || missing=1
  require_pick "$out" u-boot.itb "$prev" "${roots[@]}" -- u-boot.itb u-boot-km_osbv_sdmmc.itb || missing=1
  require_pick "$out" u-boot-spl-dtb.hex "$prev" "${roots[@]}" -- \
    u-boot-spl-dtb.hex u-boot-spl-dtb.hex-km_osbv_sdmmc u-boot-spl-dtb.hex-km_emu || missing=1
  require_pick "$out" socfpga_km_OSbV_sdmmc.dtb "$prev" "${roots[@]}" -- \
    socfpga_km_OSbV_sdmmc.dtb 'socfpga_km_OSbV_sdmmc--*.dtb' || missing=1
  require_pick "$out" core-image-full-cmdline-km_osbv_sdmmc.wic "$prev" "${roots[@]}" -- \
    core-image-full-cmdline-km_osbv_sdmmc.wic \
    core-image-full-cmdline-km_osbv_sdmmc.rootfs.wic \
    'core-image-full-cmdline-km_osbv_sdmmc.rootfs-*.wic' || missing=1
  require_pick "$out" bl31.bin "$prev" "${roots[@]}" -- bl31.bin bl31-sve.bin || missing=1
  optional_pick "$out" bl31-sve.bin "$prev" "${roots[@]}" -- bl31-sve.bin
  optional_pick "$out" u-boot.elf "$prev" "${roots[@]}" -- u-boot.elf u-boot-km_osbv_sdmmc.elf
  optional_pick "$out" modules-km_osbv_sdmmc.tgz "$prev" "${roots[@]}" -- modules-km_osbv_sdmmc.tgz

  if [[ -f "$out/core-image-full-cmdline-km_osbv_sdmmc.wic" \
     && ! -e "$out/core-image-full-cmdline-km_osbv_sdmmc.rootfs.wic" ]]; then
    ln -f "$out/core-image-full-cmdline-km_osbv_sdmmc.wic" \
          "$out/core-image-full-cmdline-km_osbv_sdmmc.rootfs.wic" 2>/dev/null \
      || cp -aL "$out/core-image-full-cmdline-km_osbv_sdmmc.wic" \
                "$out/core-image-full-cmdline-km_osbv_sdmmc.rootfs.wic"
    info "  = core-image-full-cmdline-km_osbv_sdmmc.rootfs.wic  alias"
  fi
  write_manifest "$out"; cleanup_prev "$prev"
  info "Collected osbv_sdmmc → $out"
  info "Next: ~/km-hps/scripts/stage-artifact.sh osbv --deploy $out"
  [[ "$missing" -eq 0 ]] || die "osbv_sdmmc collect incomplete"
}

case "$FLAVOR" in
  emul) collect_emul ;;
  osbv|osbv_sdmmc) collect_osbv ;;
  both) collect_emul; collect_osbv ;;
  *) die "flavor must be emul, osbv_sdmmc, or both" ;;
esac
