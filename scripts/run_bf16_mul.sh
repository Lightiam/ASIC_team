#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Check Python generator ====="
python3 -m py_compile scripts/gen_bf16_mul_vectors.py

echo "===== Generate BF16 multiplication vectors ====="
python3 scripts/gen_bf16_mul_vectors.py \
    --output build/bf16_mul_vectors.txt \
    --random-count 250000

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_bf16_mul_to_fp32 \
    -o build/tb_nce_bf16_mul_to_fp32.vvp \
    rtl/core/nce_bf16_mul_to_fp32.sv \
    tb/unit/tb_nce_bf16_mul_to_fp32.sv

echo "===== BF16 multiplier simulation ====="
vvp build/tb_nce_bf16_mul_to_fp32.vvp \
    | tee reports/tb_nce_bf16_mul_to_fp32.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_bf16_mul_to_fp32 \
    rtl/core/nce_bf16_mul_to_fp32.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/core/nce_bf16_mul_to_fp32.sv;
    hierarchy -check -top nce_bf16_mul_to_fp32;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_bf16_mul_to_fp32.log

echo "===== All BF16 multiplier checks completed ====="
