#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILES=(
    rtl/core/nce_int8_dot4.sv
    rtl/core/nce_int18_to_fp32.sv

    rtl/core/nce_fp32_decode.sv
    rtl/core/nce_fp32_add_special.sv
    rtl/core/nce_fp32_align.sv
    rtl/core/nce_fp32_addsub_raw.sv
    rtl/core/nce_fp32_normalize.sv
    rtl/core/nce_fp32_round_pack.sv
    rtl/core/nce_fp32_add.sv
    rtl/core/nce_fp32_accumulator.sv

    rtl/core/nce_int8_mac_lane.sv
    rtl/core/nce_int8_simd8_mac.sv

    rtl/memory/nce_regfile_16x256.sv
    rtl/memory/nce_register_banks.sv

    rtl/control/nce_int8_command_decoder.sv

    rtl/core/nce_int8_register_mac_core.sv
    rtl/core/nce_int8_command_core.sv

    rtl/bus/nce_axi4lite_frontend.sv
    rtl/bus/nce_axi_csr_backend.sv

    rtl/top/nce_axi_int8_top.sv
)

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_axi_int8_top \
    -o build/tb_nce_axi_int8_top.vvp \
    "${RTL_FILES[@]}" \
    tb/integration/tb_nce_axi_int8_top.sv

echo "===== Complete AXI-controlled NCE simulation ====="
vvp build/tb_nce_axi_int8_top.vvp \
    | tee reports/tb_nce_axi_int8_top.log

echo "===== Verilator full-top lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_axi_int8_top \
    "${RTL_FILES[@]}"

echo "===== Yosys full-top synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_axi_int8_top;
    proc;
    memory;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_axi_int8_top.log

echo "===== All complete AXI NCE top-level checks completed ====="
