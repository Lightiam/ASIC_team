#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILES=(
    rtl/core/nce_bf16_mul_to_fp32.sv

    rtl/core/nce_fp32_decode.sv
    rtl/core/nce_fp32_add_special.sv
    rtl/core/nce_fp32_align.sv
    rtl/core/nce_fp32_addsub_raw.sv
    rtl/core/nce_fp32_normalize.sv
    rtl/core/nce_fp32_round_pack.sv
    rtl/core/nce_fp32_add.sv

    rtl/core/nce_bf16_dot2_to_fp32.sv
)

echo "===== Check Python references ====="
python3 -m py_compile \
    scripts/gen_bf16_mul_vectors.py \
    scripts/gen_fp32_add_vectors.py \
    scripts/gen_bf16_dot2_vectors.py

echo "===== Generate BF16X2 DOT2 vectors ====="
python3 scripts/gen_bf16_dot2_vectors.py \
    --output build/bf16_dot2_vectors.txt \
    --random-count 100000

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_bf16_dot2_to_fp32 \
    -o build/tb_nce_bf16_dot2_to_fp32.vvp \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_bf16_dot2_to_fp32.sv

echo "===== BF16X2 DOT2 simulation ====="
vvp build/tb_nce_bf16_dot2_to_fp32.vvp \
    | tee reports/tb_nce_bf16_dot2_to_fp32.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_bf16_dot2_to_fp32 \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_bf16_dot2_to_fp32;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_bf16_dot2_to_fp32.log

echo "===== All BF16X2 DOT2 checks completed ====="
