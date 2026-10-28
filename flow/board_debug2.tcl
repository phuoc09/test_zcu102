# Second board run (28/10): isolates why the A53 does not see the app in DDR after `dow`.
# Board run 2 showed: PL OK (N = 0x10, K = 0x4 over AXI), isolation 0, but right after `dow`
# 0x100800 != 0x10004000 (first ELF word) and the first step lands at 0x200 (VBAR = 0, nothing
# installed yet, so no exception record).  This script separates three causes:
#   (a) DDR fails on burst writes although single-word mwr/mrd work  -> block test, step 2
#   (b) the A53 sees memory differently from the DAP (APU L2 reset, caches) -> same words read
#       through the DAP (PSU target) and through the core (A53 #0 target), steps 2 and 3
#   (c) `dow` through the core writes wrong data                    -> step 3 vs step 4
# and then runs the app with whichever load path verified (method A = dow through the core,
# method B = raw image written through the DAP, then pc set on the core).
#
# usage: xsct -no-ini flow/board_debug2.tcl <K>      (env HIL_URL, HIL_SER as in board_debug.tcl)
set k [lindex $argv 0]
set root [file normalize [file dirname [info script]]/..]
set bit $root/results/hil_zcu102_k$k.bit
set psu $root/results/psu_init_k$k.tcl
set elf $root/results/pe_hil_k$k.elf
set bin $root/results/pe_hil_k$k.bin
foreach f [list $bit $psu $elf $bin] { if {![file exists $f]} { error "missing $f" } }
set url [expr {[info exists ::env(HIL_URL)] ? $::env(HIL_URL) : "TCP:127.0.0.1:3121"}]
set ser [expr {[info exists ::env(HIL_SER)] ? $::env(HIL_SER) : "*"}]
set BASE 0x100000
set ENTRY 0x100800

proc tgt {pat} {
  global ser
  targets -set -nocase -filter "jtag_cable_serial =~ \"$ser\" && name =~ \"$pat\""
}
proc dap {} { if {[catch {tgt "PSU"}]} { tgt "APU*" } }
proc cpu {} { tgt "*A53*#0" }
proc rd {addr} { return [lindex [mrd -force -value $addr 1] 0] }
proc hex {v} { return [format 0x%08X $v] }

# expected words of the image, sampled at 64 offsets plus the entry and the vector table
set fh [open $bin rb]; set img [read $fh]; close $fh
set nw [expr {[string length $img] / 4}]
binary scan $img i* words
set samples [list 0x800 0x804 0x808 0x80C 0x1000 0x1004 0x1EC0 [expr {($nw - 1) * 4}]]
for {set i 0} {$i < 64} {incr i} { lappend samples [expr {(($i * 1103 + 7) % $nw) * 4}] }
proc check {label} {
  global samples words BASE
  set bad 0; set first ""
  foreach off $samples {
    set exp [expr {[lindex $words [expr {$off / 4}]] & 0xFFFFFFFF}]
    if {[catch {set got [rd [expr {$BASE + $off}]]}]} { set got -1 }
    if {$got != $exp} {
      incr bad
      if {$first eq ""} { set first "first @[hex [expr {$BASE + $off}]]: got [hex $got] expected [hex $exp]" }
    }
  }
  puts "VERIFY $label: [expr {[llength $samples] - $bad}]/[llength $samples] words match  $first"
  return [expr {$bad == 0}]
}
proc apu_rst {label} {
  dap
  set v [rd 0xFD1A0104]
  puts "RST_FPD_APU 0xFD1A0104 $label = [hex $v]  ACPU0_RESET(b0)=[expr {$v & 1}] APU_L2_RESET(b8)=[expr {($v >> 8) & 1}] ACPU0_PWRON(b10)=[expr {($v >> 10) & 1}]"
  return $v
}
proc result {label} {
  dap
  set res [mrd -force -value 0x10000000 16]
  set exc [mrd -force -value 0x10000040 8]
  set stg [mrd -force -value 0x10000080 2]
  puts "RESULT $label: [join [lmap v $res {hex $v}] { }]"
  puts "STAGE  $label: stage=[hex [lindex $stg 0]] vector=[hex [lindex $stg 1]]"
  if {[lindex $exc 0] == 0xE7C0DEAD} {
    set esr [lindex $exc 2]
    puts "EXCEPTION $label: vector=[lindex $exc 1] EL=[lindex $exc 3] ESR=[hex $esr] EC=[format 0x%02X [expr {($esr >> 26) & 0x3F}]] FSC=[format 0x%02X [expr {$esr & 0x3F}]] ELR=[hex [lindex $exc 4]] FAR=[format 0x%08X%08X [lindex $exc 7] [lindex $exc 6]]"
  } else {
    puts "EXCEPTION $label: none recorded"
  }
  return [expr {[lindex $res 14] == 0xA5A5A5A5}]
}
proc run_cpu {label} {
  cpu
  con
  after 12000
  catch {stop}
  puts "PC after run ($label): [lindex [rrd pc] end]"
  return [result $label]
}

# ---------------------------------------------------------------- 1. init (Vitis order)
connect -url $url
puts "== targets"; puts [targets]
configparams force-mem-access 1
tgt "APU*"
rst -system
after 3000
if {[catch {tgt "PS TAP"}]} { tgt "PSU" }
fpga -file $bit
puts "STEP1 fpga: [fpga -state]"
tgt "APU*"
source $psu
psu_init
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
catch {psu_protection}
puts "STEP1 psu_init done; PLREG N = [hex [rd 0xA0000210]] K = [hex [rd 0xA0000214]]"

apu_rst "before rst -processor"
cpu
rst -processor
after 500
set v [apu_rst "after rst -processor"]
cpu
catch {puts "A53 #0 pc after reset: [lindex [rrd pc] end]  cpsr: [lindex [rrd cpsr] end]"}
if {($v >> 8) & 1} {
  puts "WARN APU L2 cache still in reset: releasing bit 8 and resetting core 0 again"
  dap; mwr -force 0xFD1A0104 [expr {$v & ~0x100}]
  cpu; rst -processor; after 500
  apu_rst "after L2 release"
}

# ---------------------------------------------------------------- 2. memory paths
set N 1024
set A 0x00200000
set pat {}
for {set i 0} {$i < $N} {incr i} { lappend pat [expr {($i * 0x9E3779B1 + 0x12345678) & 0xFFFFFFFF}] }
dap
mwr -force $A $pat
foreach who {dap cpu} {
  $who
  set got [mrd -force -value $A $N]
  set bad 0
  for {set i 0} {$i < $N} {incr i} { if {[lindex $got $i] != [lindex $pat $i]} { incr bad } }
  puts "BLOCK 1024 words written by DAP at [hex $A], read via $who: $bad mismatches  (first: [hex [lindex $got 0]] exp [hex [lindex $pat 0]])"
}
cpu
mwr -force [expr {$A + 0x2000}] 0xC0FFEE01
dap
puts "WORD written by A53 #0 at [hex [expr {$A + 0x2000}]], read via dap: [hex [rd [expr {$A + 0x2000}]]] (exp 0xC0FFEE01)"

# ---------------------------------------------------------------- 3. method A: dow through the core
cpu
dow -force $elf
dap; set okA_dap [check "method A (dow), read via DAP"]
cpu; set okA_cpu [check "method A (dow), read via A53 #0"]
puts "A53 #0 pc after dow: [lindex [rrd pc] end]"
set pass 0
if {$okA_dap && $okA_cpu} {
  set pass [run_cpu "method A"]
}

# ---------------------------------------------------------------- 4. method B: image via the DAP
if {!$pass} {
  dap
  mwr -force 0x10000000 0 32
  mwr -force 0x10000080 0 2
  if {[catch {dow -data -force $bin $BASE} m]} {
    puts "dow -data failed ($m); falling back to mwr -bin"
    mwr -force -bin -file $bin $BASE $nw
  }
  dap; set okB_dap [check "method B (DAP load), read via DAP"]
  cpu; rst -processor; after 500
  cpu; set okB_cpu [check "method B (DAP load), read via A53 #0 after rst -processor"]
  rwr pc $ENTRY
  puts "A53 #0 pc set to [lindex [rrd pc] end]"
  set pass [run_cpu "method B"]
}

puts [expr {$pass ? "HIL_PASS k=$k" : "HIL_FAIL k=$k"}]
disconnect
puts "BOARD_DEBUG2_DONE k=$k"
