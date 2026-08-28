#!/usr/bin/env bash
# Simics environment for intel-fpga-main (km_hps_dsu_120 / real PPU).
#
# Usage:
#   cd ~/km-hps && source ./set_simics_env_main.sh
#   ./scripts/run-emul-smp.sh
#   ./scripts/run-osbv-smp.sh
#
# Do NOT source set_simics_env.sh (26.3 ext) in the same shell without unsetting first.

_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export SIMICS_PROJECT="${SIMICS_PROJECT:-$_SCRIPT_DIR}"

# Drop sticky vars from a prior `source set_simics_env.sh` (26.3 ext).
unset SIMICS_BASE SIMICS_BASE_PACKAGE SIMICS_FPGA_ROOT SIMICS_PYTHON_PACKAGE
unset SIMICS_PYTHON SDM_HMOD_FW

if [[ -f "$SIMICS_PROJECT/local-env-main.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SIMICS_PROJECT/local-env-main.sh"
elif [[ -f "$SIMICS_PROJECT/local-env.sh" ]]; then
  # shellcheck disable=SC1091
  _km_save_base="${SIMICS_BASE:-}"
  source "$SIMICS_PROJECT/local-env.sh"
  if [[ -n "${SIMICS_BASE:-}" && "${SIMICS_BASE}" != *intel-fpga-main* \
    && "${SIMICS_BASE}" != *intel-fpga_main* \
    && "${SIMICS_BASE}" != *intel-fpga-ext_main* ]]; then
    echo "WARNING: local-env.sh set non-main SIMICS_BASE=$SIMICS_BASE — ignoring for main env"
    unset SIMICS_BASE SIMICS_FPGA_ROOT SIMICS_BASE_PACKAGE
    [[ -n "$_km_save_base" ]] && export SIMICS_BASE="$_km_save_base"
  fi
fi

_km_hps_is_main_tree() {
  # Accept Altera directory names for the mainline (km_hps_dsu_120) product:
  #   intel-fpga-main*, intel-fpga_main*, intel-fpga-ext_main* (newer installer name)
  case "$1" in
    *intel-fpga-main*|*intel-fpga_main*|*intel-fpga-ext_main*) return 0 ;;
    *) return 1 ;;
  esac
}

# True if SIMICS_FPGA_ROOT (parent of simics-N) has the mainline FPGA package set.
_km_hps_main_packages_ok() {
  local root="$1"
  [[ -d "$(ls -1d "$root"/simics-gdb-* 2>/dev/null | sort -V -r | head -1)" ]] || return 1
  [[ -d "$(ls -1d "$root"/simics-python-* 2>/dev/null | sort -V -r | head -1)" ]] || return 1
  [[ -d "$(ls -1d "$root"/simics-crypto-engine-* 2>/dev/null | sort -V -r | head -1)" ]] || return 1
  # Prefer internal (km_hps_dsu_120); some drops only ship intelfpga-ext (wrong for SMP).
  [[ -d "$(ls -1d "$root"/simics-intelfpga-internal-* 2>/dev/null | sort -V -r | head -1)" ]] || return 1
  return 0
}

_km_hps_detect_simics_main() {
  local cand root fpga_root best="" best_root=""
  if [[ -n "${SIMICS_BASE:-}" && -x "${SIMICS_BASE}/bin/simics" ]] \
    && _km_hps_is_main_tree "${SIMICS_BASE}"; then
    fpga_root="${SIMICS_FPGA_ROOT:-$(cd "${SIMICS_BASE}/.." && pwd)}"
    export SIMICS_FPGA_ROOT="$fpga_root"
    return 0
  fi
  unset SIMICS_BASE SIMICS_FPGA_ROOT
  for root in \
    "${HOME}/intelFPGA_pro" \
    "${HOME}/altera_pro" \
    "${HOME}/intelFPGA" \
    "/opt/intelFPGA_pro" \
    "/opt/intelFPGA"
  do
    [[ -d "$root" ]] || continue
    while IFS= read -r cand; do
      [[ -x "${cand}/bin/simics" ]] || continue
      fpga_root="$(cd "${cand}/.." && pwd)"
      # Prefer a tree that already has intelfpga-internal + friends
      if _km_hps_main_packages_ok "$fpga_root"; then
        export SIMICS_BASE="$cand"
        export SIMICS_FPGA_ROOT="$fpga_root"
        return 0
      fi
      # Remember first executable candidate as fallback
      if [[ -z "$best" ]]; then
        best="$cand"
        best_root="$fpga_root"
      fi
    done < <(
      ls -1d \
        "$root"/intel-fpga-main*/y/simics/simics-[0-9]* \
        "$root"/intel-fpga-main*/simics/simics-[0-9]* \
        "$root"/intel-fpga_main*/y/simics/simics-[0-9]* \
        "$root"/intel-fpga_main*/simics/simics-[0-9]* \
        "$root"/intel-fpga-ext_main*/y/simics/simics-[0-9]* \
        "$root"/intel-fpga-ext_main*/simics/simics-[0-9]* \
        "$root"/intel-fpga-ext_main/y/simics/simics-[0-9]* \
        "$root"/intel-fpga-ext_main/simics/simics-[0-9]* \
        2>/dev/null | sort -V -r
    )
  done
  if [[ -n "$best" ]]; then
    export SIMICS_BASE="$best"
    export SIMICS_FPGA_ROOT="$best_root"
    return 0
  fi
  return 1
}

if ! _km_hps_detect_simics_main; then
  echo "ERROR: Could not find intel-fpga-main / intel-fpga-ext_main Simics." >&2
  echo "       Set SIMICS_BASE in $SIMICS_PROJECT/local-env-main.sh" >&2
  echo "       (directory that contains bin/simics, usually .../y/simics/simics-N.N.N)" >&2
  return 1 2>/dev/null || exit 1
fi

export SIMICS_BASE_PACKAGE="$SIMICS_BASE"
export SIMICS_FPGA_ROOT="$(cd "$SIMICS_BASE/.." && pwd)"

_km_hps_simics_python_pkg() {
  local py
  py="$(ls -1d "$SIMICS_FPGA_ROOT"/simics-python-* 2>/dev/null | sort -V -r | head -1)"
  if [[ -z "$py" || ! -d "$py" ]]; then
    echo "ERROR: no simics-python-* under $SIMICS_FPGA_ROOT" >&2
    return 1
  fi
  echo "$py"
}

_sdm="$SIMICS_FPGA_ROOT/platforms/agilex72-universal/binaries/sdm_hmod_fw/sdm_hmod_fw.hex"
if [[ -f "$_sdm" ]]; then
  export SDM_HMOD_FW="$_sdm"
elif [[ -f "$SIMICS_PROJECT/binaries/sdm_hmod_fw/sdm_hmod_fw.hex" ]]; then
  export SDM_HMOD_FW="$SIMICS_PROJECT/binaries/sdm_hmod_fw/sdm_hmod_fw.hex"
else
  export SDM_HMOD_FW=""
fi

export PATH="$SIMICS_BASE/bin:$SIMICS_PROJECT/bin:$PATH"

if [[ -x "$SIMICS_PROJECT/.venv/bin/python" ]]; then
  # shellcheck disable=SC1091
  source "$SIMICS_PROJECT/.venv/bin/activate"
fi

cd "$SIMICS_PROJECT" || return 1

_km_hps_fix_main_packages() {
  local pl="$SIMICS_PROJECT/.package-list"
  local gdb py internal crypto syscl

  gdb="$(ls -1d "$SIMICS_FPGA_ROOT"/simics-gdb-* 2>/dev/null | sort -V -r | head -1)"
  py="$(ls -1d "$SIMICS_FPGA_ROOT"/simics-python-* 2>/dev/null | sort -V -r | head -1)"
  internal="$(ls -1d "$SIMICS_FPGA_ROOT"/simics-intelfpga-internal-* 2>/dev/null | sort -V -r | head -1)"
  crypto="$(ls -1d "$SIMICS_FPGA_ROOT"/simics-crypto-engine-* 2>/dev/null | sort -V -r | head -1)"
  syscl="$(ls -1d "$SIMICS_FPGA_ROOT"/simics-systemc-library-* 2>/dev/null | sort -V -r | head -1)"

  if [[ -z "$gdb" || -z "$py" || -z "$internal" || -z "$crypto" ]]; then
    echo "ERROR: missing main packages under $SIMICS_FPGA_ROOT" >&2
    echo "       need: simics-gdb-*, simics-python-*, simics-intelfpga-internal-*, simics-crypto-engine-*" >&2
    echo "       found:" >&2
    ls -1d "$SIMICS_FPGA_ROOT"/simics-* 2>/dev/null | sed 's/^/         /' >&2 || echo "         (none)" >&2
    echo "       Also check sibling .../y/simics/ (full main installs use that path)." >&2
    echo "       Set SIMICS_BASE in $SIMICS_PROJECT/local-env-main.sh to the simics-N dir" >&2
    echo "       whose parent contains simics-intelfpga-internal-*." >&2
    return 1
  fi

  if [[ -f "$pl" ]] \
    && grep -q "$internal" "$pl" \
    && ! grep -q 'simics-intelfpga-ext' "$pl"; then
    echo "packages: simics-intelfpga-internal (OK for km_hps_dsu_120)"
    return 0
  fi

  if [[ "${KM_SIMICS_AUTO_PACKAGES:-1}" != "1" ]]; then
    echo "WARNING: .package-list is not on intel-fpga-main packages."
    return 0
  fi

  cp -f "$pl" "$pl.backup" 2>/dev/null || true
  {
    echo "$gdb"
    echo "$internal"
    echo "$py"
    [[ -n "$syscl" ]] && echo "$syscl"
    echo "$crypto"
  } > "$pl"
  echo "packages: wrote .package-list -> simics-intelfpga-internal @ $SIMICS_FPGA_ROOT"
}

_km_hps_fix_main_launcher() {
  local launcher py
  py="$(_km_hps_simics_python_pkg)" || return 1
  export SIMICS_PYTHON_PACKAGE="$py"

  for launcher in "$SIMICS_PROJECT/simics" "$SIMICS_PROJECT/bin/simics"; do
    [[ -e "$launcher" ]] || continue
    if grep -qF "$SIMICS_BASE" "$launcher" 2>/dev/null \
      && grep -qF "$py" "$launcher" 2>/dev/null; then
      continue
    fi
    if [[ "${KM_SIMICS_AUTO_PACKAGES:-1}" != "1" ]]; then
      echo "WARNING: $launcher does not match SIMICS_BASE=$SIMICS_BASE"
      continue
    fi
    cat > "$launcher" <<LAUNCHEOF
#!/bin/bash
# rewritten by set_simics_env_main.sh for intel-fpga-main
SIMICS_BASE_PACKAGE="$SIMICS_BASE"
export SIMICS_BASE_PACKAGE
if [ -z "\${SIMICS_PYTHON_PACKAGE}" ]; then
    export SIMICS_PYTHON_PACKAGE="$py"
fi
export SIMICS_PYTHON=""
exec "$SIMICS_BASE/bin/simics" --project "$SIMICS_PROJECT" "\$@"
LAUNCHEOF
    chmod +x "$launcher"
    echo "launcher: rewrote $(basename "$launcher") -> $SIMICS_BASE"
  done
}

_km_hps_fix_main_packages || return 1 2>/dev/null || exit 1
_km_hps_fix_main_launcher || return 1 2>/dev/null || exit 1

echo "SIMICS_PROJECT=$SIMICS_PROJECT"
echo "SIMICS_BASE=$SIMICS_BASE"
echo "SIMICS_FPGA_ROOT=$SIMICS_FPGA_ROOT"
echo "SIMICS_PYTHON_PACKAGE=$SIMICS_PYTHON_PACKAGE"
echo "SDM_HMOD_FW=${SDM_HMOD_FW:-<none>}"
echo "artifacts: $SIMICS_PROJECT/images/{emul,osbv}"
echo "flavor: intel-fpga-main (expect km_hps_dsu_120 + SMP maxcpus=4)"
