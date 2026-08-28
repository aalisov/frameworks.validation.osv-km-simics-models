#!/usr/bin/env bash
# KM osbv on intel-fpga-main: SMP + SVE on (default mainline).
exec "$(cd "$(dirname "$0")" && pwd)/run-osbv-smp.sh" "$@"
