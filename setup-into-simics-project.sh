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

# Import + patch km-universal-board-comp so VSIP/P3T1755 are instantiated.
# Stock intel-fpga_main board does not create vsip_memsrc_0.
install_board_with_vsip() {
  local board_dir="$PROJECT/modules/km-universal-board-comp"
  local board_py="$board_dir/km_universal_board_comp.py"
  local patch="$REPO_ROOT/patches/0001-km-universal-board-comp-VSIP-P3T1755.patch"
  local src=""

  [[ -f "$patch" ]] || die "missing board patch: $patch"

  # Prefer platform module tree (has Makefile + sources).
  if [[ -n "${SIMICS_FPGA_ROOT:-}" && -f "$SIMICS_FPGA_ROOT/platforms/agilex72-universal/modules/km-universal-board-comp/km_universal_board_comp.py" ]]; then
    src="$SIMICS_FPGA_ROOT/platforms/agilex72-universal/modules/km-universal-board-comp"
  elif [[ -n "${SIMICS_BASE:-}" ]]; then
    local cand
    for cand in \
      "$(dirname "$SIMICS_BASE")/platforms/agilex72-universal/modules/km-universal-board-comp" \
      "$SIMICS_BASE/../platforms/agilex72-universal/modules/km-universal-board-comp"
    do
      if [[ -f "$cand/km_universal_board_comp.py" ]]; then
        src="$(cd "$cand" && pwd)"
        break
      fi
    done
  fi

  [[ -n "$src" ]] || die "cannot find stock km-universal-board-comp under SIMICS_FPGA_ROOT/platforms (set env first)"

  info ""
  info "Installing km-universal-board-comp from $src"
  mkdir -p "$board_dir"

  # Board Makefile uses EXTRA_MODULE_VPATH += km/common
  local km_common_src
  km_common_src="$(cd "$src/.." && pwd)/km/common"
  if [[ ! -f "$km_common_src/km_common.py" ]]; then
    die "missing km/common next to board module: $km_common_src"
  fi
  mkdir -p "$PROJECT/modules/km"
  if [[ -e "$PROJECT/modules/km/common" || -L "$PROJECT/modules/km/common" ]]; then
    if [[ $FORCE -eq 1 ]]; then
      rm -rf "$PROJECT/modules/km/common"
    fi
  fi
  if [[ ! -e "$PROJECT/modules/km/common" ]]; then
    ln -sfn "$km_common_src" "$PROJECT/modules/km/common"
    info "Linked modules/km/common → $km_common_src"
  else
    info "OK  modules/km/common already present"
  fi

  if [[ -f "$board_py" && $FORCE -eq 0 ]] && grep -q 'create_vsip_memsrc' "$board_py" 2>/dev/null; then
    info "OK  board already has create_vsip_memsrc"
    return 0
  fi
  if [[ -f "$board_py" && $FORCE -eq 1 ]]; then
    cp -a "$board_py" "$board_py.bak.$(date +%Y%m%d%H%M%S)"
  fi
  # Keep project Makefile if present; otherwise take platform's.
  cp -a "$src/km_universal_board_comp.py" "$board_py"
  [[ -f "$board_dir/Makefile" ]] || cp -a "$src/Makefile" "$board_dir/Makefile"
  [[ -f "$board_dir/module_load.py" ]] || cp -a "$src/module_load.py" "$board_dir/module_load.py"

  if grep -q 'create_vsip_memsrc' "$board_py" 2>/dev/null; then
    info "OK  board already patched"
  else
    info "Applying $patch"
    (cd "$board_dir" && patch -p1 < "$patch") || die "board patch failed"
  fi
  grep -q 'create_vsip_memsrc' "$board_py" || die "create_vsip_memsrc missing after patch"
  info "Board: VSIP+P3T1755 hooks present"
}

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
      info "SIMICS_FPGA_ROOT=${SIMICS_FPGA_ROOT:-unset}"
    else
      info "WARNING: no set_simics_env*.sh found; relying on existing environment"
      [[ -n "${SIMICS_BASE:-}" ]] || die "SIMICS_BASE not set; pass --env-script or source env first"
    fi
    # Board patch needs env so SIMICS_FPGA_ROOT is set
    install_board_with_vsip
    if [[ -f GNUmakefile || -f Makefile ]]; then
      make ENVCHECK=disable vsip-memsrc p3t1755 km-universal-board-comp 2>/dev/null \
        || make ENVCHECK=disable \
        || make
    else
      die "no Makefile/GNUmakefile in $PROJECT — run Simics project-setup first"
    fi
  )
  info "Build finished."
elif [[ $DO_MODELS -eq 1 ]]; then
  info "Skipping build (--no-build)."
  # Still try to patch board if env is already set
  if [[ -n "${SIMICS_FPGA_ROOT:-}${SIMICS_BASE:-}" ]]; then
    install_board_with_vsip || true
  fi
fi

BOARD="$PROJECT/modules/km-universal-board-comp/km_universal_board_comp.py"
info ""
if [[ -f "$BOARD" ]] && grep -q 'create_vsip_memsrc' "$BOARD" 2>/dev/null; then
  info "Board: km-universal-board-comp has create_vsip_memsrc — good."
else
  info "WARNING: board missing create_vsip_memsrc; VSIP will not appear in the sim."
  info "         Re-run with env sourced: source $PROJECT/set_simics_env_main.sh && $0 -p $PROJECT --force"
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
