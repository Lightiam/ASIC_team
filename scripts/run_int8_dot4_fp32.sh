#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Generate reference vectors ====="
python3 scripts/gen_int8_dot4_fp32_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_int8_dot4_fp32 \
    -o build/tb_nce_int8_dot4_fp32.vvp \
    rtl/core/nce_int8_dot4.sv \
    rtl/core/nce_int18_to_fp32.sv \
    rtl/core/nce_int8_dot4_fp32.sv \
    tb/integration/tb_nce_int8_dot4_fp32.sv

echo "===== Integration simulation ====="
vvp build/tb_nce_int8_dot4_fp32.vvp \
    | tee reports/tb_nce_int8_dot4_fp32.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_int8_dot4_fp32 \
    rtl/core/nce_int8_dot4.sv \
    rtl/core/nce_int18_to_fp32.sv \
    rtl/core/nce_int8_dot4_fp32.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv \
        rtl/core/nce_int8_dot4.sv \
        rtl/core/nce_int18_to_fp32.sv \
        rtl/core/nce_int8_dot4_fp32.sv;
    hierarchy -check -top nce_int8_dot4_fp32;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_int8_dot4_fp32.log

echo "===== All integration checks completed ====="
