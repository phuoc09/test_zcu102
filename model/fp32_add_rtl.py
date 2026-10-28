"""Cycle-free Python mirror of rtl/fp32_add.sv, used to localise rounding bugs
without waiting on a full RTL simulation."""

import struct

M = (1 << 23) - 1


def rtl_add(a, b):
    a_zero = ((a >> 23) & 0xFF) == 0
    b_zero = ((b >> 23) & 0xFF) == 0
    a_gt = (a & 0x7FFFFFFF) >= (b & 0x7FFFFFFF)

    big, sml = (a, b) if a_gt else (b, a)
    bz, sz = (a_zero, b_zero) if a_gt else (b_zero, a_zero)

    big_sig = ((0 if bz else 1 << 23) | (big & M)) << 3
    sml_sig = ((0 if sz else 1 << 23) | (sml & M)) << 3
    diff = ((big >> 23) & 0xFF) - ((sml >> 23) & 0xFF)
    shamt = min(diff, 27)

    sml_shift = sml_sig >> shamt
    lost = 1 if (sml_sig & ((1 << shamt) - 1)) else 0
    op_sub = (a >> 31) ^ (b >> 31)

    if op_sub:
        s0_sum = (big_sig - sml_shift - lost) & 0xFFFFFFF
    else:
        s0_sum = (big_sig + sml_shift) & 0xFFFFFFF

    s0_exp = (big >> 23) & 0xFF
    s0_sign = big >> 31

    if a_zero and b_zero:
        return 0
    if s0_sum == 0:
        return 0

    # normalise
    lz = 28
    for i in range(28):
        if s0_sum & (1 << (27 - i)):
            lz = i
            break
    norm_drop = 0
    if s0_sum & (1 << 27):
        n_sum = s0_sum >> 1
        n_exp = s0_exp + 1
        norm_drop = s0_sum & 1
    else:
        n_sum = (s0_sum << (lz - 1)) & 0xFFFFFFF
        n_exp = s0_exp - (lz - 1)

    guard = (n_sum >> 2) & 1
    sticky = 1 if ((n_sum & 3) or lost or norm_drop) else 0
    mant = (n_sum >> 3) & 0xFFFFFF
    rnd = guard & (sticky | (mant & 1))
    rounded = mant + rnd
    if rounded >> 24:
        r_mant = (rounded >> 1) & M
        r_exp = n_exp + 1
    else:
        r_mant = rounded & M
        r_exp = n_exp

    if r_exp <= 0:
        return 0
    if r_exp >= 255:
        return (s0_sign << 31) | (0xFF << 23)
    return (s0_sign << 31) | (r_exp << 23) | r_mant


def f2b(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def b2f(v):
    return struct.unpack("<f", struct.pack("<I", v))[0]
