#!/usr/bin/env bash
# Regenerate the Dual-NCE board from nothing, in dependency order.
#
# The order is not arbitrary and the board cannot be built by running these
# in any other sequence:
#
#   1. build_board.py --no-markers   stackup, outline, design rules
#   2. add_planes.py                 zones on the 15 power/ground layers
#   3. build_schematic.py            footprints, nets, then RE-POUR
#
# Step 3 re-pours deliberately. A zone fill is only valid for the pad set it
# was filled against, so planes poured in step 2 -- when the board had no
# pads -- connect to nothing until they are filled again with U1, U2 and the
# DrMOS phases present.
set -euo pipefail

KP="${KICAD_PYTHON:-/c/Users/$USER/AppData/Local/Programs/KiCad/10.0/bin/python.exe}"
[ -x "$KP" ] || { echo "KiCad python not found at $KP (set KICAD_PYTHON)" >&2; exit 1; }

# The bindings emit "swig/python detected a memory leak" on every object the
# script releases. It is noise from the wrapper, not a fault in the board,
# and it drowns the actual output.
run() {
    echo "== $1 =="
    # The status must come from the PYTHON process, not the pipeline. An
    # earlier version ended the pipe with "|| true" and then read
    # PIPESTATUS, which by then described the "|| true" and always said 0 --
    # so build_board.py failed with a SyntaxError and the script reported
    # success. Redirect to a file, check the real status, then filter.
    local log
    log="$(mktemp)"
    set +e
    "$KP" "$@" > "$log" 2>&1
    local status=$?
    set -e
    grep -vE "swig/python detected a memory leak" "$log" || true
    rm -f "$log"
    if [ "$status" -ne 0 ]; then
        echo "FAILED: $1 exited $status" >&2
        return "$status"
    fi
}

run build_board.py --no-markers
run add_planes.py
run build_schematic.py

echo
echo "== board regenerated =="
