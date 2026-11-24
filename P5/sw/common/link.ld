/* link.ld - memory layout for the rv32_edu SoCs.
 * RAM starts at address 0.  Its size defaults to 16 KiB; the build passes
 * -Wl,--defsym=__ram_size=4096 for the small FPGA image.
 * The stack starts at the top of RAM and grows down. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x00000000, LENGTH = DEFINED(__ram_size) ? __ram_size : 16K
}

SECTIONS
{
  .text : {
    *(.text.init)              /* _start must be at address 0 (reset PC) */
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(4) {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > RAM

  .data : ALIGN(4) {
    *(.data .data.* .sdata .sdata.*)
  } > RAM

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  /DISCARD/ : { *(.riscv.attributes) *(.comment) }
}
