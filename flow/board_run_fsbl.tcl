# Working board flow (28/10): PS + DDR initialised by an FSBL, then bitstream, then the HIL app.
#
# Why not psu_init.tcl over the DAP: on both lab ZCU102 boards the DDR corrupted block writes
# (46-79 of 1024 words wrong, `dow` image unreadable) and the A53 fell to 0x200.  After the FSBL
# of the working Vitis platform the same block test gives 0 mismatches.
# That FSBL (results/fsbl_zcu102.elf) sets FPD_SLCR AFI_FS (0xFD615000) bits[9:8] = 2 (128-bit
# PS->PL port) but this block design is 32-bit.  Regs at offsets that are not multiples of 16
# (K at 0x214, WAIT at 0x218) then read 0.  The script writes bits[9:8] = 0 (what psu_init does).
#
# The app waits ~5 s for the ILA before vector 0.  With caches off after `rst -processor` that
# loop (1.5e9 iterations) takes minutes, so the script patches `movk x1,#0x5968,lsl#16` at
# 0x101db4 to #0x0001 in RAM.  The ELF on disk is untouched; ILA capture is skipped in this mode.
#
# usage: HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_run_fsbl.tcl <K>
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set bit  $root/results/hil_zcu102_k$k.bit
set elf  $root/results/pe_hil_k$k.elf
set fsbl $root/results/fsbl_zcu102.elf
set url [expr {[info exists ::env(HIL_URL)] ? $::env(HIL_URL) : "TCP:127.0.0.1:3121"}]
set ser [expr {[info exists ::env(HIL_SER)] ? $::env(HIL_SER) : "*"}]
set PATCH_ADDR 0x101db4
set PATCH_INSN 0xF2A00021
set RUN_MS 90000
foreach f [list $bit $elf $fsbl] { if {![file exists $f]} { error "missing $f" } }
proc tgt {pat} { global ser; targets -set -nocase -filter "jtag_cable_serial =~ \"$ser\" && name =~ \"$pat\"" }
proc hex {v} { return [format 0x%08X $v] }
proc rd {a} { return [lindex [mrd -force -value $a 1] 0] }

connect -url $url
configparams force-mem-access 1
if {[catch {tgt "PSU"}] && [catch {tgt "APU*"}]} {
  puts "NO_PSU_OR_APU: DAP in error, hardware-reset the board and rerun"; disconnect; exit 3
}
rst -system
after 3000
tgt "PS TAP"
fpga -file $bit
puts "STEP1 bitstream: [fpga -state]"
tgt "*A53*#0"
rst -processor -clear-registers
after 500
dow -force $fsbl
bpadd -addr &XFsbl_Exit
con -block -timeout 90
bpremove all
catch {stop}
puts "STEP2 FSBL done, pc=[lindex [rrd pc] end]"

# DDR sanity: 1024-word block must read back exactly
set pat {}; for {set i 0} {$i < 1024} {incr i} { lappend pat [expr {($i*0x9E3779B1 + 0x12345678) & 0xFFFFFFFF}] }
mwr -force 0x00200000 $pat
set got [mrd -force -value 0x00200000 1024]
set bad 0; for {set i 0} {$i < 1024} {incr i} { if {[lindex $got $i] != [lindex $pat $i]} { incr bad } }
puts "STEP3 DDR block test: $bad mismatches"
if {$bad} { puts "HIL_FAIL k=$k (DDR)"; disconnect; exit 4 }

tgt "PSU"
set v [rd 0xFD615000]
mwr -force 0xFD615000 [expr {$v & ~0x300}]
puts "STEP4 AFI_FS [hex $v] -> [hex [rd 0xFD615000]]"
puts "STEP4 PL: N=[hex [rd 0xA0000210]] K=[hex [rd 0xA0000214]] WAIT=[hex [rd 0xA0000218]]"

tgt "*A53*#0"
rst -processor
after 500
dow -force $elf
mwr -force $PATCH_ADDR $PATCH_INSN
mwr -force 0x10000000 0 32
con
after $RUN_MS
catch {stop}
puts "STEP5 pc after run: [lindex [rrd pc] end]"
set res [mrd -force -value 0x10000000 16]
set stg [mrd -force -value 0x10000080 2]
set exc [mrd -force -value 0x10000040 8]
puts "RESULT block 0x10000000: [join [lmap x $res {hex $x}] { }]"
puts "STAGE  0x10000080: stage=[hex [lindex $stg 0]] vector=[hex [lindex $stg 1]]"
puts "EXCEPTION magic [hex [lindex $exc 0]] (0xE7C0DEAD = recorded)"
puts [expr {[lindex $res 14] == 0xA5A5A5A5 ? "HIL_PASS k=$k" : "HIL_FAIL k=$k"}]
disconnect
