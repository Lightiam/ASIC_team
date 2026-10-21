#!/usr/bin/env bash
# Gap-fix suites: the modules written to close the holes the architecture
# audit found.
#
#   Layer 1   models/l1_diamond_thermal.py        CVD diamond heat spreader
#   Layer 20  sw/shim/lrai_transport_loopback.py  opt-in loopback transport
#   Layer 21  sw/fabric/l21_memory_pool.py        disaggregated memory pool
#
# The Layer 2 SerDes stub is an RTL suite and runs from run_stack_layers.sh
# with the other Verilog.
#
# As with run_photonics.sh, a missing dependency is a FAILURE and not a
# skip. A skipped check and a passing check look identical in a summary
# line, and that is how ungated code stays ungated.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python

pass=0
fail=0

run_one () {
    local dir="$1"
    local test="$2"
    echo "===== ${test} ====="
    if [ ! -f "${PROJECT_ROOT}/${dir}/${test}" ]; then
        echo "MISSING: ${dir}/${test}"
        fail=$((fail + 1))
        return
    fi
    local out
    out="$(mktemp)"
    # Status comes from the interpreter, never from a pipeline: piping into
    # tail would report every suite as passing whatever its exit code.
    ( cd "${PROJECT_ROOT}/${dir}" && "$PY" "$test" ) > "$out" 2>&1
    local rc=$?
    tail -4 "$out"
    rm -f "$out"
    if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1))
    else
        echo "FAILED: ${test} exited ${rc}"
        fail=$((fail + 1))
    fi
}

run_one models   l1_diamond_thermal.py
run_one sw/fabric test_l21_memory_pool.py
run_one sw/shim   test_lrai_transport_loopback.py
run_one phy       phy_requirements.py

echo "===== gap-fix suites: ${pass} passed, ${fail} failed ====="
[ "$fail" -eq 0 ]
