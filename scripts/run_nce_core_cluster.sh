#!/usr/bin/env bash
# Integration check for the stack-layer core cluster.
#
# Elaborates and synthesises the cluster that wires Layers 8, 9 and 12 plus
# the token-selection block behind one control/status interface, and enforces
# the same structural gates the rest of the suite uses.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

BUILD_DIR="build/nce_core_cluster"
YOSYS_LOG="${BUILD_DIR}/yosys.log"
mkdir -p "${BUILD_DIR}" reports

RTL_FILES=(
    rtl/ternary/nce_ternary_pkg.sv
    rtl/ternary/nce_ternary_dot16.sv
    rtl/spiking/nce_lif_dispatcher.sv
    rtl/collective/nce_abfp_pkg.sv
    rtl/collective/nce_abfp_align.sv
    rtl/collective/nce_collective_alu.sv
    rtl/gen/nce_neural_gen_loop.sv
    rtl/top/nce_core_cluster.sv
)

echo "===== Icarus cluster compilation ====="
timeout --foreground --signal=TERM --kill-after=5s 300s \
    iverilog -g2012 -s nce_core_cluster -o "${BUILD_DIR}/cluster.vvp" "${RTL_FILES[@]}"

echo "===== Verilator cluster lint ====="
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
    --top-module nce_core_cluster "${RTL_FILES[@]}"

echo "===== Yosys cluster synthesis check ====="
if ! timeout --foreground --signal=TERM --kill-after=5s 900s \
    yosys -l "${YOSYS_LOG}" -p "
        read_verilog -sv ${RTL_FILES[*]};
        hierarchy -check -top nce_core_cluster;
        proc;
        memory;
        opt;
        check -assert;
        stat;
    " >/dev/null
then
    echo "ERROR: cluster synthesis failed or timed out."
    tail -80 "${YOSYS_LOG}" || true
    exit 1
fi

if grep -Eqi 'logic loop|multiple conflicting drivers|Warning:.*latch|UNOPTFLAT' "${YOSYS_LOG}"
then
    echo "ERROR: structural issue detected in the core cluster."
    grep -Ei 'logic loop|multiple conflicting drivers|Warning:.*latch|UNOPTFLAT' "${YOSYS_LOG}"
    exit 1
fi

echo "===== Submodule presence checks ====="
for m in nce_ternary_dot16 nce_lif_dispatcher nce_abfp_align \
         nce_collective_alu nce_neural_gen_loop; do
    if ! grep -Eq "^[[:space:]]*${m}[[:space:]]" rtl/top/nce_core_cluster.sv; then
        echo "ERROR: ${m} is not instantiated in the cluster."
        exit 1
    fi
    echo "PASS: ${m} instantiated."
done

echo "PASS: core cluster elaborated and synthesised without structural errors."
echo "===== All core-cluster integration checks completed ====="
