set_cmd_units -time ns -capacitance pF -current mA -voltage V -resistance kOhm -distance um

read_liberty /foss/pdks/ciel/sky130/versions/f6eeac7dad085ffcc829ccfd721f7b4ce39edcf7/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

read_verilog reports/tt_um_nce_neural_engine_netlist.v
link_design tt_um_nce_neural_engine

read_sdc scripts/tt_um_nce.sdc

puts "\n========================================================"
puts "  STA REPORT: TYPICAL CORNER (tt_025C_1v80) @ 50.0 MHz"
puts "========================================================"
report_checks -path_delay max -fields {input_pin slew cap net fanout} -digits 4 -endpoint_count 5
report_worst_slack -max
report_tns

puts "\n========================================================"
puts "  CHECKING MAXIMUM OPERATING FREQUENCY (F_MAX)"
puts "========================================================"
set worst_slack [lindex [report_worst_slack -max] 0]
puts "Worst Slack = $worst_slack ns"

exit
