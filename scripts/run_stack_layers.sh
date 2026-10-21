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

# The TFLN link had no testbench at all until now, which is the worst place
# in the repository to have had none: it is the digital half of the photonic
# bridge, and the half that the 1.6T/3.2T target is measured against.
run_one nce_tfln_link       rtl/link/nce_tfln_pkg.sv                             rtl/link/nce_tfln_serializer.sv                             rtl/link/nce_tfln_deserializer.sv

# Layer 2: the 200G PAM4 SerDes behavioural stub. It carries no bandwidth
# and is deliberately not in src/, so it cannot reach the Tiny Tapeout GDS
# path -- that build compiles exactly the three files info.yaml lists.
run_one nce_serdes_200g_stub rtl/link/nce_serdes_200g_stub.sv

echo "===== All stack-layer unit suites completed ====="
