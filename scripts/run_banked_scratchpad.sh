#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/banked_scratchpad"
mkdir -p "${BUILD_DIR}"

echo "===== Icarus banked-scratchpad compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_banked_scratchpad \
    -o "${BUILD_DIR}/tb_nce_banked_scratchpad.vvp" \
    rtl/memory/nce_scratchpad_bank_1r1w.sv \
    rtl/memory/nce_banked_scratchpad.sv \
    tb/unit/tb_nce_banked_scratchpad.sv

echo "===== Banked-scratchpad simulation ====="

vvp "${BUILD_DIR}/tb_nce_banked_scratchpad.vvp"

echo "===== Verilator banked-scratchpad lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_banked_scratchpad \
    rtl/memory/nce_scratchpad_bank_1r1w.sv \
    rtl/memory/nce_banked_scratchpad.sv

echo "===== Yosys banked-scratchpad synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv rtl/memory/nce_scratchpad_bank_1r1w.sv rtl/memory/nce_banked_scratchpad.sv;
        hierarchy -check -top nce_banked_scratchpad;
        proc;
        opt;
        memory_dff;
        memory_collect;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: Yosys scratchpad synthesis failed."
    tail -100 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eq \
    'Replacing memory .*data_q with list of registers' \
    "${YOSYS_LOG}"
then
    echo "ERROR: scratchpad data memory was flattened into registers."
    grep -E \
        'Replacing memory .*data_q|Number of memories|[$]dffe' \
        "${YOSYS_LOG}" \
        | tail -40
    exit 1
fi

if ! grep -Eq '[$]mem_v2|[$]mem[^a-zA-Z0-9_]' "${YOSYS_LOG}"
then
    echo "ERROR: Yosys did not report an inferred memory cell."
    grep -E \
        'Number of memories|Number of memory bits|Number of cells|[$]dffe' \
        "${YOSYS_LOG}" \
        | tail -40
    exit 1
fi

echo "PASS: scratchpad data arrays remained inferred memories."

echo "===== All banked-scratchpad checks completed ====="
