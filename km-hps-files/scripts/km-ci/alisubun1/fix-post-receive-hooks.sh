#!/usr/bin/env bash
# Run ON alisubun1 as alisov (or: ssh alisov@alisubun1 'bash -s' < this-file).
#
# 1) Ensures web dirs are group-writable for www-data (needs sudo once if unlink fails)
# 2) Installs post-receive hooks (private work tree + rsync into webdata)
# 3) Deploys current main into simics-status / simics-runs
set -euo pipefail

WEB_ROOT="${KM_WEB_ROOT:-/DISK1/nfs/webdata/osbv-yo/KM}"
GIT_HOME="${KM_GIT_HOME:-$HOME/git}"
BRANCH="${KM_WEB_BRANCH:-main}"

fix_perms() {
  local d="$1"
  echo "[fix] permissions on $d"
  ls -ld "$d" || true
  if touch "$d/.km-ci-write-test" 2>/dev/null; then
    rm -f "$d/.km-ci-write-test"
    echo "[fix] write OK"
    return 0
  fi
  echo "[fix] cannot write $d — trying sudo chgrp/chmod (www-data)"
  if sudo -n true 2>/dev/null; then
    sudo chgrp -R www-data "$d"
    sudo chmod -R g+rwX "$d"
    sudo find "$d" -type d -exec chmod g+s {} \;
  else
    cat <<EOF >&2

Permission denied writing $d (files owned by www-data).
Run once on alisubun1 (with sudo):

  sudo chown -R alisov:www-data $WEB_ROOT/simics-status $WEB_ROOT/simics-runs
  sudo chmod -R ug+rwX $WEB_ROOT/simics-status $WEB_ROOT/simics-runs
  sudo find $WEB_ROOT/simics-status $WEB_ROOT/simics-runs -type d -exec chmod g+s {} \\;
  # and ensure:  groups | grep www-data   (or: sudo usermod -aG www-data alisov && re-login)

Then re-run this script.

EOF
    exit 1
  fi
  if ! touch "$d/.km-ci-write-test" 2>/dev/null; then
    echo "[fix] still cannot write $d after sudo attempt" >&2
    exit 1
  fi
  rm -f "$d/.km-ci-write-test"
}

write_hook() {
  local bare="$1" target="$2" work="$3"
  cat >"$bare/hooks/post-receive" <<EOF
#!/bin/bash
export KM_WEB_TARGET='$target'
export KM_WEB_WORK='$work'
export KM_WEB_BRANCH='$BRANCH'
export GIT_DIR="\$PWD"
set -euo pipefail
TARGET="\${KM_WEB_TARGET:?}"
WORK="\${KM_WEB_WORK:?}"
DEFAULT_BRANCH="\${KM_WEB_BRANCH:-main}"
GITDIR="\${GIT_DIR:-\$PWD}"
while read -r _oldrev newrev refname; do
  case "\$refname" in
    refs/heads/*)
      br="\${refname#refs/heads/}"
      if [[ "\$br" != "\$DEFAULT_BRANCH" && "\$br" != "master" && "\$br" != "main" ]]; then
        echo "[post-receive] ignore \$refname"
        continue
      fi
      echo "[post-receive] \$refname → work=\$WORK → web=\$TARGET (\$newrev)"
      mkdir -p "\$WORK" "\$TARGET"
      git --git-dir="\$GITDIR" --work-tree="\$WORK" checkout -f "\$br"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude .git "\$WORK"/ "\$TARGET"/
      else
        find "\$TARGET" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + 2>/dev/null || true
        cp -a "\$WORK"/. "\$TARGET"/
      fi
      chmod -R g+rwX "\$TARGET" 2>/dev/null || true
      echo "[post-receive] OK → \$TARGET"
      ls -la "\$TARGET" || true
      ;;
    *)
      echo "[post-receive] ignore \$refname"
      ;;
  esac
done
EOF
  chmod 0755 "$bare/hooks/post-receive"
}

for name in simics-status simics-runs; do
  bare="${GIT_HOME}/km-${name}.git"
  target="${WEB_ROOT}/${name}"
  work="${GIT_HOME}/work/${name}"
  [[ -d "$bare" ]] || { echo "missing bare $bare — run setup-git-publish.sh first" >&2; exit 1; }
  mkdir -p "$work" "$target"
  fix_perms "$target"
  write_hook "$bare" "$target" "$work"
  echo "[fix] deploy $BRANCH via $work → $target"
  git --git-dir="$bare" --work-tree="$work" checkout -f "$BRANCH"
  rsync -a --delete --exclude .git "$work"/ "$target"/
  chmod -R g+rwX "$target" 2>/dev/null || true
  ls -la "$target"
  echo
done

echo "OK — live under $WEB_ROOT"
echo "  $WEB_ROOT/simics-status/"
echo "  $WEB_ROOT/simics-runs/"
