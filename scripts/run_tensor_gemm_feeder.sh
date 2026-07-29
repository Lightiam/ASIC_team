#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_gemm_feeder"
mkdir -p "${BUILD_DIR}"

RTL_FILES=(
    rtl/memory/nce_tensor_pair_reader.sv
    rtl/memory/nce_tensor_gemm_feeder.sv
)

TB_FILE="tb/unit/tb_nce_tensor_gemm_feeder.sv"

echo "===== Icarus tensor-GEMM-feeder compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_gemm_feeder \
    -o "${BUILD_DIR}/tb_nce_tensor_gemm_feeder.vvp" \
    "${RTL_FILES[@]}" \
    "${TB_FILE}"

echo "===== Tensor-GEMM-feeder simulation ====="

set +e

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=2s \
    20s \
    vvp "${BUILD_DIR}/tb_nce_tensor_gemm_feeder.vvp"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: tensor-GEMM-feeder simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: tensor-GEMM-feeder simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator tensor-GEMM-feeder lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_gemm_feeder \
    "${RTL_FILES[@]}"

echo "===== Yosys tensor-GEMM-feeder synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_tensor_gemm_feeder;
        proc;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: Yosys tensor-GEMM-feeder synthesis failed."
    tail -100 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eqi \
    'logic loop|multiple conflicting drivers|inferred latch' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in tensor GEMM feeder."
    grep -Ei \
        'logic loop|multiple conflicting drivers|inferred latch' \
        "${YOSYS_LOG}"
    exit 1
fi

echo "PASS: tensor GEMM feeder synthesized without structural errors."
echo "===== All tensor-GEMM-feeder checks completed ====="
