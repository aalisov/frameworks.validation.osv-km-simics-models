#!/usr/bin/env bash
# Fetch a published KM artifact drop via local/NFS path or HTTP.
#
#   ./scripts/fetch-km-artifacts.sh osbv \
#     --from http://alisubun1.sj.altera.com/share/KM --date latest
#   ./scripts/fetch-km-artifacts.sh emul \
#     --from /var/www/html/share/KM --date 2026-08-21
#
# Prints the local cache directory on the last line: FETCHED=<path>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*" >&2; }

usage() {
  cat <<EOF
Usage: $0 {emul|osbv|osbv_sdmmc} --from URL_OR_PATH [--date DATE|latest] [--out DIR]

  --from   Share root: http(s)://host/share/KM  or  /mnt/share/KM
  --date   YYYY-MM-DD or latest (default: latest)
  --out    Cache root (default: \$KM_ARTIFACT_CACHE or \$HOME/km-hps/cache/KM)
EOF
  exit 1
}

FLAVOR="${1:-}"
[[ -n "$FLAVOR" ]] || usage
shift || true

FROM=""
DATE="latest"
OUT_ROOT="${KM_ARTIFACT_CACHE:-$HOME/km-hps/cache/KM}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:?}"; shift 2 ;;
    --date) DATE="${2:?}"; shift 2 ;;
    --out) OUT_ROOT="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$FROM" ]] || die "--from is required"

case "$FLAVOR" in
  emul) SUB=emul ;;
  osbv|osbv_sdmmc) SUB=osbv_sdmmc ;;
  *) die "flavor must be emul or osbv" ;;
esac

FROM="${FROM%/}"

is_http() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_date() {
  local base="$1" want="$2"
  if [[ "$want" != "latest" ]]; then
    echo "$want"
    return 0
  fi
  if is_http "$base"; then
    # Follow redirect or parse latest symlink listing — try HEAD on latest/
    if command -v curl >/dev/null 2>&1; then
      local loc
      loc="$(curl -sI -L --max-redirs 0 "$base/latest/" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="location:"{print $2; exit}')" || true
      if [[ -n "$loc" ]]; then
        # Location may be absolute or relative ending in DATE/
        basename "${loc%/}"
        return 0
      fi
    fi
    # Fallback: download latest/collected listing via curl of parent HTML is fragile —
    # require explicit date if latest cannot be resolved over HTTP without following.
    # Try fetching $base/latest/ as if it were a directory (Apache may serve it).
    echo "latest"
    return 0
  else
    if [[ -L "$base/latest" ]]; then
      basename "$(readlink -f "$base/latest")"
      return 0
    fi
    [[ -d "$base/latest" ]] && { echo "latest"; return 0; }
    die "no latest symlink under $base"
  fi
}

RESOLVED_DATE="$(resolve_date "$FROM" "$DATE")"
REMOTE_SUB="$FROM/$RESOLVED_DATE/$SUB"
OUT_DIR="$OUT_ROOT/$RESOLVED_DATE/$SUB"
mkdir -p "$OUT_DIR"

info "fetch $SUB"
info "  from = $REMOTE_SUB"
info "  out  = $OUT_DIR"

if is_http "$FROM"; then
  command -v curl >/dev/null 2>&1 || die "curl required for HTTP fetch"
  # Prefer collected-files.txt inventory
  local_list="$OUT_DIR/.fetch-list.txt"
  if ! curl -fsSL "$REMOTE_SUB/collected-files.txt" -o "$local_list"; then
    die "cannot download $REMOTE_SUB/collected-files.txt"
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    info "  get $name"
    mkdir -p "$OUT_DIR/$(dirname "$name")"
    curl -fsSL "$REMOTE_SUB/$name" -o "$OUT_DIR/$name" \
      || die "download failed: $REMOTE_SUB/$name"
  done < "$local_list"
  cp -a "$local_list" "$OUT_DIR/collected-files.txt"
  rm -f "$local_list"
  curl -fsSL "$REMOTE_SUB/SHA256SUMS" -o "$OUT_DIR/SHA256SUMS" 2>/dev/null || true
else
  [[ -d "$REMOTE_SUB" ]] || die "path missing: $REMOTE_SUB"
  # Clear dest then copy
  find "$OUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  if [[ -f "$REMOTE_SUB/collected-files.txt" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      [[ -e "$REMOTE_SUB/$name" ]] || die "missing $REMOTE_SUB/$name"
      mkdir -p "$OUT_DIR/$(dirname "$name")"
      cp -aL "$REMOTE_SUB/$name" "$OUT_DIR/$name"
      info "  + $name"
    done < "$REMOTE_SUB/collected-files.txt"
    cp -aL "$REMOTE_SUB/collected-files.txt" "$OUT_DIR/collected-files.txt"
    [[ -f "$REMOTE_SUB/SHA256SUMS" ]] && cp -aL "$REMOTE_SUB/SHA256SUMS" "$OUT_DIR/SHA256SUMS"
  else
    cp -aL "$REMOTE_SUB"/. "$OUT_DIR"/
  fi
fi

if [[ -f "$OUT_DIR/SHA256SUMS" ]]; then
  info "Verifying SHA256SUMS..."
  (cd "$OUT_DIR" && sha256sum -c SHA256SUMS) >&2 || die "checksum mismatch"
fi

info "Fetched → $OUT_DIR"
# Machine-readable for stage-artifact.sh
echo "FETCHED=$OUT_DIR"
