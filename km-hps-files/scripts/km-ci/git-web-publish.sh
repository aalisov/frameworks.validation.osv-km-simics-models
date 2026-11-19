#!/usr/bin/env bash
# Push generated web content into the km-simics-web git remote.
#
# Preferred (one GitHub repo, two subdirs):
#   KM_SIMICS_WEB_GIT=https://github.com/altera-sandbox/frameworks.validation.osv-auto.km-simics-web.git
#   ./scripts/km-ci/git-web-publish.sh ~/km-hps/var/simics-status status
#   ./scripts/km-ci/git-web-publish.sh ~/km-hps/var/simics-runs runs
#
# Legacy (dedicated remote per page):
#   ./scripts/km-ci/git-web-publish.sh <out-dir> <remote-url> <name>
#
# Env:
#   KM_SIMICS_WEB_GIT          monorepo remote (default used when only 2 args)
#   KM_CI_GIT_PUBLISH_BRANCH   default: main
#   KM_CI_GIT_AUTHOR_NAME / KM_CI_GIT_AUTHOR_EMAIL
#   KM_CI_GITHUB_TOKEN         optional; enables HTTPS push as x-access-token
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

BRANCH="${KM_CI_GIT_PUBLISH_BRANCH:-main}"
AUTHOR_NAME="${KM_CI_GIT_AUTHOR_NAME:-km-ci}"
AUTHOR_EMAIL="${KM_CI_GIT_AUTHOR_EMAIL:-km-ci@$(hostname -s 2>/dev/null || hostname)}"
WEB_GIT="${KM_SIMICS_WEB_GIT:-https://github.com/altera-sandbox/frameworks.validation.osv-auto.km-simics-web.git}"

# Map short name → subdir inside monorepo
subdir_for() {
  case "$1" in
    status|simics-status) echo "simics-status" ;;
    runs|simics-runs) echo "simics-runs" ;;
    *) echo "$1" ;;
  esac
}

auth_remote_url() {
  local url="$1"
  if [[ -n "${KM_CI_GITHUB_TOKEN:-${GH_TOKEN:-}}" && "$url" =~ ^https://github.com/ ]]; then
    local tok="${KM_CI_GITHUB_TOKEN:-$GH_TOKEN}"
    echo "$url" | sed -E "s#https://github.com/#https://x-access-token:${tok}@github.com/#"
  else
    echo "$url"
  fi
}

OUT=""
REMOTE=""
NAME=""
SUBDIR=""

if [[ $# -eq 2 ]]; then
  OUT="$1"
  NAME="$2"
  REMOTE="$WEB_GIT"
  SUBDIR="$(subdir_for "$NAME")"
elif [[ $# -eq 3 ]]; then
  OUT="$1"
  REMOTE="$2"
  NAME="$3"
  # If remote is the monorepo (or WEB_GIT), still use subdirs
  if [[ "$REMOTE" == "$WEB_GIT" || "$REMOTE" == *frameworks.validation.osv-auto.km-simics-web* ]]; then
    SUBDIR="$(subdir_for "$NAME")"
  else
    SUBDIR=""  # legacy: content at repo root
  fi
elif [[ $# -eq 4 ]]; then
  OUT="$1"
  REMOTE="$2"
  NAME="$3"
  SUBDIR="$4"
else
  echo "Usage: $0 <out-dir> <name>" >&2
  echo "   or: $0 <out-dir> <remote-url> <name> [subdir]" >&2
  exit 2
fi

[[ -d "$OUT" ]] || { echo "[git-publish] ERROR: missing out dir $OUT" >&2; exit 1; }

# Shared clone for monorepo; per-name clone for legacy remotes
if [[ -n "$SUBDIR" ]]; then
  WORK="${KM_CI_VAR}/git-publish/web"
else
  WORK="${KM_CI_VAR}/git-publish/${NAME}"
fi
mkdir -p "$KM_CI_VAR/git-publish"

PUSH_URL="$(auth_remote_url "$REMOTE")"

if [[ ! -d "$WORK/.git" ]]; then
  echo "[git-publish] clone/init → $WORK ($REMOTE)" >&2
  if git ls-remote "$PUSH_URL" HEAD >/dev/null 2>&1; then
    git clone -b "$BRANCH" "$PUSH_URL" "$WORK" 2>/dev/null \
      || git clone "$PUSH_URL" "$WORK"
  else
    mkdir -p "$WORK"
    git -C "$WORK" init -b "$BRANCH"
    git -C "$WORK" remote add origin "$REMOTE"
  fi
fi

# Store clean remote URL in config; use authenticated URL only for fetch/push
git -C "$WORK" remote set-url origin "$REMOTE"
git -C "$WORK" remote set-url --push origin "$PUSH_URL"

cur="$(git -C "$WORK" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if [[ "$cur" != "$BRANCH" && "$cur" != "HEAD" ]]; then
  git -C "$WORK" branch -M "$BRANCH" 2>/dev/null || true
fi

# Refresh from remote before editing (multi-agent / status+runs sharing one repo)
git -C "$WORK" fetch origin "$BRANCH" 2>/dev/null || true
if git -C "$WORK" rev-parse --verify "origin/${BRANCH}" >/dev/null 2>&1; then
  git -C "$WORK" checkout -B "$BRANCH" "origin/${BRANCH}" 2>/dev/null \
    || git -C "$WORK" pull --rebase origin "$BRANCH" 2>/dev/null \
    || true
fi

TARGET="$WORK"
if [[ -n "$SUBDIR" ]]; then
  TARGET="$WORK/$SUBDIR"
  mkdir -p "$TARGET"
fi

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete --exclude .git "$OUT"/ "$TARGET"/
else
  find "$TARGET" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cp -a "$OUT"/. "$TARGET"/
fi

# Drop accidental probe / junk
rm -f "$WORK/.push-probe" 2>/dev/null || true

git -C "$WORK" add -A
if git -C "$WORK" diff --cached --quiet; then
  echo "[git-publish] $NAME: no content changes" >&2
  LOCAL="$(git -C "$WORK" rev-parse HEAD 2>/dev/null || true)"
  REMOTE_REV="$(git -C "$WORK" rev-parse "origin/${BRANCH}" 2>/dev/null || true)"
  if [[ -n "$LOCAL" && -n "$REMOTE_REV" && "$LOCAL" == "$REMOTE_REV" ]]; then
    echo "[git-publish] $NAME: already up to date" >&2
    exit 0
  fi
else
  git -C "$WORK" \
    -c "user.name=$AUTHOR_NAME" \
    -c "user.email=$AUTHOR_EMAIL" \
    commit -m "km-ci publish ${NAME} $(hostname -s 2>/dev/null || hostname) $(date -Iseconds)"
fi

echo "[git-publish] push $NAME → $REMOTE ($BRANCH${SUBDIR:+ /$SUBDIR})" >&2
git -C "$WORK" push origin "HEAD:${BRANCH}"
echo "[git-publish] OK $NAME" >&2
