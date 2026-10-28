/*
 * PE HIL driver -- PS (Cortex-A53) pushes test vectors through AXI4-Lite to
 * the HIMAM processing element in the PL, polls DONE, reads Y and compares
 * every word against the bit-exact Python model.
 *
 * Register map (see rtl/pe_axi_lite.sv):
 *   0x000+4i X[i]  0x100+4i W[i]  0x200 BIAS  0x204 CTRL
 *   0x208 STATUS   0x20C Y        0x210 N     0x214 K       0x218 WAIT
 *   0x21C VEC_DONE 0x220 SCRATCH  0x224 SWTRIG
 *
 * Results are left in DDR at HIL_RESULT_ADDR so the host can read them over
 * JTAG with `mrd` even when no UART console is attached.
 */
#include <stdint.h>
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_mmu.h"
#include "xtime_l.h"

#include "hil_config.h"
#include "hil_vectors.h"

#define PE_BASE          0xA0000000U
#define HIL_RESULT_ADDR  0x10000000U

#define R_X(i)   (PE_BASE + 0x000U + 4U*(i))
#define R_W(i)   (PE_BASE + 0x100U + 4U*(i))
#define R_BIAS   (PE_BASE + 0x200U)
#define R_CTRL   (PE_BASE + 0x204U)
#define R_STATUS (PE_BASE + 0x208U)
#define R_Y      (PE_BASE + 0x20CU)
#define R_N      (PE_BASE + 0x210U)
#define R_K      (PE_BASE + 0x214U)
#define R_VEC    (PE_BASE + 0x21CU)
#define R_SCR    (PE_BASE + 0x220U)
#define R_TRIG   (PE_BASE + 0x224U)

#define ST_DONE  (1U << 0)
#define ST_BUSY  (1U << 1)

#define FNV_OFFSET 0x811C9DC5U
#define FNV_PRIME  16777619U

#if HIL_K == 0
#define HIL_VEC        hil_vec_k0
#define HIL_FNV_EXPECT HIL_FNV_EXPECTED_K0
#else
#define HIL_VEC        hil_vec_k4
#define HIL_FNV_EXPECT HIL_FNV_EXPECTED_K4
#endif

static inline uint32_t fnv_word(uint32_t h, uint32_t w)
{
    for (int i = 0; i < 4; i++) {
        h ^= (w & 0xFFU);
        h *= FNV_PRIME;
        w >>= 8;
    }
    return h;
}

int main(void)
{
    volatile uint32_t *res = (volatile uint32_t *)HIL_RESULT_ADDR;
    uint32_t mismatches = 0, first_idx = 0xFFFFFFFFU;
    uint32_t first_got = 0, first_exp = 0;
    uint32_t fnv_got = FNV_OFFSET, fnv_exp = FNV_OFFSET;
    uint32_t status = 0, vec_done = 0;
    XTime t0, t1;

    /* PL aperture is device memory: no caching, no speculative access. */
    Xil_SetTlbAttributes(PE_BASE, 0x14de2);

    xil_printf("\r\n[HIL] PE K=%d N=%d vectors=%d\r\n", HIL_K, HIL_N, HIL_NVEC);

    uint32_t n_rd = Xil_In32(R_N);
    uint32_t k_rd = Xil_In32(R_K);
    Xil_Out32(R_SCR, 0x5A5AC33CU);
    uint32_t scr_rd = Xil_In32(R_SCR);
    xil_printf("[HIL] N=%u K=%u scratch=%08X\r\n", n_rd, k_rd, scr_rd);

    /* Give the host time to arm the ILA after `con` (the capture is triggered
     * by the first START, so arming must complete before the vector loop). */
    XTime td, tn;
    XTime_GetTime(&td);
    do { XTime_GetTime(&tn); } while ((tn - td) < 5ULL * COUNTS_PER_SECOND);
    xil_printf("[HIL] ILA arm window elapsed, starting\r\n");

    /* First START also arms the ILA capture (SW trigger pulse). */
    Xil_Out32(R_TRIG, 1U);

    XTime_GetTime(&t0);
    for (uint32_t t = 0; t < HIL_NVEC; t++) {
        for (int i = 0; i < HIL_N; i++)
            Xil_Out32(R_X(i), HIL_VEC[t][i]);
        for (int i = 0; i < HIL_N; i++)
            Xil_Out32(R_W(i), HIL_VEC[t][HIL_N + i]);
        Xil_Out32(R_BIAS, HIL_VEC[t][2*HIL_N]);
        /* Poll VEC_DONE rather than DONE: the previous vector leaves DONE=1,
         * and AXI read/write channels are independent, so an early STATUS
         * read could return the previous vector's DONE.  VEC_DONE only
         * changes when this START has actually completed a vector. */
        uint32_t vd0 = Xil_In32(R_VEC);
        Xil_Out32(R_CTRL, ST_DONE);          /* START */

        uint32_t guard = 0;
        do {
            vec_done = Xil_In32(R_VEC);
            status = Xil_In32(R_STATUS);
        } while ((vec_done == vd0) && ++guard < 100000U);

        if (guard >= 100000U) {
            xil_printf("[HIL] TIMEOUT at vector %u (status=%08X)\r\n", t, status);
            mismatches = HIL_NVEC;
            first_idx = t;
            break;
        }

        uint32_t got = Xil_In32(R_Y);
        uint32_t exp = HIL_VEC[t][2*HIL_N + 1];
        fnv_got = fnv_word(fnv_got, got);
        fnv_exp = fnv_word(fnv_exp, exp);
        if (got != exp) {
            if (mismatches == 0) {
                first_idx = t;
                first_got = got;
                first_exp = exp;
            }
            mismatches++;
        }
        /* A write to CTRL bit1 clears DONE; START already does it, so the
         * next iteration's START is enough.  vec_done is read once at end. */
    }
    XTime_GetTime(&t1);

    vec_done = Xil_In32(R_VEC);
    uint32_t us = (uint32_t)((t1 - t0) * 1000000ULL / COUNTS_PER_SECOND);
    int pass = (mismatches == 0) && (vec_done == HIL_NVEC)
               && (fnv_got == fnv_exp) && (fnv_got == HIL_FNV_EXPECT);

    res[0]  = 0x48494C31U;           /* "HIL1" */
    res[1]  = HIL_NVEC;
    res[2]  = mismatches;
    res[3]  = first_idx;
    res[4]  = first_got;
    res[5]  = first_exp;
    res[6]  = fnv_got;
    res[7]  = fnv_exp;
    res[8]  = vec_done;
    res[9]  = status;
    res[10] = n_rd;
    res[11] = k_rd;
    res[12] = scr_rd;
    res[13] = us;
    res[14] = pass ? 0xA5A5A5A5U : 0xDEADDEADU;
    res[15] = HIL_FNV_EXPECT;
    Xil_DCacheFlushRange((UINTPTR)res, 128U);

    xil_printf("[HIL] done=%u vec_done=%u mismatches=%u time=%u us\r\n",
               (unsigned)pass, vec_done, mismatches, us);
    xil_printf("[HIL] fnv got=%08X exp=%08X model=%08X\r\n",
               fnv_got, fnv_exp, HIL_FNV_EXPECT);
    if (mismatches)
        xil_printf("[HIL] first mismatch idx=%u got=%08X exp=%08X\r\n",
                   first_idx, first_got, first_exp);
    xil_printf("[HIL] %s\r\n", pass ? "BIT-EXACT PASS" : "FAIL");

    while (1)
        ;

    return 0;
}
