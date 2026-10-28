# HIL evidence sheet — HIMAM PE on ZCU102

> Fill the hardware rows after `flow/run_hil.sh` on a connected board.
> The SAIF power table in `himam_lut/results/RESULTS.txt` is **not** modified
> by this flow and remains the source for the PE energy analysis.

## 1. Functional equivalence (simulation, done)

| Check | K=0 (ALM) | K=4 (LUT-ranking) |
|---|---|---|
| AXI4-Lite + PE, vectors | 2000 | 2000 |
| Bit-exact errors | 0 | 0 |
| `vec_done` | 2000 | 2000 |
| Log | `results/sim_axi/xsim_k0.log` | `results/sim_axi/xsim_k4.log` |

FNV-1a reference over expected `y` (from `vectors/manifest.json`):
`K=0 0x6A15E630`, `K=4 0xA85E4B0C`.

## 2. Implementation (Vivado 2022.1, xczu9eg-ffvb1156-2-e)

| Item | K=4 |
|---|---|
| Part / board | xczu9eg-ffvb1156-2-e / ZCU102 rev 1.0 |
| PL clock | 200 MHz (5.000 ns), MMCM from the 300 MHz SI570 (PS PL0 gives 187.5) |
| PS application | minimal bare-metal AArch64 ELF (no BSP/Vitis Java), MMIO + AXI-Lite |
| PE + AXI front-end LUTs (OOC) | 5270 (PE alone = 4444, from the area flow) |
| PE + AXI front-end FFs (OOC) | 4057 |
| Full HIL design (PE + AXI + ILA + PS glue) | 8852 LUT, 11050 FF, 31 BRAM, 0 DSP, 1 MMCM |
| ILA LUTs / BRAM | 3372 / 31 |
| WNS @ 200 MHz | **+0.043 ns** at 4.999 ns (200.02 MHz); all constraints met, WHS +0.010 ns |
| Bitstream | `results/hil_zcu102_k4.bit` |
| XSA | `results/hil_zcu102_k4.xsa` |

**K=0 (ALM baseline), built with the same flow:** 10331 LUT, 11309 FF, 31 BRAM,
0 DSP; **WNS +0.007 ns** at 4.999 ns (all constraints met);
`results/hil_zcu102_k0.bit`, `hil_zcu102_k0.xsa`, `pe_hil_k0.elf`,
`psu_init_k0.tcl`.

## 3. Hardware run (pending board)

| Item | Value |
|---|---|
| Board detected | no (run `flow/run_hil.sh 4` when connected) |
| Vectors / mismatches | — |
| FNV got / expected | — |
| `vec_done` | — |
| Runtime (PS loop) | — µs |
| ILA capture | `results/ila_k4.csv` (1024 samples @ 5 ns) |
| ILA x/w/bias/y vs vector 0 | — |

Expected on success: `RESULT: PASS`, `mismatches=0`, `vec_done=2000`,
`fnv=0xA85E4B0C`, and the ILA row at `dbg_done=1` has
`dbg_y = 0x424D10B0` (word 34 of `vectors/pevec_n16_k4.hex` line 1).
