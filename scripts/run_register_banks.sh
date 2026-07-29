#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

mkdir -p build reports

echo "===== Check Python generator ====="
python3 -m py_compile \
    scripts/gen_register_banks_vectors.py

echo "===== Generate register-bank vectors ====="
python3 scripts/gen_register_banks_vectors.py

echo "===== Icarus compilation ====="
iverilog \
    -g2012 \
    -Wall \
    -s tb_nce_register_banks \
    -o build/tb_nce_register_banks.vvp \
    rtl/memory/nce_regfile_16x256.sv \
    rtl/memory/nce_register_banks.sv \
    tb/integration/tb_nce_register_banks.sv

echo "===== Register-bank simulation ====="
vvp build/tb_nce_register_banks.vvp \
    | tee reports/tb_nce_register_banks.log

echo "===== Verilator lint ====="
verilator \
    --lint-only \
    --timing \
    -Wall \
    -Wno-fatal \
    --top-module nce_register_banks \
    rtl/memory/nce_regfile_16x256.sv \
    rtl/memory/nce_register_banks.sv

echo "===== Yosys synthesis check ====="
yosys -q -p "
    read_verilog -sv \
        rtl/memory/nce_regfile_16x256.sv \
        rtl/memory/nce_register_banks.sv;
    hierarchy -check -top nce_register_banks;
    proc;
    memory;
    opt;
    check -assert;
    stat;
" | tee reports/yosys_nce_register_banks.log

echo "===== All register-bank checks completed ====="
