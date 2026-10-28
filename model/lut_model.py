"""Bit-accurate model of the LUT-ranking key (log-domain sum of two ROM reads).

    L   = ROM[k top bits of D]            (C = k + 2 bit fixed point, in [0,1))
    S   = Lx + Lw                         (C+1 bits, in [0,2))
    exp = Ex + Ew - bias + S[C]           (carry from the log-mantissa sum)
    mag = {exp[7:0], S[C-1:0], 0...}      (packed like alm_fp so sorting_block is unchanged)

ROM[i] = round(log2(1 + (i + 0.5) / 2^k) * 2^C), clipped to 2^C - 1. Bucket-centre
sampling matches research_paper/code/lut_rank.py (build_log_lut). The RTL ROM is
generated from this file (gen_rom.py), so table and model cannot drift apart.

Also holds the pair-then-tree selection the RTL performs, including its tie rules:
with a k-bit table ties are common, and np.argmax/argmin would break them
differently from the hardware (the sorting block sends the SECOND element to the
min side on a tie).
"""
import numpy as np

BIAS, EMAX = 127, 255


def rom_table(k):
    c = k + 2
    i = np.arange(1 << k, dtype=np.float64)
    v = np.round(np.log2(1.0 + (i + 0.5) / (1 << k)) * (1 << c)).astype(np.int64)
    return np.minimum(v, (1 << c) - 1)


def lut_magnitude(x_bits, w_bits, k):
    c = k + 2
    tbl = rom_table(k)
    x_bits = np.asarray(x_bits, dtype=np.int64)
    w_bits = np.asarray(w_bits, dtype=np.int64)
    ex, ew = (x_bits >> 23) & 0xFF, (w_bits >> 23) & 0xFF
    ix = (x_bits >> (23 - k)) & ((1 << k) - 1)
    iw = (w_bits >> (23 - k)) & ((1 << k) - 1)
    s = tbl[ix] + tbl[iw]
    carry = (s >> c) & 1
    frac = s & ((1 << c) - 1)
    e_p = ex + ew - BIAS + carry
    mag = ((e_p & 0xFF) << 23) | (frac << (23 - c))
    is_zero = (ex == 0) | (ew == 0)
    mag = np.where(is_zero | (e_p <= 0), 0, mag)
    mag = np.where((~is_zero) & (e_p >= EMAX), EMAX << 23, mag)
    return mag.astype(np.int64)


def pack_key(mag, w_bits):
    sw = (np.asarray(w_bits, dtype=np.int64) >> 31) & 1
    top = 1 << 31
    return np.where(sw == 1, mag ^ (top - 1), mag | top)


def select_pair_tree(keys):
    """keys: (T, N) int keys. Returns (idx_max, idx_min), each (T,), replicating
    sorting_block (>=, tie -> element 0 is max / element 1 is min) followed by
    comparator_tree (max: a>=b keeps lower index; min: a<=b keeps lower index)."""
    t, n = keys.shape
    out_max = np.empty(t, dtype=np.int64)
    out_min = np.empty(t, dtype=np.int64)
    for r in range(t):
        mx, mn = [], []
        for h in range(n // 2):
            a, b = 2 * h, 2 * h + 1
            if keys[r, a] >= keys[r, b]:
                mx.append(a); mn.append(b)
            else:
                mx.append(b); mn.append(a)
        while len(mx) > 1:
            mx = [mx[i] if keys[r, mx[i]] >= keys[r, mx[i + 1]] else mx[i + 1]
                  for i in range(0, len(mx), 2)]
            mn = [mn[i] if keys[r, mn[i]] <= keys[r, mn[i + 1]] else mn[i + 1]
                  for i in range(0, len(mn), 2)]
        out_max[r], out_min[r] = mx[0], mn[0]
    return out_max, out_min
