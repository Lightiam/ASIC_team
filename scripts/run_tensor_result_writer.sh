#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_result_writer"
mkdir -p "${BUILD_DIR}"

RTL_FILE="rtl/memory/nce_tensor_result_writer.sv"
TB_FILE="tb/unit/tb_nce_tensor_result_writer.sv"

echo "===== Icarus tensor-result-writer compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_result_writer \
    -o "${BUILD_DIR}/tb_nce_tensor_result_writer.vvp" \
    "${RTL_FILE}" \
    "${TB_FILE}"

echo "===== Tensor-result-writer simulation ====="

set +e

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=2s \
    20s \
    vvp "${BUILD_DIR}/tb_nce_tensor_result_writer.vvp"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: tensor-result-writer simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: tensor-result-writer simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator tensor-result-writer lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_result_writer \
    "${RTL_FILE}"

echo "===== Yosys tensor-result-writer synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILE};
        hierarchy -check -top nce_tensor_result_writer;
        proc;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: Yosys tensor-result-writer synthesis failed."
    tail -100 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eqi \
    'logic loop|multiple conflicting drivers|inferred latch' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in tensor result writer."
    grep -Ei \
        'logic loop|multiple conflicting drivers|inferred latch' \
        "${YOSYS_LOG}"
    exit 1
fi

echo "PASS: tensor result writer synthesized without structural errors."
echo "===== All tensor-result-writer checks completed ====="
