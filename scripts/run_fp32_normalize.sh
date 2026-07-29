#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate FP32 normalization vectors ====="
python3 scripts/gen_fp32_normalize_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_fp32_normalize \
    -o build/tb_nce_fp32_normalize.vvp \
    rtl/core/nce_fp32_decode.sv \
    rtl/core/nce_fp32_align.sv \
    rtl/core/nce_fp32_addsub_raw.sv \
    rtl/core/nce_fp32_normalize.sv \
    tb/integration/tb_nce_fp32_normalize.sv

echo "===== Simulation ====="
vvp build/tb_nce_fp32_normalize.vvp \
    | tee reports/tb_nce_fp32_normalize.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_fp32_normalize \
    rtl/core/nce_fp32_normalize.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_fp32_normalize.sv;
    hierarchy -check -top nce_fp32_normalize;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_fp32_normalize.log

echo "===== All FP32 normalization checks completed ====="
