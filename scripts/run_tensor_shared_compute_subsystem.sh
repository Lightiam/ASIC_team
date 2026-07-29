#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

BUILD_DIR="build/tensor_shared_compute_subsystem"
mkdir -p "${BUILD_DIR}"

mapfile -t RTL_FILES < <(
    find rtl \
        -type f \
        -name '*.sv' \
        -print \
        | sort
)

TB_FILE="tb/integration/tb_nce_tensor_shared_compute_subsystem.sv"

echo "===== Shared-engine architecture source check ====="

SHARED_WRAPPER_COUNT="$(
    grep -Ec \
        '^[[:space:]]*nce_shared_systolic_gemm_4x4[[:space:]]' \
        rtl/top/nce_tensor_shared_compute_subsystem.sv
)"

PRIVATE_WRAPPER_COUNT="$(
    grep -Ec \
        '^[[:space:]]*nce_tiled_gemm_8x8[[:space:]]' \
        rtl/top/nce_tensor_shared_compute_subsystem.sv \
        || true
)"

if [[ "${SHARED_WRAPPER_COUNT}" -ne 1 ]]; then
    echo "ERROR: expected exactly one shared systolic wrapper."
    echo "Observed: ${SHARED_WRAPPER_COUNT}"
    exit 1
fi

if [[ "${PRIVATE_WRAPPER_COUNT}" -ne 0 ]]; then
    echo "ERROR: private tiled-GEMM compatibility wrapper was instantiated."
    exit 1
fi

echo "PASS: exactly one shared systolic wrapper is instantiated."
echo "PASS: no private tiled-GEMM wrapper is instantiated."

echo "===== Icarus shared tensor-compute compilation ====="

iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_tensor_shared_compute_subsystem \
    -o "${BUILD_DIR}/tb_nce_tensor_shared_compute_subsystem.vvp" \
    "${RTL_FILES[@]}" \
    "${TB_FILE}"

echo "===== Verilator shared tensor-compute simulation build ====="

SIM_MDIR="${BUILD_DIR}/verilator_sim"
rm -rf "${SIM_MDIR}"

verilator \
    --binary \
    --timing \
    --Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDSIGNAL \
    --top-module tb_nce_tensor_shared_compute_subsystem \
    --Mdir "${SIM_MDIR}" \
    "${RTL_FILES[@]}" \
    "${TB_FILE}"

echo "===== Shared-engine tensor-compute numerical simulation ====="

set +e

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=2s \
    75s \
    "${SIM_MDIR}/Vtb_nce_tensor_shared_compute_subsystem"

SIM_STATUS=$?

set -e

if [[ "${SIM_STATUS}" -eq 124 ]]; then
    echo "ERROR: shared tensor-compute simulation timed out."
    exit 1
elif [[ "${SIM_STATUS}" -ne 0 ]]; then
    echo "ERROR: shared tensor-compute simulation failed with status ${SIM_STATUS}."
    exit "${SIM_STATUS}"
fi

echo "===== Verilator shared tensor-compute lint ====="

verilator \
    --lint-only \
    --Wall \
    -Wno-fatal \
    -Wno-PINCONNECTEMPTY \
    --top-module nce_tensor_shared_compute_subsystem \
    "${RTL_FILES[@]}"

echo "===== Yosys shared tensor-compute synthesis check ====="

YOSYS_LOG="${BUILD_DIR}/yosys.log"

if ! yosys \
    -l "${YOSYS_LOG}" \
    -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_tensor_shared_compute_subsystem;
        proc;
        memory_dff;
        memory_collect;
        opt;
        check;
        stat;
    " >/dev/null
then
    echo "ERROR: shared tensor-compute synthesis failed."
    tail -160 "${YOSYS_LOG}"
    exit 1
fi

if grep -Eqi \
    'logic loop|multiple conflicting drivers|inferred latch|UNOPTFLAT' \
    "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in shared tensor compute."
    grep -Ei \
        'logic loop|multiple conflicting drivers|inferred latch|UNOPTFLAT' \
        "${YOSYS_LOG}"
    exit 1
fi

MEMORY_CELL_COUNT="$(
    awk '
        /\$mem_v2/ {
            count += $2
        }
        END {
            print count + 0
        }
    ' "${YOSYS_LOG}"
)"

if [[ "${MEMORY_CELL_COUNT}" -lt 48 ]]; then
    echo "ERROR: expected at least 48 inferred byte memories."
    echo "Observed: ${MEMORY_CELL_COUNT}"
    grep -n '\$mem_v2' "${YOSYS_LOG}" || true
    exit 1
fi

echo "PASS: retained ${MEMORY_CELL_COUNT} inferred memory cells."
echo "PASS: shared tensor compute synthesized without structural errors."
echo "===== All shared tensor-compute checks completed ====="
