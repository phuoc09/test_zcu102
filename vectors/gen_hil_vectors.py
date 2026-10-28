#!/usr/bin/env python3
"""Generate the HIL vector set and the C header embedded in the PS application.

Vectors and expected outputs come from the same bit-exact Python model used by
the RTL testbenches (model/gen_vectors_lut.py), so the PS run and the
xsim run check the hardware against one source of truth.

The inputs are identical for K = 0 and K = 4; only the expected y differs.  Three parts:
  random   2000 rows, seed 42, the set of the first board runs (unchanged).
  discrim  rows where the ranking key decides the output, filtered from random rows (seed 43):
           1000 rows where K = 0 and K = 4 give different y, and 500 rows where K = 4 picks a
           different pair than the exact product ranking while K = 0 agrees with K = 4.
           In the random part only 26 / 2000 rows tell K = 0 and K = 4 apart.
  edge     structured rows inside the normal FP32 range: all-zero x, zero weights, duplicated
           pairs (ties), equal and opposite products, exact cancellation of the bias, wide
           exponent range (sticky / alignment), near ties inside one k = 4 LUT bucket,
           one-signed weights, a single non-zero x, round-half-even ties in the adder.
Not in the set: subnormal or overflowing products.  The RTL flushes subnormals to zero and the
model uses IEEE float32 there; the key datapath for those exponents is checked by tb_key (xsim).

Negative control: the K = 4 application on the K = 0 bitstream must report exactly the rows where
y(K=0) != y(K=4) as mismatches; the count and the first index go into vectors/cross_k4_on_k0.txt.

usage: gen_hil_vectors.py
Outputs:
  vectors/pevec_n16_k{0,4}.hex        (same format as the RTL testbench)
  vectors/cross_k4_on_k0.txt          (expected mismatches, first index, per part)
  sw/hil_vectors.h                    (C arrays, part boundaries, FNV-1a reference hashes)
  vectors/manifest.json
"""
import hashlib
import json
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "model"))
from gen_vectors_lut import sample_pe, expect_pe, pe_lines, F32  # noqa: E402

MODEL = os.path.join(ROOT, "model", "gen_vectors_lut.py")
N = 16
KS = [0, 4]
FNV_OFF = 0x811C9DC5
FNV_PRIME = 16777619
MASK = 0xFFFFFFFF


def fnv_words(words):
    h = FNV_OFF
    for w in words:
        for _ in range(4):
            h ^= (w & 0xFF)
            h = (h * FNV_PRIME) & MASK
            w >>= 8
    return h


def bits(y):
    return y.view(np.uint32)


def part_random():
    return sample_pe(np.random.default_rng(42), N, 2000, 0.5)


def part_discrim(n_k=1000, n_exact=500, chunk=20000):
    rng = np.random.default_rng(43)
    keep_k, keep_e = [], []
    while len(keep_k) < n_k or len(keep_e) < n_exact:
        x, w, b = sample_pe(rng, N, chunk, 0.5)
        y0, y4, ye = (expect_pe(x, w, b, k) for k in (0, 4, None))
        dk = bits(y0) != bits(y4)
        de = (bits(y4) != bits(ye)) & ~dk
        keep_k += [(x[i], w[i], b[i]) for i in np.flatnonzero(dk)]
        keep_e += [(x[i], w[i], b[i]) for i in np.flatnonzero(de)]
    rows = keep_k[:n_k] + keep_e[:n_exact]
    return tuple(np.array([r[j] for r in rows], F32) for j in range(3))


def pw2(e):
    return F32(2.0 ** int(e))


def part_edge(per=50):
    rng = np.random.default_rng(44)
    X, W, B = [], [], []

    def rnd(shape, lo=-6, hi=7, signed=False):
        v = np.asarray(rng.uniform(1.0, 2.0, shape) * 2.0 ** rng.integers(lo, hi, shape), F32)
        if signed:
            v = v * np.asarray(rng.choice([-1.0, 1.0], shape), F32)
        return v

    def add(x, w, b):
        assert (x >= 0).all() and not np.signbit(x).any(), "x is post-ReLU: non-negative, no -0"
        X.append(np.asarray(x, F32)); W.append(np.asarray(w, F32)); B.append(F32(b))

    for _ in range(per):                                   # 1 all-zero x: y = bias
        add(np.zeros(N, F32), rnd(N, signed=True), rnd((), signed=True))
    for _ in range(per):                                   # 2 zero weights (+0 and -0)
        w = rnd(N, signed=True)
        z = rng.random(N) < 0.5
        w[z] = np.where(rng.random(z.sum()) < 0.5, F32(0.0), F32(-0.0))
        add(rnd(N), w, rnd((), signed=True))
    for _ in range(per):                                   # 3 duplicated pairs: exact ties
        x, w = rnd(N), rnd(N, signed=True)
        for _ in range(rng.integers(1, 4)):
            src, dst = rng.choice(N, 2, replace=False)
            x[dst], w[dst] = x[src], w[src]
        add(x, w, rnd((), signed=True))
    for _ in range(per // 5):                              # 3b all sixteen pairs identical
        add(np.full(N, rnd(()), F32), np.full(N, rnd((), signed=True), F32), rnd((), signed=True))
    for _ in range(per):                                   # 4 equal and opposite products
        x, w = rnd(N), rnd(N, signed=True)
        h = N // 2
        w[:h] = np.abs(w[:h]); w[h:] = -w[:h]; x[h:] = x[:h]
        p = rng.permutation(N)
        add(x[p], w[p], rnd((), signed=True))
    for _ in range(per):                                   # 5 bias cancels the pair sum: y = +0
        x, w = rnd(N), rnd(N, signed=True)
        s4 = expect_pe(x[None], w[None], np.zeros(1, F32), 4)[0]
        add(x, w, -s4 if s4 != 0 else rnd((), signed=True))
    for _ in range(2 * per):                               # 6 wide exponent range, |e| <= 60
        x = rnd(N, -60, 61); x[rng.random(N) < 0.25] = 0
        add(x, rnd(N, -60, 61, signed=True), rnd((), -100, 101, signed=True))
    for _ in range(2 * per):                               # 7 near ties inside one k = 4 bucket
        top_x, top_w = rng.integers(0, 16), rng.integers(0, 16)
        ex, ew = rng.integers(-6, 7), rng.integers(-6, 7)
        mx = 1.0 + (top_x + rng.random(N)) / 16.0
        mw = 1.0 + (top_w + rng.random(N)) / 16.0
        x = np.asarray(mx * 2.0 ** ex, F32)
        w = np.asarray(mw * 2.0 ** ew * rng.choice([-1.0, 1.0], N), F32)
        x[rng.random(N) < 0.2] = 0
        add(x, w, rnd((), signed=True))
    for s in (1.0, -1.0):                                  # 8 one-signed weights
        for _ in range(per // 2):
            add(rnd(N), np.abs(rnd(N)) * F32(s), rnd((), signed=True))
    for _ in range(per // 2):                              # 9 a single non-zero x
        x = np.zeros(N, F32); x[rng.integers(N)] = rnd(())
        add(x, rnd(N, signed=True), rnd((), signed=True))
    for i in range(per):                                   # 10 round-half-even in both adds
        e = int(rng.integers(-20, 21))
        j = int(rng.integers(0, 4))
        x = np.full(N, pw2(e - 1), F32)                    # others: 2^(e-1) * 1
        w = np.ones(N, F32)
        x[0] = F32((1.0 + j * 2.0 ** -23) * 2.0 ** e)     # max: (1 + j ulp) 2^e
        x[1], w[1] = pw2(e - 12), pw2(-12)                 # min: 2^(e-24), half an ulp of 2^e
        p = rng.permutation(N)
        b = [pw2(e - 24), -pw2(e - 24), F32(3.0 * 2.0 ** (e - 25)), pw2(e + 5)][i % 4]
        add(x[p], w[p], b)
    return np.array(X), np.array(W), np.array(B)


def main():
    parts = [("random", part_random()), ("discrim", part_discrim()), ("edge", part_edge())]
    names = [n for n, _ in parts]
    x, w, b = (np.concatenate([p[j] for _, p in parts]) for j in range(3))
    ends = [int(e) for e in np.cumsum([len(p[0]) for _, p in parts])]
    starts = [0] + ends[:-1]
    nvec = len(x)
    assert np.isfinite(x).all() and np.isfinite(w).all() and np.isfinite(b).all()

    data = {}
    for k in KS:
        y = expect_pe(x, w, b, k)
        assert np.isfinite(y).all()
        lines = pe_lines(x, w, b, y)
        out = os.path.join(ROOT, "vectors", f"pevec_n{N}_k{k}.hex")
        with open(out, "w") as f:
            f.write("\n".join(lines) + "\n")
        rows = [[int(v, 16) for v in ln.split()] for ln in lines]
        data[k] = {"rows": rows, "y": [r[-1] for r in rows],
                   "fnv_exp": fnv_words([r[-1] for r in rows]),
                   "sha256": hashlib.sha256(open(out, "rb").read()).hexdigest()}

    diff = [i for i in range(nvec) if data[0]["y"][i] != data[4]["y"][i]]
    per_part = [sum(s <= i < e for i in diff) for s, e in zip(starts, ends)]
    with open(os.path.join(ROOT, "vectors", "cross_k4_on_k0.txt"), "w") as f:
        f.write(f"{len(diff)} {diff[0]} " + " ".join(map(str, per_part)) + "\n")

    hpath = os.path.join(ROOT, "sw", "hil_vectors.h")
    with open(hpath, "w") as f:
        f.write("// AUTO-GENERATED by vectors/gen_hil_vectors.py -- do not edit.\n")
        f.write("// Each row: X[0..N-1], W[0..N-1], BIAS, EXPECTED_Y.\n")
        f.write("// Parts: " + ", ".join(f"{n} [{s}, {e})" for n, s, e in zip(names, starts, ends))
                + "\n")
        f.write("#ifndef HIL_VECTORS_H\n#define HIL_VECTORS_H\n\n")
        f.write("#include <stdint.h>\n\n")
        f.write(f"#define HIL_N {N}\n#define HIL_NVEC {nvec}\n#define HIL_NPARTS {len(parts)}\n")
        f.write("static const uint32_t hil_part_end[HIL_NPARTS] = {"
                + ", ".join(f"{e}u" for e in ends) + "};\n\n")
        for k in KS:
            f.write(f"#define HIL_FNV_EXPECTED_K{k} 0x{data[k]['fnv_exp']:08X}u\n")
            f.write(f"static const uint32_t hil_vec_k{k}[HIL_NVEC][{2*N+2}] = {{\n")
            for r in data[k]["rows"]:
                f.write("  {" + ", ".join(f"0x{v:08X}u" for v in r) + "},\n")
            f.write("};\n\n")
        f.write("#endif\n")

    manifest = {
        "nvec": nvec, "N": N,
        "parts": {n: [s, e] for n, s, e in zip(names, starts, ends)},
        "fnv_expected": {str(k): f"0x{data[k]['fnv_exp']:08X}" for k in KS},
        "sha256": {str(k): data[k]["sha256"] for k in KS},
        "cross_k4_on_k0": {"mismatches": len(diff), "first_index": diff[0],
                           "per_part": dict(zip(names, per_part))},
        "source": os.path.relpath(MODEL, ROOT),
    }
    with open(os.path.join(ROOT, "vectors", "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
