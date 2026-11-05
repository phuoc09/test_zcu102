/* Minimal bare-metal PS driver for the DMA streaming design (pe_axis). Bit-exact check of
 * every output word, plus PL-side cycle counters (see rtl/pe_axis.sv). Results at 0x10000000. */
#include <stdint.h>
#include "hil_config.h"
#include "hil_vectors.h"

#define HIL_RESULT_ADDR  0x10000000UL
#define HIL_EXC_ADDR     0x10000040UL
#define HIL_STAGE_ADDR   0x10000080UL


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

static inline uint32_t fnv_word(uint32_t h, uint32_t w)
{
    for (int i = 0; i < 4; i++) {
        h ^= (w & 0xFFU);
        h *= FNV_PRIME;
        w >>= 8;
    }
    return h;
}


/* ---- DMA design: PS DDR -> AXI DMA MM2S -> pe_axis -> AXI DMA S2MM -> PS DDR ---- */
#define DMA_BASE   0xA0000000UL
#define STAT_BASE  0xA0010000UL
#define MM2S_CR  (DMA_BASE + 0x00)
#define MM2S_SR  (DMA_BASE + 0x04)
#define MM2S_SA  (DMA_BASE + 0x18)
#define MM2S_SAH (DMA_BASE + 0x1C)
#define MM2S_LEN (DMA_BASE + 0x28)
#define S2MM_CR  (DMA_BASE + 0x30)
#define S2MM_SR  (DMA_BASE + 0x34)
#define S2MM_DA  (DMA_BASE + 0x48)
#define S2MM_DAH (DMA_BASE + 0x4C)
#define S2MM_LEN (DMA_BASE + 0x58)
#define DMA_RS     1U
#define DMA_RESET  4U
#define DMA_IDLE   2U
#define DMA_ERRS   0x70U           /* DMAIntErr | DMASlvErr | DMADecErr */

#define ST_CYC   (STAT_BASE + 0x00)
#define ST_VECS  (STAT_BASE + 0x04)
#define ST_K     (STAT_BASE + 0x08)
#define ST_STALL (STAT_BASE + 0x0C)
#define ST_CLR   (STAT_BASE + 0x10)
#define ST_STARV (STAT_BASE + 0x14)

#ifndef REP
#define REP 50U                    /* the HIL_NVEC-vector set is streamed REP times in one transfer */
#endif
#define REC_WORDS 36U              /* 9 beats x 4 words */
/* pe_axis packs four Y per output beat, so a transfer must hold a multiple of 4 records:
 * the set is padded by repeating its first vectors (4085 -> 4088). */
#define NV ((HIL_NVEC + 3U) & ~3U)
#define IN_BUF   0x20000000UL
#define OUT_BUF  0x30000000UL

static void dma_reset(void)
{
    wr32(MM2S_CR, DMA_RESET);
    wr32(S2MM_CR, DMA_RESET);
    for (int i = 0; i < 100000 && ((rd32(MM2S_CR) | rd32(S2MM_CR)) & DMA_RESET); i++)
        ;
}

/* One streamed pass of nrec records; returns 0 on success.  PS timer ticks in *ticks. */
static int run_pass(uint32_t nrec, uint64_t *ticks)
{
    uint32_t in_bytes = nrec * REC_WORDS * 4U, out_bytes = nrec * 4U;
    dma_reset();
    wr32(ST_CLR, 1U);
    wr32(S2MM_CR, DMA_RS);
    wr32(S2MM_DA, (uint32_t)OUT_BUF); wr32(S2MM_DAH, 0);
    wr32(MM2S_CR, DMA_RS);
    wr32(MM2S_SA, (uint32_t)IN_BUF);  wr32(MM2S_SAH, 0);
    uint64_t t0 = rd_cntpct();
    wr32(S2MM_LEN, out_bytes);       /* arm the receive side first */
    wr32(MM2S_LEN, in_bytes);        /* this starts the stream */
    uint32_t guard = 0;
    while (!(rd32(S2MM_SR) & DMA_IDLE)) {
        if ((rd32(S2MM_SR) | rd32(MM2S_SR)) & DMA_ERRS) return 2;
        if (++guard > 200000000U) return 1;
    }
    *ticks = rd_cntpct() - t0;
    return (rd32(S2MM_SR) | rd32(MM2S_SR)) & DMA_ERRS ? 2 : 0;
}

static void put_dec(uint64_t v)
{
    char b[24]; int n = 0;
    if (!v) b[n++] = '0';
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) { char c[2] = { b[--n], 0 }; uart_puts(c); }
}

int main(void)
{
    volatile uint32_t *res = (volatile uint32_t *)HIL_RESULT_ADDR;
    volatile uint32_t *in  = (volatile uint32_t *)IN_BUF;
    volatile uint32_t *out = (volatile uint32_t *)OUT_BUF;
    for (int i = 0; i < 8; i++) wr32(HIL_EXC_ADDR + 4UL*i, 0U);
    stage(1);
    uart_puts("\r\n[DMA] PS DDR -> AXI DMA -> pe_axis -> AXI DMA -> PS DDR\r\n");
    uart_puts("[DMA] K="); uart_hex(rd32(ST_K));
    uart_puts(" nvec="); uart_hex(HIL_NVEC); uart_puts(" padded="); uart_hex(NV); uart_puts(" rep="); uart_hex(REP); uart_puts("\r\n");
    stage(2);

    /* Build REP copies of the HIL_NVEC-vector set as 36-word records (X, W, BIAS, 3 pad). */
    for (uint32_t r = 0; r < REP; r++)
        for (uint32_t t = 0; t < NV; t++) {
            volatile uint32_t *d = in + ((uint64_t)r * NV + t) * REC_WORDS;
            for (uint32_t i = 0; i < 2*HIL_N + 1; i++) d[i] = HIL_VEC[t % HIL_NVEC][i];
            d[33] = d[34] = d[35] = 0;
        }
    stage(3);

    uint32_t mism = 0, first_idx = 0xFFFFFFFFU, first_got = 0, first_exp = 0;
    uint32_t rc[2], pass_vec[2], cyc[2], stall[2], starve[2], vecs[2];
    uint64_t tk[2];
    uint32_t nrecs[2] = { NV, NV * REP };
    for (int p = 0; p < 2; p++) {
        for (uint32_t i = 0; i < nrecs[p]; i++) out[i] = 0xDEADBEEFU;
        rc[p] = run_pass(nrecs[p], &tk[p]);
        cyc[p] = rd32(ST_CYC); vecs[p] = rd32(ST_VECS);
        stall[p] = rd32(ST_STALL); starve[p] = rd32(ST_STARV);
        pass_vec[p] = 0;
        if (rc[p]) continue;
        for (uint32_t i = 0; i < nrecs[p]; i++) {
            uint32_t got = out[i], exp = HIL_VEC[(i % NV) % HIL_NVEC][2*HIL_N + 1];
            if (got != exp) {
                if (!mism) { first_idx = i; first_got = got; first_exp = exp; }
                mism++;
            } else pass_vec[p]++;
        }
    }
    stage(5);

    uint64_t frq = rd_cntfrq();
    int pass = !rc[0] && !rc[1] && !mism && vecs[0] == nrecs[0] && vecs[1] == nrecs[1];
    res[0] = 0x444D4131U;  res[1] = nrecs[1];  res[2] = mism;  res[3] = first_idx;
    res[4] = first_got;    res[5] = first_exp; res[6] = rc[0];  res[7] = rc[1];
    res[8] = cyc[1];       res[9] = vecs[1];   res[10] = stall[1]; res[11] = starve[1];
    res[12] = (uint32_t)tk[1]; res[13] = (uint32_t)frq; res[14] = pass ? 0xA5A5A5A5U : 0xDEADDEADU;
    res[15] = rd32(ST_K);
    stage(6);

    for (int p = 0; p < 2; p++) {
        uart_puts("[DMA] pass "); put_dec((uint64_t)p);
        uart_puts(" nvec="); put_dec(nrecs[p]);
        uart_puts(" rc="); put_dec(rc[p]);
        uart_puts(" ok="); put_dec(pass_vec[p]);
        uart_puts(" pl_cycles="); put_dec(cyc[p]);
        uart_puts(" vecs="); put_dec(vecs[p]);
        uart_puts(" stall_in="); put_dec(stall[p]);
        uart_puts(" starve="); put_dec(starve[p]);
        uart_puts(" ps_ticks="); put_dec(tk[p]);
        uart_puts("\r\n");
    }
    uart_puts("[DMA] cntfrq="); put_dec(frq);
    uart_puts(" mismatches="); put_dec(mism);
    if (mism) { uart_puts(" first idx="); uart_hex(first_idx);
                uart_puts(" got="); uart_hex(first_got); uart_puts(" exp="); uart_hex(first_exp); }
    uart_puts(pass ? "\r\n[DMA] BIT-EXACT PASS\r\n" : "\r\n[DMA] FAIL\r\n");
    while (1) ;
    return 0;
}
