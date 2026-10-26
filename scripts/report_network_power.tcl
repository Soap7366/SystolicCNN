# Post-route estimate. No board-level/PS power is implied by this report.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
open_checkpoint build/full_network/cnn_route.dcp
if {[info exists activity_saif]} {
    read_saif -strip_path tb_power/dut $activity_saif
    report_power -file build/full_network/power_activity.rpt
} else {
    report_power -file build/full_network/power_vectorless.rpt
}
puts "PASS network power estimate"
