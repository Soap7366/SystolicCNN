set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
open_project CNN_Accelerator.xpr
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
