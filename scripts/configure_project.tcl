set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
open_project CNN_Accelerator.xpr
add_files -norecurse [glob $root/rtl/*.v]
add_files -fileset constrs_1 -norecurse $root/constraints/core_50mhz.xdc
add_files -fileset sim_1 -norecurse [glob $root/sim/*.sv]
add_files -norecurse [glob $root/data/*.hex]
add_files -norecurse [list $root/data/dual_task_baseline2_qat/weights.hex $root/data/dual_task_baseline2_qat/bias.hex $root/data/dual_task_baseline2_qat/quant.hex]
set_property file_type {Memory Initialization Files} [get_files *.hex]
set_property top cnn_accelerator [get_filesets sources_1]
set_property STEPS.OPT_DESIGN.TCL.PRE $root/scripts/pre_opt.tcl [get_runs impl_1]
set_property generic [list "WEIGHT_FILE=\"$root/data/dual_task_baseline2_qat/weights.hex\"" "BIAS_FILE=\"$root/data/dual_task_baseline2_qat/bias.hex\"" "QUANT_FILE=\"$root/data/dual_task_baseline2_qat/quant.hex\""] [get_filesets sources_1]
set_property top tb_network [get_filesets sim_1]
set_property generic "DATA_DIR=\"$root/data/dual_task_baseline2_qat\"" [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project
puts "PASS project configured"
