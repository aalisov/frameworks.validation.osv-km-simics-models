#!/usr/bin/env bash
# Publish latest KM gate smoke SUMMARY to Apache under KM/simics-status.
#
#   /DISK1/nfs/webdata/osbv-yo/KM/simics-status/   ← this script
#   /DISK1/nfs/webdata/osbv-yo/KM/simics-runs/     ← live sessions (instances-publish)
#
# Usage:
#   ./scripts/km-ci/publish-gate-status.sh
#   KM_SIMICS_STATUS_DEST='alisov@alisubun1:/DISK1/nfs/webdata/osbv-yo/KM/simics-status' \
#     ./scripts/km-ci/publish-gate-status.sh --publish
#   KM_SIMICS_STATUS_GIT='alisov@alisubun1:git/km-simics-status.git' \
#     ./scripts/km-ci/publish-gate-status.sh --publish
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

OUT="${KM_SIMICS_STATUS_OUT:-$KM_HPS/var/simics-status}"
DEST="${KM_SIMICS_STATUS_DEST:-}"
GIT_REMOTE="${KM_SIMICS_STATUS_GIT:-${KM_SIMICS_WEB_GIT:-}}"
URL="${KM_SIMICS_STATUS_URL:-https://altera-sandbox.github.io/frameworks.validation.osv-auto.km-simics-web/simics-status/}"
HOST_DISP="$(hostname -f 2>/dev/null || hostname)"
DO_PUBLISH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) DO_PUBLISH=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --dest) DEST="${2:?}"; shift 2 ;;
    --git) GIT_REMOTE="${2:?}"; shift 2 ;;
    --url) URL="${2:?}"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"

# Prefer newest gate-SUMMARY under test-results
SUMMARY_MD=""
SUMMARY_JSON=""
if [[ -d "$KM_CI_RESULTS" ]]; then
  SUMMARY_MD="$(find "$KM_CI_RESULTS" -type f -name gate-SUMMARY.md -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2- || true)"
fi
if [[ -n "$SUMMARY_MD" && -f "$SUMMARY_MD" ]]; then
  SUMMARY_JSON="${SUMMARY_MD%.md}.json"
  [[ -f "$SUMMARY_JSON" ]] || SUMMARY_JSON=""
fi

NOW="$(date -Iseconds)"
DATE_LABEL="unknown"
OVERALL="NONE"
if [[ -n "$SUMMARY_MD" ]]; then
  DATE_LABEL="$(basename "$(dirname "$(dirname "$SUMMARY_MD")")")"
  OVERALL="$(awk '
    /^\- Overall:/{ gsub(/\*\*/,"",$3); print $3; exit }
    /^\*\*Overall:\*\*/{print $2; exit}
    /^overall:/{print $2; exit}
  ' "$SUMMARY_MD" 2>/dev/null || true)"
  if [[ -z "$OVERALL" && -n "$SUMMARY_JSON" ]]; then
    OVERALL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("overall","?"))' "$SUMMARY_JSON" 2>/dev/null || echo '?')"
  fi
fi
: "${OVERALL:=NONE}"

# Stage copies for publish
cp -a "$SUMMARY_MD" "$OUT/gate-SUMMARY.md" 2>/dev/null || echo "(no gate SUMMARY yet)" >"$OUT/gate-SUMMARY.md"
if [[ -n "$SUMMARY_JSON" && -f "$SUMMARY_JSON" ]]; then
  cp -a "$SUMMARY_JSON" "$OUT/gate-SUMMARY.json"
else
  echo '{}' >"$OUT/gate-SUMMARY.json"
fi

python3 - "$OUT/index.html" "$HOST_DISP" "$NOW" "$DATE_LABEL" "$OVERALL" "$URL" "$OUT/gate-SUMMARY.md" <<'PY'
import html, sys
from pathlib import Path
out, host, now, date, overall, url, md_path = sys.argv[1:8]
md = Path(md_path).read_text(encoding="utf-8", errors="replace") if Path(md_path).is_file() else "(empty)"
esc = html.escape
ou = overall.upper()
cls = "pass" if ou == "PASS" else ("fail" if ou == "FAIL" else ("blocked" if ou == "BLOCKED" else "none"))
runs = url.rstrip("/").rsplit("/", 1)[0] + "/simics-runs/" if url else ""
runs_line = f'<p class="meta">Live runs: <a href="{esc(runs)}">{esc(runs)}</a></p>' if runs else ""
page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta http-equiv="refresh" content="120"/>
<title>KM Simics smoke — {esc(date)} {esc(overall)}</title>
<style>
  body {{ font-family: ui-sans-serif, system-ui, sans-serif; margin: 2rem; background: #0f1419; color: #e7ecf1; }}
  h1 {{ font-size: 1.4rem; }}
  .meta {{ color: #9aa7b5; }}
  .pass {{ color: #6bcb77; }}
  .fail {{ color: #ff6b6b; }}
  .blocked {{ color: #ffd166; }}
  .none {{ color: #9aa7b5; }}
  pre {{ background: #1a222b; padding: 1rem; overflow: auto; max-width: 1100px; border-radius: 6px; }}
  a {{ color: #6cb6ff; }}
</style>
</head>
<body>
<h1>KM Simics smoke status</h1>
<p class="meta">Host <strong>{esc(host)}</strong> &middot; Drop <strong>{esc(date)}</strong> &middot;
Overall <strong class="{cls}">{esc(overall)}</strong> &middot; Updated <strong>{esc(now)}</strong></p>
{runs_line}
<p><a href="gate-SUMMARY.md">gate-SUMMARY.md</a> · <a href="gate-SUMMARY.json">gate-SUMMARY.json</a></p>
<pre>{esc(md)}</pre>
</body>
</html>
"""
Path(out).write_text(page, encoding="utf-8")
PY

echo "Wrote: $OUT/index.html  ($DATE_LABEL / $OVERALL)"

if [[ $DO_PUBLISH -eq 1 ]]; then
  published=0
  if [[ -n "$GIT_REMOTE" ]]; then
    "$SCRIPT_DIR/git-web-publish.sh" "$OUT" "$GIT_REMOTE" status
    echo "Published (git) → $GIT_REMOTE (simics-status/)"
    published=1
  fi
  if [[ -n "$DEST" ]]; then
    case "$DEST" in
      *:*)
        if command -v rsync >/dev/null 2>&1; then
          rsync -az --delete "$OUT"/ "$DEST"/
        else
          scp -q "$OUT"/* "$DEST"/
        fi
        ;;
      *)
        mkdir -p "$DEST"
        if command -v rsync >/dev/null 2>&1; then
          rsync -a --delete "$OUT"/ "$DEST"/
        else
          cp -a "$OUT"/. "$DEST"/
        fi
        ;;
    esac
    echo "Published → $DEST"
    published=1
  fi
  if [[ $published -eq 0 ]]; then
    echo "ERROR: --publish needs KM_SIMICS_WEB_GIT / KM_SIMICS_STATUS_GIT and/or KM_SIMICS_STATUS_DEST" >&2
    exit 1
  fi
  echo "URL: $URL"
fi
