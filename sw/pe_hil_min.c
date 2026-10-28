/*
 * Minimal bare-metal PS driver for the HIL run -- no BSP, no Vitis Java, no
 * libc.  Compiled with aarch64-none-elf-gcc and downloaded with xsct `dow`.
 * psu_init.tcl has already initialised DDR and both UARTs.
 *
 * PS (A53) writes vectors over AXI4-Lite to the HIMAM PE in the PL, polls
 * VEC_DONE, reads Y and compares against the bit-exact Python model.
 * Results are left at 0x10000000 for the host's `mrd`, and printed on UART0
 * and UART1 (whichever is wired to the board's USB-UART).
 *
 * Progress for a run that never reaches the result block (`mrd -force 0x10000080 2`):
 *   [0] 0x5354000s, s = 1 entered main, 2 UART written, 3 first PL read issued,
 *       4 PL registers read back, 5 all vectors done, 6 result block written
 *   [1] index of the vector being processed
 * An exception record (see start.S) is at 0x10000040.
 */
#include <stdint.h>
#include "hil_config.h"
#include "hil_vectors.h"

#define PE_BASE          0xA0000000UL
#define HIL_RESULT_ADDR  0x10000000UL
#define HIL_EXC_ADDR     0x10000040UL
#define HIL_STAGE_ADDR   0x10000080UL
/* Host mailbox, written after `dow`: [0] = HIL_CTRL_MAGIC, [1] = ILA wait in ms.
 * Without the magic the app keeps the 5 s wait the ILA flow (flow/arm_ila.tcl) needs. */
#define HIL_CTRL_ADDR    0x100000C0UL
#define HIL_CTRL_MAGIC   0x57414954U    /* "WAIT" */
#define HIL_ILA_WAIT_MS  5000U
/* System counter (IOU_SCNTRS): psu_init / FSBL write its frequency and enable it. */
#define SCNTRS_CNTCR     0xFF260000UL
#define SCNTRS_FREQ      0xFF260020UL

#define R_X(i)   (PE_BASE + 0x000UL + 4UL*(i))
#define R_W(i)   (PE_BASE + 0x100UL + 4UL*(i))
#define R_BIAS   (PE_BASE + 0x200UL)
#define R_CTRL   (PE_BASE + 0x204UL)
#define R_STATUS (PE_BASE + 0x208UL)
#define R_Y      (PE_BASE + 0x20CUL)
#define R_N      (PE_BASE + 0x210UL)
#define R_K      (PE_BASE + 0x214UL)
#define R_VEC    (PE_BASE + 0x21CUL)
#define R_SCR    (PE_BASE + 0x220UL)
#define R_TRIG   (PE_BASE + 0x224UL)

#define ST_DONE  (1U << 0)

#define FNV_OFFSET 0x811C9DC5U
#define FNV_PRIME  16777619U

#define UART0_BASE 0xFF000000UL
#define UART1_BASE 0xFF010000UL
#define UART_SR    0x2CUL
#define UART_FIFO  0x30UL
#define UART_TXFULL (1U << 4)

#if HIL_K == 0
#define HIL_VEC        hil_vec_k0
#define HIL_FNV_EXPECT HIL_FNV_EXPECTED_K0
#else
#define HIL_VEC        hil_vec_k4
#define HIL_FNV_EXPECT HIL_FNV_EXPECTED_K4
#endif

static inline void wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
static inline uint32_t rd32(uintptr_t a) { return *(volatile uint32_t *)a; }
static inline void stage(uint32_t s) { wr32(HIL_STAGE_ADDR, 0x53540000U | s); }

static void uart_putc(uintptr_t base, char c)
{
    /* Never block forever if that UART is not clocked on this board. */
    for (int i = 0; i < 200000 && (rd32(base + UART_SR) & UART_TXFULL); i++)
        ;
    wr32(base + UART_FIFO, (uint32_t)(unsigned char)c);
}

static void uart_puts(const char *s)
{
    while (*s) {
        uart_putc(UART0_BASE, *s);
        uart_putc(UART1_BASE, *s);
        s++;
    }
}

static void uart_hex(uint32_t v)
{
    static const char h[] = "0123456789ABCDEF";
    char b[9];
    for (int i = 7; i >= 0; i--) { b[i] = h[v & 0xF]; v >>= 4; }
    b[8] = 0;
    uart_puts(b);
}

static inline uint64_t rd_cntpct(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, cntpct_el0" : "=r"(v));
    return v;
}

static inline uint64_t rd_cntfrq(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
    return v;
}

/* `rst -processor` clears CNTFRQ_EL0, so fall back to the frequency psu_init / FSBL left in
 * the system counter; make sure the counter runs.  Returns 0 if no usable timer. */
static uint64_t timer_freq(void)
{
    uint64_t f = rd_cntfrq();
    if (f <= 1000)
        f = rd32(SCNTRS_FREQ);
    if (f <= 1000)
        return 0;
    if (!(rd32(SCNTRS_CNTCR) & 1U))
        wr32(SCNTRS_CNTCR, rd32(SCNTRS_CNTCR) | 1U);
    uint64_t c0 = rd_cntpct();
    for (volatile int i = 0; i < 10000; i++)
        ;
    return rd_cntpct() != c0 ? f : 0;
}

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
    uint32_t status = 0, vec_done = 0, us = 0;

    for (int i = 0; i < 8; i++)          /* clear a stale exception record */
        wr32(HIL_EXC_ADDR + 4UL*i, 0U);
    wr32(HIL_STAGE_ADDR + 4UL, 0xFFFFFFFFU);
    stage(1);
    uart_puts("\r\n[HIL] bare-metal PS -> AXI4-Lite -> HIMAM PE\r\n");
    stage(2);

    stage(3);
    uint32_t n_rd = rd32(R_N);
    uint32_t k_rd = rd32(R_K);
    wr32(R_SCR, 0x5A5AC33CU);
    uint32_t scr_rd = rd32(R_SCR);
    stage(4);

    uart_puts("[HIL] N="); uart_hex(n_rd);
    uart_puts(" K="); uart_hex(k_rd);
    uart_puts(" scratch="); uart_hex(scr_rd);
    uart_puts(" vectors="); uart_hex(HIL_NVEC);
    uart_puts("\r\n");

    /* Let the host arm the ILA after `con`. */
    uint32_t wait_ms = (rd32(HIL_CTRL_ADDR) == HIL_CTRL_MAGIC) ? rd32(HIL_CTRL_ADDR + 4UL)
                                                              : HIL_ILA_WAIT_MS;
    uint64_t frq = timer_freq();
    uint64_t t0 = rd_cntpct();
    if (frq) {
        while ((rd_cntpct() - t0) < (uint64_t)wait_ms * frq / 1000ULL)
            ;
    } else {
        /* No timer: rough loop, ~5 s at 1.2 GHz for the default wait (much longer with caches off). */
        for (volatile uint64_t i = 0; i < (uint64_t)wait_ms * 300000ULL; i++)
            ;
    }

    wr32(R_TRIG, 1U);                    /* marker pulse in the ILA capture */

    uint64_t run0 = rd_cntpct();
    for (uint32_t t = 0; t < HIL_NVEC; t++) {
        wr32(HIL_STAGE_ADDR + 4UL, t);
        for (int i = 0; i < HIL_N; i++)
            wr32(R_X(i), HIL_VEC[t][i]);
        for (int i = 0; i < HIL_N; i++)
            wr32(R_W(i), HIL_VEC[t][HIL_N + i]);
        wr32(R_BIAS, HIL_VEC[t][2*HIL_N]);

        /* Poll VEC_DONE, not DONE: DONE is still set from the previous vector
         * and the AXI read/write channels are independent. */
        uint32_t vd0 = rd32(R_VEC);
        wr32(R_CTRL, ST_DONE);           /* START */

        uint32_t guard = 0;
        do {
            vec_done = rd32(R_VEC);
            status = rd32(R_STATUS);
        } while ((vec_done == vd0) && ++guard < 100000U);

        if (guard >= 100000U) {
            uart_puts("[HIL] TIMEOUT\r\n");
            mismatches = HIL_NVEC;
            first_idx = t;
            break;
        }

        uint32_t got = rd32(R_Y);
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
    }
    uint64_t run1 = rd_cntpct();
    stage(5);
    if (frq > 1000)
        us = (uint32_t)((run1 - run0) * 1000000ULL / frq);

    vec_done = rd32(R_VEC);
    int pass = (mismatches == 0) && (vec_done == HIL_NVEC)
               && (fnv_got == fnv_exp) && (fnv_got == HIL_FNV_EXPECT);

    res[0]  = 0x48494C31U;
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
    stage(6);

    uart_puts("[HIL] done=");   uart_hex((uint32_t)pass);
    uart_puts(" vec_done=");    uart_hex(vec_done);
    uart_puts(" mismatches=");  uart_hex(mismatches);
    uart_puts(" us=");          uart_hex(us);
    uart_puts("\r\n[HIL] fnv got="); uart_hex(fnv_got);
    uart_puts(" exp="); uart_hex(fnv_exp);
    uart_puts(" model="); uart_hex(HIL_FNV_EXPECT);
    uart_puts("\r\n");
    if (mismatches) {
        uart_puts("[HIL] first mismatch idx="); uart_hex(first_idx);
        uart_puts(" got="); uart_hex(first_got);
        uart_puts(" exp="); uart_hex(first_exp);
        uart_puts("\r\n");
    }
    uart_puts(pass ? "[HIL] BIT-EXACT PASS\r\n" : "[HIL] FAIL\r\n");

    while (1)
        ;
    return 0;
}
