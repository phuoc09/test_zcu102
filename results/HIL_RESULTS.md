# HIL evidence sheet — HIMAM PE on ZCU102

> This flow checks **function** only (bit-exact outputs on the board). It does not measure
> energy: the PE draws ~0.27 W next to ~20 W for the board. The SAIF power table in
> `himam_lut/results/RESULTS.txt` stays the source for the PE energy analysis.

## 1. Vector set (`vectors/gen_hil_vectors.py`, `vectors/manifest.json`)

Same inputs for K = 0 and K = 4, expected `y` from the bit-exact Python model (`model/`).

| Part | Rows | Index | What it covers | Rows where y(K=0) ≠ y(K=4) |
|---|---|---|---|---|
| random | 2000 | 0–1999 | the set of the first board runs (seed 42, sparsity 0.5) | 26 |
| discrim | 1500 | 2000–3499 | rows where the ranking key decides `y`: 1000 with y(K=0) ≠ y(K=4), 500 where K = 4 ≠ exact ranking | 1000 |
| edge | 585 | 3500–4084 | all-zero x, ±0 weights, ties, equal and opposite products, bias cancellation (y = +0), exponents up to ±60, near ties inside one k = 4 bucket, one-signed weights, single non-zero x, round-half-even in both adds | 98 |
| **total** | **4085** | | | **1124** (first at index 23) |

FNV-1a over expected `y`: K = 0 `0xDFE4E261`, K = 4 `0x21517BF0`.
Not covered: subnormal or overflowing products (RTL flushes subnormals; the key datapath for those
exponents is checked by `tb_key` in simulation only).

## 2. Simulation (xsim 2022.1, `tb/run_sim.sh "0 4 cross"`, 28/10)

| Check | K = 0 (ALM) | K = 4 (LUT-ranking) | Cross: K = 4 vectors on K = 0 design |
|---|---|---|---|
| Vectors | 4085 | 4085 | 4085 |
| Errors | 0 | 0 | 1124, first at 23 (expected 1124, first 23) |
| Verdict | AXI PASS | AXI PASS | CROSS SIM OK |
| Log | `sim_axi/xsim_k0.log` | `sim_axi/xsim_k4.log` | `sim_axi/xsim_cross.log` |

## 3. Implementation (Vivado 2022.1, xczu9eg-ffvb1156-2-e)

| Item | K = 4 |
|---|---|
| Part / board | xczu9eg-ffvb1156-2-e / ZCU102 rev 1.0 |
| PL clock | 200 MHz (5.000 ns), MMCM from the 300 MHz SI570 (PS PL0 gives 187.5) |
| PS application | minimal bare-metal AArch64 ELF (no BSP/Vitis Java), MMIO + AXI-Lite |
| PE + AXI front-end LUTs (OOC) | 5270 (PE alone = 4444, from the area flow) |
| PE + AXI front-end FFs (OOC) | 4057 |
| Full HIL design (PE + AXI + ILA + PS glue) | 8852 LUT, 11050 FF, 31 BRAM, 0 DSP, 1 MMCM |
| ILA LUTs / BRAM | 3372 / 31 |
| WNS @ 200 MHz | **+0.043 ns** at 4.999 ns (200.02 MHz); all constraints met, WHS +0.010 ns |
| Bitstream / XSA | `hil_zcu102_k4.bit` / `hil_zcu102_k4.xsa` |

**K = 0 (ALM baseline), same flow:** 10331 LUT, 11309 FF, 31 BRAM, 0 DSP; **WNS +0.007 ns**
at 4.999 ns (all constraints met); `hil_zcu102_k0.bit`, `hil_zcu102_k0.xsa`.

## 4. Hardware runs (ZCU102 zcu102-1, xsct 2025.2, PS init by FSBL)

| Date / script | Vectors | K = 4 | K = 0 | Cross | Log |
|---|---|---|---|---|---|
| 28/10 `board_run_fsbl.tcl 4` (×2) | 2000 | PASS, 0 wrong, FNV `0xA85E4B0C` | — | — | `hil_run_zcu102_k4_PASS.log` |
| 28/10 `board_run.tcl 4 0` | 2000 | PASS, 0 wrong, FNV `0xA85E4B0C` | PASS, 0 wrong, FNV `0x6A15E630` | — | `hil_run_k4_k0.log` |
| next: `board_run.tcl` (4 0 cross) | 4085 | expect PASS, FNV `0x21517BF0` | expect PASS, FNV `0xDFE4E261` | expect 1124 wrong, first 23 | `hil_run_v4085.log` |

Run time of the PS loop: 21.2 ms for 2000 vectors (10.6 µs/vector). With the MMU and caches off
this is the AXI4-Lite MMIO rate of the A53, not the speed of the PE; it is not a throughput figure.

ILA capture: not taken yet (`HIL_ILA=1`, then `flow/arm_ila.tcl`).
