#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate exhaustive reference vectors ====="
python3 scripts/gen_int18_to_fp32_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_int18_to_fp32 \
    -o build/tb_nce_int18_to_fp32.vvp \
    rtl/core/nce_int18_to_fp32.sv \
    tb/unit/tb_nce_int18_to_fp32.sv

echo "===== Exhaustive simulation ====="
vvp build/tb_nce_int18_to_fp32.vvp \
    | tee reports/tb_nce_int18_to_fp32.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_int18_to_fp32 \
    rtl/core/nce_int18_to_fp32.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_int18_to_fp32.sv;
    hierarchy -check -top nce_int18_to_fp32;
    proc;
    opt;
    check -assert;
    stat
" | tee reports/yosys_nce_int18_to_fp32.log

echo "===== All checks completed ====="
