/* Minimal bare-metal ELF layout for the HIL app.
 * Loaded by xsct `dow` at 0x00100000 (low DDR, initialised by psu_init). */
ENTRY(_start)
SECTIONS
{
  . = 0x00100000;
  .text : {
    KEEP(*(.text.boot))
    *(.text*)
  }
  .rodata : { *(.rodata*) }
  .data   : { *(.data*) }
  . = ALIGN(8);              /* start.S clears .bss with 8-byte stores */
  .bss    : {
    __bss_start = .;
    *(.bss*) *(COMMON)
    . = ALIGN(8);
    __bss_end = .;
  }
  . = ALIGN(16);
  . = . + 0x100000;          /* 1 MiB stack */
  __stack_top = .;
}
