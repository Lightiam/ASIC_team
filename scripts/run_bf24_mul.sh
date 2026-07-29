#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILE="rtl/core/nce_bf24_mul_to_fp32.sv"
TB_FILE="tb/unit/tb_nce_bf24_mul_to_fp32.sv"

echo "===== Check Python generator ====="
python3 -m py_compile \
    scripts/gen_bf24_mul_vectors.py

echo "===== Generate BF24 multiplication vectors ====="
python3 scripts/gen_bf24_mul_vectors.py \
    --output build/bf24_mul_vectors.txt

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_bf24_mul_to_fp32 \
    -o build/tb_nce_bf24_mul_to_fp32.vvp \
    "${RTL_FILE}" \
    "${TB_FILE}"

echo "===== BF24 multiplier simulation ====="
vvp build/tb_nce_bf24_mul_to_fp32.vvp \
    | tee reports/tb_nce_bf24_mul_to_fp32.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_bf24_mul_to_fp32 \
    "${RTL_FILE}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILE};
    hierarchy -check -top nce_bf24_mul_to_fp32;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_bf24_mul_to_fp32.log

echo "===== All BF24 multiplier checks completed ====="
