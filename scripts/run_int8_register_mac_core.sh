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

    rtl/core/nce_int8_register_mac_core.sv
)

echo "===== Check Python generator ====="
python3 -m py_compile \
    scripts/gen_int8_register_mac_core_vectors.py

echo "===== Generate register-to-MAC vectors ====="
python3 scripts/gen_int8_register_mac_core_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_int8_register_mac_core \
    -o build/tb_nce_int8_register_mac_core.vvp \
    "${RTL_FILES[@]}" \
    tb/integration/tb_nce_int8_register_mac_core.sv

echo "===== Register-to-MAC integration simulation ====="
vvp build/tb_nce_int8_register_mac_core.vvp \
    | tee reports/tb_nce_int8_register_mac_core.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_int8_register_mac_core \
    "${RTL_FILES[@]}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILES[*]};
    hierarchy -check -top nce_int8_register_mac_core;
    proc;
    memory;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_int8_register_mac_core.log

echo "===== All register-to-MAC checks completed ====="
