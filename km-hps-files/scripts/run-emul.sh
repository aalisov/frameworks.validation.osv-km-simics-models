#!/usr/bin/env bash
# KM emul on intel-fpga-main (alias for run-emul-smp.sh).
exec "$(cd "$(dirname "$0")" && pwd)/run-emul-smp.sh" "$@"
