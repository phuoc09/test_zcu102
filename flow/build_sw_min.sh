#!/usr/bin/env bash
# Build the minimal bare-metal PS ELF and extract psu_init.tcl from the XSA.
# usage: ./flow/build_sw_min.sh [K]
set -euo pipefail
cd "$(dirname "$0")/.."
K=${1:-4}
# Any aarch64-none-elf toolchain works (Vitis/xsct ships one under gnu/aarch64/lin/aarch64-none/bin).
TC=${AARCH64_TC:-/opt/petalinux/tools/xsct/gnu/aarch64/lin/aarch64-none/bin}
GCC=$TC/aarch64-none-elf-gcc
SIZE=$TC/aarch64-none-elf-size
OBJCOPY=$TC/aarch64-none-elf-objcopy
XSA=results/hil_zcu102_k$K.xsa
ELF=results/pe_hil_k$K.elf
BIN=results/pe_hil_k$K.bin

[ -f "$XSA" ] || { echo "missing $XSA -- build the bitstream first"; exit 2; }

# -mstrict-align: the MMU is off under JTAG boot, so all memory is Device memory and an
# unaligned access faults.
"$GCC" -nostdlib -ffreestanding -fno-builtin -O2 -mgeneral-regs-only -mstrict-align -Wall \
       -DHIL_K="$K" -I sw -T sw/link.ld \
       -o "$ELF" sw/start.S sw/pe_hil_min.c

# The XSA carries the exact psu_init for this PS configuration.
unzip -p "$XSA" psu_init.tcl > results/psu_init_k$K.tcl

# Raw image (load address 0x100000, entry 0x100800) for board_debug2.tcl method B, which writes
# it straight into DDR through the DAP instead of `dow` through the core.
"$OBJCOPY" -O binary "$ELF" "$BIN"

"$SIZE" "$ELF"
echo "SW_MIN_DONE k=$K elf=$ELF bin=$BIN psu_init=results/psu_init_k$K.tcl"
