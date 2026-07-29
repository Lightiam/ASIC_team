#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tiled_gemm_client_mux"
mkdir -p "${BUILD_DIR}"

echo "===== Icarus tiled-client-mux compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tiled_gemm_client_mux \
    -o "${BUILD_DIR}/tb_nce_tiled_gemm_client_mux.vvp" \
    rtl/core/nce_tiled_gemm_client_mux.sv \
    tb/unit/tb_nce_tiled_gemm_client_mux.sv

echo "===== Tiled-client-mux simulation ====="

set +e

timeout     --foreground     --signal=TERM     --kill-after=2s     15s     vvp "${BUILD_DIR}/tb_nce_tiled_gemm_client_mux.vvp"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: tiled-client-mux simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: tiled-client-mux simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator tiled-client-mux lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tiled_gemm_client_mux \
    rtl/core/nce_tiled_gemm_client_mux.sv

echo "===== Yosys tiled-client-mux synthesis check ====="

yosys -q -p "
    read_verilog -sv rtl/core/nce_tiled_gemm_client_mux.sv;
    hierarchy -check -top nce_tiled_gemm_client_mux;
    proc;
    opt;
    check;
"

echo "===== All tiled-client-mux checks completed ====="
