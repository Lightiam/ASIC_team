read_liberty /foss/pdks/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog reports/tt_um_nce_neural_engine_synth.v
link_design tt_um_nce_neural_engine

create_clock -name clk -period 20.0 [get_ports clk]
set_input_delay -clock clk 2.0 [get_ports {ui_in[*] uio_in[*] ena rst_n}]
set_output_delay -clock clk 2.0 [get_ports {uo_out[*] uio_out[*] uio_oe[*]}]

report_checks -path_delay max -fields {slew cap input nets fanout} -digits 3
report_worst_slack -max
report_tns
