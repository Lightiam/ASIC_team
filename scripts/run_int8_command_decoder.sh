#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Check Python generator ====="
python3 -m py_compile \
    scripts/gen_int8_command_decoder_vectors.py

echo "===== Generate exhaustive decoder vectors ====="
python3 scripts/gen_int8_command_decoder_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_int8_command_decoder \
    -o build/tb_nce_int8_command_decoder.vvp \
    rtl/control/nce_int8_command_decoder.sv \
    tb/unit/tb_nce_int8_command_decoder.sv

echo "===== Command-decoder simulation ====="
vvp build/tb_nce_int8_command_decoder.vvp \
    | tee reports/tb_nce_int8_command_decoder.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_int8_command_decoder \
    rtl/control/nce_int8_command_decoder.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/control/nce_int8_command_decoder.sv;
    hierarchy -check -top nce_int8_command_decoder;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_int8_command_decoder.log

echo "===== All command-decoder checks completed ====="
