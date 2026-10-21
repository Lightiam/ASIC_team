#!/usr/bin/env bash
# Unit suites for the 22-layer stack RTL blocks.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"
mkdir -p build/stack_layers

run_one () {
    local top="$1"; shift
    local tb="tb/unit/tb_${top}.sv"
    echo "===== ${top} ====="
    iverilog -g2012 -s "tb_${top}" -o "build/stack_layers/${top}.vvp" "$@" "${tb}"
    vvp "build/stack_layers/${top}.vvp" | tail -4
}

run_one nce_ternary_dot16   rtl/ternary/nce_ternary_pkg.sv rtl/ternary/nce_ternary_dot16.sv
run_one nce_abfp_align      rtl/collective/nce_abfp_pkg.sv rtl/collective/nce_abfp_align.sv
run_one nce_collective_alu  rtl/collective/nce_collective_alu.sv
run_one nce_lif_dispatcher  rtl/spiking/nce_lif_dispatcher.sv
run_one nce_neural_gen_loop rtl/gen/nce_neural_gen_loop.sv

echo "===== All stack-layer unit suites completed ====="
