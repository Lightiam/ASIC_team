#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_axi4lite_frontend \
    -o build/tb_nce_axi4lite_frontend.vvp \
    rtl/bus/nce_axi4lite_frontend.sv \
    tb/unit/tb_nce_axi4lite_frontend.sv

echo "===== AXI4-Lite protocol simulation ====="
vvp build/tb_nce_axi4lite_frontend.vvp \
    | tee reports/tb_nce_axi4lite_frontend.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_axi4lite_frontend \
    rtl/bus/nce_axi4lite_frontend.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/bus/nce_axi4lite_frontend.sv;
    hierarchy -check -top nce_axi4lite_frontend;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_axi4lite_frontend.log

echo "===== All AXI4-Lite frontend checks completed ====="
