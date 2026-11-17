#!/usr/bin/env bash
# Notification stub for KM CI agent (Slack/email later).
# Args: status message...
set -euo pipefail
STATUS="${1:-info}"
shift || true
MSG="${*:-}"
echo "[notify] status=$STATUS $MSG" >&2
# Hook: set KM_CI_NOTIFY_CMD to a custom notifier, e.g.
#   export KM_CI_NOTIFY_CMD='curl -X POST ...'
if [[ -n "${KM_CI_NOTIFY_CMD:-}" ]]; then
  # shellcheck disable=SC2086
  eval "$KM_CI_NOTIFY_CMD" "$STATUS" "$MSG" || true
fi
exit 0
