#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate FP32 decode vectors ====="
python3 scripts/gen_fp32_decode_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_fp32_decode \
    -o build/tb_nce_fp32_decode.vvp \
    rtl/core/nce_fp32_decode.sv \
    tb/unit/tb_nce_fp32_decode.sv

echo "===== Simulation ====="
vvp build/tb_nce_fp32_decode.vvp \
    | tee reports/tb_nce_fp32_decode.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_fp32_decode \
    rtl/core/nce_fp32_decode.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_fp32_decode.sv;
    hierarchy -check -top nce_fp32_decode;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_fp32_decode.log

echo "===== All FP32 decode checks completed ====="
