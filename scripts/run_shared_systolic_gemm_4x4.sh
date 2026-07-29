#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="build/shared_systolic_gemm_4x4"
mkdir -p "$BUILD_DIR"

mapfile -t RTL_SOURCES < <(
    grep -oE \
        'rtl/[A-Za-z0-9_./-]+\.sv' \
        scripts/run_axi_systolic_gemm_top.sh \
        | awk '!seen[$0]++'
)

if [[ "${#RTL_SOURCES[@]}" -eq 0 ]]; then
    echo "ERROR: could not recover the shared-engine RTL source manifest."
    exit 1
fi

echo "===== Icarus shared physical-engine compilation ====="

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=3s \
    120s \
    iverilog \
        -g2012 \
        -s tb_nce_shared_systolic_gemm_4x4 \
        -o "$BUILD_DIR/tb_nce_shared_systolic_gemm_4x4.vvp" \
        "${RTL_SOURCES[@]}" \
        tb/unit/tb_nce_shared_systolic_gemm_4x4.sv

echo "===== Shared physical-engine arbitration simulation ====="

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=3s \
    120s \
    vvp "$BUILD_DIR/tb_nce_shared_systolic_gemm_4x4.vvp"

echo "===== Verilator shared physical-engine lint ====="

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=3s \
    180s \
    verilator \
        --lint-only \
        --timing \
        -Wall \
        -Wno-fatal \
        -Wno-PINCONNECTEMPTY \
        --top-module nce_shared_systolic_gemm_4x4 \
        "${RTL_SOURCES[@]}"

echo "===== Yosys shared physical-engine synthesis check ====="

YOSYS_SOURCES="$(printf '%s ' "${RTL_SOURCES[@]}")"

timeout \
    --foreground \
    --signal=TERM \
    --kill-after=3s \
    180s \
    yosys \
        -q \
        -p "
            read_verilog -sv ${YOSYS_SOURCES};
            hierarchy -check -top nce_shared_systolic_gemm_4x4;
            proc;
            check;
        "

ENGINE_COUNT="$(
    grep -cE \
        '^[[:space:]]*nce_systolic_gemm_4x4[[:space:]]*(#|\()' \
        rtl/core/nce_shared_systolic_gemm_4x4.sv
)"

if [[ "$ENGINE_COUNT" -ne 1 ]]; then
    echo "ERROR: expected exactly one physical 4x4 GEMM instance declaration."
    echo "Observed count: $ENGINE_COUNT"
    exit 1
fi

echo "PASS: exactly one physical 4x4 GEMM instance is present."
echo "===== All shared physical-engine checks completed ====="
