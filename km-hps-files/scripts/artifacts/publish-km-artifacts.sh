#!/usr/bin/env bash
# Publish curated collected-binaries into a local or NFS-mounted share tree.
#
#   ./scripts/artifacts/publish-km-artifacts.sh both \
#     --dest /DISK1/nfs/webdata/osbv-yo/KM --latest \
#     --collect-root /home/alisov/WORK/KM/yocto/build/collected-binaries
#
# Transport: local path or NFS mount only (no SSH/HTTP upload).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK="$(cd "$HERE/../.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }

usage() {
  cat <<EOF
Usage: $0 {emul|osbv_sdmmc|osbv|both} --dest DIR [--date YYYY-MM-DD] [--latest]
           [--collect-root DIR]

  First arg is required: emul | osbv_sdmmc | osbv | both

  --dest DIR         Writable local or NFS-mounted share root
                     (e.g. /DISK1/nfs/webdata/osbv-yo/KM)
  --date YYYY-MM-DD  Drop date (default: today)
  --latest           Update \$DEST/latest -> \$DATE symlink
  --collect-root DIR Source collected-binaries root
                     (default: \$YOCTO_BUILD/collected-binaries)

Example:
  $0 both --dest /DISK1/nfs/webdata/osbv-yo/KM --latest \\
    --collect-root /home/alisov/WORK/KM/yocto/build/collected-binaries
EOF
  exit 1
}

FLAVOR="${1:-}"
[[ -n "$FLAVOR" ]] || usage
case "$FLAVOR" in
  -h|--help) usage ;;
  --*)
    die "missing flavor before flags (got '$FLAVOR'). Use: $0 {emul|osbv_sdmmc|both} --dest DIR ..."
    ;;
esac
shift || true

DEST=""
DATE="$(date +%F)"
LATEST=0
COLLECT_ROOT="${COLLECT_ROOT:-}"
YOCTO_BUILD="${YOCTO_BUILD:-$HOME/WORK/KM/yocto/build}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:?}"; shift 2 ;;
    --date) DATE="${2:?}"; shift 2 ;;
    --latest) LATEST=1; shift ;;
    --collect-root|--collected-root|-collected-root)
      COLLECT_ROOT="${2:?}"; shift 2
      ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

[[ -n "$DEST" ]] || die "--dest is required"
DEST="${DEST%/}"
[[ -d "$DEST" ]] || die "--dest must be an existing directory (local or NFS mount): $DEST"
[[ -w "$DEST" ]] || die "--dest is not writable: $DEST"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "bad --date: $DATE"

[[ -z "$COLLECT_ROOT" ]] && COLLECT_ROOT="$YOCTO_BUILD/collected-binaries"
COLLECT_ROOT="${COLLECT_ROOT%/}"

publish_one() {
  local flavor="$1"  # emul | osbv_sdmmc
  local src="$COLLECT_ROOT/$flavor"
  local dst="$DEST/$DATE/$flavor"
  [[ -d "$src" ]] || die "collect dir missing: $src (run collect-km-artifacts.sh first)"
  [[ -f "$src/collected-files.txt" ]] || die "missing $src/collected-files.txt"

  mkdir -p "$dst"
  find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  info "publish $flavor → $dst"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ -e "$src/$name" ]] || die "listed in collected-files.txt but missing: $src/$name"
    # Prefer hardlink within same FS when possible for large WIC
    if ln "$src/$name" "$dst/$name" 2>/dev/null; then
      info "  + $name (hardlink)"
    else
      cp -aL "$src/$name" "$dst/$name"
      info "  + $name ($(du -h "$dst/$name" | awk '{print $1}'))"
    fi
  done < "$src/collected-files.txt"

  # Always ship inventory + checksums if present
  cp -aL "$src/collected-files.txt" "$dst/collected-files.txt"
  [[ -f "$src/SHA256SUMS" ]] && cp -aL "$src/SHA256SUMS" "$dst/SHA256SUMS"
}

write_drop_manifest() {
  local drop="$DEST/$DATE"
  local mf="$drop/MANIFEST.txt"
  local git_rev="unknown"
  if git -C "$FRAMEWORK" rev-parse --short HEAD >/dev/null 2>&1; then
    git_rev="$(git -C "$FRAMEWORK" rev-parse --short HEAD)"
  fi
  {
    echo "date: $DATE"
    echo "host: $(hostname -f 2>/dev/null || hostname)"
    echo "published: $(date -Is)"
    echo "framework_git: $git_rev"
    echo "collect_root: $COLLECT_ROOT"
    echo ""
    for sub in emul osbv_sdmmc; do
      [[ -d "$drop/$sub" ]] || continue
      echo "[$sub]"
      if [[ -f "$drop/$sub/SHA256SUMS" ]]; then
        sed "s|^|$sub/|" "$drop/$sub/SHA256SUMS"
      elif [[ -f "$drop/$sub/collected-files.txt" ]]; then
        while IFS= read -r n; do
          [[ -f "$drop/$sub/$n" ]] || continue
          (cd "$drop/$sub" && sha256sum "$n" | sed "s|^|$sub/|")
        done < "$drop/$sub/collected-files.txt"
      fi
      echo ""
    done
  } > "$mf"
  info "Wrote $mf"
}

case "$FLAVOR" in
  emul) publish_one emul ;;
  osbv|osbv_sdmmc) publish_one osbv_sdmmc ;;
  both)
    publish_one emul
    publish_one osbv_sdmmc
    ;;
  *) die "flavor must be emul, osbv_sdmmc, or both" ;;
esac

write_drop_manifest

if [[ "$LATEST" -eq 1 ]]; then
  ln -sfn "$DATE" "$DEST/latest"
  info "Updated $DEST/latest -> $DATE"
fi

info "Published → $DEST/$DATE"
