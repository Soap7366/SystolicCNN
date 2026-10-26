# Begin after image upload and stop immediately after the verified inference.
run 82 us
while {[get_value -radix bin /tb_power/activity_window] ne "1"} {run 20 ns}
open_saif build/full_network/inference_rtl.saif
log_saif [get_objects -r /tb_power/dut/*]
run 1302340 ns
close_saif
if {[get_value /tb_power/activity_window] ne "0"} {error "Power capture did not cover complete inference"}
puts "PASS inference SAIF: sample 0, complete inference only, 50 MHz"
quit
