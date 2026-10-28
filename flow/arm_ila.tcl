# Arm the integrated logic analyser and save a CSV capture.
# Run this BEFORE the PS application starts; the app's first START triggers it.
# usage: vivado -mode batch -source flow/arm_ila.tcl -tclargs <K>
load_features labtools
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set csv  $root/results/ila_k$k.csv
set vcd  $root/results/ila_k$k.vcd

open_hw_manager
connect_hw_server -url [expr {[info exists ::env(HIL_URL)] ? [string map {TCP: ""} $::env(HIL_URL)] : "localhost:3121"}]
open_hw_target

set dev [lindex [get_hw_devices xczu9*] 0]
current_hw_device $dev
set ltx $root/results/hil_k$k.ltx
if {[file exists $ltx]} {
  set_property PROBES.FILE $ltx $dev
  set_property FULL_PROBES.FILE $ltx $dev
}
refresh_hw_device -update_hw_probes false $dev

set ilas [get_hw_ilas -of_objects $dev]
if {[llength $ilas] == 0} { error "no ILA found on $dev" }
set ila [lindex $ilas 0]
puts "ILA_PROBES: [get_hw_probes -of_objects $ila]"

set_property C_DATA_DEPTH 1024 $ila
set_property CONTROL.TRIGGER_POSITION 128 $ila

set probe [get_hw_probes -of_objects $ila dbg_start]
if {[llength $probe] == 0} {
  set probe [get_hw_probes -of_objects $ila probe0]
}
if {[llength $probe] == 0} {
  set probe [lindex [get_hw_probes -of_objects $ila] 0]
}
puts "ILA_TRIGGER on $probe"
set_property TRIGGER_COMPARE_VALUE eq1'b1 $probe

run_hw_ila $ila
if {[catch {wait_on_hw_ila $ila -timeout 2} m]} {
  puts "ILA_WAIT_WARN: $m"
}
upload_hw_ila_data $ila
write_hw_ila_data -force -csv_file $csv [get_hw_ila_data]
catch { write_hw_ila_data -force -vcd_file $vcd [get_hw_ila_data] }
puts "ILA_DONE $csv"

close_hw_target
disconnect_hw_server
