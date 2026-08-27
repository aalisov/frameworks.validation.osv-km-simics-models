#!/usr/bin/env bash
# Install KM Simics device models into a Simics project (fresh or existing).
#
# Typical use after a new Simics / km-hps checkout:
#
#   git clone https://github.com/aalisov/frameworks.validation.osv-km-simics-models.git
#   cd frameworks.validation.osv-km-simics-models
#   ./setup-into-simics-project.sh
#
# Options:
#   -p, --project DIR   Simics project (default: $SIMICS_PROJECT or ~/km-hps)
#   -c, --copy          Copy modules instead of symlink
#   -f, --force         Replace existing modules/vsip-memsrc and modules/p3t1755
#   -n, --no-build      Link/copy only; skip make
#   -e, --env-script F  Env script to source before build (default: PROJECT/set_simics_env_main.sh)
#   -h, --help          This help
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES=(vsip-memsrc p3t1755)

PROJECT="${SIMICS_PROJECT:-$HOME/km-hps}"
MODE=symlink
FORCE=0
DO_BUILD=1
ENV_SCRIPT=""

usage() {
  cat <<'EOF'
Install KM Simics device models into a Simics project (fresh or existing).

Typical use after a new Simics / km-hps checkout:

  git clone https://github.com/aalisov/frameworks.validation.osv-km-simics-models.git
  cd frameworks.validation.osv-km-simics-models
  ./setup-into-simics-project.sh

Options:
  -p, --project DIR   Simics project (default: $SIMICS_PROJECT or ~/km-hps)
  -c, --copy          Copy modules instead of symlink
  -f, --force         Replace existing modules/vsip-memsrc and modules/p3t1755
  -n, --no-build      Link/copy only; skip make
  -e, --env-script F  Env script to source before build
                      (default: PROJECT/set_simics_env_main.sh)
  -h, --help          This help
EOF
  exit "${1:-0}"
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT="$2"; shift 2 ;;
    -c|--copy) MODE=copy; shift ;;
    -f|--force) FORCE=1; shift ;;
    -n|--no-build) DO_BUILD=0; shift ;;
    -e|--env-script) ENV_SCRIPT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) die "unexpected argument: $1 (try --help)" ;;
  esac
done

PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "project not found: $PROJECT"
[[ -d "$PROJECT/modules" ]] || die "not a Simics project (missing modules/): $PROJECT"

for m in "${MODULES[@]}"; do
  [[ -d "$REPO_ROOT/$m" ]] || die "missing module source: $REPO_ROOT/$m"
done

install_one() {
  local name="$1"
  local src="$REPO_ROOT/$name"
  local dst="$PROJECT/modules/$name"

  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ $FORCE -eq 0 ]]; then
      if [[ -L "$dst" ]]; then
        local cur
        cur="$(readlink -f "$dst" 2>/dev/null || readlink "$dst")"
        if [[ "$cur" == "$(readlink -f "$src")" ]]; then
          info "OK  $name already linked → $cur"
          return 0
        fi
      fi
      die "$dst already exists (use --force to replace)"
    fi
    # Backup then remove
    local bak="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backing up $dst → $bak"
    mv "$dst" "$bak"
  fi

  if [[ "$MODE" == symlink ]]; then
    ln -sfn "$src" "$dst"
    info "Linked $dst → $src"
  else
    mkdir -p "$dst"
    # Prefer rsync; fall back to cp
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete \
        --exclude='linux64/' --exclude='*.so' --exclude='*.o' --exclude='.dmldep' \
        "$src/" "$dst/"
    else
      cp -a "$src/." "$dst/"
    fi
    info "Copied $src → $dst"
  fi
}

info "Repo:     $REPO_ROOT"
info "Project:  $PROJECT"
info "Mode:     $MODE"
info ""

for m in "${MODULES[@]}"; do
  install_one "$m"
done

if [[ $DO_BUILD -eq 1 ]]; then
  if [[ -z "$ENV_SCRIPT" ]]; then
    if [[ -f "$PROJECT/set_simics_env_main.sh" ]]; then
      ENV_SCRIPT="$PROJECT/set_simics_env_main.sh"
    elif [[ -f "$PROJECT/set_simics_env.sh" ]]; then
      ENV_SCRIPT="$PROJECT/set_simics_env.sh"
    fi
  fi

  info ""
  info "Building modules..."
  (
    cd "$PROJECT"
    if [[ -n "$ENV_SCRIPT" ]]; then
      # shellcheck disable=SC1090
      source "$ENV_SCRIPT"
      info "Sourced $ENV_SCRIPT"
      info "SIMICS_BASE=${SIMICS_BASE:-unset}"
    else
      info "WARNING: no set_simics_env*.sh found; relying on existing environment"
      [[ -n "${SIMICS_BASE:-}" ]] || die "SIMICS_BASE not set; pass --env-script or source env first"
    fi
    # Module builds need MODULE_MAKEFILE from the project; top-level make is safest.
    if [[ -f GNUmakefile || -f Makefile ]]; then
      make ENVCHECK=disable vsip-memsrc p3t1755 2>/dev/null \
        || make ENVCHECK=disable \
        || make
    else
      die "no Makefile/GNUmakefile in $PROJECT"
    fi
  )
  info "Build finished."
else
  info "Skipping build (--no-build)."
fi

# Board wiring hint
BOARD="$PROJECT/modules/km-universal-board-comp/km_universal_board_comp.py"
info ""
if [[ -f "$BOARD" ]]; then
  if grep -q 'board_hooks' "$BOARD" 2>/dev/null; then
    info "Board: km-universal-board-comp already references board_hooks — good."
  else
    info "NOTE: $BOARD does not reference board_hooks yet."
    info "      Wire VSIP/P3T1755 using the helpers documented in README.md, or"
    info "      merge hooks from this repo into your board component."
  fi
else
  info "NOTE: no km-universal-board-comp in project; call board_hooks from your board."
fi

info ""
info "Done. Models available as Simics modules: vsip_memsrc, p3t1755"
info "  (classes vsip_memsrc_comp / p3t1755_comp via board_hooks)"
