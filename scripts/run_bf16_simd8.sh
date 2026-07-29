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
    rtl/core/nce_fp32_accumulator.sv

    rtl/core/nce_bf16_dot2_mac_lane.sv
    rtl/core/nce_bf16_simd8_mac.sv
)

echo "===== Check Python generator ====="
python3 -m py_compile \
    scripts/gen_bf16_simd8_vectors.py

echo "===== Generate BF16X2 SIMD8 vectors ====="
python3 scripts/gen_bf16_simd8_vectors.py \
    --output build/bf16_simd8_vectors.txt \
    --operation-count 5000

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_bf16_simd8_mac \
    -o build/tb_nce_bf16_simd8_mac.vvp \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_bf16_simd8_mac.sv

echo "===== BF16X2 SIMD8 simulation ====="
vvp build/tb_nce_bf16_simd8_mac.vvp \
    | tee reports/tb_nce_bf16_simd8_mac.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_bf16_simd8_mac \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_bf16_simd8_mac;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_bf16_simd8_mac.log

echo "===== All BF16 SIMD8 checks completed ====="
