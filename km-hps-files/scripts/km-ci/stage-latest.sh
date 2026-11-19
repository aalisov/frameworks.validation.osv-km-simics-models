#!/usr/bin/env bash
# Stage latest osbv (or emul) from the HTTP share into ~/km-hps/images/.
# Records drop fingerprint only after a successful stage.
#
# Fingerprint sources (in order):
#   1) pending manifest from poll-share.sh
#   2) legacy latest/MANIFEST.txt
#   3) synthetic from latest/<flavor>/SHA256SUMS (+ SOURCES.txt)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

FLAVOR="${1:-$KM_CI_FLAVOR}"
case "$FLAVOR" in
  osbv|osbv_sdmmc) FLAVOR=osbv; LAST="$KM_CI_LAST_MANIFEST"; PENDING="${KM_CI_VAR}/pending-osbv-manifest.txt"; SECTION=osbv_sdmmc ;;
  emul) LAST="${KM_CI_VAR}/last-emul-manifest.txt"; PENDING="${KM_CI_VAR}/pending-emul-manifest.txt"; SECTION=emul ;;
  *) echo "ERROR: flavor must be osbv or emul" >&2; exit 1 ;;
esac

STAGE="$KM_HPS/scripts/stage-artifact.sh"
[[ -x "$STAGE" ]] || { echo "ERROR: missing $STAGE" >&2; exit 1; }

echo "[stage-latest] $FLAVOR --from $SHARE_ROOT --date latest"
"$STAGE" "$FLAVOR" --from "$SHARE_ROOT" --date latest

record_fingerprint() {
  if [[ -f "$PENDING" ]]; then
    cp -a "$PENDING" "$LAST"
    rm -f "$PENDING"
    return 0
  fi
  local share="${SHARE_ROOT%/}"
  if curl -fsSL --connect-timeout 20 --max-time 120 \
      "${share}/latest/MANIFEST.txt" -o "$LAST" 2>/dev/null; then
    return 0
  fi
  # Synthesize from SHA256SUMS (same shape as poll-share.sh)
  local sums sources date_str published host
  sums="$(mktemp)"
  sources="$(mktemp)"
  trap 'rm -f "$sums" "$sources"' RETURN
  curl -fsSL --connect-timeout 20 --max-time 120 \
    "${share}/latest/${SECTION}/SHA256SUMS" -o "$sums"
  curl -fsSL --connect-timeout 20 --max-time 60 \
    "${share}/latest/${SECTION}/SOURCES.txt" -o "$sources" 2>/dev/null || : >"$sources"
  host="$(echo "$share" | sed -n 's#https\?://\([^/]*\).*#\1#p')"
  : "${host:=alisubun1}"
  published="$(awk -F= '/^# collected_at=/{print $2; exit}' "$sources" || true)"
  : "${published:=unknown}"
  date_str="${published%%T*}"
  : "${date_str:=unknown}"
  {
    echo "date: $date_str"
    echo "host: $host"
    echo "published: $published"
    echo "source: latest/${SECTION}/SHA256SUMS"
    echo
    echo "[${SECTION}]"
    while read -r hash name; do
      [[ -z "${hash:-}" || "$hash" =~ ^# ]] && continue
      [[ -z "${name:-}" ]] && continue
      echo "${SECTION}/${hash}  ${name}"
    done <"$sums"
  } >"$LAST"
}

record_fingerprint

echo "[stage-latest] recorded fingerprint → $LAST"
if [[ -f "$LAST" ]]; then
  grep -E '^(date|published|host|source):' "$LAST" || true
fi
