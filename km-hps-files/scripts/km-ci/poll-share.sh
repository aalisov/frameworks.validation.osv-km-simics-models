#!/usr/bin/env bash
# Fetch latest drop fingerprint from the KM HTTP share and compare to last.
#
# Prefers legacy \$SHARE_ROOT/latest/MANIFEST.txt when present.
# New publishes omit MANIFEST — fingerprint from latest/<flavor>/SHA256SUMS
# (+ SOURCES.txt header) instead.
#
# Exit codes:
#   0  — new / changed (or KM_CI_FORCE=1)
#  10  — unchanged
#   2  — fetch / usage error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

usage() {
  cat <<EOF
Usage: $0 [--flavor osbv|emul] [--print]

  Exit 0  if new (or KM_CI_FORCE=1)
  Exit 10 if unchanged
  Exit 2  on error
EOF
  exit 2
}

FLAVOR="$KM_CI_FLAVOR"
DO_PRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavor) FLAVOR="${2:?}"; shift 2 ;;
    --print) DO_PRINT=1; shift ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage ;;
  esac
done

case "$FLAVOR" in
  osbv|osbv_sdmmc)
    FLAVOR=osbv
    LAST="$KM_CI_LAST_MANIFEST"
    SECTION="osbv_sdmmc"
    ;;
  emul)
    LAST="${KM_CI_VAR}/last-emul-manifest.txt"
    SECTION="emul"
    ;;
  *)
    echo "ERROR: flavor must be osbv or emul (got $FLAVOR)" >&2
    exit 2
    ;;
esac

SHARE="${SHARE_ROOT%/}"
MANIFEST_URL="${SHARE}/latest/MANIFEST.txt"
SUMS_URL="${SHARE}/latest/${SECTION}/SHA256SUMS"
SOURCES_URL="${SHARE}/latest/${SECTION}/SOURCES.txt"

TMP="$(mktemp "${TMPDIR:-/tmp}/km-ci-manifest.XXXXXX")"
SUMS_TMP="$(mktemp "${TMPDIR:-/tmp}/km-ci-sums.XXXXXX")"
SRC_TMP="$(mktemp "${TMPDIR:-/tmp}/km-ci-src.XXXXXX")"
trap 'rm -f "$TMP" "$SUMS_TMP" "$SRC_TMP"' EXIT

fetch_ok() {
  local url="$1" out="$2"
  curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$out"
}

# Build a MANIFEST-shaped text file into $TMP for fingerprint + stage record.
build_from_sums() {
  local date_str published host
  host="$(echo "$SHARE" | sed -n 's#https\?://\([^/]*\).*#\1#p')"
  : "${host:=alisubun1}"

  published="unknown"
  date_str="unknown"
  if [[ -s "$SRC_TMP" ]]; then
    # # collected_at=2026-11-17T22:33:02Z
    published="$(awk -F= '/^# collected_at=/{print $2; exit}' "$SRC_TMP" || true)"
    if [[ -n "$published" && "$published" != "unknown" ]]; then
      date_str="${published%%T*}"
    fi
  fi
  if [[ "$date_str" == "unknown" ]]; then
    # Newest YYYY-MM-DD directory on the share index
    date_str="$(
      curl -fsSL --connect-timeout 20 --max-time 60 "${SHARE}/" 2>/dev/null \
        | grep -oE 'href="[0-9]{4}-[0-9]{2}-[0-9]{2}/"' \
        | sed 's/href="//;s/\/"//' \
        | sort -u | tail -1 || true
    )"
    : "${date_str:=unknown}"
    published="${date_str}T00:00:00Z"
  fi

  {
    echo "date: $date_str"
    echo "host: $host"
    echo "published: $published"
    echo "source: latest/${SECTION}/SHA256SUMS"
    echo
    echo "[${SECTION}]"
    # Prefix paths like legacy MANIFEST lines: section/hash  name
    while read -r hash name; do
      [[ -z "${hash:-}" || "$hash" =~ ^# ]] && continue
      [[ -z "${name:-}" ]] && continue
      echo "${SECTION}/${hash}  ${name}"
    done <"$SUMS_TMP"
    if [[ -s "$SRC_TMP" ]]; then
      echo
      echo "[sources]"
      cat "$SRC_TMP"
    fi
  } >"$TMP"
}

MODE=""
if fetch_ok "$MANIFEST_URL" "$TMP" 2>/dev/null; then
  MODE=manifest
  echo "poll: using MANIFEST.txt"
elif fetch_ok "$SUMS_URL" "$SUMS_TMP"; then
  MODE=sha256sums
  echo "poll: MANIFEST.txt missing — using ${SECTION}/SHA256SUMS"
  fetch_ok "$SOURCES_URL" "$SRC_TMP" 2>/dev/null || : >"$SRC_TMP"
  build_from_sums
else
  echo "ERROR: failed to fetch $MANIFEST_URL and $SUMS_URL" >&2
  exit 2
fi

fingerprint() {
  local f="$1"
  case "$MODE" in
    sha256sums)
      # Stable: date/published + sha lines for this section
      {
        grep -E '^(date|published|source):' "$f" || true
        awk -v sec="[$SECTION]" '
          $0 == sec { insec=1; next }
          /^\[/ { insec=0 }
          insec && NF { print }
        ' "$f"
      } | sha256sum | awk '{print $1}'
      ;;
    *)
      {
        grep -E '^published:' "$f" || true
        awk -v sec="[$SECTION]" '
          $0 == sec { insec=1; next }
          /^\[/ { insec=0 }
          insec && NF { print }
        ' "$f"
      } | sha256sum | awk '{print $1}'
      ;;
  esac
}

NEW_FP="$(fingerprint "$TMP")"
OLD_FP=""
if [[ -f "$LAST" ]]; then
  # Recompute with current MODE semantics when possible
  OLD_FP="$(fingerprint "$LAST" 2>/dev/null || true)"
fi

PUBLISHED="$(grep -E '^published:' "$TMP" | head -1 || echo "published: unknown")"
DATE_LINE="$(grep -E '^date:' "$TMP" | head -1 || echo "date: unknown")"

if [[ $DO_PRINT -eq 1 ]]; then
  cat "$TMP"
fi

if [[ "${KM_CI_FORCE:-0}" == "1" ]]; then
  echo "poll: FORCE=1 — treat as new ($DATE_LINE $PUBLISHED fp=$NEW_FP mode=$MODE)"
  cp -a "$TMP" "${KM_CI_VAR}/pending-${FLAVOR}-manifest.txt"
  exit 0
fi

if [[ -n "$OLD_FP" && "$OLD_FP" == "$NEW_FP" ]]; then
  echo "poll: unchanged ($DATE_LINE $PUBLISHED fp=$NEW_FP mode=$MODE)"
  exit 10
fi

echo "poll: NEW ($DATE_LINE $PUBLISHED fp=$NEW_FP prev=${OLD_FP:-none} mode=$MODE)"
cp -a "$TMP" "${KM_CI_VAR}/pending-${FLAVOR}-manifest.txt"
exit 0
