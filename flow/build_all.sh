#!/usr/bin/env bash
# Build everything for one K: block design, bitstream/XSA, Vitis platform + ELF.
# usage: ./flow/build_all.sh [K]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p logs
K=${1:-4}
source "${VIVADO_SETTINGS:-/opt/Xilinx/Vivado/2022.1/settings64.sh}" >/dev/null 2>&1

echo "=== BD k=$K ==="
vivado -mode batch -nojournal -nolog -source bd/build_bd.tcl -tclargs "$K" \
       > "logs/bd_k$K.log" 2>&1
grep -E "BD_DONE|ERROR" "logs/bd_k$K.log"

echo "=== bitstream + XSA k=$K ==="
vivado -mode batch -nojournal -nolog -source flow/build_hil.tcl -tclargs "$K" \
       > "logs/build_hil_k$K.log" 2>&1
grep -E "BUILD_HIL_DONE|ERROR" "logs/build_hil_k$K.log"

echo "=== bare-metal PS app k=$K ==="
./flow/build_sw_min.sh "$K" > "logs/build_sw_k$K.log" 2>&1
grep -E "SW_MIN_DONE|ERROR" "logs/build_sw_k$K.log"
echo "DONE k=$K"
