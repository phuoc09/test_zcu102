#!/usr/bin/env bash
# Simulate the AXI4-Lite front-end bit-exactly against the same Python model
# that generated the PE vectors.  usage: ./run_sim.sh "0 4"
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
RTL_PE=${RTL_PE:-$ROOT/pe_rtl}
KS=${1:-"0 4"}
source "${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2022.1/settings64.sh}" >/dev/null 2>&1

WORK=$ROOT/results/sim_axi
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog -sv -nolog "$RTL_PE"/*.sv "$ROOT"/rtl/*.sv "$ROOT"/tb/tb_axi_lite.sv > xvlog.log 2>&1 || {
  tail -40 xvlog.log; exit 1; }

fail=0
for k in $KS; do
  python3 "$ROOT/model/gen_vectors_lut.py" \
          pe 16 "$k" 2000 "pevec_n16_k${k}.hex" 0.5 >/dev/null
  xelab -nolog -O0 -timescale 1ns/1ps tb_axi_lite \
        -generic_top "K=$k" -s "axi_k${k}" > "xelab_k${k}.log" 2>&1 || {
    tail -40 "xelab_k${k}.log"; exit 1; }
  xsim "axi_k${k}" -nolog -runall > "xsim_k${k}.log" 2>&1 || true
  grep -E "AXI (PASS|FAIL)|AXI [0-9]+ vectors|got |N_PARAM|K_PARAM|SCRATCH" \
       "xsim_k${k}.log" || tail -30 "xsim_k${k}.log"
  grep -q "K=$k AXI PASS" "xsim_k${k}.log" || fail=1
done
[ $fail = 0 ] && echo "AXI SIM ALL PASS" || echo "AXI SIM SOME FAILED"
exit $fail
