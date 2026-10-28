# Board run for every K in one go: PS + DDR init, bitstream, HIL app, result check.
#
# PS init (env HIL_INIT):
#   psinit  results/psinit_k$K.elf: the C psu_init from this design's own XSA, run from OCM (the PS
#           part of an FSBL).  AFI widths come out right for this 32-bit block design.
#   fsbl    results/fsbl_zcu102.elf from the lab's Vitis platform (the flow that passed on 28/10).
#           It sets the PS->PL port to 128 bit, so AFI_FS 0xFD615000 bits[9:8] are cleared afterwards.
#   auto    (default) psinit first; if the DDR block test or the app fails, redo everything with fsbl.
# psu_init.tcl over the DAP is not used: it corrupted DDR block writes on both lab boards.
#
# The app's ILA wait is set through its mailbox (0x100000C0), so nothing is patched in memory.
# env HIL_ILA=1 keeps the 5 s wait: start flow/arm_ila.tcl when "STEP5 app running" is printed.
#
# usage: HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_run.tcl [K ...]
#        (default K list: 4 0)
set klist [expr {[llength $argv] ? $argv : {4 0}}]
set root [file normalize [file dirname [info script]]/..]
set url  [expr {[info exists ::env(HIL_URL)]  ? $::env(HIL_URL)  : "TCP:127.0.0.1:3121"}]
set ser  [expr {[info exists ::env(HIL_SER)]  ? $::env(HIL_SER)  : "*"}]
set mode [expr {[info exists ::env(HIL_INIT)] ? $::env(HIL_INIT) : "auto"}]
set ila  [expr {[info exists ::env(HIL_ILA)]  ? $::env(HIL_ILA)  : 0}]
set fsbl $root/results/fsbl_zcu102.elf
set PSINIT_STATUS 0xFFFDFFF0
set CTRL 0x100000C0

proc tgt {pat} { global ser; targets -set -nocase -filter "jtag_cable_serial =~ \"$ser\" && name =~ \"$pat\"" }
proc hex {v} { return [format 0x%08X $v] }
proc rd {a} { return [lindex [mrd -force -value $a 1] 0] }
proc dap {} { if {[catch {tgt "PSU"}]} { tgt "APU*" } }

# PS + DDR init with the given method, bitstream first (Vitis order).  Returns 1 if DDR is usable.
proc init_ps {how k} {
  global root fsbl PSINIT_STATUS
  dap
  rst -system
  after 3000
  tgt "PS TAP"
  fpga -file $root/results/hil_zcu102_k$k.bit
  puts "STEP1 k=$k bitstream: [fpga -state]"
  tgt "*A53*#0"
  rst -processor -clear-registers
  after 500
  if {$how eq "psinit"} {
    dap; mwr -force $PSINIT_STATUS 0 4
    tgt "*A53*#0"
    dow -force $root/results/psinit_k$k.elf
    con
    set s 0
    for {set i 0} {$i < 40} {incr i} {
      after 500
      dap; set s [rd $PSINIT_STATUS]
      if {$s == 0x50534901 || $s == 0x505349E1} break
    }
    tgt "*A53*#0"; catch {stop}
    dap
    puts "STEP2 k=$k psinit status=[hex $s] psu_init_ret=[hex [rd [expr {$PSINIT_STATUS + 4}]]] printf=[rd [expr {$PSINIT_STATUS + 8}]]  (0x50534901 = OK)"
    if {$s != 0x50534901} { return 0 }
  } else {
    dow -force $fsbl
    bpadd -addr &XFsbl_Exit
    con -block -timeout 90
    bpremove all
    catch {stop}
    puts "STEP2 k=$k FSBL done, pc=[lindex [rrd pc] end]"
  }

  set pat {}
  for {set i 0} {$i < 1024} {incr i} { lappend pat [expr {($i * 0x9E3779B1 + 0x12345678) & 0xFFFFFFFF}] }
  dap
  mwr -force 0x00200000 $pat
  set got [mrd -force -value 0x00200000 1024]
  set bad 0
  for {set i 0} {$i < 1024} {incr i} { if {[lindex $got $i] != [lindex $pat $i]} { incr bad } }
  puts "STEP3 k=$k ($how) DDR block test: $bad / 1024 mismatches"
  if {$bad} { return 0 }

  set v [rd 0xFD615000]
  if {($v >> 8) & 3} { mwr -force 0xFD615000 [expr {$v & ~0x300}] }
  puts "STEP4 k=$k AFI_FS [hex $v] -> [hex [rd 0xFD615000]]  (bits 9:8 must be 0)"
  puts "STEP4 k=$k PL: N=[hex [rd 0xA0000210]] K=[hex [rd 0xA0000214]] WAIT=[hex [rd 0xA0000218]]"
  return 1
}

# Load and run the app; returns {pass us}.
proc run_app {how k} {
  global root CTRL ila
  tgt "*A53*#0"
  rst -processor
  after 500
  dow -force $root/results/pe_hil_k$k.elf
  dap
  mwr -force 0x10000000 0 32
  mwr -force 0x10000080 0 2
  mwr -force $CTRL [list 0x57414954 [expr {$ila ? 5000 : 0}]]
  tgt "*A53*#0"
  con
  puts "STEP5 k=$k app running (ILA wait [expr {$ila ? 5000 : 0}] ms)"
  set stg 0
  for {set i 0} {$i < 240} {incr i} {
    after 1000
    dap
    if {[catch {set stg [rd 0x10000080]}]} { continue }
    if {$stg == 0x53540006} break
  }
  tgt "*A53*#0"; catch {stop}
  puts "STEP5 k=$k pc after run: [lindex [rrd pc] end]  ([expr {$i + 1}] s)"
  dap
  set res [mrd -force -value 0x10000000 16]
  set st2 [mrd -force -value 0x10000080 2]
  set exc [mrd -force -value 0x10000040 8]
  puts "RESULT k=$k ($how): [join [lmap x $res {hex $x}] { }]"
  puts "STAGE  k=$k: stage=[hex [lindex $st2 0]] vector=[hex [lindex $st2 1]]"
  puts "EXCEPTION k=$k: magic [hex [lindex $exc 0]] (0xE7C0DEAD = recorded) ESR=[hex [lindex $exc 2]] ELR=[hex [lindex $exc 4]] FAR=[hex [lindex $exc 6]]"
  return [list [expr {[lindex $res 14] == 0xA5A5A5A5 && [lindex $res 2] == 0}] [lindex $res 13]]
}

connect -url $url
configparams force-mem-access 1
if {[catch {dap}]} { puts "NO_PSU_OR_APU: DAP in error, hardware-reset the board and rerun"; disconnect; exit 3 }
puts "== targets"; puts [targets]

set summary {}
foreach k $klist {
  foreach f [list hil_zcu102_k$k.bit pe_hil_k$k.elf psinit_k$k.elf] {
    if {![file exists $root/results/$f]} { error "missing results/$f" }
  }
  set tries [expr {$mode eq "auto" ? {psinit fsbl} : [list $mode]}]
  set out "HIL_FAIL k=$k"
  foreach how $tries {
    if {[catch {set ok [init_ps $how $k]} m]} { puts "ERROR k=$k init $how: $m"; set ok 0 }
    if {!$ok} { puts "NOTE k=$k: init with $how did not give a usable DDR"; continue }
    if {[catch {lassign [run_app $how $k] pass us} m]} { puts "ERROR k=$k run ($how): $m"; set pass 0; set us 0 }
    if {$pass} {
      set out "HIL_PASS k=$k init=$how run_us=$us ([format %.2f [expr {$us / 2000.0}]] us/vector, caches off, AXI4-Lite MMIO bound)"
      break
    }
    set out "HIL_FAIL k=$k init=$how"
  }
  puts $out
  lappend summary $out
}
disconnect
puts "== SUMMARY"
foreach s $summary { puts $s }
puts "BOARD_RUN_DONE"
