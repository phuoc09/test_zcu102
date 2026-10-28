# One board run in the Vitis/FSBL order, then a full diagnostic dump.
#   1. rst -system   2. fpga -file (PL configured BEFORE the PS-PL glue is opened)
#   3. psu_init      4. psu_ps_pl_isolation_removal   5. psu_ps_pl_reset_config
#   6. rst -processor on A53 #0, dow, con, wait, stop   7. dump results / exception / PS-PL state
# Configuring the PL after the isolation removal can leave the FPD->PL port isolated: every AXI
# access then returns SLVERR, the A53 takes a synchronous external abort and, with no vector
# table, stops at 0x200 (the symptom of the first board run, 28/10).
#
# usage: xsct -no-ini flow/board_debug.tcl <K>
#   env HIL_URL  hw_server URL   (default TCP:127.0.0.1:3121, e.g. TCP:172.16.36.2:3121)
#   env HIL_SER  JTAG cable serial filter (default *, e.g. 210308A65523)
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set bit $root/results/hil_zcu102_k$k.bit
set psu $root/results/psu_init_k$k.tcl
set elf $root/results/pe_hil_k$k.elf
foreach f [list $bit $psu $elf] { if {![file exists $f]} { error "missing $f" } }
set url [expr {[info exists ::env(HIL_URL)] ? $::env(HIL_URL) : "TCP:127.0.0.1:3121"}]
set ser [expr {[info exists ::env(HIL_SER)] ? $::env(HIL_SER) : "*"}]

proc tgt {pat} {
  global ser
  targets -set -nocase -filter "jtag_cable_serial =~ \"$ser\" && name =~ \"$pat\""
}
proc rd {addr} { return [lindex [mrd -force -value $addr 1] 0] }
proc hex {v} { return [format 0x%08X $v] }

connect -url $url
puts "== targets"; puts [targets]

tgt "PSU"
rst -system
after 3000
if {[catch {tgt "PS TAP"}]} { tgt "PSU" }
fpga -file $bit
puts "BD_STEP fpga programmed: [fpga -state]"

tgt "APU"
source $psu
psu_init
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
puts "BD_STEP psu_init + isolation removal + PL reset done"

# PS-side state of the PS-PL interface (addresses are the ones psu_init writes)
set iso [rd 0xFFD80110]
set rfpd [rd 0xFD1A0100]
set gpio [rd 0xFF0A0054]
puts "PSPL isolation status 0xFFD80110 = [hex $iso]  bit23 (FPD-PL isolation) = [expr {($iso >> 23) & 1}]  (must be 0)"
puts "PSPL RST_FPD_TOP     0xFD1A0100 = [hex $rfpd]  bits12:7 (AFI/HPM resets) = [format 0x%02X [expr {($rfpd >> 7) & 0x3F}]]  (must be 0)"
puts "PSPL EMIO pl_resetn  0xFF0A0054 = [hex $gpio]  bit31 = [expr {($gpio >> 31) & 1}]  (1 = released; not used by this BD: its reset comes from the MMCM 'locked')"

tgt "*A53*#0"
rst -processor
dow -force $elf
con
after 12000
catch {stop}
puts "== A53 #0 pc: [lindex [rrd pc] end]"

set res [mrd -force -value 0x10000000 16]
set exc [mrd -force -value 0x10000040 8]
set stg [mrd -force -value 0x10000080 2]
puts "RESULT block 0x10000000: [join [lmap v $res {hex $v}] { }]"
puts "STAGE  0x10000080: stage=[hex [lindex $stg 0]] vector=[hex [lindex $stg 1]]"
puts "   (0x53540001 main, 2 UART done, 3 first PL read issued, 4 PL regs read, 5 vectors done, 6 result written)"
if {[lindex $exc 0] == 0xE7C0DEAD} {
  set esr [lindex $exc 2]
  set ec [expr {($esr >> 26) & 0x3F}]
  set fsc [expr {$esr & 0x3F}]
  set elr [expr {([lindex $exc 5] << 32) | [lindex $exc 4]}]
  set far [expr {([lindex $exc 7] << 32) | [lindex $exc 6]}]
  puts "EXCEPTION vector=[lindex $exc 1] EL=[lindex $exc 3] ESR=[hex $esr] EC=[format 0x%02X $ec] FSC=[format 0x%02X $fsc]"
  puts "          ELR (faulting pc) = [format 0x%016X $elr]   FAR (faulting address) = [format 0x%016X $far]"
  puts "   EC 0x25 = data abort; FSC 0x10 = synchronous external abort (AXI SLVERR/DECERR from the PL port),"
  puts "   FSC 0x21 = alignment fault, FSC 0x04-0x07 = translation fault. FAR 0xA00002xx = PE register access."
} else {
  puts "EXCEPTION none recorded (magic [hex [lindex $exc 0]])"
}

# PL registers through the debugger (may fail if the AXI port does not respond)
foreach {name a exp} {N 0xA0000210 0x00000010 K 0xA0000214 "0x00000004 (K=4) / 0 (K=0)"} {
  if {[catch {set v [rd $a]} m]} { puts "PLREG $name [hex $a]: read error: $m" } else { puts "PLREG $name [hex $a] = [hex $v]  expected $exp" }
}
disconnect
puts "BOARD_DEBUG_DONE k=$k"
