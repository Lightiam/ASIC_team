#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate FP32 alignment vectors ====="
python3 scripts/gen_fp32_align_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_fp32_align \
    -o build/tb_nce_fp32_align.vvp \
    rtl/core/nce_fp32_decode.sv \
    rtl/core/nce_fp32_align.sv \
    tb/unit/tb_nce_fp32_align.sv

echo "===== Simulation ====="
vvp build/tb_nce_fp32_align.vvp \
    | tee reports/tb_nce_fp32_align.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_fp32_align \
    rtl/core/nce_fp32_align.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_fp32_align.sv;
    hierarchy -check -top nce_fp32_align;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_fp32_align.log

echo "===== All FP32 alignment checks completed ====="
