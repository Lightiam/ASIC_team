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
    rtl/core/nce_mixed_precision_simd8_mac.sv
    rtl/memory/nce_regfile_16x256.sv
    rtl/memory/nce_register_banks.sv
    rtl/memory/nce_scratchpad_bank_1r1w.sv
    rtl/memory/nce_banked_scratchpad.sv
    rtl/memory/nce_tensor_scratchpad.sv
    rtl/memory/nce_tensor_stream_loader.sv
    rtl/memory/nce_tensor_memory_subsystem.sv
    rtl/memory/nce_tensor_pair_reader.sv
    rtl/memory/nce_tensor_gemm_feeder.sv
    rtl/memory/nce_tensor_result_writer.sv
    rtl/control/nce_mixed_precision_command_decoder.sv
    rtl/core/nce_mixed_precision_register_mac_core.sv
    rtl/core/nce_mixed_precision_command_core.sv
    rtl/core/nce_systolic_pe.sv
    rtl/core/nce_systolic_array_4x4.sv
    rtl/core/nce_systolic_gemm_4x4.sv
    rtl/core/nce_shared_systolic_gemm_4x4.sv
    rtl/core/nce_tiled_gemm_8x8_controller.sv
    rtl/core/nce_tiled_gemm_client_mux.sv
    rtl/core/nce_conv3x3_valid_4x4_int8_controller.sv
    rtl/core/nce_tensor_gemm_shared_client.sv
    rtl/core/nce_tiled_gemm_8x8.sv
    rtl/bus/nce_axi4lite_frontend.sv
    rtl/bus/nce_axi_csr_backend.sv
    rtl/bus/nce_axi_systolic_gemm_csr.sv
    rtl/bus/nce_axi_tiled_gemm_csr.sv
    rtl/bus/nce_axi_conv3x3_csr.sv
    rtl/bus/nce_axi_tensor_compute_csr.sv
    rtl/top/nce_axi_mixed_precision_top.sv
)

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_axi_mixed_precision_top \
    -o build/tb_nce_axi_mixed_precision_top.vvp \
    "${RTL_FILES[@]}" \
    tb/integration/tb_nce_axi_mixed_precision_top.sv

echo "===== AXI mixed-precision full-system simulation ====="
vvp build/tb_nce_axi_mixed_precision_top.vvp \
    | tee reports/tb_nce_axi_mixed_precision_top.log

echo "===== Verilator full-top lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_axi_mixed_precision_top \
    "${RTL_FILES[@]}"

echo "===== Yosys full-top synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_axi_mixed_precision_top;
    proc;
    memory;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_axi_mixed_precision_top.log

echo "===== All AXI mixed-precision top checks completed ====="
