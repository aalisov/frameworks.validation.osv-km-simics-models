#!/usr/bin/env bash
# Fetch latest MANIFEST from the KM HTTP share and compare to last fingerprint.
#
# Exit codes:
#   0  — new / changed MANIFEST (or KM_CI_FORCE=1)
#  10  — unchanged
#   2  — fetch / usage error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

usage() {
  cat <<EOF
Usage: $0 [--flavor osbv|emul] [--print]

  Fetch \$SHARE_ROOT/latest/MANIFEST.txt and compare to the last staged
  fingerprint under \$KM_CI_VAR.

  Exit 0  if new (or KM_CI_FORCE=1)
  Exit 10 if unchanged
  Exit 2  on error

  --print   write remote MANIFEST to stdout (still sets exit code)
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
    ;;
  emul)
    LAST="${KM_CI_VAR}/last-emul-manifest.txt"
    ;;
  *)
    echo "ERROR: flavor must be osbv or emul (got $FLAVOR)" >&2
    exit 2
    ;;
esac

MANIFEST_URL="${SHARE_ROOT%/}/latest/MANIFEST.txt"
TMP="$(mktemp "${TMPDIR:-/tmp}/km-ci-manifest.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

if ! curl -fsSL --connect-timeout 20 --max-time 120 "$MANIFEST_URL" -o "$TMP"; then
  echo "ERROR: failed to fetch $MANIFEST_URL" >&2
  exit 2
fi

# Fingerprint: published line + all sha lines for this flavor section
fingerprint() {
  local f="$1" section
  case "$FLAVOR" in
    osbv) section="osbv_sdmmc" ;;
    emul) section="emul" ;;
  esac
  {
    grep -E '^published:' "$f" || true
    awk -v sec="[$section]" '
      $0 == sec { insec=1; next }
      /^\[/ { insec=0 }
      insec && NF { print }
    ' "$f"
  } | sha256sum | awk '{print $1}'
}

NEW_FP="$(fingerprint "$TMP")"
OLD_FP=""
if [[ -f "$LAST" ]]; then
  OLD_FP="$(fingerprint "$LAST" 2>/dev/null || true)"
fi

PUBLISHED="$(grep -E '^published:' "$TMP" | head -1 || echo "published: unknown")"
DATE_LINE="$(grep -E '^date:' "$TMP" | head -1 || echo "date: unknown")"

if [[ $DO_PRINT -eq 1 ]]; then
  cat "$TMP"
fi

if [[ "${KM_CI_FORCE:-0}" == "1" ]]; then
  echo "poll: FORCE=1 — treat as new ($DATE_LINE $PUBLISHED fp=$NEW_FP)"
  cp -a "$TMP" "${KM_CI_VAR}/pending-${FLAVOR}-manifest.txt"
  exit 0
fi

if [[ -n "$OLD_FP" && "$OLD_FP" == "$NEW_FP" ]]; then
  echo "poll: unchanged ($DATE_LINE $PUBLISHED fp=$NEW_FP)"
  exit 10
fi

echo "poll: NEW ($DATE_LINE $PUBLISHED fp=$NEW_FP prev=${OLD_FP:-none})"
cp -a "$TMP" "${KM_CI_VAR}/pending-${FLAVOR}-manifest.txt"
exit 0
