#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_axi_csr_backend \
    -o build/tb_nce_axi_csr_backend.vvp \
    rtl/bus/nce_axi_csr_backend.sv \
    tb/unit/tb_nce_axi_csr_backend.sv

echo "===== AXI CSR backend simulation ====="
vvp build/tb_nce_axi_csr_backend.vvp \
    | tee reports/tb_nce_axi_csr_backend.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_axi_csr_backend \
    rtl/bus/nce_axi_csr_backend.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/bus/nce_axi_csr_backend.sv;
    hierarchy -check -top nce_axi_csr_backend;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_axi_csr_backend.log

echo "===== All AXI CSR backend checks completed ====="
