// Minimal AArch64 bare-metal startup for the HIL app (no BSP, no Vitis).
// xsct's psu_init.tcl has already configured DDR and the UARTs before `dow`.
//
// A vector table is installed first: without it VBAR is left at its reset value and any
// exception lands at 0x200 with no trace.  The handler stores the exception syndrome at
// HIL_EXC_ADDR (read it with `mrd -force 0x10000040 8`) and spins:
//   [0] 0xE7C0DEAD  [1] vector id (0..15, 4 = sync exception, current EL, SPx)
//   [2] ESR  [3] CurrentEL  [4,5] ELR lo/hi (faulting PC)  [6,7] FAR lo/hi (faulting address)
.equ HIL_EXC_ADDR, 0x10000040

.section .text.boot, "ax"
.global _start
_start:
    adr x0, hil_vectors
    mrs x1, CurrentEL
    lsr x1, x1, #2
    cmp x1, #3
    b.ne 1f
    msr vbar_el3, x0
    b 3f
1:  cmp x1, #2
    b.ne 2f
    msr vbar_el2, x0
    b 3f
2:  msr vbar_el1, x0
3:  isb

    ldr x0, =__stack_top
    mov sp, x0

    // Zero .bss (8 bytes at a time); symbols come from link.ld.
    ldr x1, =__bss_start
    ldr x2, =__bss_end
4:  cmp x1, x2
    b.hs 5f
    str xzr, [x1], #8
    b 4b

5:  bl main
6:  wfe
    b 6b

// ---------------------------------------------------------------- exceptions
.macro VEC id
    .balign 0x80
    mov x9, #\id
    b hil_exc
.endm

.balign 0x800
hil_vectors:
    VEC 0
    VEC 1
    VEC 2
    VEC 3
    VEC 4
    VEC 5
    VEC 6
    VEC 7
    VEC 8
    VEC 9
    VEC 10
    VEC 11
    VEC 12
    VEC 13
    VEC 14
    VEC 15

hil_exc:
    ldr x10, =HIL_EXC_ADDR
    mrs x11, CurrentEL
    lsr x11, x11, #2
    cmp x11, #3
    b.ne 1f
    mrs x12, esr_el3
    mrs x13, elr_el3
    mrs x14, far_el3
    b 3f
1:  cmp x11, #2
    b.ne 2f
    mrs x12, esr_el2
    mrs x13, elr_el2
    mrs x14, far_el2
    b 3f
2:  mrs x12, esr_el1
    mrs x13, elr_el1
    mrs x14, far_el1
3:  ldr w15, =0xE7C0DEAD
    str w15, [x10, #0]
    str w9,  [x10, #4]
    str w12, [x10, #8]
    str w11, [x10, #12]
    str x13, [x10, #16]
    str x14, [x10, #24]
4:  wfe
    b 4b
