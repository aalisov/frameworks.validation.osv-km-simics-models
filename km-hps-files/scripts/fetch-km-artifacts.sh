#!/usr/bin/env bash
# Fetch a published KM artifact drop via local/NFS path or HTTP.
#
# Share layout:  $ROOT/YYYY-MM-DD/{emul|osbv_sdmmc}/collected-files.txt
#
#   # share root + date
#   ./scripts/fetch-km-artifacts.sh osbv \
#     --from http://alisubun1.sj.altera.com/osbv-yo/KM --date 2026-11-12
#   # share root + latest (newest YYYY-MM-DD that has this flavor)
#   ./scripts/fetch-km-artifacts.sh osbv \
#     --from http://alisubun1.sj.altera.com/osbv-yo/KM --date latest
#   # direct drop (date+flavor already in URL — --date ignored)
#   ./scripts/fetch-km-artifacts.sh osbv \
#     --from http://alisubun1.sj.altera.com/osbv-yo/KM/2026-11-12/osbv_sdmmc/
#
# Prints the local cache directory on the last line: FETCHED=<path>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*" >&2; }

usage() {
  cat <<EOF
Usage: $0 {emul|osbv|osbv_sdmmc} --from URL_OR_PATH [--date DATE|latest] [--out DIR]

  --from   Share root, date dir, or direct drop:
             http://host/osbv-yo/KM
             http://host/osbv-yo/KM/2026-11-12
             http://host/osbv-yo/KM/2026-11-12/osbv_sdmmc
           (or local/NFS equivalent)
  --date   YYYY-MM-DD or latest (default: latest). Ignored if --from is a direct drop.
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

http_ok() {
  local url="$1" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 -L "$url" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

# Parse Apache/nginx autoindex HTML for YYYY-MM-DD/ entries (newest first).
list_http_dates() {
  local base="$1"
  curl -fsSL --connect-timeout 5 --max-time 30 "$base/" 2>/dev/null \
    | grep -oE 'href="[0-9]{4}-[0-9]{2}-[0-9]{2}/?"' \
    | sed -E 's/href="//;s|/?"$||' \
    | sort -ru
}

resolve_latest_date() {
  local base="$1"
  local d loc

  if is_http "$base"; then
    # Prefer real latest/ symlink redirect if present.
    if command -v curl >/dev/null 2>&1; then
      loc="$(curl -sI -L --max-redirs 0 "$base/latest/" 2>/dev/null \
        | tr -d '\r' | awk 'tolower($1)=="location:"{print $2; exit}')" || true
      if [[ -n "$loc" ]]; then
        d="$(basename "${loc%/}")"
        if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
          echo "$d"
          return 0
        fi
      fi
      if http_ok "$base/latest/$SUB/collected-files.txt"; then
        echo "latest"
        return 0
      fi
    fi
    # No latest/ on share — pick newest dated drop that has this flavor.
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      if http_ok "$base/$d/$SUB/collected-files.txt"; then
        echo "$d"
        return 0
      fi
    done < <(list_http_dates "$base")
    die "no dated $SUB drop under $base (no latest/ and no YYYY-MM-DD/$SUB)"
  fi

  if [[ -L "$base/latest" ]]; then
    basename "$(readlink -f "$base/latest")"
    return 0
  fi
  if [[ -d "$base/latest/$SUB" ]]; then
    echo "latest"
    return 0
  fi
  # Local: newest dated directory with flavor
  while IFS= read -r d; do
    [[ -d "$base/$d/$SUB" ]] || continue
    echo "$d"
    return 0
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
            | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -ru)
  die "no latest symlink / dated $SUB under $base"
}

# Classify --from:
#   direct  → already .../DATE/SUB  (or .../latest/SUB)
#   dated   → .../DATE              (append /SUB)
#   root    → share root            (append /DATE/SUB)
classify_from() {
  local base="$1"
  local leaf parent_leaf
  leaf="$(basename "$base")"
  parent_leaf="$(basename "$(dirname "$base")")"

  if [[ "$leaf" == "$SUB" || "$leaf" == "emul" || "$leaf" == "osbv_sdmmc" ]]; then
    # If user pointed at wrong flavor leaf, still treat as direct but warn.
    if [[ "$leaf" != "$SUB" ]]; then
      die "--from ends in '$leaf' but flavor wants '$SUB'"
    fi
    echo "direct"
    return 0
  fi
  if [[ "$leaf" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ || "$leaf" == "latest" ]]; then
    echo "dated"
    return 0
  fi
  echo "root"
}

FROM_KIND="$(classify_from "$FROM")"
REMOTE_SUB=""
RESOLVED_DATE=""

case "$FROM_KIND" in
  direct)
    REMOTE_SUB="$FROM"
    RESOLVED_DATE="$(basename "$(dirname "$FROM")")"
    if [[ "$DATE" != "latest" && "$DATE" != "$RESOLVED_DATE" ]]; then
      info "NOTE: --from is a direct drop ($RESOLVED_DATE); ignoring --date=$DATE"
    fi
    ;;
  dated)
    RESOLVED_DATE="$(basename "$FROM")"
    if [[ "$DATE" != "latest" && "$DATE" != "$RESOLVED_DATE" ]]; then
      info "NOTE: --from already has date $RESOLVED_DATE; ignoring --date=$DATE"
    fi
    REMOTE_SUB="$FROM/$SUB"
    ;;
  root)
    if [[ "$DATE" == "latest" ]]; then
      RESOLVED_DATE="$(resolve_latest_date "$FROM")"
    else
      [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "bad --date: $DATE"
      RESOLVED_DATE="$DATE"
    fi
    REMOTE_SUB="$FROM/$RESOLVED_DATE/$SUB"
    ;;
esac

OUT_DIR="$OUT_ROOT/$RESOLVED_DATE/$SUB"
mkdir -p "$OUT_DIR"

info "fetch $SUB"
info "  from = $REMOTE_SUB"
info "  out  = $OUT_DIR"

if is_http "$FROM"; then
  command -v curl >/dev/null 2>&1 || die "curl required for HTTP fetch"
  local_list="$OUT_DIR/.fetch-list.txt"
  if ! curl -fsSL "$REMOTE_SUB/collected-files.txt" -o "$local_list"; then
    die "cannot download $REMOTE_SUB/collected-files.txt
hint: use share root + --date, e.g.
  --from http://alisubun1.sj.altera.com/osbv-yo/KM --date 2026-11-12
or a direct drop URL ending in /$SUB/"
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
