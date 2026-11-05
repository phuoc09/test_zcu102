#!/usr/bin/env bash
# usage: ./tb/run_sim_axis.sh "0 4"   (each K run with GAPS=0 and GAPS=1)
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
RTL_PE=${RTL_PE:-$ROOT/pe_rtl}
KS=${1:-"0 4"}
source /opt/Xilinx/Vivado/2022.1/settings64.sh >/dev/null 2>&1
WORK=$ROOT/results/sim_axis; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog -sv -nolog "$RTL_PE"/*.sv "$ROOT/rtl/pe_axis.sv" "$ROOT/tb/tb_axis.sv" > xvlog.log 2>&1 || { tail -40 xvlog.log; exit 1; }
fail=0
for k in $KS; do
  # Same vectors as the board app (vectors/gen_hil_vectors.py), truncated to a multiple of 4
  # because pe_axis packs four results per output beat.
  n=$(( $(wc -l < "$ROOT/vectors/pevec_n16_k${k}.hex") / 4 * 4 ))
  head -n "$n" "$ROOT/vectors/pevec_n16_k${k}.hex" > "pevec_n16_k${k}.hex"
  for g in 0 1; do
    xelab -nolog -O0 -timescale 1ns/1ps tb_axis -generic_top "K=$k" -generic_top "GAPS=$g" -s "s_k${k}_g${g}" > "xelab_${k}_${g}.log" 2>&1 || { tail -40 "xelab_${k}_${g}.log"; exit 1; }
    xsim "s_k${k}_g${g}" -nolog -runall > "xsim_k${k}_g${g}.log" 2>&1 || true
    grep -E "AXIS|CYCLES|VECS|STALL|STARVE|MISMATCH|TIMEOUT" "xsim_k${k}_g${g}.log" || tail -20 "xsim_k${k}_g${g}.log"
    grep -q "AXIS PASS" "xsim_k${k}_g${g}.log" || fail=1
  done
done
[ $fail = 0 ] && echo "AXIS SIM ALL PASS" || echo "AXIS SIM SOME FAILED"; exit $fail
