#!/usr/bin/env bash
# Full hardware-in-the-loop run on a ZCU102:
#   PS bare-metal -> AXI4-Lite -> HIMAM PE @ 200 MHz -> 2000 bit-exact vectors
#   + one ILA capture of the first vector's pipeline.
#
# usage: ./flow/run_hil.sh [K]        (K = 4 default, or 0 for the ALM baseline)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
K=${1:-4}
VIVADO_BIN=/opt/Xilinx/Vivado/2022.1/bin
XSCT=/opt/petalinux/tools/xsct/bin/xsct

BIT=$ROOT/results/hil_zcu102_k$K.bit
XSA=$ROOT/results/hil_zcu102_k$K.xsa
ELF=$ROOT/results/pe_hil_k$K.elf

for f in "$BIT" "$XSA" "$ELF"; do
  [ -f "$f" ] || { echo "MISSING $f -- build it first (see README.md)"; exit 2; }
done

if ! lsusb 2>/dev/null | grep -qiE 'xilinx|digilent|0403:'; then
  echo "No ZCU102 JTAG/UART bridge detected."
  echo "Connect the board's USB-JTAG and USB-UART cables, power it on, then rerun."
  echo "Expected: an FTDI/Digilent device in lsusb and /dev/ttyUSB* for the console."
  exit 2
fi

if ! ss -ltn 2>/dev/null | grep -q ':3121'; then
  echo "Starting hw_server..."
  "$VIVADO_BIN/hw_server" -d
  sleep 2
fi

echo "=== 1/3 PS init + bitstream ($K) ==="
"$XSCT" -no-ini flow/prep_hw.tcl "$K" 2>&1 | tee "logs/prep_k$K.log"

echo "=== 2/3 arming ILA ==="
(
  source /opt/Xilinx/Vivado/2022.1/settings64.sh >/dev/null 2>&1
  vivado -mode batch -nojournal -nolog -source flow/arm_ila.tcl -tclargs "$K" \
         > "logs/ila_k$K.log" 2>&1
) &
ILA_PID=$!
sleep 10

echo "=== 3/3 running PS application ==="
"$XSCT" -no-ini flow/run_app.tcl "$K" 2>&1 | tee "logs/run_app_k$K.log"

wait "$ILA_PID" || echo "WARNING: ILA capture failed; see logs/ila_k$K.log"

python3 flow/check_result.py "$K" "logs/run_app_k$K.log" | tee "logs/check_k$K.txt"
