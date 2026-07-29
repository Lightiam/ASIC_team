#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/axi_conv3x3_csr"
mkdir -p "${BUILD_DIR}"

echo "===== Icarus convolution-CSR compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_axi_conv3x3_csr \
    -o "${BUILD_DIR}/tb_nce_axi_conv3x3_csr.vvp" \
    rtl/bus/nce_axi_conv3x3_csr.sv \
    tb/unit/tb_nce_axi_conv3x3_csr.sv

echo "===== Convolution-CSR simulation ====="

vvp "${BUILD_DIR}/tb_nce_axi_conv3x3_csr.vvp"

echo "===== Verilator convolution-CSR lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_axi_conv3x3_csr \
    rtl/bus/nce_axi_conv3x3_csr.sv

echo "===== Yosys convolution-CSR synthesis check ====="

yosys -q -p "
    read_verilog -sv rtl/bus/nce_axi_conv3x3_csr.sv;
    hierarchy -check -top nce_axi_conv3x3_csr;
    proc;
    opt;
    check;
"

echo "===== All convolution-CSR checks completed ====="
