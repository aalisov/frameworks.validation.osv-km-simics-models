#!/usr/bin/env bash
# Run ON alisubun1 (cron/timer): pull KM Simics status/runs from GitHub into Apache webdata.
#
# Agents push to GitHub; this host only needs *read* access. GitHub no longer accepts
# account passwords over HTTPS — use one of:
#
#   A) Make the repo public  → no token needed
#   B) Fine-grained PAT (Contents: Read) in env / file:
#        export KM_CI_GITHUB_TOKEN=ghp_...   # or GH_TOKEN
#        # or:  echo ghp_... > ~/.config/km-simics-web.token && chmod 600 ...
#   C) Read-only deploy key + SSH URL:
#        KM_SIMICS_WEB_GIT=git@github.com:altera-sandbox/frameworks.validation.osv-auto.km-simics-web.git
#        KM_SIMICS_WEB_SSH_KEY=$HOME/.ssh/km-simics-web_ro
#
# Cron example (alisov):
#   */5 * * * *  KM_CI_GITHUB_TOKEN=$(cat $HOME/.config/km-simics-web.token) \
#                $HOME/bin/sync-simics-web-from-github.sh >>$HOME/var/km-simics-web-sync.log 2>&1
#
# Env:
#   KM_SIMICS_WEB_GIT / KM_WEB_ROOT / KM_WEB_CACHE / KM_WEB_BRANCH
#   KM_CI_GITHUB_TOKEN | GH_TOKEN | KM_SIMICS_WEB_TOKEN_FILE
#   KM_SIMICS_WEB_SSH_KEY
set -euo pipefail

# Never hang on interactive username/password prompts (cron-safe)
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=echo
export GCM_INTERACTIVE=never

REPO="${KM_SIMICS_WEB_GIT:-https://github.com/altera-sandbox/frameworks.validation.osv-auto.km-simics-web.git}"
WEB_ROOT="${KM_WEB_ROOT:-/DISK1/nfs/webdata/osbv-yo/KM}"
CACHE="${KM_WEB_CACHE:-${HOME}/git/km-simics-web-cache}"
BRANCH="${KM_WEB_BRANCH:-main}"
TOKEN_FILE="${KM_SIMICS_WEB_TOKEN_FILE:-${HOME}/.config/km-simics-web.token}"

STATUS_DST="${WEB_ROOT}/simics-status"
RUNS_DST="${WEB_ROOT}/simics-runs"

ts() { date -Iseconds; }
log() { echo "$(ts) [sync-simics-web] $*"; }

# Resolve token: env wins, else optional file
TOKEN="${KM_CI_GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" && -f "$TOKEN_FILE" ]]; then
  TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"
fi

auth_url() {
  local url="$1"
  if [[ -n "$TOKEN" && "$url" =~ ^https://github.com/ ]]; then
    echo "$url" | sed -E "s#https://github.com/#https://x-access-token:${TOKEN}@github.com/#"
  else
    echo "$url"
  fi
}

if [[ -n "${KM_SIMICS_WEB_SSH_KEY:-}" ]]; then
  export GIT_SSH_COMMAND="ssh -i ${KM_SIMICS_WEB_SSH_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi

FETCH_URL="$(auth_url "$REPO")"
# Clean URL stored in git config (no token on disk in .git/config)
CLEAN_URL="$REPO"
if [[ "$CLEAN_URL" =~ ^https://x-access-token: ]]; then
  CLEAN_URL="$(echo "$CLEAN_URL" | sed -E 's#https://x-access-token:[^@]+@#https://#')"
fi

mkdir -p "$(dirname "$CACHE")" "$STATUS_DST" "$RUNS_DST"
mkdir -p "$(dirname "$TOKEN_FILE")" 2>/dev/null || true

clone_or_update() {
  if [[ ! -d "$CACHE/.git" ]]; then
    log "clone $CLEAN_URL → $CACHE"
    if ! git clone --depth 1 -b "$BRANCH" "$FETCH_URL" "$CACHE"; then
      log "ERROR: clone failed (private repo needs token/deploy key, or make repo public)"
      log "  export KM_CI_GITHUB_TOKEN=ghp_...   # classic/fine-grained PAT, Contents:Read"
      log "  or: echo ghp_... > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
      log "  or: KM_SIMICS_WEB_GIT=git@github.com:altera-sandbox/frameworks.validation.osv-auto.km-simics-web.git"
      exit 1
    fi
    git -C "$CACHE" remote set-url origin "$CLEAN_URL"
  else
    log "fetch $BRANCH in $CACHE"
    git -C "$CACHE" remote set-url origin "$CLEAN_URL"
    # fetch with auth URL without writing token into remote.pushurl permanently
    if ! git -C "$CACHE" fetch --depth 1 "$FETCH_URL" "$BRANCH"; then
      log "ERROR: fetch failed — check KM_CI_GITHUB_TOKEN / deploy key / repo visibility"
      exit 1
    fi
    git -C "$CACHE" checkout -B "$BRANCH" FETCH_HEAD
  fi
}

clone_or_update

sync_one() {
  local src="$1" dst="$2"
  if [[ ! -d "$src" ]]; then
    log "WARN: missing $src — skip"
    return 0
  fi
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude .git "$src"/ "$dst"/
  else
    find "$dst" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "$src"/. "$dst"/
  fi
  chmod -R g+rwX "$dst" 2>/dev/null || true
  log "updated $dst"
}

sync_one "$CACHE/simics-status" "$STATUS_DST"
sync_one "$CACHE/simics-runs" "$RUNS_DST"

log "done"
log "  http://alisubun1.sj.altera.com/osbv-yo/KM/simics-status/"
log "  http://alisubun1.sj.altera.com/osbv-yo/KM/simics-runs/"
