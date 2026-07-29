#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILE="rtl/control/nce_mixed_precision_command_decoder.sv"
TB_FILE="tb/unit/tb_nce_mixed_precision_command_decoder.sv"

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_mixed_precision_command_decoder \
    -o build/tb_nce_mixed_precision_command_decoder.vvp \
    "${RTL_FILE}" \
    "${TB_FILE}"

echo "===== Mixed-precision command-decoder simulation ====="
vvp build/tb_nce_mixed_precision_command_decoder.vvp \
    | tee reports/tb_nce_mixed_precision_command_decoder.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_mixed_precision_command_decoder \
    "${RTL_FILE}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILE};
    hierarchy -check -top nce_mixed_precision_command_decoder;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_mixed_precision_command_decoder.log

echo "===== All mixed-precision command-decoder checks completed ====="
