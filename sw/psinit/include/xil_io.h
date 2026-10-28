/* Just enough of the Xilinx standalone BSP for psu_init.c from the XSA. */
#ifndef XIL_IO_H
#define XIL_IO_H
#include <stdint.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uintptr_t UINTPTR;
static inline u32 Xil_In32(UINTPTR a) { return *(volatile u32 *)a; }
static inline void Xil_Out32(UINTPTR a, u32 v) { *(volatile u32 *)a = v; }
void xil_printf(const char *fmt, ...);
#endif
