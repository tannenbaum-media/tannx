# crt0.S - C runtime startup for ring-3 TannX OS programs.
#   Entered by the kernel (do_run) at USER_PROG_BASE with EIP here,
#   ESP = top of the user-stack region. We zero .bss (the linker
#   script gives us its bounds), call main(), then SYS_EXIT with
#   main's return value. SYS_EXIT never returns; the 1: loop is a
#   belt-and-braces guard in case it ever did.
    .section .text._start, "ax"
    .globl _start
_start:
    cld
    mov $__bss_start, %edi        # zero the .bss the program assumes is 0
    mov $__bss_end, %ecx
    sub %edi, %ecx
    xor %eax, %eax
    rep stosb
    xor %ebp, %ebp                # mark the bottom of the call chain
    call main                     # int main(void)
    mov %eax, %ebx               # exit code = main's return value
    mov $4, %eax                 # SYS_EXIT
    int $0x30
1:  jmp 1b

    .section .note.GNU-stack, "", @progbits   # non-exec stack, silence ld
