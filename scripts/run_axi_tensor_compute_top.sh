#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

BUILD_DIR="build/axi_tensor_compute_top"
SIM_MDIR="${BUILD_DIR}/verilator_sim"
YOSYS_LOG="${BUILD_DIR}/yosys.log"

mkdir -p "${BUILD_DIR}" "${SIM_MDIR}" reports

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


echo "===== AXI tensor architecture source checks ====="

[[ "$(
    grep -Ec \
        '^[[:space:]]*nce_tensor_memory_subsystem[[:space:]]' \
        rtl/top/nce_axi_mixed_precision_top.sv
)" -eq 1 ]]

[[ "$(
    grep -Ec \
        '^[[:space:]]*nce_tensor_gemm_shared_client[[:space:]]' \
        rtl/top/nce_axi_mixed_precision_top.sv
)" -eq 1 ]]

[[ "$(
    grep -Ec \
        '^[[:space:]]*nce_tiled_gemm_8x8_controller[[:space:]]' \
        rtl/top/nce_axi_mixed_precision_top.sv
)" -eq 1 ]]

[[ "$(
    grep -Ec \
        '^[[:space:]]*nce_shared_systolic_gemm_4x4[[:space:]]' \
        rtl/top/nce_axi_mixed_precision_top.sv
)" -eq 1 ]]

[[ "$(
    grep -Ec \
        '^[[:space:]]*nce_tiled_gemm_8x8[[:space:]]' \
        rtl/top/nce_axi_mixed_precision_top.sv ||
    true
)" -eq 0 ]]

echo "PASS: AXI top contains one tensor-memory subsystem."
echo "PASS: AXI top contains one shared tensor client."
echo "PASS: AXI top contains one tiled controller."
echo "PASS: AXI top contains one shared physical systolic wrapper."
echo "PASS: AXI top contains no private tiled-GEMM wrapper."

echo "===== Icarus AXI tensor compilation check ====="

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=2s \
    60s \
    iverilog \
        -g2012 \
        -Wall \
        -s tb_nce_axi_tensor_compute_top \
        -o "${BUILD_DIR}/tb_nce_axi_tensor_compute_top.vvp" \
        "${RTL_FILES[@]}" \
        tb/integration/tb_nce_axi_tensor_compute_top.sv

echo "===== Verilator AXI tensor simulation build ====="

rm -rf "${SIM_MDIR}"
mkdir -p "${SIM_MDIR}"

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=5s \
    300s \
    verilator \
        --binary \
        --timing \
        --top-module tb_nce_axi_tensor_compute_top \
        --Mdir "${SIM_MDIR}" \
        -Wall \
        -Wno-fatal \
        -Wno-PINCONNECTEMPTY \
        "${RTL_FILES[@]}" \
        tb/integration/tb_nce_axi_tensor_compute_top.sv

echo "===== AXI tensor end-to-end numerical simulation ====="

set +e

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=5s \
    180s \
    "${SIM_MDIR}/Vtb_nce_axi_tensor_compute_top" \
    | tee reports/tb_nce_axi_tensor_compute_top.log

SIM_STATUS=${PIPESTATUS[0]}

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: AXI tensor numerical simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: AXI tensor numerical simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator complete AXI top lint ====="

verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_axi_mixed_precision_top \
    "${RTL_FILES[@]}"

echo "===== Yosys complete AXI top synthesis check ====="

if ! timeout \
    --foreground \
    --signal=TERM \
    --kill-after=5s \
    900s \
    yosys \
        -l "${YOSYS_LOG}" \
        -p "
            read_verilog -sv ${RTL_FILES[*]};
            hierarchy -check -top nce_axi_mixed_precision_top;
            proc;
            memory;
            opt;
            check -assert;
            stat;
        " >/dev/null
then
    echo "ERROR: complete AXI top synthesis failed or timed out."
    tail -150 "${YOSYS_LOG}" || true
    exit 1
fi

if grep -Eqi \
    'logic loop|multiple conflicting drivers|inferred latch|UNOPTFLAT' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in complete AXI tensor top."
    grep -Ei \
        'logic loop|multiple conflicting drivers|inferred latch|UNOPTFLAT' \
        "${YOSYS_LOG}"
    exit 1
fi

echo "PASS: complete AXI tensor top synthesized without structural errors."
echo "===== All AXI tensor-compute integration checks completed ====="
