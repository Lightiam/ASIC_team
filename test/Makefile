# Makefile for cocotb simulation in Tiny Tapeout

SIM ?= icarus
TOPLEVEL_LANG ?= verilog

PROJECT_SOURCES = \
  ../rtl/pkg/nce_pkg.sv \
  ../rtl/core/nce_int8_dot4.sv \
  ../rtl/core/nce_int18_to_fp32.sv \
  ../rtl/core/nce_int8_dot4_fp32.sv \
  ../rtl/core/nce_fp32_decode.sv \
  ../rtl/core/nce_fp32_align.sv \
  ../rtl/core/nce_fp32_addsub_raw.sv \
  ../rtl/core/nce_fp32_normalize.sv \
  ../rtl/core/nce_fp32_round_pack.sv \
  ../rtl/core/nce_fp32_add.sv \
  ../rtl/core/nce_fp32_add_special.sv \
  ../rtl/core/nce_fp32_accumulator.sv \
  ../rtl/core/nce_int8_mac_lane.sv \
  ../rtl/core/nce_int8_simd8_mac.sv \
  ../rtl/memory/nce_regfile_16x256.sv \
  ../rtl/memory/nce_register_banks.sv \
  ../rtl/core/nce_int8_register_mac_core.sv \
  ../rtl/control/nce_int8_command_decoder.sv \
  ../rtl/core/nce_int8_command_core.sv \
  ../rtl/bus/nce_axi4lite_frontend.sv \
  ../rtl/bus/nce_axi_csr_backend.sv \
  ../rtl/top/nce_axi_int8_top.sv \
  ../rtl/top/tt_um_nce_neural_engine.sv

VERILOG_SOURCES += $(PROJECT_SOURCES) tb.v

TOPLEVEL = tb
MODULE = test

COMPILE_ARGS += -I../rtl/pkg -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
