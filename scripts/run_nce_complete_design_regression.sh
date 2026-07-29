#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.." &&
    pwd
)"

cd "$ROOT_DIR"

DEFAULT_TIMEOUT="${NCE_DEFAULT_TIMEOUT:-420}"
MEDIUM_TIMEOUT="${NCE_MEDIUM_TIMEOUT:-900}"
HEAVY_TIMEOUT="${NCE_HEAVY_TIMEOUT:-1800}"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

REPORT_DIR="${NCE_REPORT_DIR:-reports/complete_design_regression/${TIMESTAMP}}"

mkdir -p "$REPORT_DIR"

SUMMARY_FILE="${REPORT_DIR}/summary.tsv"
METADATA_FILE="${REPORT_DIR}/metadata.txt"

printf 'suite\tstatus\texit_code\tseconds\tlog\n' \
    > "$SUMMARY_FILE"

PASS_COUNT=0
FAIL_COUNT=0
SUITE_COUNT=0

SUITES=(
    run_axi4lite_frontend.sh
    run_axi_conv3x3_csr.sh
    run_axi_csr_backend.sh
    run_axi_int8_top.sh
    run_axi_mixed_precision_top.sh
    run_axi_systolic_gemm_top.sh
    run_axi_tensor_compute_csr.sh
    run_axi_tensor_compute_top.sh
    run_axi_tiled_gemm_8x8_top.sh
    run_banked_scratchpad.sh
    run_bf16_dot2_mac_lane.sh
    run_bf16_dot2.sh
    run_bf16_mac_lane.sh
    run_bf16_mul.sh
    run_bf16_simd8.sh
    run_bf24_mac_lane.sh
    run_bf24_mul.sh
    run_conv3x3_valid_4x4_int8.sh
    run_fp32_accumulator.sh
    run_fp32_add.sh
    run_fp32_add_special.sh
    run_fp32_addsub_raw.sh
    run_fp32_align.sh
    run_fp32_decode.sh
    run_fp32_normalize.sh
    run_fp32_round_pack.sh
    run_gemm_command_core.sh
    run_gemm_controller.sh
    run_int18_to_fp32.sh
    run_int8_command_core.sh
    run_int8_command_decoder.sh
    run_int8_dot4_fp32.sh
    run_int8_dot4.sh
    run_int8_mac_lane.sh
    run_int8_register_mac_core.sh
    run_int8_simd8_mac.sh
    run_mixed_precision_command_core.sh
    run_mixed_precision_command_decoder.sh
    run_mixed_precision_full_regression.sh
    run_mixed_precision_mac_lane.sh
    run_mixed_precision_register_core.sh
    run_mixed_precision_simd8.sh
    run_regfile_16x256.sh
    run_register_banks.sh
    run_shared_systolic_gemm_4x4.sh
    run_systolic_array_2x2.sh
    run_systolic_array_4x4.sh
    run_systolic_gemm_4x4.sh
    run_tensor_compute_subsystem.sh
    run_tensor_gemm_execution.sh
    run_tensor_gemm_feeder.sh
    run_tensor_gemm_shared_client.sh
    run_tensor_memory_subsystem.sh
    run_tensor_pair_reader.sh
    run_tensor_result_writer.sh
    run_tensor_scratchpad.sh
    run_tensor_shared_compute_subsystem.sh
    run_tensor_stream_loader.sh
    run_tiled_gemm_8x8.sh
    run_tiled_gemm_client_mux.sh
)

suite_timeout() {
    local suite="$1"

    case "$suite" in
        run_axi_tensor_compute_top.sh | \
        run_axi_tiled_gemm_8x8_top.sh | \
        run_mixed_precision_full_regression.sh)
            printf '%s\n' "$HEAVY_TIMEOUT"
            ;;

        run_axi_mixed_precision_top.sh | \
        run_axi_systolic_gemm_top.sh | \
        run_tensor_compute_subsystem.sh | \
        run_tensor_gemm_execution.sh | \
        run_tensor_shared_compute_subsystem.sh | \
        run_tiled_gemm_8x8.sh)
            printf '%s\n' "$MEDIUM_TIMEOUT"
            ;;

        *)
            printf '%s\n' "$DEFAULT_TIMEOUT"
            ;;
    esac
}

run_command() {
    local suite_name="$1"
    local timeout_seconds="$2"

    shift 2

    local safe_name
    local log_file
    local start_time
    local end_time
    local elapsed
    local exit_code
    local status

    SUITE_COUNT=$((SUITE_COUNT + 1))

    printf -v safe_name \
        '%02d_%s' \
        "$SUITE_COUNT" \
        "${suite_name//[^A-Za-z0-9_.-]/_}"

    log_file="${REPORT_DIR}/${safe_name}.log"

    echo
    echo "================================================================"
    echo "SUITE ${SUITE_COUNT}: ${suite_name}"
    echo "Timeout: ${timeout_seconds} seconds"
    echo "Log: ${log_file}"
    echo "================================================================"

    start_time="$(date +%s)"

    timeout \
        --foreground \
        --signal=TERM \
        --kill-after=10s \
        "${timeout_seconds}s" \
        "$@" \
        2>&1 \
        | tee "$log_file"

    exit_code="${PIPESTATUS[0]}"

    end_time="$(date +%s)"
    elapsed=$((end_time - start_time))

    if [[ "$exit_code" -eq 0 ]]; then
        status="PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        status="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$suite_name" \
        "$status" \
        "$exit_code" \
        "$elapsed" \
        "$log_file" \
        >> "$SUMMARY_FILE"

    echo
    echo "RESULT: ${status}"
    echo "Elapsed: ${elapsed} seconds"
}

echo "===== NCE complete-design regression ====="
echo "Repository: ${ROOT_DIR}"
echo "Reports: ${REPORT_DIR}"
echo "Default timeout: ${DEFAULT_TIMEOUT}s"
echo "Medium timeout: ${MEDIUM_TIMEOUT}s"
echo "Heavy timeout: ${HEAVY_TIMEOUT}s"

{
    echo "timestamp=${TIMESTAMP}"
    echo "repository=${ROOT_DIR}"
    echo "branch=$(git branch --show-current)"
    echo "commit=$(git rev-parse HEAD)"
    echo "commit_description=$(git describe --always --dirty --tags)"
    echo "default_timeout=${DEFAULT_TIMEOUT}"
    echo "medium_timeout=${MEDIUM_TIMEOUT}"
    echo "heavy_timeout=${HEAVY_TIMEOUT}"

    echo
    echo "===== Git status ====="
    git status --short

    echo
    echo "===== Tool versions ====="

    iverilog -V 2>&1 | head -n 2 || true
    verilator --version || true
    yosys -V || true
} > "$METADATA_FILE"

cat "$METADATA_FILE"

# ----------------------------------------------------------------------
# Ensure every run_*.sh script is represented in the authoritative list.
# The master script excludes itself.
# ----------------------------------------------------------------------

declare -A LISTED_SUITES=()

for suite in "${SUITES[@]}"; do
    if [[ -n "${LISTED_SUITES[$suite]+x}" ]]; then
        echo "ERROR: duplicate suite in master list: ${suite}"
        exit 2
    fi

    LISTED_SUITES["$suite"]=1

    if [[ ! -f "scripts/${suite}" ]]; then
        echo "ERROR: listed regression script is missing: scripts/${suite}"
        exit 2
    fi

    if [[ ! -x "scripts/${suite}" ]]; then
        echo "ERROR: regression script is not executable: scripts/${suite}"
        exit 2
    fi
done

MANIFEST_ERROR=0

while IFS= read -r discovered_suite; do
    if [[ "$discovered_suite" == \
          "run_nce_complete_design_regression.sh" ]]; then
        continue
    fi

    if [[ -z "${LISTED_SUITES[$discovered_suite]+x}" ]]; then
        echo "ERROR: regression script omitted from master list:"
        echo "       scripts/${discovered_suite}"

        MANIFEST_ERROR=1
    fi
done < <(
    find scripts \
        -maxdepth 1 \
        -type f \
        -name 'run_*.sh' \
        -printf '%f\n' \
        | sort
)

if [[ "$MANIFEST_ERROR" -ne 0 ]]; then
    exit 2
fi

echo
echo "PASS: all ${#SUITES[@]} existing regression scripts are covered."

# ----------------------------------------------------------------------
# Package constants and encodings test. This was the only testbench without
# an existing dedicated runner.
# ----------------------------------------------------------------------

PACKAGE_RUNNER="${REPORT_DIR}/run_nce_package_test.sh"

cat > "$PACKAGE_RUNNER" <<'PKG'
#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="build/nce_package_test"
mkdir -p "$BUILD_DIR"

PKG_FILE="$(
    find rtl \
        -type f \
        -name 'nce_pkg.sv' \
        -print \
        -quit
)"

if [[ -z "$PKG_FILE" ]]; then
    echo "ERROR: nce_pkg.sv was not found."
    exit 1
fi

iverilog \
    -g2012 \
    -s tb_nce_pkg \
    -o "$BUILD_DIR/tb_nce_pkg.vvp" \
    "$PKG_FILE" \
    tb/unit/tb_nce_pkg.sv

vvp "$BUILD_DIR/tb_nce_pkg.vvp"
PKG

chmod +x "$PACKAGE_RUNNER"

run_command \
    "nce_package_constants" \
    "$DEFAULT_TIMEOUT" \
    "$PACKAGE_RUNNER"

# ----------------------------------------------------------------------
# Run all existing regressions. Failures are recorded without stopping the
# remaining suites.
# ----------------------------------------------------------------------

for suite in "${SUITES[@]}"; do
    timeout_seconds="$(suite_timeout "$suite")"

    run_command \
        "$suite" \
        "$timeout_seconds" \
        "scripts/${suite}"
done

# ----------------------------------------------------------------------
# Final hierarchy and synthesizable-RTL architecture checks.
# ----------------------------------------------------------------------

ARCH_RUNNER="${REPORT_DIR}/run_nce_architecture_checks.sh"

cat > "$ARCH_RUNNER" <<'ARCH'
#!/usr/bin/env bash

set -uo pipefail

TOP_FILE="rtl/top/nce_axi_mixed_precision_top.sv"
SHARED_FILE="rtl/core/nce_shared_systolic_gemm_4x4.sv"

ERROR_COUNT=0
CHECK_COUNT=0

count_pattern() {
    local pattern="$1"
    local file="$2"

    grep -cE "$pattern" "$file" 2>/dev/null || true
}

expect_count() {
    local description="$1"
    local expected="$2"
    local observed="$3"

    CHECK_COUNT=$((CHECK_COUNT + 1))

    if [[ "$observed" -ne "$expected" ]]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))

        echo "ERROR: ${description}"
        echo "       expected=${expected} observed=${observed}"
    else
        echo "PASS: ${description} (${observed})"
    fi
}

if [[ ! -f "$TOP_FILE" ]]; then
    echo "ERROR: missing complete NCE top: ${TOP_FILE}"
    exit 1
fi

if [[ ! -f "$SHARED_FILE" ]]; then
    echo "ERROR: missing shared engine wrapper: ${SHARED_FILE}"
    exit 1
fi

expect_count \
    "one shared physical-engine wrapper in final AXI top" \
    1 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_shared_systolic_gemm_4x4([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "one tiled GEMM controller in final AXI top" \
    1 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_tiled_gemm_8x8_controller([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "one three-client tiled GEMM mux in final AXI top" \
    1 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_tiled_gemm_client_mux([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "one tensor-memory subsystem in final AXI top" \
    1 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_tensor_memory_subsystem([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "one shared tensor GEMM client in final AXI top" \
    1 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_tensor_gemm_shared_client([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "no direct physical 4x4 engine instantiated in final AXI top" \
    0 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_systolic_gemm_4x4([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "no private tiled-GEMM wrapper instantiated in final AXI top" \
    0 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_tiled_gemm_8x8([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "no private tensor compute subsystem instantiated in final AXI top" \
    0 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_tensor_compute_subsystem([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "no private shared tensor subsystem instantiated in final AXI top" \
    0 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_tensor_shared_compute_subsystem([[:space:]]*#\(|[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\()' \
            "$TOP_FILE"
    )"

expect_count \
    "exactly one physical 4x4 engine inside the shared wrapper" \
    1 \
    "$(
        count_pattern \
            '^[[:space:]]*nce_systolic_gemm_4x4[[:space:]]*(#|\()' \
            "$SHARED_FILE"
    )"

CHECK_COUNT=$((CHECK_COUNT + 1))

if grep -RInE \
    '(^|[^A-Za-z0-9_])#[[:space:]]*[0-9]' \
    rtl \
    >/tmp/nce_rtl_delay_check.txt; then

    ERROR_COUNT=$((ERROR_COUNT + 1))

    echo "ERROR: delay controls were found in synthesizable RTL:"
    cat /tmp/nce_rtl_delay_check.txt
else
    echo "PASS: no delay controls exist in synthesizable RTL."
fi

CHECK_COUNT=$((CHECK_COUNT + 1))

if grep -RInE \
    '^[[:space:]]*initial([[:space:]]|$)' \
    rtl \
    >/tmp/nce_rtl_initial_check.txt; then

    ERROR_COUNT=$((ERROR_COUNT + 1))

    echo "ERROR: initial blocks were found in synthesizable RTL:"
    cat /tmp/nce_rtl_initial_check.txt
else
    echo "PASS: no initial blocks exist in synthesizable RTL."
fi

CHECK_COUNT=$((CHECK_COUNT + 1))

if grep -q \
    '`ifndef SYNTHESIS' \
    rtl/core/nce_tiled_gemm_client_mux.sv; then

    echo "PASS: tiled-client assertions are synthesis guarded."
else
    ERROR_COUNT=$((ERROR_COUNT + 1))
    echo "ERROR: tiled-client assertions are not synthesis guarded."
fi

CHECK_COUNT=$((CHECK_COUNT + 1))

if grep -q \
    '`ifndef SYNTHESIS' \
    rtl/core/nce_shared_systolic_gemm_4x4.sv; then

    echo "PASS: shared-engine assertions are synthesis guarded."
else
    ERROR_COUNT=$((ERROR_COUNT + 1))
    echo "ERROR: shared-engine assertions are not synthesis guarded."
fi

if [[ "$ERROR_COUNT" -ne 0 ]]; then
    echo
    echo "FAIL: ${ERROR_COUNT} architecture errors in ${CHECK_COUNT} checks."
    exit 1
fi

echo
echo "PASS: all ${CHECK_COUNT} final-top architecture checks completed."
ARCH

chmod +x "$ARCH_RUNNER"

run_command \
    "final_top_architecture" \
    "$DEFAULT_TIMEOUT" \
    "$ARCH_RUNNER"

# ----------------------------------------------------------------------
# Consolidated result
# ----------------------------------------------------------------------

TOTAL_SECONDS="$(
    awk \
        -F '\t' \
        'NR > 1 { total += $4 } END { print total + 0 }' \
        "$SUMMARY_FILE"
)"

echo
echo "================================================================"
echo "NCE COMPLETE-DESIGN REGRESSION SUMMARY"
echo "================================================================"

column \
    -t \
    -s $'\t' \
    "$SUMMARY_FILE" \
    2>/dev/null \
    || cat "$SUMMARY_FILE"

echo
echo "Suites executed: ${SUITE_COUNT}"
echo "Suites passed:   ${PASS_COUNT}"
echo "Suites failed:   ${FAIL_COUNT}"
echo "Total suite time: ${TOTAL_SECONDS} seconds"
echo "Report directory: ${REPORT_DIR}"
echo "Git commit: $(git rev-parse HEAD)"
echo "Git branch: $(git branch --show-current)"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
    echo
    echo "FAILED SUITES:"

    awk \
        -F '\t' \
        'NR > 1 && $2 == "FAIL" {
            printf "  %-45s exit=%s log=%s\n", $1, $3, $5
        }' \
        "$SUMMARY_FILE"

    echo
    echo "FAIL: complete NCE design regression detected failures."

    exit 1
fi

echo
echo "PASS: complete NCE design regression passed all ${SUITE_COUNT} suites."
