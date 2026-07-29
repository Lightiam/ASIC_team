#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate FP32 special-case vectors ====="
python3 scripts/gen_fp32_add_special_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_fp32_add_special \
    -o build/tb_nce_fp32_add_special.vvp \
    rtl/core/nce_fp32_add_special.sv \
    tb/unit/tb_nce_fp32_add_special.sv

echo "===== Simulation ====="
vvp build/tb_nce_fp32_add_special.vvp \
    | tee reports/tb_nce_fp32_add_special.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_fp32_add_special \
    rtl/core/nce_fp32_add_special.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_fp32_add_special.sv;
    hierarchy -check -top nce_fp32_add_special;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_fp32_add_special.log

echo "===== All FP32 special-case checks completed ====="
