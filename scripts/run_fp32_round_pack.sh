#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate exact FP32 rounding vectors ====="
python3 scripts/gen_fp32_round_pack_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_fp32_round_pack \
    -o build/tb_nce_fp32_round_pack.vvp \
    rtl/core/nce_fp32_decode.sv \
    rtl/core/nce_fp32_align.sv \
    rtl/core/nce_fp32_addsub_raw.sv \
    rtl/core/nce_fp32_normalize.sv \
    rtl/core/nce_fp32_round_pack.sv \
    tb/integration/tb_nce_fp32_round_pack.sv

echo "===== Simulation ====="
vvp build/tb_nce_fp32_round_pack.vvp \
    | tee reports/tb_nce_fp32_round_pack.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_fp32_round_pack \
    rtl/core/nce_fp32_round_pack.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_fp32_round_pack.sv;
    hierarchy -check -top nce_fp32_round_pack;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_fp32_round_pack.log

echo "===== All FP32 round-pack checks completed ====="
