# SDC Timing Constraints for tt_um_nce_neural_engine
set_units -time ns -resistance kOhm -capacitance pF -voltage V -current mA

# 50 MHz system clock (Period = 20.0 ns)
create_clock -name clk -period 20.00 [get_ports clk]

# Clock uncertainty and latency
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition 0.15 [get_clocks clk]

# Input delays (2.0 ns setup budget for external pad / board trace)
set_input_delay -clock clk 2.00 [get_ports {ui_in[*] uio_in[*] ena rst_n}]

# Output delays (2.0 ns setup budget for external sampling)
set_output_delay -clock clk 2.00 [get_ports {uo_out[*] uio_out[*] uio_oe[*]}]

# Driving cell and output load
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 [get_ports {ui_in[*] uio_in[*] ena rst_n}]
set_load 0.035 [get_ports {uo_out[*] uio_out[*] uio_oe[*]}]
