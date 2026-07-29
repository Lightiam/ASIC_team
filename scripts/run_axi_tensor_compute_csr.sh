#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/axi_tensor_compute_csr"
mkdir -p "${BUILD_DIR}"

echo "===== Icarus tensor-compute CSR compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_axi_tensor_compute_csr \
    -o "${BUILD_DIR}/tb_nce_axi_tensor_compute_csr.vvp" \
    rtl/bus/nce_axi_tensor_compute_csr.sv \
    tb/unit/tb_nce_axi_tensor_compute_csr.sv

echo "===== Tensor-compute CSR simulation ====="

set +e

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=2s \
    20s \
    vvp "${BUILD_DIR}/tb_nce_axi_tensor_compute_csr.vvp"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: tensor-compute CSR simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: tensor-compute CSR simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator tensor-compute CSR lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_axi_tensor_compute_csr \
    rtl/bus/nce_axi_tensor_compute_csr.sv

echo "===== Yosys tensor-compute CSR synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv rtl/bus/nce_axi_tensor_compute_csr.sv;
        hierarchy -check -top nce_axi_tensor_compute_csr;
        proc;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: tensor-compute CSR synthesis failed."
    tail -120 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eqi \
    'logic loop|multiple conflicting drivers|inferred latch' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in tensor-compute CSR."
    grep -Ei \
        'logic loop|multiple conflicting drivers|inferred latch' \
        "${YOSYS_LOG}"
    exit 1
fi

echo "PASS: tensor-compute CSR synthesized without structural errors."
echo "===== All tensor-compute CSR checks completed ====="
