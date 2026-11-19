#!/usr/bin/env bash
# Run ON alisubun1 (as alisov, in www-data group) to create bare repos + hooks
# that publish into Apache webdata.
#
#   scp -r scripts/km-ci/alisubun1 alisov@alisubun1:~/km-ci-alisubun1
#   ssh alisov@alisubun1 'bash ~/km-ci-alisubun1/setup-git-publish.sh'
#
# Then on ghrdbld1 authorize SSH and set:
#   KM_SIMICS_STATUS_GIT=alisov@alisubun1:git/km-simics-status.git
#   KM_SIMICS_RUNS_GIT=alisov@alisubun1:git/km-simics-runs.git
set -euo pipefail

WEB_ROOT="${KM_WEB_ROOT:-/DISK1/nfs/webdata/osbv-yo/KM}"
GIT_HOME="${KM_GIT_HOME:-$HOME/git}"
BRANCH="${KM_WEB_BRANCH:-main}"
HOOK_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/post-receive.hook"

setup_one() {
  local name="$1"  # simics-status | simics-runs
  local bare="${GIT_HOME}/km-${name}.git"
  local target="${WEB_ROOT}/${name}"
  local work="${GIT_HOME}/work/${name}"

  mkdir -p "$GIT_HOME" "$target" "$work"
  if [[ ! -d "$bare" ]]; then
    git init --bare "$bare"
    echo "[setup] created bare $bare"
  else
    echo "[setup] bare exists $bare"
  fi

  git --git-dir="$bare" config receive.denyCurrentBranch ignore 2>/dev/null || true

  # Private work tree + rsync into webdata (avoids git unlink on www-data files)
  {
    echo '#!/bin/bash'
    echo "export KM_WEB_TARGET='${target}'"
    echo "export KM_WEB_WORK='${work}'"
    echo "export KM_WEB_BRANCH='${BRANCH}'"
    echo 'export GIT_DIR="$PWD"'
    tail -n +2 "$HOOK_SRC"
  } >"$bare/hooks/post-receive"
  chmod 0755 "$bare/hooks/post-receive"

  echo "[setup] hook → work=$work → web=$target"
  echo "[setup] remote URL for ghrdbld1:  $(whoami)@$(hostname -s):git/km-${name}.git"
}

echo "[setup] WEB_ROOT=$WEB_ROOT  GIT_HOME=$GIT_HOME  user=$(whoami)"
id
ls -ld "$WEB_ROOT" "$WEB_ROOT/simics-status" "$WEB_ROOT/simics-runs" 2>/dev/null || true

setup_one simics-status
setup_one simics-runs

echo
echo "Next on ghrdbld1 (osvuser):"
echo "  1) Install SSH key for $(whoami)@$(hostname -f):"
echo "       ssh-copy-id $(whoami)@$(hostname -f)"
echo "     or append ghrdbld1 ~/.ssh/id_ed25519.pub to ~$(whoami)/.ssh/authorized_keys here."
echo "  2) In km-ci config / env:"
echo "       export KM_SIMICS_STATUS_GIT='$(whoami)@$(hostname -s):git/km-simics-status.git'"
echo "       export KM_SIMICS_RUNS_GIT='$(whoami)@$(hostname -s):git/km-simics-runs.git'"
echo "  3) Publish:"
echo "       ./scripts/km-ci/publish-gate-status.sh --publish"
echo "       ./scripts/host/km-simics-instances-publish.sh --publish"
