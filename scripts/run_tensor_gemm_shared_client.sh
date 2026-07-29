#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_gemm_shared_client"
mkdir -p "${BUILD_DIR}"

RTL_FILES=(
    rtl/memory/nce_tensor_pair_reader.sv
    rtl/memory/nce_tensor_gemm_feeder.sv
    rtl/memory/nce_tensor_result_writer.sv
    rtl/core/nce_tensor_gemm_shared_client.sv
)

echo "===== Icarus shared tensor-client compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s nce_tensor_gemm_shared_client \
    -o "${BUILD_DIR}/nce_tensor_gemm_shared_client.vvp" \
    "${RTL_FILES[@]}"

echo "===== Verilator shared tensor-client lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_gemm_shared_client \
    "${RTL_FILES[@]}"

echo "===== Yosys shared tensor-client synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_tensor_gemm_shared_client;
        proc;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: shared tensor-client synthesis failed."
    tail -120 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eqi \
    'logic loop|multiple conflicting drivers|inferred latch' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in shared tensor client."
    grep -Ei \
        'logic loop|multiple conflicting drivers|inferred latch' \
        "${YOSYS_LOG}"
    exit 1
fi

if grep -Eq \
    'nce_tiled_gemm_8x8|nce_systolic_gemm_4x4' \
    "${YOSYS_LOG}"
then
    echo "ERROR: shared tensor client unexpectedly retained a private GEMM engine."
    grep -En \
        'nce_tiled_gemm_8x8|nce_systolic_gemm_4x4' \
        "${YOSYS_LOG}"
    exit 1
fi

echo "PASS: shared tensor client contains no private GEMM engine."
echo "PASS: shared tensor client synthesized without structural errors."
echo "===== All shared tensor-client checks completed ====="
