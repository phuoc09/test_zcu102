# Create the Vitis platform + bare-metal application for one HIL bitstream.
# usage: xsct -no-ini flow/build_sw.tcl <K>
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set xsa $root/results/hil_zcu102_k$k.xsa
set ws  $root/vitis_ws_k$k

if {![file exists $xsa]} {
  error "missing $xsa -- run flow/build_hil.tcl first"
}
file delete -force $ws
setws $ws

platform create -name hil_platform -hw $xsa -proc psu_cortexa53_0 \
               -os standalone -out $ws -no-boot-bsp
platform generate

app create -name pe_hil -platform hil_platform -domain standalone_domain \
           -template "Empty Application(C)"
importsources -name pe_hil -path $root/sw

# Remove any template-provided sources (we supply our own main).
foreach f [glob -nocomplain $ws/pe_hil/src/*.c] {
  if {[file tail $f] ne "pe_hil.c"} {
    puts "SW_REMOVE $f"
    file delete -force $f
  }
}

# Select the K variant for this bitstream.
set fd [open $ws/pe_hil/src/hil_config.h w]
puts $fd "#ifndef HIL_CONFIG_H"
puts $fd "#define HIL_CONFIG_H"
puts $fd "#define HIL_K $k"
puts $fd "#endif"
close $fd

app build -name pe_hil
puts "SW_DONE k=$k elf=$ws/pe_hil/Debug/pe_hil.elf"
