/* Minimal PS initialisation for JTAG boot (no FSBL): runs the C psu_init generated in this design's
 * XSA on A53 #0 from OCM -- the PS part of what the FSBL does -- then opens the PS-PL interface.
 * Board runs showed psu_init.tcl over the DAP corrupts DDR block writes while the FSBL does not;
 * this is the FSBL's C code path without the rest of the FSBL.
 *
 * Status at PSINIT_STATUS (read with `mrd -force 0xFFFDFFF0 4`):
 *   [0] 0x50534901 done, 0x505349E1 psu_init reported a failure, 0x50534900 still running
 *   [1] psu_init return value (0 = OK)   [2] xil_printf calls (SERDES timeout messages)  */
#include <stdint.h>
#include "xil_io.h"

#define PSINIT_STATUS 0xFFFDFFF0UL

int psu_init(void);
unsigned long psu_ps_pl_isolation_removal_data(void);
unsigned long psu_ps_pl_reset_config_data(void);

/* Busy-wait at no more than one iteration per cycle of a 1.3 GHz A53: never shorter than asked.
 * psu_init only waits a few hundred microseconds in total. */
int usleep(unsigned long us)
{
    for (volatile uint64_t i = 0; i < (uint64_t)us * 1300ULL; i++)
        ;
    return 0;
}

unsigned sleep(unsigned int s)
{
    usleep(s * 1000000UL);
    return 0;
}

void xil_printf(const char *fmt, ...)
{
    (void)fmt;
    Xil_Out32(PSINIT_STATUS + 8, Xil_In32(PSINIT_STATUS + 8) + 1);
}

int main(void)
{
    Xil_Out32(PSINIT_STATUS + 8, 0);
    Xil_Out32(PSINIT_STATUS, 0x50534900U);
    int st = psu_init();
    Xil_Out32(PSINIT_STATUS + 4, (u32)st);
    psu_ps_pl_isolation_removal_data();
    psu_ps_pl_reset_config_data();
    Xil_Out32(PSINIT_STATUS, st ? 0x505349E1U : 0x50534901U);
    return 0;
}
