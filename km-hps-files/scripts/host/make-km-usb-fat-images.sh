#!/usr/bin/env bash
# Create superfloppy FAT images for Simics USB mass-storage (usb.scr gate).
# Sizes match km-universal-board-comp: usb3_disk=128MiB, usb3_hs_disk=256MiB.
set -euo pipefail
export PATH="/sbin:/usr/sbin:${PATH}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/images/usb}"
mkdir -p "$OUT"

make_one() {
  local name="$1" mb="$2" label="$3"
  local path="$OUT/$name"
  echo "Writing $path (${mb} MiB, label=$label)"
  dd if=/dev/zero of="$path" bs=1M count="$mb" status=none
  mkfs.vfat -F 32 -n "$label" -I "$path"
}

make_one km-usb-fat-128m.img 128 KMUSB3
make_one km-usb-fat-hs-256m.img 256 KMUSBHS
ls -lh "$OUT"/km-usb-fat-*.img
echo "Boot script loads these via usb3_image_filename / usb3_hs_image_filename."
