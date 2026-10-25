set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set_param general.maxThreads 4
read_verilog [glob rtl/*.v]
synth_design -top cnn_layer_accelerator -part xc7z020clg400-1
read_xdc constraints/core_50mhz.xdc
report_utilization -file build/utilization_synth.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file build/timing_synth.rpt
report_timing -max_paths 20 -file build/paths_synth.rpt
write_checkpoint -force build/cnn_synth.dcp
opt_design
place_design
phys_opt_design
route_design
report_utilization -file build/utilization_route.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file build/timing_route.rpt
report_timing -max_paths 20 -file build/paths_route.rpt
report_drc -file build/drc_route.rpt
report_methodology -file build/methodology_route.rpt
write_checkpoint -force build/cnn_route.dcp
write_verilog -force -mode timesim -sdf_anno false build/cnn_timesim.v
write_sdf -force build/cnn_timesim.sdf
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
set f [open build/implementation_status.txt w]
puts $f "setup_slack_ns=[get_property SLACK $setup]"
puts $f "hold_slack_ns=[get_property SLACK $hold]"
close $f
if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} {error "Timing failed; inspect build/timing_route.rpt"}
puts "PASS implementation timing"
