#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILES=(
    # Register banks
    rtl/memory/nce_regfile_16x256.sv
    rtl/memory/nce_register_banks.sv

    # INT8 arithmetic
    rtl/core/nce_int8_dot4.sv
    rtl/core/nce_int18_to_fp32.sv

    # BF16 arithmetic
    rtl/core/nce_bf16_mul_to_fp32.sv
    rtl/core/nce_bf16_dot2_to_fp32.sv

    # BF24 arithmetic
    rtl/core/nce_bf24_mul_to_fp32.sv

    # Shared FP32 accumulation
    rtl/core/nce_fp32_decode.sv
    rtl/core/nce_fp32_add_special.sv
    rtl/core/nce_fp32_align.sv
    rtl/core/nce_fp32_addsub_raw.sv
    rtl/core/nce_fp32_normalize.sv
    rtl/core/nce_fp32_round_pack.sv
    rtl/core/nce_fp32_add.sv
    rtl/core/nce_fp32_accumulator.sv

    # SIMD execution
    rtl/core/nce_mixed_precision_mac_lane.sv
    rtl/core/nce_mixed_precision_simd8_mac.sv
    rtl/core/nce_mixed_precision_register_mac_core.sv

    # Command control
    rtl/control/nce_mixed_precision_command_decoder.sv
    rtl/core/nce_mixed_precision_command_core.sv

    # GEMM control and integration
    rtl/control/nce_gemm_controller.sv
    rtl/core/nce_gemm_command_core.sv
)

TB_FILE="tb/integration/tb_nce_gemm_command_core.sv"

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_gemm_command_core \
    -o build/tb_nce_gemm_command_core.vvp \
    "${RTL_FILES[@]}" \
    "${TB_FILE}"

echo "===== GEMM command-core integration simulation ====="
vvp build/tb_nce_gemm_command_core.vvp \
    | tee reports/tb_nce_gemm_command_core.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_gemm_command_core \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_gemm_command_core;
    proc;
    memory;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_gemm_command_core.log

echo "===== All GEMM command-core checks completed ====="
