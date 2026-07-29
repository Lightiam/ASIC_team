#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Check Python generator ====="
python3 -m py_compile \
    scripts/gen_regfile_16x256_vectors.py

echo "===== Generate register-file vectors ====="
python3 scripts/gen_regfile_16x256_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_regfile_16x256 \
    -o build/tb_nce_regfile_16x256.vvp \
    rtl/memory/nce_regfile_16x256.sv \
    tb/unit/tb_nce_regfile_16x256.sv

echo "===== Register-file simulation ====="
vvp build/tb_nce_regfile_16x256.vvp \
    | tee reports/tb_nce_regfile_16x256.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_regfile_16x256 \
    rtl/memory/nce_regfile_16x256.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv rtl/memory/nce_regfile_16x256.sv;
    hierarchy -check -top nce_regfile_16x256;
    proc;
    memory;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_regfile_16x256.log

echo "===== All register-file checks completed ====="
