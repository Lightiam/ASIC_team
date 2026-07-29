#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_gemm_execution"
mkdir -p "${BUILD_DIR}"

mapfile -t RTL_FILES < <(
    find rtl \
        -type f \
        -name '*.sv' \
        -print \
        | sort
)

TB_FILE="tb/integration/tb_nce_tensor_gemm_execution.sv"

echo "===== Icarus tensor-GEMM-execution compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_gemm_execution \
    -o "${BUILD_DIR}/tb_nce_tensor_gemm_execution.vvp" \
    "${RTL_FILES[@]}" \
    "${TB_FILE}"

echo "===== Tensor-GEMM-execution numerical simulation ====="

set +e

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=2s \
    45s \
    vvp "${BUILD_DIR}/tb_nce_tensor_gemm_execution.vvp"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: tensor-GEMM-execution simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: tensor-GEMM-execution simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator tensor-GEMM-execution lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_tensor_gemm_execution \
    "${RTL_FILES[@]}"

echo "===== Yosys tensor-GEMM-execution synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_tensor_gemm_execution;
        proc;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: Yosys tensor-GEMM-execution synthesis failed."
    tail -120 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eqi \
    'logic loop|multiple conflicting drivers|inferred latch' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in tensor GEMM execution."
    grep -Ei \
        'logic loop|multiple conflicting drivers|inferred latch' \
        "${YOSYS_LOG}"
    exit 1
fi

echo "PASS: tensor GEMM execution synthesized without structural errors."
echo "===== All tensor-GEMM-execution checks completed ====="
