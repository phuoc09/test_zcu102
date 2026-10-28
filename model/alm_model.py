"""Bit-accurate model of the HIMAM approximate logarithmic multiplier (ALM).

Reference: Spagnolo, Corsonello, Perri, "HIMAM", IEEE TCAS-II 72(8), 2025, eqs (5)-(7).

Parameterised by format so FP32 and FP16 share one implementation; a second copy
of this logic would be free to drift from the RTL it is meant to check.

Two readings of eq (5) are implemented. The literal one matches the "-1 / >>1 /
+1" datapath drawn in Fig. 3 and yields a symmetric +-11.1% error with almost no
bias, which is the point of the two-region scheme; plain Mitchell is kept for
comparison and always underestimates.
"""

import numpy as np

FORMATS = {
    "fp32": dict(exp_w=8, mant_w=23, uint=np.uint32, float=np.float32),
    "fp16": dict(exp_w=5, mant_w=10, uint=np.uint16, float=np.float16),
}


def fmt(name):
    f = FORMATS[name]
    return f["exp_w"], f["mant_w"], f["uint"], f["float"]


def to_bits(x, name="fp32"):
    _, _, uint, flt = fmt(name)
    return np.asarray(x, dtype=flt).view(uint)


def from_bits(b, name="fp32"):
    _, _, uint, flt = fmt(name)
    return np.asarray(b, dtype=uint).view(flt)


# backwards-compatible FP32 helpers
def f32_to_bits(x):
    return to_bits(x, "fp32")


def bits_to_f32(b):
    return from_bits(b, "fp32")


def _split(bits, name):
    exp_w, mant_w, uint, _ = fmt(name)
    bits = np.asarray(bits, dtype=uint).astype(np.int64)
    sign = (bits >> (exp_w + mant_w)) & 1
    exp = (bits >> mant_w) & ((1 << exp_w) - 1)
    mant = bits & ((1 << mant_w) - 1)
    return sign, exp, mant


def _preprocess(exp, mant, mant_w, variant):
    """Eq (5): map (E, D) -> (E*, D*). D* is signed, scaled by 2**mant_w."""
    if variant == "mitchell":
        return exp, mant
    one = 1 << mant_w
    upper = mant >= (one >> 1)
    return np.where(upper, exp + 1, exp), np.where(upper, (mant - one) >> 1, mant)


def alm_magnitude(x_bits, w_bits, name="fp32", variant="literal"):
    """Eqs (6)-(7): approximate |x*w| as a packed magnitude {exponent, mantissa}.

    The antilogarithm step is skipped because HIMAM only ever compares the value.
    """
    exp_w, mant_w, _, _ = fmt(name)
    one = 1 << mant_w
    bias = (1 << (exp_w - 1)) - 1
    emax = (1 << exp_w) - 1

    _, ex, dx = _split(x_bits, name)
    _, ew, dw = _split(w_bits, name)
    ex_s, dx_s = _preprocess(ex, dx, mant_w, variant)
    ew_s, dw_s = _preprocess(ew, dw, mant_w, variant)

    r = dx_s + dw_s                       # eq (6)
    exp_sum = ex_s + ew_s - bias

    if variant == "mitchell":
        carry = r >= one
        e_p = np.where(carry, exp_sum + 1, exp_sum)
        d_p = np.where(carry, r - one, r)
    else:
        # eq (7): significand is (R+1) for R>=0, else 2(R+1) with E_P decremented
        neg = r < 0
        e_p = np.where(neg, exp_sum - 1, exp_sum)
        d_p = np.where(neg, 2 * r + one, r)

    mag = (e_p << mant_w) | (d_p & (one - 1))
    is_zero = (ex == 0) | (ew == 0)
    mag = np.where(is_zero | (e_p <= 0), 0, mag)
    mag = np.where((~is_zero) & (e_p >= emax), (emax << mant_w), mag)
    return mag.astype(np.int64)


def sorting_key(x_bits, w_bits, name="fp32", variant="literal"):
    """Signed ordering key for the (x, W) product, assuming x >= 0 (ReLU).

    The product's sign is the weight's sign, so negating the magnitude for
    negative weights makes a plain integer compare reproduce float ordering,
    including the both-negative case the paper's Fig. 2 text glosses over.
    """
    exp_w, mant_w, _, _ = fmt(name)
    top = 1 << (exp_w + mant_w)
    sw, _, _ = _split(w_bits, name)
    mag = alm_magnitude(x_bits, w_bits, name, variant)
    # Mirror the RTL bit-for-bit: {~sign, mag ^ {sign}}. Negating the magnitude
    # instead would collapse +0 and -0 to the same key, while the hardware keeps
    # them one apart -- invisible until the stimulus contains zeros.
    return np.where(sw == 1, mag ^ (top - 1), mag | top)


def exact_product(x_bits, w_bits, name="fp32"):
    return (from_bits(x_bits, name).astype(np.float64) *
            from_bits(w_bits, name).astype(np.float64))


def monotonicity_violations(n=2_000_000, seed=0, variant="literal", name="fp32"):
    """Fraction of random pairs where the ALM key mis-orders the true products."""
    _, _, _, flt = fmt(name)
    rng = np.random.default_rng(seed)
    x1 = np.abs(rng.normal(0, 1, n)).astype(flt)
    x2 = np.abs(rng.normal(0, 1, n)).astype(flt)
    w1 = rng.normal(0, 1, n).astype(flt)
    w2 = rng.normal(0, 1, n).astype(flt)

    k1 = sorting_key(to_bits(x1, name), to_bits(w1, name), name, variant)
    k2 = sorting_key(to_bits(x2, name), to_bits(w2, name), name, variant)
    p1 = exact_product(to_bits(x1, name), to_bits(w1, name), name)
    p2 = exact_product(to_bits(x2, name), to_bits(w2, name), name)

    strict = p1 != p2
    return np.mean((k1 > k2)[strict] != (p1 > p2)[strict])


def mam_vs_himam(num_neurons=200_000, n_inputs=8, seed=1, variant="literal", name="fp32"):
    """Table I methodology: exact MAM output vs HIMAM output on the same data."""
    _, _, _, flt = fmt(name)
    rng = np.random.default_rng(seed)
    x = np.abs(rng.normal(0, 1, (num_neurons, n_inputs))).astype(flt)
    w = rng.normal(0, 1, (num_neurons, n_inputs)).astype(flt)
    xb, wb = to_bits(x, name), to_bits(w, name)

    prod = exact_product(xb, wb, name)
    y_mam = prod.max(axis=1) + prod.min(axis=1)

    key = sorting_key(xb, wb, name, variant)
    rows = np.arange(num_neurons)
    y_himam = prod[rows, key.argmax(axis=1)] + prod[rows, key.argmin(axis=1)]

    err = y_himam - y_mam
    return {
        "MSE": float(np.mean(err ** 2)),
        "MAE": float(np.mean(np.abs(err))),
        "RMSE": float(np.sqrt(np.mean(err ** 2))),
        "mismatch_rate": float(np.mean((key.argmax(axis=1) != prod.argmax(axis=1)) |
                                       (key.argmin(axis=1) != prod.argmin(axis=1)))),
    }


def compare_variants(name="fp32"):
    for variant in ("literal", "mitchell"):
        viol = monotonicity_violations(variant=variant, name=name)
        stats = mam_vs_himam(variant=variant, name=name)
        print(f"[{name}] {variant:9s} pair-order violations = {viol:.4%}   "
              f"neuron mismatch = {stats['mismatch_rate']:.4%}")
        print(f"{'':9s}        MSE = {stats['MSE']:.3e}  MAE = {stats['MAE']:.3e}  "
              f"RMSE = {stats['RMSE']:.3e}")


if __name__ == "__main__":
    compare_variants("fp32")
    compare_variants("fp16")
