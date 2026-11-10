# =====================================================================
#  TannX OS UEFI stage 0 - made by Tannenbaum Media
#
#  A complete PE32+ executable laid out BY HAND in GNU assembler -
#  no compiler, no gnu-efi. The file from objcopy IS the .EFI binary.
#
#  What it does:
#    1. banner via ConOut (UTF-16)
#    2. open kernel32.bin on our own ESP (LoadedImage -> DeviceHandle
#       -> SimpleFileSystem -> root->Open -> file->Read)
#    3. collect the GOP framebuffer (base, resolution) for the kernel console
#    4. GetMemoryMap + ExitBootServices - the firmware is gone now
#    5. copy the flat kernel image to its linked home 0x7C00, drop a
#       boot-info block at 0x28000 (UEFI_INFO: magic "UEFI", fb data)
#    6. lgdt the KERNEL's own GDT (pointer at fixed offset 500 in the
#       image), far-jump into a 32-bit code segment (compatibility
#       mode), switch paging off, EFER.LME off, CR4.PAE off - plain
#       protected mode - and jump to uefi_entry32 (offset 504).
#
#  Why it loads anywhere: code is 100% RIP-relative + a .reloc section
#  with two no-op entries (EDK2 wants one to relocate at all).
#
#  Layout (FileAlignment = SectionAlignment = 0x200, identity-mapped):
#    0x000  DOS header   0x040 PE headers + section table
#    0x200  .text  (0x800)   0xA00  .reloc (0x200)   0xC00 end
#
#  x64 EFI calling convention (Microsoft): RCX, RDX, R8, R9 + 32 bytes
#  shadow space; 5th argument at [RSP+0x20]; RBX/RBP/RSI/RDI/R12-R15
#  are callee-saved (we never return on success, on error we hang).
# =====================================================================
    .code64
    .section .text

# --------------------------- DOS header -----------------------------
    .ascii "MZ"
    .org 0x3c
    .long 0x40                   # e_lfanew

# --------------------------- PE header ------------------------------
    .org 0x40
    .ascii "PE\0\0"
    .word 0x8664                 # Machine: x86-64
    .word 2                      # NumberOfSections
    .long 0                     # TimeDateStamp
    .long 0                     # PointerToSymbolTable
    .long 0                     # NumberOfSymbols
    .word 0xf0                   # SizeOfOptionalHeader
    .word 0x022e                 # Characteristics
# ---------------------- optional header (PE32+) ----------------------
    .word 0x020b                 # Magic: PE32+
    .byte 0, 0
    .long 0x800                  # SizeOfCode
    .long 0x200                  # SizeOfInitializedData
    .long 0                     # SizeOfUninitializedData
    .long 0x200                  # AddressOfEntryPoint
    .long 0x200                  # BaseOfCode
    .quad 0x140000000            # ImageBase (cosmetic - we are PIC)
    .long 0x200                  # SectionAlignment
    .long 0x200                  # FileAlignment
    .word 0, 0                   # OS version
    .word 0, 0                   # image version
    .word 0, 0                   # subsystem version
    .long 0                     # Win32VersionValue
    .long 0xc00                  # SizeOfImage
    .long 0x200                  # SizeOfHeaders
    .long 0                     # CheckSum
    .word 10                     # Subsystem: EFI_APPLICATION
    .word 0                     # DllCharacteristics
    .quad 0x10000                # SizeOfStackReserve
    .quad 0x1000                 # SizeOfStackCommit
    .quad 0x10000                # SizeOfHeapReserve
    .quad 0x1000                 # SizeOfHeapCommit
    .long 0                     # LoaderFlags
    .long 16                     # NumberOfRvaAndSizes
    .quad 0                     # export
    .quad 0                     # import
    .quad 0                     # resource
    .quad 0                     # exception
    .quad 0                     # certificate
    .long 0xa00, 12              # base relocation -> our .reloc
    .quad 0                     # debug
    .quad 0                     # architecture
    .quad 0                     # global ptr
    .quad 0                     # TLS
    .quad 0                     # load config
    .quad 0                     # bound import
    .quad 0                     # IAT
    .quad 0                     # delay import
    .quad 0                     # CLR
    .quad 0                     # reserved

# --------------------------- section table --------------------------
    .ascii ".text\0\0\0"
    .long 0x800                  # VirtualSize
    .long 0x200                  # VirtualAddress
    .long 0x800                  # SizeOfRawData
    .long 0x200                  # PointerToRawData
    .long 0, 0
    .word 0, 0
    .long 0x60000020             # CODE | EXECUTE | READ

    .ascii ".reloc\0\0"
    .long 12
    .long 0xa00
    .long 0x200
    .long 0xa00
    .long 0, 0
    .word 0, 0
    .long 0x42000040             # INITIALIZED_DATA | DISCARDABLE | READ

# ============================ .text ==================================
    .org 0x200
# entry(RCX = ImageHandle, RDX = EFI_SYSTEM_TABLE*)
# stack frame after sub: 0x00 shadow | 0x20 arg5 | 0x28,0x30,0x38,
# 0x40, 0x48, 0x50, 0x58 locals (see uses below)
uefi_entry:
    sub $0xC8, %rsp              # entry RSP%16==8 -> 8+0xC8 keeps calls aligned
                                 #   (0x60..0xC0 stages the GOP mode list; see below)
    mov %rcx, %r12               # ImageHandle
    mov %rdx, %r13               # SystemTable
    mov 96(%r13), %r14           # BootServices

    mov 64(%r13), %rcx           # banner via ConOut->OutputString
    lea msg_hello(%rip), %rdx
    call *8(%rcx)

    # --- our own device -> filesystem -> kernel32.bin ---------------
    mov %r12, %rcx               # HandleProtocol(image, &LoadedImage)
    lea guid_li(%rip), %rdx
    lea 0x28(%rsp), %r8
    call *152(%r14)
    test %rax, %rax
    jnz fail
    mov 0x28(%rsp), %rax
    mov 24(%rax), %rcx           # LoadedImage->DeviceHandle
    lea guid_sfs(%rip), %rdx     # HandleProtocol(dev, &SimpleFileSystem)
    lea 0x28(%rsp), %r8
    call *152(%r14)
    test %rax, %rax
    jnz fail
    mov 0x28(%rsp), %rcx
    lea 0x30(%rsp), %rdx
    call *8(%rcx)                # fs->OpenVolume(&root)
    test %rax, %rax
    jnz fail
    mov 0x30(%rsp), %rcx         # root->Open(&file, L"kernel32.bin", READ)
    lea 0x28(%rsp), %rdx
    lea fname(%rip), %r8
    mov $1, %r9d
    movq $0, 0x20(%rsp)          # attributes (arg 5)
    call *8(%rcx)
    test %rax, %rax
    jnz fail

    xor %ecx, %ecx               # AllocatePages(AnyPages, LoaderData,
    mov $2, %edx                 #   v2.77: 32 pages = 128 KB (256-sector kernel)
    mov $32, %r8d
    lea 0x38(%rsp), %r9
    call *40(%r14)
    test %rax, %rax
    jnz fail
    mov 0x38(%rsp), %r15         # R15 = kernel buffer

    movq $0x20000, 0x40(%rsp)    # file->Read(&size=128K, buffer) - v2.77 256 sectors
    mov 0x28(%rsp), %rcx
    lea 0x40(%rsp), %rdx
    mov %r15, %r8
    call *32(%rcx)
    test %rax, %rax
    jnz fail
    cmpw $0xaa55, 510(%r15)      # smells like our boot image?
    jne fail

    mov 64(%r13), %rcx           # progress report - the last words
    lea msg_loaded(%rip), %rdx   # before ExitBootServices
    call *8(%rcx)

    # --- GOP framebuffer for the 6.4 console (optional) -------------
    lea guid_gop(%rip), %rcx     # LocateProtocol(&gop, 0, &loc)
    xor %edx, %edx
    lea 0x28(%rsp), %r8
    call *320(%r14)
    xor %ebx, %ebx               # RBX = fb base (0 = none)
    xor %edi, %edi               # RDI = vres<<32 | hres
    xor %esi, %esi               # ESI = pixels per scanline
    xor %ebp, %ebp               # RBP = GOP mode count (0 = none; the loop
                                 #   below sets it, the post-EBS flush reads it)
    test %rax, %rax
    jnz no_gop
    # --- enumerate the available GOP modes (read-only) ---------------
    # QueryMode each mode and STAGE (vres<<16)|hres on OUR OWN stack at
    # 0x60(%rsp)+i*4. NO SetMode (the boot mode stays as the firmware chose
    # it; the kernel 'display' command just lists these). The list is copied
    # to UEFI_INFO (0x28000+0x1c/0x20) AFTER ExitBootServices - so we NEVER
    # touch the firmware-owned 0x28000 page pre-EBS (an audit found the old code
    # wrote it here and re-read the loop bound from it every iteration; a
    # firmware that owned/staled that page could then run the loop away).
    # The bound now lives in RBX, so the loop is register-bounded regardless.
    # (RBX/RDI/RSI are free here - set to the current mode below; RBP carries
    # the count out; QueryMode preserves non-volatiles.)
    mov 0x28(%rsp), %rax         # gop
    mov 24(%rax), %rax           # gop->Mode
    mov (%rax), %ebx             # RBX = Mode->MaxMode = loop bound (a register,
    cmp $24, %ebx                #   not the hazard page)
    jbe gop_cnt_ok
    mov $24, %ebx                # cap the staged list at 24 entries
gop_cnt_ok:
    xor %ebp, %ebp               # RBP = mode index
gop_enum:
    cmp %ebx, %ebp               # index >= count? (unsigned, bound in RBX)
    jae gop_enum_done
    mov 0x28(%rsp), %rcx         # arg1 This = gop
    mov %rbp, %rdx               # arg2 ModeNumber = index
    lea 0x30(%rsp), %r8          # arg3 &SizeOfInfo
    lea 0x38(%rsp), %r9          # arg4 &Info
    mov 0x28(%rsp), %rax
    call *(%rax)                 # gop->QueryMode (offset 0)
    xor %ecx, %ecx               # default 0x0 on a failed query
    test %rax, %rax
    jnz gop_store
    mov 0x38(%rsp), %rax         # Info*
    mov 4(%rax), %ecx            # HorizontalResolution
    movzwl %cx, %ecx             #   width = low 16
    mov 8(%rax), %edx            # VerticalResolution
    shl $16, %edx
    or %edx, %ecx                # ECX = (height<<16) | width
gop_store:
    mov %ecx, 0x60(%rsp,%rbp,4)  # stage on OUR stack (safe pre-EBS), NOT 0x28000
    inc %rbp
    jmp gop_enum
gop_enum_done:                   # RBP == count (staged entries); RBX reused below
    mov 0x28(%rsp), %rax
    mov 24(%rax), %rax           # gop->Mode
    mov 24(%rax), %rbx           # Mode->FrameBufferBase
    mov 8(%rax), %rax            # Mode->Info
    mov 8(%rax), %edi            # VerticalResolution
    shl $32, %rdi
    mov 4(%rax), %ecx            # HorizontalResolution
    or  %rcx, %rdi
    mov 32(%rax), %esi           # PixelsPerScanLine
no_gop:

    xor %ecx, %ecx               # AllocatePages(AnyPages, LoaderData, 16 pages
    mov $2, %edx                 #   = 64 KB): generous headroom so GetMemoryMap
    mov $16, %r8d                #   fits even a fragmented real-HW memory map
    lea 0x48(%rsp), %r9          #   (was 8 pages/32 KB - a bigger map overflowed
    call *40(%r14)               #   it, and the old loop then spun forever)
    test %rax, %rax
    jnz fail

    movl $16, 0xC0(%rsp)         # bound the retry: a stale mapkey needs one more
                                 #   GetMemoryMap, but this must NEVER hang. 0xC0 is
                                 #   free stack (just past the GOP stage 0x60..0xC0)
ebs_retry:
    movq $0x10000, 0x40(%rsp)    # mapsize (in/out) = the 64 KB we allocated
    lea 0x40(%rsp), %rcx
    mov 0x48(%rsp), %rdx
    lea 0x50(%rsp), %r8          # &mapkey
    lea 0x58(%rsp), %r9          # &descsize
    lea 0x38(%rsp), %rax         # &descversion (arg 5)
    mov %rax, 0x20(%rsp)
    call *56(%r14)               # GetMemoryMap
    test %rax, %rax              # too small / any error: do NOT hand a garbage
    jnz fail                     #   mapkey to EBS (that was the infinite spin) -
                                 #   boot services are still up, so 'fail' reports it
    mov %r12, %rcx
    mov 0x50(%rsp), %rdx
    call *232(%r14)              # ExitBootServices(image, mapkey)
    test %rax, %rax
    jz ebs_done                  # success -> the machine is ours
    decl 0xC0(%rsp)              # map changed under us: re-map + retry, bounded
    jnz ebs_retry
    jmp fail                     # too many retries -> clean diagnostic + halt
ebs_done:

    # --- the machine is ours now -------------------------------------
    cli
    cld
    call com2_init               # SOL on server boards is COM2 (0x2F8): program it
    mov $0x41, %al               # DEBUG 'A': survived ExitBootServices
    call dbg_out
    xor %eax, %eax               # bar 0 (red) on the GOP framebuffer
    call dbg_bar
    call dbg_dump                # handover state + firmware memory map -> serial
    movl $0x49464555, 0x28000    # boot info: magic "UEFI" (v2.77: UEFI_INFO 0x28000)
    mov %rbx, 0x28008            # +8  fb base
    mov %rdi, 0x28010            # +16 vres<<32 | hres
    mov %esi, 0x28018            # +24 pixels per scanline
    # --- flush the GOP mode list staged on our stack (post-EBS: 0x28000 is
    #     ours now, so no firmware-owned-page hazard). RBP = entry count. ----
    mov %ebp, 0x2801c            # +0x1c mode count
    lea 0x60(%rsp), %rsi         # source: the staged list
    mov $0x28020, %edi           # dest: UEFI_INFO+0x20
    mov %ebp, %ecx               # count dwords (0 -> copies nothing)
    rep movsl
    call ram_total               # usable RAM below 4 GB -> 0x4000 (E820_TOTAL)
    mov %r15, %rsi               # copy kernel to its linked home
    mov $0x7c00, %edi
    mov $0x20000, %ecx           # v2.77: copy 128 KB (the whole 256-sector image)
    rep movsb

    mov $0x42, %al               # DEBUG 'B': kernel copied to 0x7C00
    call dbg_out
    mov $1, %eax                 # bar 1
    call dbg_bar
    mov 0x7c00+516, %eax         # kernel handoff: gdtr address
    movzwl (%rax), %ecx          # build a 10-byte long-mode lgdt
    mov %cx, 0x40(%rsp)          # operand from the kernel's 6-byte one
    mov 2(%rax), %eax            # (limit word + zero-extended base)
    mov %rax, 0x42(%rsp)
    lgdt 0x40(%rsp)
    mov $0x43, %al               # DEBUG 'C': kernel GDT loaded
    call dbg_out
    mov $2, %eax                 # bar 2
    call dbg_bar
    mov 0x7c00+520, %ebx         # EBX = uefi_entry32 (survives the drop)
    # The firmware may load this image ABOVE 4 GB (AMI on a 32 GB Xeon box
    #   honours ImageBase 0x140000000): a 32-bit code segment cannot run
    #   there, the far return truncated EIP and the box triple-faulted. So
    #   the position-independent descent runs from a low copy at DESCENT_LO
    #   (the kernel's IDT page, built only later - free scratch right now).
    lea descent32(%rip), %rsi
    mov $DESCENT_LO, %edi
    mov $descent32_end-descent32, %ecx
    rep movsb
    mov $DESCENT_LO, %eax
    push $8                      # far "return" into the kernel's
    push %rax                    # 32-bit code segment 0x08
    lretq
    .equ DESCENT_LO, 0x2f000

# The 'ABCDE' markers STAY: after ExitBootServices there is no console
# and no debugger - on real hardware (6.5) these five raw COM1 bytes
# are the only way to see where a dying descent got to. They already
# earned their keep once: 'ABCDE' + a flood of \r unmasked the
# CR0.WP=1 page-fault recursion (see HISTORY).
dbg_out:                         # AL -> COM1 AND COM2 (SOL), bounded wait,
    push %rdx                    #   an absent UART (LSR 0xFF) is skipped
    push %rcx
    push %rax
    mov %al, %ah
    mov $0x3fd, %dx
    call dbg_tx
    mov $0x2fd, %dx
    call dbg_tx
    pop %rax
    pop %rcx
    pop %rdx
    ret
dbg_out2:                        # AL -> COM2 only (the verbose dump; COM1
    push %rdx                    #   keeps the exact ABCDE the QEMU gate greps)
    push %rcx
    push %rax
    mov %al, %ah
    mov $0x2fd, %dx
    call dbg_tx
    pop %rax
    pop %rcx
    pop %rdx
    ret
dbg_tx:                          # DX = LSR port, AH = byte
    mov $0x100000, %ecx
dbg_wait:
    in %dx, %al
    cmp $0xff, %al
    je dbg_txd
    test $0x20, %al
    jnz dbg_go
    loop dbg_wait
    jmp dbg_txd
dbg_go:
    sub $5, %dx
    mov %ah, %al
    out %al, %dx
    add $5, %dx
dbg_txd:
    ret

com2_init:                       # 115200 8N1, FIFO, no IRQ (COM2 = 0x2F8)
    push %rax
    push %rdx
    mov $0x2f9, %dx
    xor %al, %al
    out %al, %dx                 # IER off
    mov $0x2fb, %dx
    mov $0x80, %al
    out %al, %dx                 # DLAB
    mov $0x2f8, %dx
    mov $1, %al
    out %al, %dx                 # divisor 1
    mov $0x2f9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x2fb, %dx
    mov $3, %al
    out %al, %dx                 # 8N1
    mov $0x2fa, %dx
    mov $0xc7, %al
    out %al, %dx                 # FIFO on + clear
    mov $0x2fc, %dx
    mov $3, %al
    out %al, %dx                 # DTR+RTS
    pop %rdx
    pop %rax
    ret

dbg_hex:                         # RAX -> 16 hex digits + ' ' (all preserved)
    push %rcx
    push %rdx
    push %rax
    mov %rax, %rdx
    mov $16, %ecx
dbg_hx:
    rol $4, %rdx
    mov %dl, %al
    and $15, %al
    add $0x30, %al
    cmp $0x39, %al
    jbe dbg_hd
    add $7, %al
dbg_hd:
    call dbg_out2
    loop dbg_hx
    mov $0x20, %al
    call dbg_out2
    pop %rax
    pop %rdx
    pop %rcx
    ret

# dbg_dump: one line of handover state, then every firmware memory map
#   descriptor (type start pages attr). RBX/RDI/RSI/RBP/R15 preserved.
dbg_dump:
    push %rax
    push %rcx
    push %rdx
    push %r8
    push %r9
    mov $0x0a0d, %ax             # "\r\n"
    call dbg_out2
    mov %ah, %al
    call dbg_out2
    lea 0x30(%rsp), %rax         # caller RSP (5 pushes + ret addr = 0x30)
    call dbg_hex
    lea uefi_entry(%rip), %rax   # where the firmware loaded us
    call dbg_hex
    mov %r15, %rax               # kernel buffer
    call dbg_hex
    mov %rbx, %rax               # fb base
    call dbg_hex
    mov %rdi, %rax               # res
    call dbg_hex
    mov %rsi, %rax               # ppsl
    call dbg_hex
    mov %cr0, %rax
    call dbg_hex
    mov %cr3, %rax
    call dbg_hex
    mov %cr4, %rax
    call dbg_hex
    mov $0xc0000080, %ecx
    rdmsr
    shl $32, %rdx
    or %rdx, %rax
    call dbg_hex
    mov $0x1b, %ecx              # IA32_APIC_BASE (x2APIC = bit 10)
    rdmsr
    shl $32, %rdx
    or %rdx, %rax
    call dbg_hex
    mov 0x30+0x48(%rsp), %r8     # caller's map buffer
    mov 0x30+0x40(%rsp), %r9     # caller's map size
    add %r8, %r9                 # end
dbg_ml:
    cmp %r9, %r8
    jae dbg_md
    mov $0x0a0d, %ax
    call dbg_out2
    mov %ah, %al
    call dbg_out2
    mov (%r8), %eax              # Type
    call dbg_hex
    mov 8(%r8), %rax             # PhysicalStart
    call dbg_hex
    mov 24(%r8), %rax            # NumberOfPages
    call dbg_hex
    add 0x30+0x58(%rsp), %r8     # += DescriptorSize
    jmp dbg_ml
dbg_md:
    mov $0x0a0d, %ax
    call dbg_out2
    mov %ah, %al
    call dbg_out2
    pop %r9
    pop %r8
    pop %rdx
    pop %rcx
    pop %rax
    ret

# ram_total: the kernel's E820_TOTAL (0x4000, bytes, 32-bit) - the BIOS path
#   fills it from INT 15h E820; on UEFI it used to be whatever the firmware
#   left there. Sum the RAM types the OS may use (loader/boot-services code+
#   data, conventional) below 4 GB from the final memory map. Post-EBS only.
ram_total:
    push %rax
    push %rcx
    push %rdx
    push %r8
    push %r9
    push %r10
    xor %r10, %r10               # total
    mov 0x38+0x48(%rsp), %r8     # caller's map buffer (6 pushes + ret)
    mov 0x38+0x40(%rsp), %r9     # caller's map size
    add %r8, %r9
rt_l:
    cmp %r9, %r8
    jae rt_d
    mov (%r8), %eax              # Type
    cmp $7, %eax                 # 1-4 loader/BS code+data, 7 conventional
    je rt_use
    cmp $1, %eax
    jb rt_n
    cmp $4, %eax
    ja rt_n
rt_use:
    mov 8(%r8), %rax             # start
    mov 24(%r8), %rcx            # pages
    shl $12, %rcx
    add %rax, %rcx               # end
    mov $0x100000000, %rdx
    cmp %rdx, %rax
    jae rt_n                     # starts above 4 GB: invisible to a 32-bit kernel
    cmp %rdx, %rcx
    jbe rt_e
    mov %rdx, %rcx               # clip at 4 GB
rt_e:
    sub %rax, %rcx
    add %rcx, %r10
rt_n:
    add 0x38+0x58(%rsp), %r8
    jmp rt_l
rt_d:
    mov $0xfffff000, %eax        # saturate to 32 bits
    cmp %rax, %r10
    jbe rt_s
    mov %rax, %r10
rt_s:
    mov %r10d, 0x4000
    pop %r10
    pop %r9
    pop %r8
    pop %rdx
    pop %rcx
    pop %rax
    ret

# dbg_bar: EAX = index -> a 16-px colour stripe at y = 8 + index*20 across
#   the GOP framebuffer (RBX base, RSI ppsl, EDI hres). Webcam progress.
dbg_bar:
    test %rbx, %rbx
    jz dbg_bnone
    push %rax
    push %rcx
    push %rdx
    push %r8
    mov %eax, %edx
    and $7, %edx
    lea dbg_cols(%rip), %rcx
    mov (%rcx,%rdx,4), %r8d      # colour
    imul $20, %eax, %eax
    add $8, %eax
    imul %esi, %eax              # pixel offset of the stripe's first row
    lea (%rbx,%rax,4), %rdx
    mov $16, %ecx                # rows
dbg_br:
    push %rcx
    push %rdx
    mov %edi, %ecx               # hres pixels
dbg_bp:
    mov %r8d, (%rdx)
    add $4, %rdx
    loop dbg_bp
    pop %rdx
    pop %rcx
    lea (%rdx,%rsi,4), %rdx
    loop dbg_br
    pop %r8
    pop %rdx
    pop %rcx
    pop %rax
dbg_bnone:
    ret
dbg_cols:
    .long 0xff0000, 0xff8000, 0xffff00, 0x00ff00, 0x00ffff, 0x0000ff, 0xff00ff, 0xffffff

fail:                            # something EFI said no - report + hang
    mov 64(%r13), %rcx
    lea msg_fail(%rip), %rdx
    call *8(%rcx)
fail_hang:
    hlt
    jmp fail_hang

# --- long mode -> protected mode (Intel SDM "leaving IA-32e") --------
    .code32
descent32:                       # compatibility mode (CS.L=0, CS.D=1)
    mov $0x10, %ax               # kernel flat data segment
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x44, %al               # DEBUG 'D': compat mode reached
    mov $0x3f8, %dx
    out %al, %dx
    mov $0x2f8, %dx              # + COM2 (SOL)
    out %al, %dx
    mov %cr0, %eax
    and $0x7fffffff, %eax        # paging OFF
    mov %eax, %cr0
    mov $0xc0000080, %ecx        # EFER: long mode enable OFF
    rdmsr
    and $0xfffffeff, %eax
    wrmsr
    mov %cr4, %eax
    and $0xffffffdf, %eax        # PAE OFF - the kernel builds plain
    mov %eax, %cr4               # 32-bit page tables
    mov $0x45, %al               # DEBUG 'E': protected mode, jumping in
    mov $0x3f8, %dx
    out %al, %dx
    mov $0x2f8, %dx              # + COM2 (SOL)
    out %al, %dx
    jmp *%ebx                    # -> uefi_entry32: TannX OS takes over
descent32_end:

# ----------------------------- data ---------------------------------
    .code64
fname:
    .string16 "kernel32.bin"
guid_li:                         # EFI_LOADED_IMAGE_PROTOCOL_GUID
    .long 0x5B1B31A1
    .word 0x9562, 0x11d2
    .byte 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
guid_sfs:                        # EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID
    .long 0x964E5B22
    .word 0x6459, 0x11D2
    .byte 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
guid_gop:                        # EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID
    .long 0x9042A9DE
    .word 0x23DC, 0x4A38
    .byte 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A

msg_hello:
    .string16 "\r\nTannX OS UEFI stage 0 - made by Tannenbaum Media\r\n"
msg_loaded:
    .string16 "kernel32.bin loaded - leaving boot services, the kernel takes it from here.\r\n\r\n"
msg_fail:
    .string16 "stage 0: EFI call failed - halting. (Is kernel32.bin on the ESP?)\r\n"

# ============================ .reloc =================================
    .org 0xa00
    .long 0x200                  # block: page RVA
    .long 12                     # block size
    .word 0, 0                   # 2x IMAGE_REL_BASED_ABSOLUTE no-ops

    .org 0xc00                   # SizeOfImage - end of file
