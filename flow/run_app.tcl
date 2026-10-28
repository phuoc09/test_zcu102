# Download the PS application and read the result block back over JTAG.
# usage: xsct -no-ini flow/run_app.tcl <K>
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set elf  $root/results/pe_hil_k$k.elf

if {![file exists $elf]} { error "missing $elf (run flow/build_sw_min.sh $k)" }

connect
targets -set -filter {name =~ "APU*"}
dow -force $elf
con
after 8000
puts "HIL_MRD_BEGIN"
mrd -force 0x10000000 16
puts "HIL_MRD_END"
stop
disconnect
