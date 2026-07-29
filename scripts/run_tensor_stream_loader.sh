#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_stream_loader"
mkdir -p "${BUILD_DIR}"

RTL_FILES=(
    rtl/memory/nce_scratchpad_bank_1r1w.sv
    rtl/memory/nce_banked_scratchpad.sv
    rtl/memory/nce_tensor_scratchpad.sv
    rtl/memory/nce_tensor_stream_loader.sv
    rtl/memory/nce_tensor_loader_scratchpad.sv
)

echo "===== Icarus tensor-stream-loader compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_stream_loader \
    -o "${BUILD_DIR}/tb_nce_tensor_stream_loader.vvp" \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_tensor_stream_loader.sv

echo "===== Tensor-stream-loader simulation ====="

vvp "${BUILD_DIR}/tb_nce_tensor_stream_loader.vvp"

echo "===== Verilator tensor-stream-loader lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_stream_loader \
    rtl/memory/nce_tensor_stream_loader.sv

echo "===== Verilator integrated-loader lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_loader_scratchpad \
    "${RTL_FILES[@]}"

echo "===== Yosys integrated-loader synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_tensor_loader_scratchpad;
        proc;
        opt;
        memory_dff;
        memory_collect;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: Yosys loader-subsystem synthesis failed."
    tail -100 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eq \
    'Replacing memory .*data_q with list of registers' \
    "${YOSYS_LOG}"
then
    echo "ERROR: loader scratchpad was flattened into registers."
    exit 1
fi

if ! grep -Eq '[$]mem_v2' "${YOSYS_LOG}"
then
    echo "ERROR: no inferred loader-scratchpad memories found."
    exit 1
fi

echo "PASS: loader subsystem retained inferred memories."
echo "===== All tensor-stream-loader checks completed ====="
