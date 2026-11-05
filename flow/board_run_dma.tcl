# DMA streaming run on the board: PS DDR -> AXI DMA (MM2S) -> pe_axis -> AXI DMA (S2MM) -> PS DDR,
# everything in the PL at 200 MHz (clk_wiz from the 300 MHz board oscillator, not from the PS).
#
# The app (results/pe_dma_k4.elf, from sw/pe_dma_min.c) makes two passes:
#   pass 0: the vector set once (4085 vectors padded to 4088, a multiple of 4)
#   pass 1: the set REP = 50 times in ONE transfer (204 400 vectors, 29.4 MB in, 0.8 MB out)
# Every output word is checked bit-exactly, and PL counters give the cycles, input stalls and
# input starvation, so the measured rate can be split into PE-bound and stream-bound.
#
# What it measures: the sustained rate of the STREAMED design. One vector needs 9 beats of 128 bit,
# so the expected ceiling is 200 MHz / 9 = 22.2 M vectors/s (xsim: 9.0 cycles/vector, 0 stalls).
# That is the stream limit, not the PE limit (the PE pipeline accepts 1 vector per clock).
#
# PS init = the lab FSBL (results/fsbl_zcu102.elf), as in board_run.tcl.  After it the script
#   - clears AFI_FS 0xFD615000 bits[9:8] (M_AXI_HPM0_FPD = 32 bit, as in this design),
#   - sets S_AXI_HP0_FPD (AFIFM2 RDCTRL 0xFD380000 / WRCTRL 0xFD380014 bits[1:0]) to 128 bit,
#   - releases the AFI resets in RST_FPD_TOP 0xFD1A0100 bits[12:7] (AFI_FM0..5, as in psu_afi_config of this XSA),
# because the lab FSBL was built for another platform.
#
# usage: HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_run_dma.tcl [K]
#        (default K = 4; only the K = 4 DMA bitstream is prebuilt)
set k    [expr {[llength $argv] ? [lindex $argv 0] : 4}]
set root [file normalize [file dirname [info script]]/..]
set url  [expr {[info exists ::env(HIL_URL)] ? $::env(HIL_URL) : "TCP:127.0.0.1:3121"}]
set ser  [expr {[info exists ::env(HIL_SER)] ? $::env(HIL_SER) : "*"}]
set fsbl $root/results/fsbl_zcu102.elf
set bit  $root/results/dma_zcu102_k$k.bit
set elf  $root/results/pe_dma_k$k.elf
foreach f [list $fsbl $bit $elf] { if {![file exists $f]} { error "missing $f" } }

proc tgt {pat} { global ser; targets -set -nocase -filter "jtag_cable_serial =~ \"$ser\" && name =~ \"$pat\"" }
proc hex {v} { return [format 0x%08X $v] }
proc rd {a} { return [lindex [mrd -force -value $a 1] 0] }
proc dap {} { if {[catch {tgt "PSU"}]} { tgt "APU*" } }
proc setbits {a mask val} {
  set v [rd $a]; set n [expr {($v & ~$mask) | ($val & $mask)}]
  if {$n != $v} { mwr -force $a $n }
  return "[hex $v] -> [hex [rd $a]]"
}

connect -url $url
configparams force-mem-access 1
if {[catch {dap}]} { puts "NO_PSU_OR_APU: DAP in error, hardware-reset the board and rerun"; disconnect; exit 3 }
puts "== targets"; puts [targets]

# 1. reset, bitstream, FSBL
dap
rst -system
after 3000
tgt "PS TAP"
fpga -file $bit
puts "STEP1 k=$k DMA bitstream: [fpga -state]"
tgt "*A53*#0"
rst -processor -clear-registers
after 500
dow -force $fsbl
bpadd -addr &XFsbl_Exit
con -block -timeout 90
bpremove all
catch {stop}
puts "STEP2 FSBL done, pc=[lindex [rrd pc] end]"

# 2. DDR block test (the DMA buffers are at 0x20000000 / 0x30000000)
set pat {}
for {set i 0} {$i < 1024} {incr i} { lappend pat [expr {($i * 0x9E3779B1 + 0x12345678) & 0xFFFFFFFF}] }
dap
set bad 0
foreach base {0x00200000 0x20000000 0x30000000} {
  mwr -force $base $pat
  set got [mrd -force -value $base 1024]
  for {set i 0} {$i < 1024} {incr i} { if {[lindex $got $i] != [lindex $pat $i]} { incr bad } }
}
puts "STEP3 DDR block test at 0x00200000/0x20000000/0x30000000: $bad / 3072 mismatches"
if {$bad} { puts "DMA_FAIL DDR not usable after FSBL"; disconnect; exit 4 }

# 3. PS-PL ports for this design
puts "STEP4 AFI_FS (HPM0 32 bit)      [setbits 0xFD615000 0x300 0]"
puts "STEP4 HP0 RDCTRL (128 bit)      [setbits 0xFD380000 0x3 0]"
puts "STEP4 HP0 WRCTRL (128 bit)      [setbits 0xFD380014 0x3 0]"
puts "STEP4 RST_FPD_TOP AFI resets    [setbits 0xFD1A0100 0x00001F80 0]"
puts "STEP4 PL: DMA MM2S_SR=[hex [rd 0xA0000004]] S2MM_SR=[hex [rd 0xA0000034]] PE K=[hex [rd 0xA0010008]]"

# 4. app
tgt "*A53*#0"
rst -processor
after 500
dow -force $elf
dap
mwr -force 0x10000000 0 32
mwr -force 0x10000080 0 2
mwr -force 0x10000040 0 8
tgt "*A53*#0"
con
puts "STEP5 app running"
set stg 0
for {set i 0} {$i < 300} {incr i} {
  after 1000
  dap
  if {[catch {set stg [rd 0x10000080]}]} { continue }
  if {$stg == 0x53540006} break
}
tgt "*A53*#0"; catch {stop}
puts "STEP5 pc after run: [lindex [rrd pc] end]  ([expr {$i + 1}] s, stage [hex $stg])"
dap
set r [mrd -force -value 0x10000000 16]
set exc [mrd -force -value 0x10000040 8]
puts "RESULT: [join [lmap x $r {hex $x}] { }]"
puts "EXCEPTION: magic [hex [lindex $exc 0]] (0xE7C0DEAD = recorded) ESR=[hex [lindex $exc 2]] ELR=[hex [lindex $exc 4]] FAR=[hex [lindex $exc 6]]"
disconnect

# 5. summary.  res: 0 magic 'DMA1', 1 nrec(pass 1), 2 mismatches, 3 first idx, 4 got, 5 exp,
#    6/7 rc pass 0/1, 8 PL cycles, 9 vecs, 10 stall_in, 11 starve, 12 PS ticks, 13 cntfrq,
#    14 0xA5A5A5A5 = pass, 15 K read from the PL
lassign $r magic nrec mism first got exp rc0 rc1 cyc vecs stall starve ticks frq flag kpl
puts "== SUMMARY"
if {$magic != 0x444D4131} {
  puts "DMA_FAIL app did not finish (stage [hex $stg])"
} elseif {$flag == 0xA5A5A5A5} {
  set cpv [expr {double($cyc) / $vecs}]
  set mvs [expr {200.0 / $cpv}]
  set line "DMA_PASS k=$kpl vectors=$vecs mismatches=0 pl_cycles=$cyc ([format %.3f $cpv] cycles/vector)"
  append line " -> [format %.2f $mvs] M vectors/s = [format %.3f [expr {$mvs * 16 / 1000.0}]] GMAC/s at 200 MHz"
  append line ", in [format %.0f [expr {$mvs * 144}]] MB/s; stall_in=$stall starve=$starve"
  if {$frq} {
    set us [expr {$ticks * 1e6 / $frq}]
    append line "; PS timer [format %.0f $us] us ([format %.2f [expr {$vecs / $us}]] M vectors/s incl. DMA start/stop)"
  }
  puts $line
} else {
  puts "DMA_FAIL k=$kpl rc=$rc0/$rc1 mismatches=$mism first=$first got=[hex $got] exp=[hex $exp] vecs=$vecs/$nrec"
}
puts "BOARD_RUN_DMA_DONE"
