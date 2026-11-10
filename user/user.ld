/* user.ld - link a ring-3 TannX OS C program as a flat binary at the
 * fixed userspace base. ENTRY(_start) is crt0; it must be the very
 * first byte of .text (0x400000), so crt0.o is linked first. No
 * relocations, no GOT/PLT (built -fno-pic -fno-pie, checked with
 * objdump). .bss is NOT in the binary - crt0 zeroes it at runtime. */
ENTRY(_start)
SECTIONS {
  . = 0x00400000;                 /* USER_PROG_BASE (must match the kernel) */
  .text   : { *(.text._start) *(.text) *(.text.*) }
  .rodata : { *(.rodata) *(.rodata.*) }
  .data   : { *(.data) *(.data.*) }
  . = ALIGN(16);
  __bss_start = .;
  .bss    : { *(.bss) *(.bss.*) *(COMMON) }
  . = ALIGN(16);
  __bss_end = .;
  /DISCARD/ : { *(.eh_frame) *(.comment) *(.note*) *(.got*) *(.plt*) }
}
