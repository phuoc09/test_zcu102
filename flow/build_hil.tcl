# Synthesise, implement and export one HIL bitstream + XSA.
# usage: vivado -mode batch -source build_hil.tcl -tclargs <K>
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set proj $root/vivado/hil_k$k/hil_k$k.xpr

open_project $proj
set top [get_property top [current_fileset]]
puts "TOP=$top"

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  error "synth_1 failed: [get_property STATUS [get_runs synth_1]]"
}

reset_run impl_1
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  error "impl_1 failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_utilization     -file $root/results/util_k$k.rpt
report_timing_summary  -file $root/results/timing_k$k.rpt
set wns "n/a"
catch { set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] }
puts "WNS=$wns"
set clocks ""
catch { set clocks [get_clocks] }
puts "PL_CLOCKS=$clocks"

write_debug_probes -force $root/results/hil_k$k.ltx
write_hw_platform -fixed -include_bit -force -file $root/results/hil_zcu102_k$k.xsa
file copy -force [get_property DIRECTORY [get_runs impl_1]]/hil_wrapper.bit \
               $root/results/hil_zcu102_k$k.bit

set fh [open $root/results/build_k$k.txt w]
puts $fh "k $k"
puts $fh "top $top"
puts $fh "wns $wns"
puts $fh "clocks $clocks"
close $fh
puts "BUILD_HIL_DONE k=$k wns=$wns"
