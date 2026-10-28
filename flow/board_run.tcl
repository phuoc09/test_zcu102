# Board run in one go: PS + DDR init, bitstream, HIL app, result check, for each item of the list:
#   4, 0   the K = 4 / K = 0 bitstream with its own application: must PASS (all vectors bit-exact)
#   cross  negative control: the K = 4 application on the K = 0 bitstream.  It must FAIL with exactly
#          the mismatch count and first index in vectors/cross_k4_on_k0.txt (the rows where
#          y(K=0) != y(K=4)), which shows the check reads the PL and detects a wrong ranking key.
#
# PS init (env HIL_INIT):
#   fsbl    (default) results/fsbl_zcu102.elf from the lab's Vitis platform (passed on every run
#           since 28/10).  It sets the PS->PL port to 128 bit, so AFI_FS 0xFD615000 bits[9:8] are
#           cleared afterwards.
#   psinit  experimental: results/psinit_k$K.elf, the C psu_init from this design's own XSA run
#           from OCM.  On the lab board psu_init() did not return (status stays 0x50534900).
#   auto    psinit first, then fsbl if the DDR block test or the app fails.
# psu_init.tcl over the DAP is not used: it corrupted DDR block writes on both lab boards.
#
# The app's ILA wait is set through its mailbox (0x100000C0), so nothing is patched in memory.
# env HIL_ILA=1 keeps the 5 s wait: start flow/arm_ila.tcl when "STEP5 app running" is printed.
#
# usage: HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_run.tcl [item ...]
#        (default list: 4 0 cross)
set klist [expr {[llength $argv] ? $argv : {4 0 cross}}]
set root [file normalize [file dirname [info script]]/..]
set url  [expr {[info exists ::env(HIL_URL)]  ? $::env(HIL_URL)  : "TCP:127.0.0.1:3121"}]
set ser  [expr {[info exists ::env(HIL_SER)]  ? $::env(HIL_SER)  : "*"}]
set mode [expr {[info exists ::env(HIL_INIT)] ? $::env(HIL_INIT) : "fsbl"}]
set ila  [expr {[info exists ::env(HIL_ILA)]  ? $::env(HIL_ILA)  : 0}]
set fsbl $root/results/fsbl_zcu102.elf
set PSINIT_STATUS 0xFFFDFFF0
set CTRL 0x100000C0
set PART 0x10000100

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

# Load and run the app built for K = k; returns {pass us mismatches first_idx k_read nvec}.
proc run_app {how k} {
  global root CTRL PART ila
  tgt "*A53*#0"
  rst -processor
  after 500
  dow -force $root/results/pe_hil_k$k.elf
  dap
  mwr -force 0x10000000 0 32
  mwr -force 0x10000080 0 2
  mwr -force $PART 0 8
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
  set prt [mrd -force -value $PART 8]
  puts "RESULT k=$k ($how): [join [lmap x $res {hex $x}] { }]"
  puts "STAGE  k=$k: stage=[hex [lindex $st2 0]] vector=[hex [lindex $st2 1]]"
  if {[lindex $prt 0] == 0x50415254} {
    set np [lindex $prt 1]
    puts "PARTS  k=$k: mismatches per part (random discrim edge) = [lrange $prt 2 [expr {1 + $np}]]"
  }
  puts "EXCEPTION k=$k: magic [hex [lindex $exc 0]] (0xE7C0DEAD = recorded) ESR=[hex [lindex $exc 2]] ELR=[hex [lindex $exc 4]] FAR=[hex [lindex $exc 6]]"
  return [list [expr {[lindex $res 14] == 0xA5A5A5A5 && [lindex $res 2] == 0}] [lindex $res 13] \
               [lindex $res 2] [lindex $res 3] [lindex $res 11] [lindex $res 1]]
}

connect -url $url
configparams force-mem-access 1
if {[catch {dap}]} { puts "NO_PSU_OR_APU: DAP in error, hardware-reset the board and rerun"; disconnect; exit 3 }
puts "== targets"; puts [targets]

set summary {}
foreach item $klist {
  # cross = K = 4 application on the K = 0 bitstream
  if {$item eq "cross"} { set kb 0; set ka 4 } else { set kb $item; set ka $item }
  set need [list hil_zcu102_k$kb.bit pe_hil_k$ka.elf]
  if {$mode ne "fsbl"} { lappend need psinit_k$kb.elf }
  foreach f $need { if {![file exists $root/results/$f]} { error "missing results/$f" } }
  set tries [expr {$mode eq "auto" ? {psinit fsbl} : [list $mode]}]
  set out [expr {$item eq "cross" ? "CROSS_WRONG no usable run" : "HIL_FAIL k=$item"}]
  foreach how $tries {
    if {[catch {set ok [init_ps $how $kb]} m]} { puts "ERROR $item init $how: $m"; set ok 0 }
    if {!$ok} { puts "NOTE $item: init with $how did not give a usable DDR"; continue }
    if {[catch {lassign [run_app $how $ka] pass us mism first kread nv} m]} {
      puts "ERROR $item run ($how): $m"; set pass 0; set us 0; set mism -1; set first -1; set kread -1; set nv 0
    }
    if {$item eq "cross"} {
      set fh [open $root/vectors/cross_k4_on_k0.txt]; lassign [gets $fh] emism efirst; close $fh
      set tag [expr {$mism == $emism && $first == $efirst && $kread == 0 && !$pass ? "CROSS_OK" : "CROSS_WRONG"}]
      set out "$tag K=4 app on K=0 bitstream (init=$how): mismatches=$mism first=$first, expected $emism first=$efirst"
      if {$tag eq "CROSS_OK"} break
      continue
    }
    if {$pass} {
      set out "HIL_PASS k=$item init=$how vectors=$nv run_us=$us ([format %.2f [expr {$us / double($nv)}]] us/vector, caches off, AXI4-Lite MMIO bound)"
      break
    }
    set out "HIL_FAIL k=$item init=$how mismatches=$mism first=$first"
  }
  puts $out
  lappend summary $out
}
disconnect
puts "== SUMMARY"
foreach s $summary { puts $s }
puts "BOARD_RUN_DONE"
