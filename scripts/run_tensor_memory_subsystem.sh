#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_memory_subsystem"
mkdir -p "${BUILD_DIR}"

RTL_FILES=(
    rtl/memory/nce_scratchpad_bank_1r1w.sv
    rtl/memory/nce_banked_scratchpad.sv
    rtl/memory/nce_tensor_scratchpad.sv
    rtl/memory/nce_tensor_stream_loader.sv
    rtl/memory/nce_tensor_memory_subsystem.sv
)

echo "===== Icarus tensor-memory-subsystem compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_memory_subsystem \
    -o "${BUILD_DIR}/tb_nce_tensor_memory_subsystem.vvp" \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_tensor_memory_subsystem.sv

echo "===== Verilator tensor-memory-subsystem simulation build ====="

SIM_MDIR="${BUILD_DIR}/verilator_sim"
rm -rf "${SIM_MDIR}"

verilator \
    --binary \
    --timing \
    --Wall \
    -Wno-fatal \
    --top-module tb_nce_tensor_memory_subsystem \
    --Mdir "${SIM_MDIR}" \
    "${RTL_FILES[@]}" \
    tb/unit/tb_nce_tensor_memory_subsystem.sv

echo "===== Tensor-memory-subsystem simulation ====="

set +e

timeout --foreground --signal=TERM --kill-after=2s 30s \
    "${SIM_MDIR}/Vtb_nce_tensor_memory_subsystem"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: tensor-memory-subsystem simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: tensor-memory-subsystem simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator tensor-memory-subsystem lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    --top-module nce_tensor_memory_subsystem \
    "${RTL_FILES[@]}"

echo "===== Yosys tensor-memory-subsystem synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_tensor_memory_subsystem;
        proc;
        opt;
        memory_dff;
        memory_collect;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: Yosys tensor-memory-subsystem synthesis failed."
    tail -100 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eq \
    'Replacing memory .*data_q with list of registers' \
    "${YOSYS_LOG}"
then
    echo "ERROR: tensor memory was flattened into registers."
    exit 1
fi

MEMORY_CELL_COUNT="$(
    grep -E '[$]mem_v2[[:space:]]+[0-9]+' \
        "${YOSYS_LOG}" \
        | tail -1 \
        | awk '{print $2}'
)"

if [[ -z "${MEMORY_CELL_COUNT}" ]]; then
    echo "ERROR: no inferred tensor memories found."
    exit 1
fi

if (( MEMORY_CELL_COUNT < 48 )); then
    echo "ERROR: expected at least 48 inferred byte memories; found ${MEMORY_CELL_COUNT}."
    exit 1
fi

echo "PASS: subsystem retained ${MEMORY_CELL_COUNT} inferred memory cells."
echo "===== All tensor-memory-subsystem checks completed ====="
