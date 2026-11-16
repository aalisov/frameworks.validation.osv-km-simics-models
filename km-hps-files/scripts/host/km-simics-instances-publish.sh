#!/usr/bin/env bash
# Publish live KM Simics instance table as HTML + JSON for Apache under KM/simics-runs.
#
# Layout on alisubun1 (NFS webdata):
#   /DISK1/nfs/webdata/osbv-yo/KM/simics-runs/   ← this script (live sessions)
#   /DISK1/nfs/webdata/osbv-yo/KM/simics-status/ ← gate smoke results (km-ci/publish-gate-status.sh)
#
# On ghrdbld1 (Simics host):
#   ./scripts/host/km-simics-instances-publish.sh
#   # writes ~/km-hps/var/simics-runs/{index.html,instances.json,instances.txt}
#
# Push to Apache (NFS mount or remote):
#   KM_SIMICS_RUNS_DEST=/DISK1/nfs/webdata/osbv-yo/KM/simics-runs \
#     ./scripts/host/km-simics-instances-publish.sh --publish
#
#   KM_SIMICS_RUNS_DEST='alisov@alisubun1:/DISK1/nfs/webdata/osbv-yo/KM/simics-runs' \
#   KM_SIMICS_RUNS_URL='http://alisubun1.sj.altera.com/osbv-yo/KM/simics-runs/' \
#     ./scripts/host/km-simics-instances-publish.sh --publish
#
# Cron / after long-sims:
#   */5 * * * *  KM_SIMICS_RUNS_DEST=... $HOME/km-hps/scripts/host/km-simics-instances-publish.sh --publish
#
# Env:
#   KM_SIMICS_RUNS_OUT   local work dir (default: $KM_HPS/var/simics-runs)
#   KM_SIMICS_RUNS_DEST  rsync/scp/cp target dir (required for --publish)
#   KM_SIMICS_RUNS_URL   optional public URL printed in the page footer
#   KM_SIMICS_RUNS_HOST  display hostname (default: fqdn)
#   KM_SIMICS_RUNS_LAN   LAN IP shown in ssh hints (default: default-route IPv4)
# Legacy aliases: KM_SIMICS_STATUS_{OUT,DEST,URL,HOST,LAN}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/host/km-simics-instances.sh"

OUT="${KM_SIMICS_RUNS_OUT:-${KM_SIMICS_STATUS_OUT:-$ROOT/var/simics-runs}}"
DEST="${KM_SIMICS_RUNS_DEST:-${KM_SIMICS_STATUS_DEST:-}}"
URL="${KM_SIMICS_RUNS_URL:-${KM_SIMICS_STATUS_URL:-http://alisubun1.sj.altera.com/osbv-yo/KM/simics-runs/}}"
HOST_DISP="${KM_SIMICS_RUNS_HOST:-${KM_SIMICS_STATUS_HOST:-$(hostname -f 2>/dev/null || hostname)}}"
DO_PUBLISH=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) DO_PUBLISH=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --dest) DEST="${2:?}"; shift 2 ;;
    --url) URL="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

lan_ip() {
  if [[ -n "${KM_SIMICS_RUNS_LAN:-${KM_SIMICS_STATUS_LAN:-}}" ]]; then
    echo "${KM_SIMICS_RUNS_LAN:-$KM_SIMICS_STATUS_LAN}"
    return
  fi
  local ifc
  ifc="$(ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
  if [[ -n "$ifc" ]]; then
    ip -4 -o addr show dev "$ifc" 2>/dev/null \
      | awk '{print $4}' | head -1 | cut -d/ -f1
  fi
}

LAN="$(lan_ip)"
: "${LAN:=<host-LAN-IP>}"
NOW="$(date -Iseconds)"

mkdir -p "$OUT"
km_simics_prune

JSON="$OUT/instances.json"
HTML="$OUT/index.html"
TXT="$OUT/instances.txt"

# Collect rows into a temp file: inst|pid|ssh|telnet|bind|lan|started|label
ROWS="$(mktemp)"
trap 'rm -f "$ROWS"' EXIT

if [[ -d "$KM_SIMICS_REG_DIR" ]]; then
  for f in "$KM_SIMICS_REG_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
    bind="${HOST_BIND_IP:-0.0.0.0}"
    hint="${HOST_LAN_HINT:-$bind}"
    if [[ "$hint" == "0.0.0.0" || -z "$hint" ]]; then
      hint="$LAN"
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "${SIMICS_INSTANCE}" "${PID}" "${HOST_SSH_PORT}" "${TELNET_PORT}" \
      "$bind" "$hint" "${STARTED:-}" "${LABEL:-}" >>"$ROWS"
  done
fi

# --- plain text (same shape as km-simics-instances.sh status) ---
{
  printf "%-8s %-8s %-8s %-8s %-16s %-16s %-20s %s\n" \
    "INSTANCE" "PID" "SSH" "TELNET" "BIND_IP" "LAN_HINT" "STARTED" "LABEL"
  if [[ -s "$ROWS" ]]; then
    sort -t'|' -k1,1n "$ROWS" | while IFS='|' read -r inst pid ssh tel bind hint started label; do
      printf "%-8s %-8s %-8s %-8s %-16s %-16s %-20s %s\n" \
        "$inst" "$pid" "$ssh" "$tel" "$bind" "$hint" "$started" "$label"
    done
  else
    echo "(no live instances)"
  fi
  echo
  echo "host=$HOST_DISP  lan=$LAN  updated=$NOW"
} >"$TXT"

# --- JSON ---
python3 - "$JSON" "$HOST_DISP" "$LAN" "$NOW" "$ROWS" <<'PY'
import json, sys
from pathlib import Path
out, host, lan, now, rows_path = sys.argv[1:6]
instances = []
text = Path(rows_path).read_text(encoding="utf-8") if Path(rows_path).is_file() else ""
for line in text.splitlines():
    if not line.strip():
        continue
    inst, pid, ssh, tel, bind, hint, started, label = line.split("|", 7)
    instances.append({
        "instance": int(inst) if inst.isdigit() else inst,
        "pid": int(pid) if pid.isdigit() else pid,
        "ssh_port": int(ssh) if str(ssh).isdigit() else ssh,
        "telnet_port": int(tel) if str(tel).isdigit() else tel,
        "bind_ip": bind,
        "lan_hint": hint,
        "started": started,
        "label": label,
        "ssh": f"ssh -p {ssh} root@{hint}",
        "telnet_local": f"telnet 127.0.0.1 {tel}",
    })
doc = {
    "host": host,
    "lan_ip": lan,
    "updated": now,
    "instances": instances,
}
Path(out).write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY

# --- HTML ---
python3 - "$HTML" "$HOST_DISP" "$LAN" "$NOW" "$ROWS" "$URL" <<'PY'
import html, sys
from pathlib import Path
out, host, lan, now, rows_path, url = sys.argv[1:7]
rows = []
text = Path(rows_path).read_text(encoding="utf-8") if Path(rows_path).is_file() else ""
for line in text.splitlines():
    if not line.strip():
        continue
    rows.append(line.split("|", 7))

def esc(s):
    return html.escape(str(s))

body_rows = []
if not rows:
    body_rows.append('<tr><td colspan="8"><em>No live KM Simics instances</em></td></tr>')
else:
    for inst, pid, ssh, tel, bind, hint, started, label in sorted(rows, key=lambda r: int(r[0]) if r[0].isdigit() else r[0]):
        ssh_cmd = f"ssh -p {ssh} root@{hint}"
        body_rows.append(
            "<tr>"
            f"<td>{esc(inst)}</td><td>{esc(pid)}</td><td>{esc(ssh)}</td><td>{esc(tel)}</td>"
            f"<td>{esc(bind)}</td><td>{esc(hint)}</td><td>{esc(started)}</td><td>{esc(label)}</td>"
            "</tr>"
            f'<tr class="hint"><td colspan="8"><code>{esc(ssh_cmd)}</code>'
            f' &nbsp;|&nbsp; UART on sim host: <code>telnet 127.0.0.1 {esc(tel)}</code></td></tr>'
        )

url_line = f'<p>Public URL: <a href="{esc(url)}">{esc(url)}</a></p>' if url else ""
status_link = url.rstrip("/").rsplit("/", 1)[0] + "/simics-status/" if url else ""
status_line = (
    f'<p class="meta">Smoke results: <a href="{esc(status_link)}">{esc(status_link)}</a></p>'
    if status_link else ""
)
page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta http-equiv="refresh" content="60"/>
<title>KM Simics runs — {esc(host)}</title>
<style>
  body {{ font-family: ui-sans-serif, system-ui, sans-serif; margin: 2rem; background: #0f1419; color: #e7ecf1; }}
  h1 {{ font-size: 1.4rem; margin-bottom: 0.25rem; }}
  .meta {{ color: #9aa7b5; margin-bottom: 1.25rem; }}
  table {{ border-collapse: collapse; width: 100%; max-width: 1100px; }}
  th, td {{ border-bottom: 1px solid #2a3440; padding: 0.45rem 0.6rem; text-align: left; font-size: 0.95rem; }}
  th {{ color: #9aa7b5; font-weight: 600; }}
  tr.hint td {{ border-bottom: 1px solid #1a222b; color: #9aa7b5; font-size: 0.85rem; padding-top: 0; padding-bottom: 0.7rem; }}
  code {{ background: #1a222b; padding: 0.1rem 0.35rem; border-radius: 4px; }}
  a {{ color: #6cb6ff; }}
</style>
</head>
<body>
<h1>KM Simics runs</h1>
<p class="meta">Host <strong>{esc(host)}</strong> &middot; LAN <strong>{esc(lan)}</strong> &middot; Updated <strong>{esc(now)}</strong> &middot; auto-refresh 60s</p>
{url_line}
{status_line}
<table>
<thead>
<tr><th>Inst</th><th>PID</th><th>SSH</th><th>Telnet</th><th>Bind</th><th>LAN</th><th>Started</th><th>Label</th></tr>
</thead>
<tbody>
{''.join(body_rows)}
</tbody>
</table>
<p class="meta">Generated by <code>scripts/host/km-simics-instances-publish.sh</code> on the Simics host.</p>
</body>
</html>
"""
Path(out).write_text(page, encoding="utf-8")
PY

echo "Wrote:"
echo "  $HTML"
echo "  $JSON"
echo "  $TXT"

if [[ $DO_PUBLISH -eq 1 ]]; then
  [[ -n "$DEST" ]] || {
    echo "ERROR: --publish needs KM_SIMICS_RUNS_DEST or --dest (e.g. alisov@alisubun1:/DISK1/nfs/webdata/osbv-yo/KM/simics-runs)" >&2
    exit 1
  }
  case "$DEST" in
    *:*)
      if command -v rsync >/dev/null 2>&1; then
        rsync -az --delete "$OUT"/ "$DEST"/
      else
        scp -q "$HTML" "$JSON" "$TXT" "$DEST"/
      fi
      ;;
    *)
      mkdir -p "$DEST"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$OUT"/ "$DEST"/
      else
        cp -a "$HTML" "$JSON" "$TXT" "$DEST"/
      fi
      ;;
  esac
  echo "Published → $DEST"
  [[ -n "$URL" ]] && echo "URL: $URL"
fi
