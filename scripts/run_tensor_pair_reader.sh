#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_pair_reader"
mkdir -p "${BUILD_DIR}"

RTL_FILE="rtl/memory/nce_tensor_pair_reader.sv"
TB_FILE="tb/unit/tb_nce_tensor_pair_reader.sv"

echo "===== Icarus tensor-pair-reader compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_pair_reader \
    -o "${BUILD_DIR}/tb_nce_tensor_pair_reader.vvp" \
    "${RTL_FILE}" \
    "${TB_FILE}"

echo "===== Tensor-pair-reader simulation ====="

set +e

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=2s \
    15s \
    vvp "${BUILD_DIR}/tb_nce_tensor_pair_reader.vvp"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: tensor-pair-reader simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: tensor-pair-reader simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator tensor-pair-reader lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_pair_reader \
    "${RTL_FILE}"

echo "===== Yosys tensor-pair-reader synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILE};
        hierarchy -check -top nce_tensor_pair_reader;
        proc;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: Yosys tensor-pair-reader synthesis failed."
    tail -100 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eq \
    'found logic loop|multiple conflicting drivers|Warning:.*latch' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in tensor pair reader."
    grep -Ei \
        'logic loop|multiple conflicting drivers|latch' \
        "${YOSYS_LOG}"
    exit 1
fi

echo "PASS: tensor pair reader synthesized without structural errors."
echo "===== All tensor-pair-reader checks completed ====="
