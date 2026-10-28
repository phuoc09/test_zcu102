#!/usr/bin/env bash
# Simulate the AXI4-Lite front-end bit-exactly against the same Python model
# that generated the PE vectors (vectors/pevec_n16_k*.hex, from vectors/gen_hil_vectors.py).
# usage: ./run_sim.sh "0 4 cross"
#   cross = negative control: K = 4 vectors on the K = 0 design must give exactly the
#           mismatch count in vectors/cross_k4_on_k0.txt.
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
RTL_PE=${RTL_PE:-$ROOT/pe_rtl}
KS=${1:-"0 4 cross"}
source "${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2022.1/settings64.sh}" >/dev/null 2>&1

WORK=$ROOT/results/sim_axi
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
xvlog -sv -nolog "$RTL_PE"/*.sv "$ROOT"/rtl/*.sv "$ROOT"/tb/tb_axi_lite.sv > xvlog.log 2>&1 || {
  tail -40 xvlog.log; exit 1; }

fail=0
for k in $KS; do
  if [ "$k" = cross ]; then
    # same K = 0 snapshot, but the vector file it reads at run time holds the K = 4 expectations
    [ -d xsim.dir/axi_k0 ] || xelab -nolog -O0 -timescale 1ns/1ps tb_axi_lite \
          -generic_top "K=0" -s axi_k0 > xelab_k0.log 2>&1 || { tail -40 xelab_k0.log; exit 1; }
    cp "$ROOT/vectors/pevec_n16_k4.hex" pevec_n16_k0.hex
    xsim axi_k0 -nolog -runall > xsim_cross.log 2>&1 || true
    cp "$ROOT/vectors/pevec_n16_k0.hex" pevec_n16_k0.hex
    read -r exp first _ < "$ROOT/vectors/cross_k4_on_k0.txt"
    got=$(sed -n 's/.*AXI [0-9]* vectors, errors=\([0-9]*\),.*/\1/p' xsim_cross.log)
    gfirst=$(sed -n 's/^ *y\[\([0-9]*\)\] got.*/\1/p' xsim_cross.log | head -1)
    echo "cross (K=4 vectors on K=0 design): errors=$got first=$gfirst  expected errors=$exp first=$first"
    if [ "$got" = "$exp" ] && [ "$gfirst" = "$first" ]; then echo "CROSS SIM OK"; else echo "CROSS SIM WRONG"; fail=1; fi
    continue
  fi
  cp "$ROOT/vectors/pevec_n16_k${k}.hex" .
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
