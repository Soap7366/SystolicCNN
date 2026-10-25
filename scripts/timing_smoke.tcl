# Bounded SDF test using the unmodified routed DUT and tb_timing snapshot.
# The first Conv1 tile needs input rows 0..2 (top/left halo is padding).
# Load at least these 192 bytes through the real host interface, then skip
# the remainder of the TESTBENCH input loop. No DUT state/memory is forced.
run 5 us
set loaded [get_value -radix unsigned /tb_timing/i]
if {$loaded < 192 || $loaded >= 4095} {error "Unexpected host load progress: $loaded"}
puts "SMOKE loaded prefix bytes=$loaded; skipping unused testbench input writes"
set_value -radix unsigned /tb_timing/i 4095
set f [open data/s0_conv1_out.hex r]
set golden [split [string trim [read $f]] \n]
close $f
array set seen {}
set writes 0
# Sample at external rising edge +19 ns, after routed combinational settling.
run 9 ns
for {set cycle 0} {$cycle < 3000} {incr cycle} {
    # post_n_22 is the routed WRITE-state decode (also gated by layer busy).
    # The synthesized wire named post/state is the D bus, not the state Q.
    if {[get_value /tb_timing/dut/post_n_22] eq "1"} {
        set addr [get_value -radix unsigned /tb_timing/dut/output_addr]
        set value [get_value -radix hex /tb_timing/dut/output_data]
        set oc [expr {$writes / 2}]
        set expected_addr [expr {$oc * 1024 + $writes % 2}]
        if {$addr ne "$expected_addr" || [info exists seen($addr)]} {error "Unexpected/duplicate tile address $addr, expected $expected_addr"}
        set expected [string trim [lindex $golden $addr]]
        if {![string equal -nocase $value $expected]} {error "SDF tile mismatch addr=$addr got=$value expected=$expected"}
        set seen($addr) 1
        incr writes
        puts "SMOKE write $writes addr=$addr value=$value"
    }
    run 20 ns
    if {$writes == 16} {break}
}
if {$writes != 16} {error "SDF first tile timeout: writes=$writes"}
# The final write has now committed. Abort the layer synchronously, preserving
# feature RAM, then read the 16 actual bytes through the normal host interface.
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
puts "PASS timing_smoke: routed Conv1 first tile, 16 exact pool writes and actual BRAM readback, synchronous abort/reset"
quit
