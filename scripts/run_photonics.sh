#!/usr/bin/env bash
# Photonic model suites -- stack layers 1 to 7.
#
# These layers were previously ungated. The models are the only evidence the
# project has for its optical claims, and nothing ran them automatically, so
# any of them could have broken silently between commits. They are physics
# calculators rather than hardware drivers, which is exactly why a
# regression matters: a wrong number here is invisible until someone quotes
# it in a deck.
#
# Layer 1 (PDN) and layer 6 (memristive crossbar) shell out to ngspice,
# which is present in the iic-osic-tools container. The rest need only
# numpy. A suite that cannot find its dependency is reported as a FAILURE,
# not skipped quietly -- a skipped check and a passing check look identical
# in a summary line, and that is how ungated code stays ungated.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}/photonics"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python

SUITES=(
    test_l01_pdn.py
    test_l02_l04.py
    test_l03_laser.py
    test_l05_mzi_mesh.py
    test_l06_crossbar.py
    test_l07_receiver.py
)

pass=0
fail=0

for t in "${SUITES[@]}"; do
    echo "===== ${t} ====="
    if [ ! -f "$t" ]; then
        echo "MISSING: ${t}"
        fail=$((fail + 1))
        continue
    fi
    # Status comes from the interpreter, not from a pipeline. Piping into
    # tail would make every suite look successful regardless of its exit
    # code, which is the same mistake that hid a crashed board build.
    out="$(mktemp)"
    "$PY" "$t" > "$out" 2>&1
    rc=$?
    tail -3 "$out"
    rm -f "$out"
    if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1))
    else
        echo "FAILED: ${t} exited ${rc}"
        fail=$((fail + 1))
    fi
done

echo "===== photonic model suites: ${pass} passed, ${fail} failed ====="
[ "$fail" -eq 0 ]
