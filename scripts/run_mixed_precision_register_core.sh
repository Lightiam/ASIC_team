#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

REGISTER_BANKS_FILE="$(
    grep -RIl \
        --include='*.sv' \
        'module[[:space:]]\+nce_register_banks' \
        rtl |
    head -n 1
)"

REGFILE_FILE="$(
    grep -RIl \
        --include='*.sv' \
        'module[[:space:]]\+nce_regfile_16x256' \
        rtl |
    head -n 1
)"

if [[ -z "${REGISTER_BANKS_FILE}" ]]; then
    echo "ERROR: Unable to locate module nce_register_banks."
    exit 1
fi

if [[ -z "${REGFILE_FILE}" ]]; then
    echo "ERROR: Unable to locate module nce_regfile_16x256."
    exit 1
fi

echo "Using register file : ${REGFILE_FILE}"
echo "Using register banks: ${REGISTER_BANKS_FILE}"

RTL_FILES=(
    "${REGFILE_FILE}"
    "${REGISTER_BANKS_FILE}"

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
    rtl/core/nce_mixed_precision_register_mac_core.sv
)

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_mixed_precision_register_mac_core \
    -o build/tb_nce_mixed_precision_register_mac_core.vvp \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_mixed_precision_register_mac_core.sv

echo "===== Mixed-precision register-core simulation ====="
vvp build/tb_nce_mixed_precision_register_mac_core.vvp \
    | tee reports/tb_nce_mixed_precision_register_mac_core.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_mixed_precision_register_mac_core \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_mixed_precision_register_mac_core;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_mixed_precision_register_mac_core.log

echo "===== All mixed-precision register-core checks completed ====="
