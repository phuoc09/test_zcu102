# Reset the PS, apply the platform's psu_init (PL0 = 200 MHz, DDR, UART1),
# and load the HIL bitstream.  Run before arming the ILA.
# usage: xsct -no-ini flow/prep_hw.tcl <K>
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set bit  $root/results/hil_zcu102_k$k.bit
set psu  $root/results/psu_init_k$k.tcl

if {![file exists $bit]} { error "missing $bit" }
if {![file exists $psu]} { error "missing $psu (run flow/build_sw_min.sh $k)" }

connect
targets -set -filter {name =~ "APU*"}
if {[catch {rst -system} m]} {
  puts "PREP_WARN reset: $m"
}
after 1000
if {[file exists $psu]} {
  source $psu
  puts "PREP_PSU_INIT $psu"
} else {
  puts "PREP_WARN no psu_init.tcl at $psu (PS may already be initialised)"
}
fpga -file $bit
puts "PREP_HW_READY k=$k"
disconnect
