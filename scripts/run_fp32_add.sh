#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILES=(
    rtl/core/nce_fp32_decode.sv
    rtl/core/nce_fp32_add_special.sv
    rtl/core/nce_fp32_align.sv
    rtl/core/nce_fp32_addsub_raw.sv
    rtl/core/nce_fp32_normalize.sv
    rtl/core/nce_fp32_round_pack.sv
    rtl/core/nce_fp32_add.sv
)

echo "===== Generate complete FP32 addition vectors ====="
python3 scripts/gen_fp32_add_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_fp32_add \
    -o build/tb_nce_fp32_add.vvp \
    "${RTL_FILES[@]}" \
    tb/integration/tb_nce_fp32_add.sv

echo "===== Complete FP32 addition simulation ====="
vvp build/tb_nce_fp32_add.vvp \
    | tee reports/tb_nce_fp32_add.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_fp32_add \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_fp32_add;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_fp32_add.log

echo "===== All complete FP32 adder checks completed ====="
