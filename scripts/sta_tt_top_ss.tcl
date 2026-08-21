read_liberty /foss/pdks/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib
read_verilog build/tt_um_nce_neural_engine.gl.v
link_design tt_um_nce_neural_engine

create_clock -name clk -period 20.0 [get_ports clk]
set_input_delay -clock clk 2.0 [get_ports {ui_in[*] uio_in[*] ena rst_n}]
set_output_delay -clock clk 2.0 [get_ports {uo_out[*] uio_out[*] uio_oe[*]}]

puts "=== STA REPORT (SLOW-SLOW CORNER ss_100C_1v60): MAX DELAY / SETUP ==="
report_checks -path_delay max -fields {slew cap input fanout} -digits 3

puts "=== STA REPORT (SLOW-SLOW CORNER ss_100C_1v60): WORST SLACK & TNS ==="
report_worst_slack -max
report_worst_slack -min
report_tns

exit
