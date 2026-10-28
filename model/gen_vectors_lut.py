"""Stimulus + bit-exact expectations for tb_lut.sv (whole PE) and tb_key.sv (key only).

usage: gen_vectors_lut.py pe  <N> <K> <n_tests> <out> [sparsity]
       gen_vectors_lut.py key <K> <n_tests> <out>
K = 0 selects the original ALM, so the same flow regression-checks the baseline.
"""
import sys
import os
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from alm_model import f32_to_bits, alm_magnitude
from lut_model import lut_magnitude, pack_key, select_pair_tree

F32 = np.float32


def magnitude(xb, wb, k):
    return alm_magnitude(xb, wb, "fp32", "literal") if k == 0 else lut_magnitude(xb, wb, k)


def sample(rng, shape, signed):
    # same distribution as ../himam/model/gen_vectors.py
    mant = rng.uniform(1.0, 2.0, shape)
    expo = rng.integers(-6, 7, shape)
    v = (mant * 2.0 ** expo).astype(F32)
    if signed:
        v *= rng.choice([-1.0, 1.0], shape).astype(F32)
    return v


def sample_pe(rng, n, t, sparsity):
    x = sample(rng, (t, n), False)
    if sparsity > 0:
        x = np.where(rng.random((t, n)) < sparsity, F32(0.0), x)
    w = sample(rng, (t, n), True)
    bias = sample(rng, (t,), True)
    return x, w, bias


def expect_pe(x, w, bias, k):
    """Bit-exact PE output for float32 arrays x, w (T, N) and bias (T,) with key K
    (0 = ALM).  K = None ranks by the exact product (the ideal MAM)."""
    xb, wb = f32_to_bits(x).astype(np.int64), f32_to_bits(w).astype(np.int64)
    prod = (x * w).astype(F32)
    mag = f32_to_bits(np.abs(prod)).astype(np.int64) if k is None else magnitude(xb, wb, k)
    keys = pack_key(mag, wb)
    imax, imin = select_pair_tree(keys)
    rows = np.arange(len(x))
    return (F32(prod[rows, imax] + prod[rows, imin]) + bias).astype(F32)


def pe_lines(x, w, bias, y):
    lines = []
    for i in range(len(x)):
        f = [f"{v:08x}" for v in f32_to_bits(x[i])] + [f"{v:08x}" for v in f32_to_bits(w[i])]
        f += [f"{f32_to_bits(bias[i]):08x}", f"{f32_to_bits(y[i]):08x}"]
        lines.append(" ".join(f))
    return lines


def gen_pe(n, k, t, sparsity, seed=42):
    x, w, bias = sample_pe(np.random.default_rng(seed), n, t, sparsity)
    return pe_lines(x, w, bias, expect_pe(x, w, bias, k))


def gen_key(k, t, seed=7):
    """Full-range operands: zeros, denormals (exp=0), exp=255, underflow and
    overflow of the exponent sum. Only the key datapath is checked here."""
    rng = np.random.default_rng(seed)
    xb = rng.integers(0, 1 << 31, t, dtype=np.int64)          # sign = 0 (ReLU)
    wb = rng.integers(0, 1 << 32, t, dtype=np.int64)
    # pin a share of the exponents to the edges so every branch is hit often
    for arr in (xb, wb):
        pick = rng.random(t)
        e = (arr >> 23) & 0xFF
        e = np.where(pick < 0.05, 0, e)
        e = np.where((pick >= 0.05) & (pick < 0.10), 255, e)
        e = np.where((pick >= 0.10) & (pick < 0.20), rng.integers(1, 20, t), e)
        e = np.where((pick >= 0.20) & (pick < 0.30), rng.integers(235, 255, t), e)
        arr[:] = (arr & ~(0xFF << 23)) | (e << 23)
    mag = magnitude(xb, wb, k)
    return [f"{a:08x} {b:08x} {m:08x}" for a, b, m in zip(xb, wb, mag)]


if __name__ == "__main__":
    if sys.argv[1] == "pe":
        n, k, t, out = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
        sp = float(sys.argv[6]) if len(sys.argv) > 6 else 0.5
        lines = gen_pe(n, k, t, sp)
    else:
        k, t, out = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
        lines = gen_key(k, t)
    open(out, "w").write("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} lines to {out}")
