#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Icarus compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_int8_dot4 \
    -o build/tb_nce_int8_dot4.vvp \
    rtl/core/nce_int8_dot4.sv \
    tb/unit/tb_nce_int8_dot4.sv

echo "===== Simulation ====="

vvp build/tb_nce_int8_dot4.vvp \
    | tee reports/tb_nce_int8_dot4.log

echo "===== Verilator lint ====="

verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_int8_dot4 \
    rtl/core/nce_int8_dot4.sv

echo "===== Test completed ====="
