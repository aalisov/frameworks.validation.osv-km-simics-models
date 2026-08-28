#!/usr/bin/env bash
# Install KM Simics device models + km-hps project scripts into a Simics project.
#
# Typical use after a new Simics / km-hps checkout:
#
#   git clone https://github.com/aalisov/frameworks.validation.osv-km-simics-models.git
#   cd frameworks.validation.osv-km-simics-models
#   ./setup-into-simics-project.sh -p ~/km-hps --force
#
# Options:
#   -p, --project DIR   Simics project (default: $SIMICS_PROJECT or ~/km-hps)
#   -c, --copy          Copy modules instead of symlink (scripts always copied)
#   -f, --force         Replace existing modules and overwrite project scripts
#   -n, --no-build      Link/copy only; skip make
#   --models-only       Install modules only (skip km-hps-files scripts)
#   --scripts-only      Install km-hps-files only (skip modules / build)
#   -e, --env-script F  Env script to source before build
#   -h, --help          This help
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES=(vsip-memsrc p3t1755)
HPS_FILES="$REPO_ROOT/km-hps-files"

PROJECT="${SIMICS_PROJECT:-$HOME/km-hps}"
MODE=symlink
FORCE=0
DO_BUILD=1
DO_MODELS=1
DO_SCRIPTS=1
ENV_SCRIPT=""

usage() {
  cat <<'EOF'
Install KM Simics device models + project scripts into a Simics project.

  git clone https://github.com/aalisov/frameworks.validation.osv-km-simics-models.git
  cd frameworks.validation.osv-km-simics-models
  ./setup-into-simics-project.sh -p ~/km-hps --force

Options:
  -p, --project DIR   Simics project (default: $SIMICS_PROJECT or ~/km-hps)
  -c, --copy          Copy modules instead of symlink (scripts always copied)
  -f, --force         Replace existing modules; overwrite project scripts
  -n, --no-build      Skip make
  --models-only       Modules only
  --scripts-only      km-hps-files (env + scripts/) only
  -e, --env-script F  Env script before build (default: PROJECT/set_simics_env_main.sh)
  -h, --help          This help

After install (Simics host):

  source ~/km-hps/set_simics_env_main.sh
  ~/km-hps/scripts/stage-artifact.sh osbv \
    --from http://HOST/share/KM --date latest
  ~/km-hps/scripts/run-osbv-smp.sh
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
    --models-only) DO_SCRIPTS=0; shift ;;
    --scripts-only) DO_MODELS=0; DO_BUILD=0; shift ;;
    -e|--env-script) ENV_SCRIPT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) die "unexpected argument: $1 (try --help)" ;;
  esac
done

# Create project skeleton if missing (scripts-only / first-time)
if [[ ! -d "$PROJECT" ]]; then
  [[ $FORCE -eq 1 || $DO_SCRIPTS -eq 1 ]] || die "project not found: $PROJECT"
  info "Creating project directory $PROJECT"
  mkdir -p "$PROJECT/modules" "$PROJECT/scripts" "$PROJECT/images/emul" "$PROJECT/images/osbv"
fi
PROJECT="$(cd "$PROJECT" && pwd)"
mkdir -p "$PROJECT/modules" "$PROJECT/scripts" "$PROJECT/images/emul" "$PROJECT/images/osbv"

install_module() {
  local name="$1"
  local src="$REPO_ROOT/$name"
  local dst="$PROJECT/modules/$name"

  [[ -d "$src" ]] || die "missing module source: $src"

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
    local bak="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backing up $dst → $bak"
    mv "$dst" "$bak"
  fi

  if [[ "$MODE" == symlink ]]; then
    ln -sfn "$src" "$dst"
    info "Linked $dst → $src"
  else
    mkdir -p "$dst"
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

install_scripts() {
  [[ -d "$HPS_FILES" ]] || die "missing $HPS_FILES"
  info ""
  info "Installing km-hps project files from $HPS_FILES"

  local f base
  for f in "$HPS_FILES"/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    if [[ -e "$PROJECT/$base" && $FORCE -eq 0 ]]; then
      info "OK  keep existing $PROJECT/$base (use --force to overwrite)"
      continue
    fi
    if [[ -e "$PROJECT/$base" && $FORCE -eq 1 ]]; then
      cp -a "$PROJECT/$base" "$PROJECT/${base}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    cp -a "$f" "$PROJECT/$base"
    [[ "$base" == *.sh || "$base" == simics ]] && chmod +x "$PROJECT/$base"
    info "  + $base"
  done

  mkdir -p "$PROJECT/scripts"
  for f in "$HPS_FILES/scripts"/*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    if [[ -e "$PROJECT/scripts/$base" && $FORCE -eq 0 ]]; then
      info "OK  keep existing scripts/$base (use --force to overwrite)"
      continue
    fi
    if [[ -e "$PROJECT/scripts/$base" && $FORCE -eq 1 ]]; then
      cp -a "$PROJECT/scripts/$base" "$PROJECT/scripts/${base}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    cp -a "$f" "$PROJECT/scripts/$base"
    [[ "$base" == *.sh ]] && chmod +x "$PROJECT/scripts/$base"
    info "  + scripts/$base"
  done

  if [[ -f "$PROJECT/scripts/README.main-smp.md" ]]; then
    cp -a "$PROJECT/scripts/README.main-smp.md" "$PROJECT/README.KM-SIMICS.md"
  fi

  # targets/km (agilex72-universal-fixed.simics + SMP fixup wrapper)
  if [[ -d "$HPS_FILES/targets" ]]; then
    mkdir -p "$PROJECT/targets"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "$HPS_FILES/targets/" "$PROJECT/targets/"
    else
      cp -a "$HPS_FILES/targets/." "$PROJECT/targets/"
    fi
    info "  + targets/ (from km-hps-files/targets)"
  fi
}

info "Repo:     $REPO_ROOT"
info "Project:  $PROJECT"
info "Mode:     modules=$MODE  scripts=copy  force=$FORCE"
info ""

if [[ $DO_SCRIPTS -eq 1 ]]; then
  install_scripts
fi

if [[ $DO_MODELS -eq 1 ]]; then
  for m in "${MODULES[@]}"; do
    install_module "$m"
  done
fi

if [[ $DO_BUILD -eq 1 && $DO_MODELS -eq 1 ]]; then
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
    if [[ -f GNUmakefile || -f Makefile ]]; then
      make ENVCHECK=disable vsip-memsrc p3t1755 2>/dev/null \
        || make ENVCHECK=disable \
        || make
    else
      die "no Makefile/GNUmakefile in $PROJECT — run Simics project-setup first"
    fi
  )
  info "Build finished."
elif [[ $DO_MODELS -eq 1 ]]; then
  info "Skipping build (--no-build)."
fi

BOARD="$PROJECT/modules/km-universal-board-comp/km_universal_board_comp.py"
info ""
if [[ -f "$BOARD" ]]; then
  if grep -q 'board_hooks' "$BOARD" 2>/dev/null; then
    info "Board: km-universal-board-comp already references board_hooks — good."
  else
    info "NOTE: $BOARD does not reference board_hooks yet."
    info "      See README.md for wiring VSIP/P3T1755."
  fi
else
  info "NOTE: no km-universal-board-comp in project; call board_hooks from your board."
fi

info ""
info "Done."
info "  Models:  vsip_memsrc, p3t1755"
info "  Scripts: $PROJECT/scripts/  (stage-artifact, run-*-smp, fetch-km-artifacts)"
info "  Env:     source $PROJECT/set_simics_env_main.sh"
info ""
info "Stage OSBV from share:"
info "  $PROJECT/scripts/stage-artifact.sh osbv --from http://HOST/share/KM --date latest"
info "  $PROJECT/scripts/run-osbv-smp.sh"
