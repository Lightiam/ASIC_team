# -----------------------------------------------------------------------------
# Block-level constraints for nce_core_cluster.
#
# WHY THIS FILE EXISTS
# --------------------
# The cluster was hardened against LibreLane's base.sdc, which applies an
# input and output delay of 20% of the clock period each -- 6.0 ns apiece at
# a 30 ns period. That consumes 12 ns, 40% of the budget, before any logic
# in this block runs.
#
# Those defaults are placeholders for a chip top talking to the outside
# world. nce_core_cluster is not a chip top. It is a block that sits behind
# a CSR frontend inside a larger design, so its inputs are driven by
# registers on the same die and its outputs are captured by registers on the
# same die. The arrival and required times should reflect that.
#
# Evidence that this is the binding constraint and not a guess: in the
# cluster2 run every worst-path startpoint in max_ss_100C_1v60 was an input
# port, and there were no register-to-register paths among them. WNS was
# -5.637 ns.
#
# WHAT IS CLAIMED AND WHAT IS NOT
# -------------------------------
# This file does NOT false-path anything to make the numbers close. In
# particular the recovery path from ctrl_i[1] -- the soft reset, which gates
# the asynchronous reset of the submodules -- is left fully constrained. It
# is a real path and arguably a design smell, since a CSR data bit reaching
# an async reset pin is how recovery checks appear in a synchronous block.
# Hiding it with set_false_path would make the report green without making
# the silicon better.
#
# If setup still fails with these constraints, the deficit is in the logic
# and the fix is pipelining, not constraint tuning.
# -----------------------------------------------------------------------------

# ---- clock ------------------------------------------------------------------
create_clock -name clk_i -period 30.0 [get_ports clk_i]

# Uncertainty covers jitter plus the margin a real CTS leaves. 0.25 ns is
# what LibreLane's own base.sdc applies, kept so the comparison against the
# cluster2 baseline changes one variable rather than several.
set_clock_uncertainty 0.25 [get_clocks clk_i]
set_clock_transition  0.15 [get_clocks clk_i]

# ---- I/O timing --------------------------------------------------------------
# 3.0 ns, 10% of the period, at both ends. The budget behind that number:
# a sky130_fd_sc_hd flop's clock-to-Q at the ss corner is roughly 1 ns, and
# the remainder covers routing from the driving register and any logic the
# parent puts in the path. The same figure at the output covers routing plus
# the capturing flop's setup.
#
# This is the same 10% the Tiny Tapeout block uses in scripts/tt_um_nce.sdc,
# which is a design that has been through this flow.
set clk_in_delay   3.0
set clk_out_delay  3.0

set_input_delay  -clock clk_i -max $clk_in_delay  [all_inputs -no_clocks]
set_output_delay -clock clk_i -max $clk_out_delay [all_outputs]

# Minimum delays drive the hold checks. Hold passed at every corner in the
# cluster2 run with the 6 ns defaults, and a SMALLER min input delay makes
# hold harder, not easier -- so this is the conservative direction and the
# hold result stays meaningful rather than being relaxed alongside setup.
set_input_delay  -clock clk_i -min 0.5 [all_inputs -no_clocks]
set_output_delay -clock clk_i -min 0.5 [all_outputs]

# ---- drive and load ----------------------------------------------------------
# An input port with no driving cell is treated as having infinite drive,
# which understates the input transition and flatters timing. inv_2 is a
# modest real driver rather than the weakest cell available, matching a
# register output that has been buffered once.
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y \
    [all_inputs -no_clocks]

# 0.05 pF is a short on-die route into a nearby register, not a pad.
set_load 0.05 [all_outputs]

# ---- derate ------------------------------------------------------------------
# 5%, as base.sdc applies. Kept for the same single-variable reason as the
# uncertainty above.
set_timing_derate -early 0.95
set_timing_derate -late  1.05
