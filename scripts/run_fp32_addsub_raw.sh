#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate FP32 raw arithmetic vectors ====="
python3 scripts/gen_fp32_addsub_raw_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_fp32_addsub_raw \
    -o build/tb_nce_fp32_addsub_raw.vvp \
    rtl/core/nce_fp32_decode.sv \
    rtl/core/nce_fp32_align.sv \
    rtl/core/nce_fp32_addsub_raw.sv \
    tb/integration/tb_nce_fp32_addsub_raw.sv

echo "===== Simulation ====="
vvp build/tb_nce_fp32_addsub_raw.vvp \
    | tee reports/tb_nce_fp32_addsub_raw.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_fp32_addsub_raw \
    rtl/core/nce_fp32_addsub_raw.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_fp32_addsub_raw.sv;
    hierarchy -check -top nce_fp32_addsub_raw;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_fp32_addsub_raw.log

echo "===== All FP32 raw arithmetic checks completed ====="
