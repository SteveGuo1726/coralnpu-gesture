ENTRY(_start)

SECTIONS
{
  . = 0x00100000;

  .text : ALIGN(4)
  {
    *(.text.start)
    *(.text*)
    *(.rodata*)
  }

  .data : ALIGN(4)
  {
    *(.data*)
  }

  .bss : ALIGN(4)
  {
    *(.bss*)
    *(COMMON)
  }

  /DISCARD/ :
  {
    *(.ARM.exidx*)
    *(.ARM.extab*)
    *(.comment)
    *(.note*)
  }
}
