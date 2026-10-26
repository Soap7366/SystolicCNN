# Bounded SDF test using the unmodified routed DUT and tb_timing snapshot.
# Own only the TESTBENCH start/input stimulus. The DUT is never forced.
# For this bounded first-tile test, explicitly write/read its 27 non-padding
# input bytes with address/data setup and hold cycles around host_wr_en.
set start_force [add_force /tb_timing/start 0]
run 5 us
set_value -radix unsigned /tb_timing/i 4095
run 1 us
run 11 ns
set f [open data/s0_conv1_input.hex r];set input_golden [split [string trim [read $f]] \n];close $f
set input_addresses {0 1 2 3 4 5 6 7 8 64 65 66 67 68 69 70 71 72 128 129 130 131 132 133 134 135 136}
set_value /tb_timing/host_wr_en 0
set_value /tb_timing/host_rd_en 0
set_value /tb_timing/host_bank 0
foreach addr $input_addresses {
    set_value -radix unsigned /tb_timing/host_addr $addr
    set_value -radix hex /tb_timing/host_wr_data [lindex $input_golden $addr]
    run 20 ns
    set_value /tb_timing/host_wr_en 1
    run 20 ns
    set_value /tb_timing/host_wr_en 0
    run 20 ns
}
set_value /tb_timing/host_rd_en 1
foreach addr $input_addresses {
    set_value -radix unsigned /tb_timing/host_addr $addr
    run 60 ns
    run 18 ns
    set value [get_value -radix hex /tb_timing/host_rd_data]
    if {[get_value /tb_timing/host_rd_valid] ne "1" || ![string equal -nocase $value [lindex $input_golden $addr]]} {
        error "Input BRAM verification failed addr=$addr got=$value expected=[lindex $input_golden $addr]"
    }
    run 2 ns
}
puts "SMOKE input BRAM: 27 exact first-tile bytes verified before start"
set_value /tb_timing/host_rd_en 0
run 60 ns
remove_forces $start_force
set_value /tb_timing/start 1
run 20 ns
set_value /tb_timing/start 0
set f [open data/s0_conv1_out.hex r]
set golden [split [string trim [read $f]] \n]
close $f
array set seen {}
set writes 0
# Observe the actual destination RAM write enable, rather than a synthesis
# temporary post_n_XX name that can change after implementation optimization.
set write_enable ""
foreach obj [get_objects /tb_timing/dut/*] {
    if {[regexp {feature_memories\[1\]\.wr\s*$} $obj]} {set write_enable $obj}
}
if {$write_enable eq ""} {error "Destination BRAM write enable is not observable"}
puts "SMOKE write-enable signal=$write_enable"
# Synthesis may remove top-level aliases output_addr/output_data. The Post
# write ports remain connected directly to both Feature BRAM write ports in
# the routed netlist; use this module interface instead of temporary nets.
set write_address /tb_timing/dut/post/wr_addr
set write_data /tb_timing/dut/post/wr_data
if {[llength [get_objects $write_address]] != 1 || [llength [get_objects $write_data]] != 1} {
    error "Routed Post/BRAM write interface is not observable"
}
# Sample at external rising edge +19 ns, after routed combinational settling.
run 18 ns
for {set cycle 0} {$cycle < 3000} {incr cycle} {
    if {[get_value $write_enable] eq "1"} {
        set addr [get_value -radix unsigned $write_address]
        set value [get_value -radix hex $write_data]
        set oc [expr {$writes / 4}]
        set expected_addr [expr {$oc * 1024 + $writes % 4}]
        if {$addr ne "$expected_addr" || [info exists seen($addr)]} {error "Unexpected/duplicate tile address $addr, expected $expected_addr"}
        set expected [string trim [lindex $golden $addr]]
        if {![string equal -nocase $value $expected]} {error "SDF tile mismatch addr=$addr got=$value expected=$expected"}
        set seen($addr) 1
        incr writes
        puts "SMOKE write $writes addr=$addr value=$value"
    }
    run 20 ns
    if {$writes == 32} {break}
}
if {$writes != 32} {error "SDF first tile timeout: writes=$writes"}
# The final write has now committed. Abort the layer synchronously, preserving
# feature RAM, then read the 32 actual bytes through the normal host interface.
run 2 ns
set_value /tb_timing/rst 1
run 60 ns
set_value /tb_timing/rst 0
run 80 ns
if {[get_value /tb_timing/host_ready] ne "1"} {error "Host did not recover after reset"}
set_value /tb_timing/host_rd_en 1
set_value /tb_timing/host_bank 1
foreach addr [lsort -integer [array names seen]] {
    set_value -radix unsigned /tb_timing/host_addr $addr
    run 60 ns
    run 18 ns
    set actual [get_value -radix hex /tb_timing/host_rd_data]
    if {[get_value /tb_timing/host_rd_valid] ne "1" || ![string equal -nocase $actual [string trim [lindex $golden $addr]]]} {
        error "SDF BRAM readback mismatch addr=$addr got=$actual"
    }
    run 2 ns
}
puts "PASS timing_smoke: routed Conv1 first tile, 32 exact pool writes and actual BRAM readback, synchronous abort/reset"
quit
