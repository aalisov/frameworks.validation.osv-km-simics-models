#!/usr/bin/env bash
# Stage latest osbv (or emul) from the HTTP share into ~/km-hps/images/.
# Records MANIFEST fingerprint only after a successful stage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

FLAVOR="${1:-$KM_CI_FLAVOR}"
case "$FLAVOR" in
  osbv|osbv_sdmmc) FLAVOR=osbv; LAST="$KM_CI_LAST_MANIFEST"; PENDING="${KM_CI_VAR}/pending-osbv-manifest.txt" ;;
  emul) LAST="${KM_CI_VAR}/last-emul-manifest.txt"; PENDING="${KM_CI_VAR}/pending-emul-manifest.txt" ;;
  *) echo "ERROR: flavor must be osbv or emul" >&2; exit 1 ;;
esac

STAGE="$KM_HPS/scripts/stage-artifact.sh"
[[ -x "$STAGE" ]] || { echo "ERROR: missing $STAGE" >&2; exit 1; }

echo "[stage-latest] $FLAVOR --from $SHARE_ROOT --date latest"
"$STAGE" "$FLAVOR" --from "$SHARE_ROOT" --date latest

# Prefer pending MANIFEST captured by poll; else re-fetch
if [[ -f "$PENDING" ]]; then
  cp -a "$PENDING" "$LAST"
  rm -f "$PENDING"
else
  curl -fsSL --connect-timeout 20 --max-time 120 \
    "${SHARE_ROOT%/}/latest/MANIFEST.txt" -o "$LAST"
fi

echo "[stage-latest] recorded fingerprint → $LAST"
if [[ -f "$LAST" ]]; then
  grep -E '^(date|published|host):' "$LAST" || true
fi
