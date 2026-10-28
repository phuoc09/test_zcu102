/* PS init runs from OCM (DDR is not up yet), where the FSBL would run. */
ENTRY(_start)
SECTIONS
{
  . = 0xFFFC0000;
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
  . = . + 0x4000;            /* 16 KiB stack */
  __stack_top = .;
  ASSERT(__stack_top <= 0xFFFDFF00, "PS init does not fit below the status word")
}
