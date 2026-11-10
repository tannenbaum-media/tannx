/* TannX OS linker script: everything from 0x7C00 up (the BIOS load address) */
ENTRY(_start)
SECTIONS
{
    . = 0x7C00;
    .text : { *(.text) }
    /DISCARD/ : { *(.note*) *(.eh_frame*) *(.comment) *(.rela*) }
}
