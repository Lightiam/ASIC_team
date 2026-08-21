#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Simulation and Verification runner for tt_um_nce_neural_engine
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${ROOT_DIR}/build"
REPORTS_DIR="${ROOT_DIR}/reports"

mkdir -p "${BUILD_DIR}" "${REPORTS_DIR}"

echo "===== Compiling Tiny Tapeout NCE Top Level with Icarus Verilog ====="
iverilog -g2012 -Wall \
    -I "${ROOT_DIR}/rtl/pkg" \
    -s tb_tt_um_nce_neural_engine \
    -o "${BUILD_DIR}/tb_tt_um_nce_neural_engine.vvp" \
    "${ROOT_DIR}/rtl/pkg/nce_pkg.sv" \
    "${ROOT_DIR}/rtl/core/nce_int8_dot4.sv" \
    "${ROOT_DIR}/rtl/core/nce_int18_to_fp32.sv" \
    "${ROOT_DIR}/rtl/core/nce_int8_dot4_fp32.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_decode.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_align.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_addsub_raw.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_normalize.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_round_pack.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_add.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_add_special.sv" \
    "${ROOT_DIR}/rtl/core/nce_fp32_accumulator.sv" \
    "${ROOT_DIR}/rtl/core/nce_int8_mac_lane.sv" \
    "${ROOT_DIR}/rtl/core/nce_int8_simd8_mac.sv" \
    "${ROOT_DIR}/rtl/memory/nce_regfile_16x256.sv" \
    "${ROOT_DIR}/rtl/memory/nce_register_banks.sv" \
    "${ROOT_DIR}/rtl/core/nce_int8_register_mac_core.sv" \
    "${ROOT_DIR}/rtl/control/nce_int8_command_decoder.sv" \
    "${ROOT_DIR}/rtl/core/nce_int8_command_core.sv" \
    "${ROOT_DIR}/rtl/bus/nce_axi4lite_frontend.sv" \
    "${ROOT_DIR}/rtl/bus/nce_axi_csr_backend.sv" \
    "${ROOT_DIR}/rtl/top/nce_axi_int8_top.sv" \
    "${ROOT_DIR}/rtl/top/tt_um_nce_neural_engine.sv" \
    "${ROOT_DIR}/tb/unit/tb_tt_um_nce_neural_engine.sv"

echo "===== Running Simulation ====="
vvp "${BUILD_DIR}/tb_tt_um_nce_neural_engine.vvp" | tee "${REPORTS_DIR}/tb_tt_um_nce_neural_engine.log"

echo "===== Tiny Tapeout Simulation Completed Successfully ====="
