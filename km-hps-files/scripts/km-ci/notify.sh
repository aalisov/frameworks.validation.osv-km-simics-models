#!/usr/bin/env bash
# KM CI notifications: Altera SMTP + optional KM_CI_NOTIFY_CMD hook.
# Args: status message...
# Status values: pass | fail | blocked | error | runs-up | runs-partial | runs-none | info
#
# Preferred: s-nail / Heirloom mailx with -S mta=...
#   echo body | mailx -S mta="smtp://smtp.altera.com:587" -s "Subject" to@addr
# Fallback: python3 smtplib (ghrdbld1 default mailx is bsd-mailx without -S).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

STATUS="${1:-info}"
shift || true
MSG="${*:-}"

echo "[notify] status=$STATUS $MSG" >&2

HOST_DISP="$(hostname -f 2>/dev/null || hostname)"
SUBJECT="${KM_CI_MAIL_SUBJECT_PREFIX} ${STATUS}: ${MSG}"
SUBJECT="$(printf '%s' "$SUBJECT" | tr '\n' ' ' | cut -c1-200)"

BODY="$(
  cat <<EOF
KM CI notification
==================
Status:  $STATUS
Host:    $HOST_DISP
When:    $(date -Iseconds)
Message: $MSG

Smoke overall: $(cat "${KM_CI_VAR}/last-gate-overall.txt" 2>/dev/null || echo n/a)
Summary:       $(cat "${KM_CI_VAR}/last-gate-summary.txt" 2>/dev/null || echo n/a)
Status URL:    ${KM_SIMICS_STATUS_URL:-}
Runs URL:      ${KM_SIMICS_RUNS_URL:-}
Long PIDs:     ${KM_CI_LONG_PIDS:-}
EOF
)"

# True if binary accepts -S (s-nail); false for bsd-mailx.
mailx_has_dash_S() {
  local bin="$1" out
  out="$("$bin" -S 2>&1 || true)"
  [[ "$out" != *"invalid option"* ]]
}

send_mail_mailx() {
  local bin="$1"
  set +e
  printf '%s\n' "$BODY" | "$bin" \
    -S "mta=${KM_CI_MAIL_MTA}" \
    ${KM_CI_MAIL_FROM:+-r "$KM_CI_MAIL_FROM"} \
    -s "$SUBJECT" \
    "$KM_CI_MAIL_TO" 2> >(grep -v -e 'Obsoletion warning' -e 'On URL syntax' >&2 || true)
  local rc=$?
  set -e
  return "$rc"
}

send_mail_python() {
  python3 - "$KM_CI_MAIL_MTA" "${KM_CI_MAIL_FROM:-}" "$KM_CI_MAIL_TO" "$SUBJECT" <<'PY'
import smtplib, ssl, sys, re, socket
from email.message import EmailMessage

mta, frm, to, subject = sys.argv[1:5]
body = sys.stdin.read()
m = re.match(r"^smtp://([^:/]+):?(\d+)?$", mta.strip(), re.I)
if not m:
    print(f"[notify] bad MTA URL: {mta!r}", file=sys.stderr)
    sys.exit(2)
host, port = m.group(1), int(m.group(2) or 587)
if not frm:
    frm = f"km-ci@{socket.gethostname()}"
msg = EmailMessage()
msg["From"] = frm
msg["To"] = to
msg["Subject"] = subject
msg.set_content(body)
# Internal relay often uses a corp CA not in the host trust store.
ctx = ssl.create_default_context()
try:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
except Exception:
    ctx = ssl._create_unverified_context()
with smtplib.SMTP(host, port, timeout=60) as s:
    s.ehlo()
    if s.has_extn("starttls"):
        s.starttls(context=ctx)
        s.ehlo()
    s.send_message(msg)
print(f"[notify] mailed to {to} via python smtp {host}:{port}", file=sys.stderr)
PY
}

if [[ "${KM_CI_MAIL_ENABLE:-1}" == "1" && -n "${KM_CI_MAIL_TO:-}" ]]; then
  sent=0
  for cand in "${KM_CI_MAILX:-}" s-nail mailx; do
    [[ -z "$cand" ]] && continue
    command -v "$cand" >/dev/null 2>&1 || continue
    mailx_has_dash_S "$cand" || continue
    if send_mail_mailx "$cand"; then
      echo "[notify] mailed to $KM_CI_MAIL_TO via $cand mta=$KM_CI_MAIL_MTA" >&2
      sent=1
      break
    fi
    echo "[notify] WARN: $cand send failed — trying next" >&2
  done
  if [[ $sent -eq 0 ]]; then
    if printf '%s\n' "$BODY" | send_mail_python; then
      sent=1
    else
      echo "[notify] WARN: python SMTP send failed" >&2
    fi
  fi
fi

if [[ -n "${KM_CI_NOTIFY_CMD:-}" ]]; then
  # shellcheck disable=SC2086
  eval "$KM_CI_NOTIFY_CMD" "$STATUS" "$MSG" || true
fi
exit 0
