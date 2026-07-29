#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_scratchpad"
mkdir -p "${BUILD_DIR}"

RTL_FILES=(
    rtl/memory/nce_scratchpad_bank_1r1w.sv
    rtl/memory/nce_banked_scratchpad.sv
    rtl/memory/nce_tensor_scratchpad.sv
)

echo "===== Icarus tensor-scratchpad compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_scratchpad \
    -o "${BUILD_DIR}/tb_nce_tensor_scratchpad.vvp" \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_tensor_scratchpad.sv

echo "===== Tensor-scratchpad simulation ====="

vvp "${BUILD_DIR}/tb_nce_tensor_scratchpad.vvp"

echo "===== Verilator tensor-scratchpad lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_scratchpad \
    "${RTL_FILES[@]}"

echo "===== Yosys tensor-scratchpad synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_tensor_scratchpad;
        proc;
        opt;
        memory_dff;
        memory_collect;
        opt;
        check;
        stat;
    " >/dev/null

if grep -Eq \
    'Replacing memory .*data_q with list of registers' \
    "${YOSYS_LOG}"
then
    echo "ERROR: tensor scratchpad memory flattened into registers."
    exit 1
fi

if ! grep -Eq '[$]mem_v2' "${YOSYS_LOG}"
then
    echo "ERROR: no inferred tensor-scratchpad memories found."
    exit 1
fi

echo "PASS: tensor scratchpad retained inferred memories."
echo "===== All tensor-scratchpad checks completed ====="
