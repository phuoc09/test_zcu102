#!/usr/bin/env python3
"""Check the PS HIL result block and the ILA capture.

usage: check_result.py <K> <xsct log>
Reads results/ila_k<K>.csv when present and verifies the captured first-vector
operands/output against the same vector file the PS used.
"""
import csv
import re
import sys

K = int(sys.argv[1])
LOG = sys.argv[2]
ROOT = "."

MAGIC = 0x48494C31
PASS_FLAG = 0xA5A5A5A5
SCRATCH = 0x5A5AC33C


def parse_mrd(path):
    vals = []
    in_block = False
    for line in open(path, errors="replace"):
        if "HIL_MRD_BEGIN" in line:
            in_block = True
            continue
        if "HIL_MRD_END" in line:
            break
        if not in_block:
            continue
        m = re.search(r"=\s*(?:0x)?([0-9a-fA-F]{8})\b", line)
        if m:
            vals.append(int(m.group(1), 16))
            continue
        toks = line.split()
        if toks and re.fullmatch(r"[0-9a-fA-F]{8}", toks[-1]):
            vals.append(int(toks[-1], 16))
    return vals


def parse_num(s):
    s = s.strip()
    if s.startswith("0x") or s.startswith("0X"):
        return int(s, 16)
    if s and all(c in "01" for c in s) and len(s) > 8:
        return int(s, 2)
    if re.fullmatch(r"[0-9a-fA-F]+", s) and re.search(r"[a-fA-F]", s):
        return int(s, 16)
    return int(s, 0)


def split_words(val, n=16):
    # Probe is {x[N-1], ..., x[0]}; the CSV value is the same bit string.
    width = 32 * n
    s = f"{val:0{width}b}"
    return [int(s[width - 32 * (i + 1): width - 32 * i], 2) for i in range(n)]


def parse_ila(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    hi = next(i for i, r in enumerate(rows) if any(c.strip() == "TRIGGER" for c in r))
    header = [c.strip() for c in rows[hi]]
    data = rows[hi + 1:]
    idx = {name: i for i, name in enumerate(header)}

    def find(name):
        if name in idx:
            return idx[name]
        for k, v in idx.items():
            if k.startswith(name):
                return v
        return None

    def col(row, name, fallback=None):
        i = find(name)
        if i is None:
            i = fallback
        return parse_num(row[i]) if i is not None and i < len(row) else None

    trig_row = None
    for row in data:
        if trig_row is None:
            t = col(row, "TRIGGER")
            if t == 1:
                trig_row = row
    if trig_row is None:
        return None

    x = col(trig_row, "dbg_x_flat", 4)
    w = col(trig_row, "dbg_w_flat", 5)
    bias = col(trig_row, "dbg_bias", 6)

    done_row = None
    seen = False
    for row in data:
        if row is trig_row:
            seen = True
            continue
        if not seen:
            continue
        if col(row, "dbg_done", 8) == 1:
            done_row = row
            break
    y = col(done_row, "dbg_y", 7) if done_row is not None else None
    return {"x": x, "w": w, "bias": bias, "y": y, "depth": len(data), "ncols": len(header)}


def main():
    vals = parse_mrd(LOG)
    ok = True
    if len(vals) < 16:
        print(f"RESULT: FAIL -- only {len(vals)} result words parsed from {LOG}")
        return 1
    (magic, nvec, mism, first_idx, first_got, first_exp, fnv_got, fnv_exp,
     vec_done, status, n, k, scratch, us, flag, model_fnv) = vals[:16]

    checks = [
        ("magic", magic == MAGIC, f"{magic:08X}"),
        ("N", n == 16, str(n)),
        ("K", k == K, str(k)),
        ("scratch", scratch == SCRATCH, f"{scratch:08X}"),
        ("mismatches", mism == 0, str(mism)),
        ("vec_done", vec_done == nvec, f"{vec_done}/{nvec}"),
        ("fnv_got==fnv_exp", fnv_got == fnv_exp, f"{fnv_got:08X} vs {fnv_exp:08X}"),
        ("fnv==model", fnv_got == model_fnv, f"{fnv_got:08X} vs {model_fnv:08X}"),
        ("pass_flag", flag == PASS_FLAG, f"{flag:08X}"),
    ]
    for name, good, detail in checks:
        print(f"  {name:18s} {'PASS' if good else 'FAIL'}  {detail}")
        ok &= good

    print(f"RESULT: {'PASS' if ok else 'FAIL'}  nvec={nvec} mismatches={mism} "
          f"time={us} us  fnv={fnv_got:08X}")
    if mism:
        print(f"  first mismatch idx={first_idx} got={first_got:08X} exp={first_exp:08X}")

    # ILA cross-check against vector 0 (same file the app embedded).
    ila_path = f"results/ila_k{K}.csv"
    try:
        ila = parse_ila(ila_path)
    except FileNotFoundError:
        print(f"ILA: missing {ila_path} (capture did not run)")
        return 0 if ok else 1
    if ila is None or ila["y"] is None:
        print(f"ILA: capture present but no trigger/done row found ({ila_path})")
        return 0 if ok else 1

    hex_path = f"vectors/pevec_n16_k{K}.hex"
    first = [int(t, 16) for t in open(hex_path).readline().split()]
    exp_x, exp_w = first[0:16], first[16:32]
    exp_bias, exp_y = first[32], first[33]
    got_x, got_w = split_words(ila["x"]), split_words(ila["w"])
    ila_ok = (got_x == exp_x and got_w == exp_w
              and ila["bias"] == exp_bias and ila["y"] == exp_y)
    print(f"ILA: depth={ila['depth']} cols={ila['ncols']} "
          f"x/w/bias/y {'match' if ila_ok else 'MISMATCH'} vector 0")
    if not ila_ok:
        print(f"  x match={got_x == exp_x} w match={got_w == exp_w} "
              f"bias={ila['bias']:08X}/{exp_bias:08X} "
              f"y={ila['y']:08X}/{exp_y:08X}")
    return 0 if (ok and ila_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
