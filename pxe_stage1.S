# =====================================================================
#  TannX OS PXE stage 1 - made by Tannenbaum Media
#
#  The "no more stick juggling" boot path. A PXE-capable NIC's option
#  ROM (the firmware, NOT us) downloads pxe.img over the network at
#  boot and loads the WHOLE file to 0000:7C00, then jumps there in
#  real mode. pxe.img = this 512-byte stub + the flat kernel, so after
#  the download the kernel already sits at 0x7E00 - exactly where the
#  disk Stage 1 would have placed it. This stub therefore does NOT
#  touch the disk (there may be none): it just sets up segments and
#  jumps straight into Stage 2. From there the kernel is identical to
#  every other boot path.
#
#  Dev loop this enables: rebuild on the dev box -> reboot the test PC
#  (network boot) -> the new version runs. No re-flashing.
# =====================================================================
    .code16
    .section .text
    .global _start
_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x7c00, %sp
    sti
    cld
    mov $pxe_msg, %si            # a sign of life via BIOS teletype
px_putc:
    lodsb
    test %al, %al
    jz px_go
    mov $0x0e, %ah
    mov $0x0007, %bx
    int $0x10
    jmp px_putc
px_go:
    ljmp $0, $0x7e00            # Stage 2 is already in RAM (PXE loaded it)

pxe_msg: .asciz "TannX OS: network boot, kernel in RAM, jumping to stage 2...\r\n"

    .org 510
    .word 0xaa55
