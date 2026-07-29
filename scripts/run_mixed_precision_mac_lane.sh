#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILES=(
    rtl/core/nce_int8_dot4.sv
    rtl/core/nce_int18_to_fp32.sv

    rtl/core/nce_bf16_mul_to_fp32.sv
    rtl/core/nce_bf16_dot2_to_fp32.sv

    rtl/core/nce_bf24_mul_to_fp32.sv

    rtl/core/nce_fp32_decode.sv
    rtl/core/nce_fp32_add_special.sv
    rtl/core/nce_fp32_align.sv
    rtl/core/nce_fp32_addsub_raw.sv
    rtl/core/nce_fp32_normalize.sv
    rtl/core/nce_fp32_round_pack.sv
    rtl/core/nce_fp32_add.sv
    rtl/core/nce_fp32_accumulator.sv

    rtl/core/nce_mixed_precision_mac_lane.sv
)

echo "===== Check Python references ====="
python3 -m py_compile \
    scripts/gen_bf16_mul_vectors.py \
    scripts/gen_bf24_mul_vectors.py \
    scripts/gen_fp32_add_vectors.py \
    scripts/gen_bf16_dot2_vectors.py \
    scripts/gen_mixed_precision_mac_lane_vectors.py

echo "===== Generate mixed-precision vectors ====="
python3 scripts/gen_mixed_precision_mac_lane_vectors.py \
    --output build/mixed_precision_mac_lane_vectors.txt \
    --random-count 12000

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_mixed_precision_mac_lane \
    -o build/tb_nce_mixed_precision_mac_lane.vvp \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_mixed_precision_mac_lane.sv

echo "===== Mixed-precision MAC simulation ====="
vvp build/tb_nce_mixed_precision_mac_lane.vvp \
    | tee reports/tb_nce_mixed_precision_mac_lane.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_mixed_precision_mac_lane \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_mixed_precision_mac_lane;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_mixed_precision_mac_lane.log

echo "===== All mixed-precision MAC lane checks completed ====="
