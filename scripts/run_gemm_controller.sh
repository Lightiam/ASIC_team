#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

RTL_FILE="rtl/control/nce_gemm_controller.sv"
TB_FILE="tb/unit/tb_nce_gemm_controller.sv"

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_gemm_controller \
    -o build/tb_nce_gemm_controller.vvp \
    "${RTL_FILE}" \
    "${TB_FILE}"

echo "===== GEMM controller simulation ====="
vvp build/tb_nce_gemm_controller.vvp \
    | tee reports/tb_nce_gemm_controller.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_gemm_controller \
    "${RTL_FILE}"

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv ${RTL_FILE};
    hierarchy -check -top nce_gemm_controller;
    proc;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_gemm_controller.log

echo "===== All GEMM controller checks completed ====="
