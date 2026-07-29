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
    rtl/core/nce_systolic_pe.sv
    rtl/core/nce_systolic_array_4x4.sv
    rtl/core/nce_systolic_gemm_4x4.sv
)

TB_FILE="tb/integration/tb_nce_systolic_gemm_4x4.sv"

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_systolic_gemm_4x4 \
    -o build/tb_nce_systolic_gemm_4x4.vvp \
    "${RTL_FILES[@]}" \
    "${TB_FILE}"

echo "===== Autonomous native 4x4 systolic GEMM simulation ====="
vvp build/tb_nce_systolic_gemm_4x4.vvp \
    | tee reports/tb_nce_systolic_gemm_4x4.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_systolic_gemm_4x4 \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_systolic_gemm_4x4;
    proc;
    memory;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_systolic_gemm_4x4.log

echo "===== All autonomous systolic-GEMM checks completed ====="
