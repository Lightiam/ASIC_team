#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

TESTS=(
    # BF16 arithmetic and dedicated execution blocks
    scripts/run_bf16_mul.sh
    scripts/run_bf16_dot2.sh
    scripts/run_bf16_dot2_mac_lane.sh
    scripts/run_bf16_simd8.sh

    # BF24 arithmetic and dedicated execution block
    scripts/run_bf24_mul.sh
    scripts/run_bf24_mac_lane.sh

    # Shared three-precision execution hierarchy
    scripts/run_mixed_precision_mac_lane.sh
    scripts/run_mixed_precision_simd8.sh
    scripts/run_mixed_precision_register_core.sh

    # Command control hierarchy
    scripts/run_mixed_precision_command_decoder.sh
    scripts/run_mixed_precision_command_core.sh

    # Full AXI4-Lite logical system
    scripts/run_axi_mixed_precision_top.sh
)

PASSED_TESTS=0

for test_script in "${TESTS[@]}"; do
    echo
    echo "================================================================"
    echo "RUNNING: ${test_script}"
    echo "================================================================"

    if [[ ! -x "${test_script}" ]]; then
        echo "ERROR: Missing or non-executable test script: ${test_script}"
        exit 1
    fi

    "${test_script}"

    PASSED_TESTS=$((PASSED_TESTS + 1))
done

echo
echo "================================================================"
echo "PASS: Complete INT8X4/BF16X2/BF24 regression finished"
echo "PASS: ${PASSED_TESTS}/${#TESTS[@]} regression stages completed"
echo "================================================================"
