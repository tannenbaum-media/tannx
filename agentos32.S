# =====================================================================
#  AgentOS/32 v2.87 - a 32-bit x86 kernel in GNU assembler
#
#  One flat source file: stage-1 boot sector, stage-2 real-mode setup,
#  the protected-mode kernel and its data. The BIOS (or the UEFI stub in
#  agentos-uefi.S, or a PXE ROM via pxe_stage1.S) only loads us and sets
#  a video mode - after the jump to protected mode nothing but our own
#  code runs.
#
#  What is in here:
#    * own GDT, IDT, PIC remap, PIT timer; CPU exceptions report instead
#      of triple-faulting
#    * identity paging 0-32 MB (page 0 unmapped as a NULL guard), a
#      kernel heap, optional 4 MB pages for RAM above 32 MB
#    * preemptive round-robin threads; the "agents" run in RING 3 with
#      their own stacks and reach the kernel only through INT 0x30 -
#      a wild pointer kills the agent, never the system
#    * a ring-3 C userspace (user/, loaded from LBA 300): video player,
#      games, TCP/IP + HTTP, HDA, NVMe, xHCI, virtio-blk/gpu, GUI
#    * drivers: VGA text + framebuffer console, PS/2 + USB (EHCI) HID,
#      COM1 serial console (mirrored output), ATA PIO + AHCI, AC97,
#      RTL8139 / e1000 / RTL8168 / virtio-net with a minimal IPv4/UDP
#      layer, SMP bring-up (opt-in via 'smpon'), ACPI power-off
#    * AgentFS: eight 512-byte "slots" on the boot medium, a scripting
#      language over them, and the LLM bridge (wish / llm / llmscript /
#      autopilot talk to llm-proxy.py on a host over the network)
#
#  Build:  make            Start:  make run32 (BIOS) / make run-uefi
#  Test:   make test-all   Docs:   README.md, docs/ARCHITECTURE.md
#
#  Build-time switches (as --defsym): MINIMAL=1 drops the games;
#  REMOTE_CTL=1 compiles in the unauthenticated UDP remote-control
#  channel (see net_handle) - OFF in the default image.
#
#  Style notes: several routines (PCI scans, MMIO mapping, hex/decimal
#  printers) exist in more than one hand-unrolled copy. That is
#  deliberate for now - each copy is verified on hardware and the
#  kernel has no linker-level dead-code pressure yet.
#
#  "The test PC" mentioned in comments is the bare-metal test machine:
#  a Haswell desktop (Core i5, RTL8168 NIC, AHCI SATA, EHCI/xHCI USB,
#  Intel HDA) used for hardware testing alongside QEMU.
# =====================================================================


.ifndef MAXW
.set MAXW, 3840                  # VBE mode cap (see stage 2)
.endif
.ifndef MAXH
.set MAXH, 2160
.endif
.code16
    .section .text
    .global _start

# =====================================================================
#  STAGE 1 - BOOTLOADER (512 bytes):
#  floppy -> CHS in chunks, hard disk -> LBA (AH=42h)
# =====================================================================
_start:
    ljmp $0, $boot_main
boot_main:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x7c00, %sp
    sti
    cld
    mov %dl, boot_drive

    mov $msg_boot, %si
    call puts16

    mov boot_drive, %dl
    cmp $0x80, %dl
    jae read_hdd

    mov $0x7e00, %bx             # cyl 0, head 0, sectors 2..18
    mov $0x0211, %ax
    mov $0x0002, %cx
    xor %dh, %dh
    call read_chs
    mov $0xa000, %bx             # cyl 0, head 1, sectors 1..18
    mov $0x0212, %ax
    mov $0x0001, %cx
    mov $1, %dh
    call read_chs
    mov $0xc400, %bx             # cyl 1, head 0, sectors 1..18
    mov $0x0212, %ax
    mov $0x0101, %cx
    xor %dh, %dh
    call read_chs
    mov $0xe800, %bx             # cyl 1, head 1, sectors 1..18
    mov $0x0212, %ax
    mov $0x0101, %cx
    mov $1, %dh
    call read_chs
    mov $0x1000, %bx             # ES = 0x1000 for the chunks above 0x10000
    mov %bx, %es
    mov $0x0c00, %bx             # cyl 2, head 0, sectors 1..18 -> 0x1000:0C00 = 0x10C00
    mov $0x0212, %ax
    mov $0x0201, %cx
    xor %dh, %dh
    call read_chs
    mov $0x3000, %bx             # cyl 2, head 1, sectors 1..7 -> 0x13000 (96 total)
    mov $0x0207, %ax
    mov $0x0201, %cx
    mov $1, %dh
    call read_chs
    xor %bx, %bx                 # ES back to 0 for the rest of stage 1/2
    mov %bx, %es
    jmp boot_go

read_hdd:                        # 256 sectors in TWO calls - SeaBIOS EDD
    mov $dap, %si                #   won't do >128 in one INT 13h/AH=42h call
    call hdd_read                # read 1: 128 sectors @ LBA 1   -> linear 0x7e00
    mov $dap2, %si
    call hdd_read                # read 2: 128 sectors @ LBA 129 -> linear 0x17e00
    jmp boot_go
hdd_read:
    mov $3, %di
hdd_try:
    push %si
    mov $0x42, %ah
    mov boot_drive, %dl
    int $0x13
    pop %si
    jnc hdd_ok
    xor %ah, %ah
    int $0x13
    dec %di
    jnz hdd_try
disk_fail:
    mov $msg_diskerr, %si
    call puts16
hang:
    hlt
    jmp hang
hdd_ok:
    ret

boot_go:
    ljmp $0, $stage2

read_chs:
    mov $3, %di
rc_try:
    push %ax
    mov boot_drive, %dl
    int $0x13
    jnc rc_ok
    xor %ah, %ah
    int $0x13
    pop %ax
    dec %di
    jnz rc_try
    jmp disk_fail
rc_ok:
    pop %ax
    ret

puts16:
    lodsb
    test %al, %al
    jz puts16_done
    mov $0x0e, %ah
    mov $0x0007, %bx
    int $0x10
    jmp puts16
puts16_done:
    ret

dap:                             # 256-sector kernel loaded in two DAP reads
    .byte 0x10, 0                #   (the NIC rings / UEFI_INFO / user-stacks moved up
    .word 128                    #   so the kernel can grow from 0x17e00 to 0x27e00;
    .word 0x7e00, 0              #   buffer 0:0x7e00 = linear 0x7e00, LBA 1
    .long 1
    .long 0
dap2:
    .byte 0x10, 0
    .word 128                    # second half: 128 sectors
    .word 0x7e00, 0x1000         # buffer 0x1000:0x7e00 = linear 0x17e00
    .long 129                    # LBA 129
    .long 0

boot_drive:  .byte 0
msg_boot:    .asciz "TannX OS: loading kernel...\r\n"
msg_diskerr: .asciz "Disk error! System halted."

# MBR partition table: the SAME sector serves both worlds.
# BIOS executes the code above and never looks down here; UEFI firmware
# ignores the code and reads this table, finds the type-EF entry and
# boots \EFI\BOOT\BOOTX64.EFI from the FAT12 ESP at LBA 2048. Entry 1
# is marked bootable - some BIOSes refuse USB-HDD boot without it.
# CHS fields are 0xFF dummies, we live in LBA land. The .org doubles
# as the stage-1 size limit (code must stay below 446 bytes).
    .org 446
    .byte 0x80                   # active/bootable
    .byte 0xff, 0xff, 0xff       # CHS start dummy
    .byte 0xef                   # type: EFI System Partition
    .byte 0xff, 0xff, 0xff       # CHS end dummy
    .long 2048                   # first LBA
    .long 2880                   # sector count (1440 KB ESP)
                                 # entries 2-4 stay zero
    .org 510
    .word 0xaa55

# =====================================================================
#  STAGE 2a - REAL-MODE PROLOGUE: last BIOS services, then switch over
# =====================================================================
stage2:
    jmp stage2_go                # hop over the UEFI handoff block
# UEFI handoff: the stage-0 EFI stub loads this flat
# image and reads these two pointers at FIXED file offsets 516/520
# (memory 0x7E04/0x7E08). They used to live at 500/504 - inside MBR
# partition entry 4, which the hybrid layout needs for real.
    .org 516
    .long gdtr                   # +516: lgdt operand (word limit, long base)
    .long uefi_entry32           # +520: 32-bit protected-mode entry
stage2_go:
    cld
    mov $0x0003, %ax             # video mode 3 (80x25)
    int $0x10

    # --- C3: sum usable RAM via INT 15h E820 (still real mode, BIOS here).
    #   Store the byte total at E820_TOTAL for the PM kernel; 0 = no E820,
    #   so 'mem' falls back to CMOS. DS=ES=0 from Stage 1, so the buffer at
    #   0:0x5000 is reachable with plain DI displacements. LAST BIOS call. ---
    xor %ax, %ax
    mov %ax, %es                 # ES = 0 for the E820 buffer
    movl $0, (E820_TOTAL)
    xor %ebx, %ebx               # continuation = 0
e820_loop:
    mov $0xe820, %eax
    mov $0x534d4150, %edx        # 'SMAP'
    mov $24, %ecx
    mov $0x5000, %di             # ES:DI -> 24-byte entry scratch
    int $0x15
    jc e820_done                 # CF on the first call = E820 unsupported
    cmp $0x534d4150, %eax        # must echo 'SMAP'
    jne e820_done
    cmpl $1, 16(%di)             # type 1 = usable RAM?
    jne e820_more
    mov 8(%di), %eax             # length, low 32 bits (high 32 ignored <4GB)
    addl %eax, (E820_TOTAL)
e820_more:
    test %ebx, %ebx              # EBX = 0 -> that was the last entry
    jz e820_done
    jmp e820_loop
e820_done:

    # --- graphics: set a VBE linear-framebuffer mode so the BIOS/PXE
    #   console is graphical (feeds the SAME framebuffer console the UEFI path
    #   uses). On any failure we stay in text mode 3 (set above) and fb stays
    #   inactive. Scratch: 0:0x6000 VBE info, 0:0x6200 mode info, 0:0x6600 mode
    #   list copy (all below the 0x7C00 stack, above nothing in use). ---
    mov $0x2800, %ax             # ES:0 = UEFI_INFO (0x28000). This used to be
    mov %ax, %es                 #   0x1800 - the block's OLD home, which the
    movl $0, %es:0x0             #   kernel has long grown over: every BIOS boot
                                 #   zeroed 4 bytes of kernel at 0x18000 (it hit
                                 #   the "sysinfo" command string once the code
                                 #   shifted). Clear the boot-info magic (no fb
                                 #   unless we win).
    xor %ax, %ax
    mov %ax, %es                 # ES=0 for the VBE scratch buffers
    mov $0x6000, %di
    movl $0x32454256, %es:(%di)  # ask for VBE 2.0 info ("VBE2")
    mov $0x4f00, %ax
    int $0x10
    cmp $0x004f, %ax
    jne vbe_done
    xor %ax, %ax
    mov %ax, %es                 # ES=0 (the call may have touched it)
    movzwl %es:0x600e, %esi      # VideoModePtr: offset
    mov %es:0x6010, %ax          #   segment
    mov %ax, %gs
    mov $0x6600, %di             # copy the mode list to 0:0x6600 (no BIOS call
vbe_cpl:                         #   in the loop -> GS stays valid)
    mov %gs:(%si), %ax
    mov %ax, %es:(%di)
    add $2, %si
    add $2, %di
    cmp $0xffff, %ax
    jne vbe_cpl
    mov $0x6600, %si             # SI walks the local copy now
    xor %ebx, %ebx               # BX = best mode (0 = none yet)
    xor %ebp, %ebp               # EBP = best area (w*h) seen so far
vbe_next:
    mov %es:(%si), %cx           # next mode number
    add $2, %si
    cmp $0xffff, %cx
    je vbe_choose
    push %cx
    push %si
    mov $0x6200, %di             # CX = mode -> mode info at 0:0x6200
    mov $0x4f01, %ax
    int $0x10
    pop %si
    pop %cx
    cmp $0x004f, %ax
    jne vbe_next
    xor %ax, %ax
    mov %ax, %es                 # ES=0 to read the mode info
    mov %es:0x6200, %ax          # ModeAttributes: supported|graphics|LFB
    and $0x91, %ax
    cmp $0x91, %ax
    jne vbe_next
    cmpb $32, %es:0x6219         # 32 bits per pixel (the fb code assumes BGRx)
    jne vbe_next
    movzwl %es:0x6212, %eax      # width
    movzwl %es:0x6214, %edx      # height
    cmp $MAXW, %eax              # cap at 4K: take the largest 32bpp mode (native res
    ja vbe_next                  #   on most monitors). The console font scales with the
    cmp $MAXH, %edx              #   resolution (fb_scale) so it fills the screen and
    ja vbe_next                  #   stays sharp on whatever monitor is plugged in.
                                 #   (make MAXW=1920 MAXH=1080 forces a smaller mode
                                 #   under QEMU -vga std - desktop layout tests.)
    imul %edx, %eax              # area = w*h -> pick the LARGEST mode (min..max)
    cmp %ebp, %eax
    jbe vbe_next
    mov %eax, %ebp
    mov %cx, %bx
    jmp vbe_next
vbe_choose:
    test %ebx, %ebx
    jz vbe_done                  # no usable mode -> stay in text mode
vbe_set:
    push %bx
    mov %bx, %cx                 # re-fetch the chosen mode's info
    mov $0x6200, %di
    mov $0x4f01, %ax
    int $0x10
    pop %bx
    cmp $0x004f, %ax
    jne vbe_done
    mov %bx, %cx
    or $0x4000, %bx              # set the mode WITH the linear-framebuffer bit
    mov $0x4f02, %ax
    int $0x10
    cmp $0x004f, %ax
    jne vbe_textback
    xor %ax, %ax
    mov %ax, %es                 # ES=0 to read the mode info fields
    mov %es:0x6228, %eax         # PhysBasePtr (linear framebuffer base)
    movzwl %es:0x6232, %ecx      # LinBytesPerScanLine (VBE 2.0)
    test %ecx, %ecx
    jnz vbe_pit
    movzwl %es:0x6210, %ecx      # else BytesPerScanLine
vbe_pit:
    shr $2, %ecx                 # bytes -> pixels/scanline (32 bpp)
    movzwl %es:0x6212, %esi      # XResolution
    movzwl %es:0x6214, %edi      # YResolution
    mov $0x2800, %dx
    mov %dx, %es                 # ES=0x2800 -> boot-info block at UEFI_INFO 0x28000
    movl $0x49464555, %es:0x00   # magic "UEFI" - fb_init keys off this
    mov %eax, %es:0x08           # framebuffer base
    movl $0, %es:0x0c            # base high = 0
    mov %esi, %es:0x10           # hres
    mov %edi, %es:0x14           # vres
    mov %ecx, %es:0x18           # pixels per scanline
    movl $0, %es:0x1c            # GOP mode count = 0 (BIOS/VBE enumerates none)
    jmp vbe_done
vbe_textback:
    mov $0x0003, %ax             # mode-set failed mid-way -> back to text
    int $0x10
vbe_done:
    xor %ax, %ax
    mov %ax, %es                 # ES=0 again for the A20 / PM switch

    in $0x92, %al                # open the A20 gate (fast A20, port 0x92)
    or $2, %al
    and $0xfe, %al               # bit 0 (reset!) safely kept at 0
    out %al, $0x92

    cli                          # no interrupts from here until the IDT
    lgdtl gdtr                   # load our own GDT
    mov %cr0, %eax
    or $1, %eax                  # PE bit: protected mode ON
    mov %eax, %cr0
    ljmp $0x08, $pm_entry        # continue in the 32-bit code segment

# --- GDT: flat model - code and data each 0..4 GB ---------------------
    .align 8
gdt:
    .quad 0x0000000000000000     # null descriptor
    .quad 0x00CF9A000000FFFF     # 0x08: code, base 0, limit 4 GB, 32-bit
    .quad 0x00CF92000000FFFF     # 0x10: data, base 0, limit 4 GB
    .quad 0x00CFFA000000FFFF     # 0x18: user code, DPL 3 - for the agents
    .quad 0x00CFF2000000FFFF     # 0x20: user data, DPL 3
    .quad 0                      # 0x28: TSS core 0  } per-core TSS descriptors,
    .quad 0                      # 0x30: TSS core 1  } filled by tss_init; each
    .quad 0                      # 0x38: TSS core 2  } core ltr's 0x28 + id*8 so
    .quad 0                      # 0x40: TSS core 3  } ring3->0 lands on ITS ESP0
    .quad 0                      # 0x48: TSS core 4
    .quad 0                      # 0x50: TSS core 5
    .quad 0                      # 0x58: TSS core 6
    .quad 0                      # 0x60: TSS core 7
gdtr:
    .word 103                    # limit (13 entries x 8 - 1)
    .long gdt
idtr:
    .word 2047                   # 256 gates x 8 - 1
    .long IDT_BASE                # IDT in free RAM - NOT in page 0,
                                 # because that is the NULL guard page!

# =====================================================================
#  STAGE 2b - 32-BIT KERNEL
# =====================================================================
    .code32
# UEFI entry: the stage-0 stub arrives here in protected
# mode, paging off, with OUR gdt already loaded - exactly the state
# pm_entry expects. Only difference: we remember the boot path (the
# framebuffer console in 6.4 will need it; no VGA text mode on UEFI).
# hw_mark progress markers: one byte on COM2 (the BMC's Serial-over-LAN
#   port on server boards; COM1 stays clean for the QEMU gate) + a colour
#   stripe in the firmware framebuffer while paging is still off. They
#   show how far a dying boot on real silicon got.
.macro HWM c
    push %eax
    mov $\c, %al
    call hw_mark
    pop %eax
.endm
uefi_entry32:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov $0x9f000, %esp
    pushl $2                     # clean EFLAGS (no NT/AC/DF leftovers from firmware)
    popfl
    cld
    call hw_com2_init
    mov $hwm_hello, %esi
    call hw_puts
    mov %cr0, %eax
    call hw_hex
    mov %cr4, %eax
    call hw_hex
    mov (E820_TOTAL), %eax
    call hw_hex
    # Firmware CR4 leftovers break a plain 32-bit kernel: SMEP/SMAP fault
    #   every supervisor access to our U=1 kernel pages the moment paging is
    #   on (#PF recursion -> triple fault on server firmware), PKE/PGE/
    #   OSXSAVE/VMXE/MCE etc. are not ours either. Keep only PSE/DE/OSFXSR/
    #   OSXMMEXCPT; sse_init/lapic_map set what they need.
    mov %cr4, %eax
    and $0x00000618, %eax
    mov %eax, %cr4
    movb $1, boot_uefi
    jmp pm_go

pm_entry:
    mov $0x10, %ax               # all segments: flat data segment
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov $0x9f000, %esp           # stack high up in free RAM
    cld
pm_go:
    HWM 0x61
    call pxe_stage               # FIRST: rescue the PXE-image program+clip from
                                 #   low RAM before idt/paging/stacks overwrite it
    call pit_init                # 18.2 Hz - UEFI firmware reprograms
                                 # the PIT (~100 Hz); BIOS default just
                                 # gets confirmed, costs nothing
    HWM 0x62
    call idt_setup               # 256 gates + exceptions + driver IRQs
    HWM 0x63
    call paging_init             # our own page tables, NULL guard
    HWM 0x64
    call lapic_map               # map the local APIC (every core reads its own id)
    call my_core                 # remember the BSP's APIC id NOW (even single-core), so
    mov %eax, bsp_apic           #   the AP-vs-BSP fallback test works before smp_init runs
    HWM 0x65
    call user_pages_init         # ABI v2: flip U=1 on 4-32 MB (ring-3 C userspace)
    mov $SCRATCH_BASE, %edi      # zero the relocated scratch buffers (tss/
    mov $0x1500, %ecx            #   cursor-save/fs_buf/inbox + EXEC bufs + SLOT_RAM + shadow
    xor %eax, %eax               #   left the kernel image; RAM is not pre-zeroed
    rep stosl                    #   the way .fill bytes were) - BEFORE tss_init
    HWM 0x66
    call sse_init                # enable SSE (for the hwtest bandwidth loop)
    HWM 0x67
    call tss_init                # TSS + task register: ring 3 may come
    HWM 0x68
    call pic_remap               # IRQ0-15 -> INT 0x20-0x2F
    HWM 0x69
    call ata_init                # disk: we poll, no disk IRQs
    HWM 0x6a
    call serial_init             # COM1: 115200 8N1, receive IRQ on
    HWM 0x6b
    call net_init                # RTL8139 NIC if present
    HWM 0x6c
    call log_boot                # first lines of the kernel log (dmesg)
    HWM 0x6d
    call log_hwinfo              # log CPU + RAM detection (read remotely via dmesg)
    HWM 0x6e
    call log_ahci                # probe + IDENTIFY the AHCI disk -> dmesg
    HWM 0x6f
    call log_usb                 # USB: report host controllers -> dmesg
    HWM 0x70
    call log_xhci                # USB: bring up the xHCI + report ports -> dmesg
    HWM 0x71
    call log_ehci                # USB: read-only EHCI port probe -> dmesg
    HWM 0x72
    call load_persisted          # restore task results from a TannX OS medium
    HWM 0x73
    call highmem_init            # map RAM above 32 MB (4 MB pages) -> big heap
    HWM 0x74
    call heap_init               # kernel heap (relocated into high RAM if mapped)
    HWM 0x75
    call fb_init                 # UEFI framebuffer console, if any
    HWM 0x76
    call desktop_init            # lay out the graphical desktop (concept C, >=1024x768)
    HWM 0x77
    call mouse_init              # PS/2 mouse + framebuffer cursor (if present)
    HWM 0x78
    sti                          # interrupts on - now we are an OS

    call logo_palette            # VGA text mode: the brand teals for the logo
    call cls
    call draw_status
    mov $banner, %esi            # the TannX logo (colours inline,
    call puts_attr               #   variant picked at build time: LOGO=A|B|C)
    mov $msg_welcome, %esi
    call puts_attr
    movb $0x0a, cur_attr         # body text: house green
    HWM 0x79
    call run_selftest            # boot self-test (CPU + RAM) -> dmesg, always runs
                                 #   (reliable, unlike the idle-loop remote trigger)
.ifdef BOOT_CHIME                # make CHIME=1: boot chime through the HDA codec
    mov $cs_chime, %esi          #   (ring-3 'run chime', silent without HDA). Off by
    call llm_stage_only          #   default so the headless gate stays deterministic.
.endif
    HWM 0x7a
    call pxe_blob_load           # stage the ring-3 C program (PXE path)
                                 #   AFTER the self-test: its RAM test sweeps
                                 #   0x200000-0x1200000 and would otherwise wipe the
                                 #   0x400000 landing zone. The source at 0x27C00 sits
                                 #   below 0x200000, so the test leaves it intact.
    # smp_init is not called at boot: waking the APs is QEMU-verified
    #   but a triple-faulting AP resets real silicon into a reboot loop.
    #   The OS boots single-core; 'smpon' wakes the cores on demand.
    # usb_init (EHCI HID bring-up) is not called at boot either: boot-time
    #   enumeration wedged the test PC's rate-matching hub. The idle loop
    #   runs it once ~3 s after boot when usb_autostart is set (kg_usbauto),
    #   or on the 'usb'/EHCITEST paths.

# ---------------------------------------------------------------------
#  Shell main loop
# ---------------------------------------------------------------------
shell:
    mov %esp, shell_safe_esp     # rescue anchor for the #PF handler
    cmpl $0, pending_ptr         # mid-chain? feed the next ';'-separated command
    jne sh_chain
.ifdef REMOTE_CTL                # remote EXEC staging (REMOTE_CTL builds only)
    cmpb $0, exec_cap            # an EXEC chain just finished? ship its output -
    je sh_noflush                #   UNLESS this chain launched a background ring-3
    mov runprog_slot, %al        #   prog (hda/games): runprog_slot changed vs the
    cmp exec_prog0, %al          #   stage snapshot. Then keep capturing until the
    je sh_doflush                #   prog exits (kg_nck_flush) or its deadline hits,
    movzbl runprog_slot, %eax    #   so its output isn't lost.
    cmpb $0, agents_tbl(,%eax,8)
    jne sh_noflush
sh_doflush:
    call exec_flush
sh_noflush:
    cmpb $0, exec_req            # a wire EXEC waiting? stage it like typed input
    je sh_noexec
    movb $0, exec_req
    mov $EXEC_CMD, %esi
    mov $PEND_BUF, %edi
    call pend_copy
    movl $PEND_BUF, pending_ptr
    movb $1, exec_cap            # capture every putc until the chain ends
    movw $0, exec_olen
    mov runprog_slot, %al        # snapshot: did THIS chain launch a program?
    mov %al, exec_prog0
    mov ticks, %eax              # backstop deadline (~10 s): flush even if a
    add $180, %eax               #   launched program hangs (test PC HDA codec wedge)
    mov %eax, exec_deadline
    jmp sh_feed
.endif
sh_noexec:
    mov $0x0b, %al               # prompt in bright cyan
    mov $prompt, %esi
    call putsc
    movb $0x0a, cur_attr         # body text green (also resets after faults)
    call readline
    mov $linebuf, %esi           # stage the whole line so 'a; b; c' can chain
    mov $PEND_BUF, %edi
    call pend_copy
    movl $PEND_BUF, pending_ptr
    jmp sh_feed
sh_chain:                        # mid-chain (incl. 'script'): ESC/Ctrl+C abort -
    cmpb $0, abort_req           #   ...or AGENTOS-ABORT over the wire (stop a
    jne sh_remote_abort          #   wedged autopilot loop remotely, no reboot)
    mov kb_tail, %al             #   a self-calling script slot is a LOOP, so
    cmp kb_head, %al             #   the user needs a way back to the prompt
    je sh_feed
    movzbl kb_tail, %ebx
    movzwl kbuf(,%ebx,2), %eax
    cmp $0x1b, %al               # ESC (PS/2) or Ctrl+C (serial passes 0x03);
    je sh_abort                  #   other type-ahead stays queued for readline
    cmp $3, %al
    jne sh_feed
sh_abort:
    mov kb_tail, %bl
    inc %bl
    and $63, %bl
    mov %bl, kb_tail
    movl $0, pending_ptr
    movl $0, rep_count           # a 'repeat' loop dies with its chain
    mov $msg_chain_abort, %esi
    call puts
    jmp shell
sh_remote_abort:                 # AGENTOS-ABORT landed: drop the chain, no reboot
    movb $0, abort_req
    movl $0, pending_ptr
    movl $0, rep_count
    mov $msg_chain_abort, %esi
    call puts
    jmp shell
sh_feed:
    call pend_next               # linebuf = next command; pending_ptr=0 at the end

dispatch:                        # 'if' re-enters here with its consequent
    call subst_reg               # '$' anywhere -> the script register's value
    mov $linebuf, %esi
    cmpb $0, (%esi)
    je shell

    mov $cs_help, %edi
    call try_cmd
    jnc do_help
    mov $cs_about, %edi
    call try_cmd
    jnc do_about
    mov $cs_agents, %edi
    call try_cmd
    jnc do_agents
    mov $cs_ps, %edi
    call try_cmd
    jnc do_agents
    mov $cs_spawn, %edi
    call try_cmd
    jnc do_spawn
    mov $cs_kill, %edi
    call try_cmd
    jnc do_kill
    mov $cs_reap, %edi
    call try_cmd
    jnc do_reap
    mov $cs_tick, %edi
    call try_cmd
    jnc do_tick
    mov $cs_run, %edi
    call try_cmd
    jnc do_run
    mov $cs_llmscript, %edi      # BEFORE llm: try_cmd needs the longer word first
    call try_cmd
    jnc do_llmscript
    mov $cs_hda, %edi            # HDA sound (driver lives in ring-3 C)
    call try_cmd
    jnc do_hda
    mov $cs_vgpu, %edi           # virtio-gpu probe (ring-3 C, QEMU)
    call try_cmd
    jnc do_vgpu
    mov $cs_nvme, %edi           # NVMe block driver (ring-3 C)
    call try_cmd
    jnc do_nvme
    mov $cs_httpd, %edi          # HTTP server (ring-3 C, server-OS)
    call try_cmd
    jnc do_httpd
    mov $cs_usb, %edi            # USB xHCI driver (ring-3 C)
    call try_cmd
    jnc do_usb
    mov $cs_vblk, %edi           # virtio-blk disk (ring-3 C, VM/cloud)
    call try_cmd
    jnc do_vblk
    mov $cs_llm, %edi            # ask the LLM over the wire
    call try_cmd
    jnc do_llm
    mov $cs_offload, %edi        # ship a compute job to the proxy's /compute
    call try_cmd
    jnc do_offload
    mov $cs_autopilot, %edi      # BEFORE auto (longer word first)
    call try_cmd
    jnc do_autopilot
    mov $cs_auto, %edi
    call try_cmd
    jnc do_auto
    mov $cs_waittask, %edi       # BEFORE wait (longer word first): join on an agent task
    call try_cmd
    jnc do_waittask
    mov $cs_waitall, %edi        # BEFORE wait too: join on ALL agent tasks (fan-out)
    call try_cmd
    jnc do_waitall
    mov $cs_wait, %edi
    call try_cmd
    jnc do_wait
    mov $cs_echo, %edi
    call try_cmd
    jnc do_echo
    mov $cs_heap, %edi
    call try_cmd
    jnc do_heap
    mov $cs_top, %edi
    call try_cmd
    jnc do_top
    mov $cs_banner, %edi
    call try_cmd
    jnc do_banner
    mov $cs_kbd, %edi
    call try_cmd
    jnc do_kbd
    mov $cs_gui, %edi            # the Dark Glass compositor (ring-3, user/gui.c)
    call try_cmd
    jnc do_gui
    mov $cs_fetch, %edi          # neofetch-style system card (ring-3, user/fetch.c)
    call try_cmd
    jnc do_fetch
    mov $cs_forest, %edi         # live agent forest (ring-3, user/forest.c)
    call try_cmd
    jnc do_forest
.ifndef MINIMAL                  # games are extras (make minimal drops them)
    mov $cs_snake, %edi          # easter egg - not in help
    call try_cmd
    jnc do_snake
    mov $cs_invaders, %edi       # Space Invaders
    call try_cmd
    jnc do_invaders
.endif
    mov $cs_wishes, %edi         # BEFORE 'wish': try_cmd matches whole
    call try_cmd                 # words, but keep the longer one first
    jnc do_wishes
    mov $cs_sendwishes, %edi     # BEFORE wishes/wish (longer word first)
    call try_cmd
    jnc do_sendwishes
    mov $cs_netwish, %edi         # BEFORE net (longer word first)
    call try_cmd
    jnc do_netwish
    mov $cs_net, %edi
    call try_cmd
    jnc do_net
    mov $cs_lspci, %edi
    call try_cmd
    jnc do_lspci
    mov $cs_aread, %edi           # BEFORE 'ahci' (longer word first)
    call try_cmd
    jnc do_aread
    mov $cs_awrite, %edi          # BEFORE 'ahci' (longer word first)
    call try_cmd
    jnc do_awrite
    mov $cs_cdread, %edi
    call try_cmd
    jnc do_cdread
    mov $cs_ahci, %edi
    call try_cmd
    jnc do_ahci
    mov $cs_wish, %edi
    call try_cmd
    jnc do_wish
    mov $cs_alloc, %edi
    call try_cmd
    jnc do_alloc
    mov $cs_free, %edi
    call try_cmd
    jnc do_free
    mov $cs_color, %edi
    call try_cmd
    jnc do_color
    mov $cs_rnd, %edi
    call try_cmd
    jnc do_rnd
    mov $cs_calc, %edi
    call try_cmd
    jnc do_calc
    mov $cs_gfx, %edi
    call try_cmd
    jnc do_gfx
    mov $cs_beep, %edi
    call try_cmd
    jnc do_beep
    mov $cs_play, %edi
    call try_cmd
    jnc do_play
.ifndef MINIMAL                  # 2a: AC97 sound is an extra (lean core drops it)
    mov $cs_sound, %edi
    call try_cmd
    jnc do_sound
.endif
    mov $cs_lines, %edi
    call try_cmd
    jnc do_lines
    mov $cs_task, %edi
    call try_cmd
    jnc do_task
    mov $cs_tasks, %edi
    call try_cmd
    jnc do_tasks
    mov $cs_queue, %edi
    call try_cmd
    jnc do_tasks
    mov $cs_date, %edi
    call try_cmd
    jnc do_date
    mov $cs_time, %edi
    call try_cmd
    jnc do_time
    mov $cs_dump, %edi
    call try_cmd
    jnc do_dump
    mov $cs_cpuid, %edi
    call try_cmd
    jnc do_cpuid
    mov $cs_cpu, %edi
    call try_cmd
    jnc do_cpu
    mov $cs_smpon, %edi          # BEFORE smp (longer word first)
    call try_cmd
    jnc do_smpon
    mov $cs_smp, %edi
    call try_cmd
    jnc do_smp
    mov $cs_pbench, %edi
    call try_cmd
    jnc do_pbench
    mov $cs_selftest, %edi
    call try_cmd
    jnc do_selftest
    mov $cs_sysinfo, %edi
    call try_cmd
    jnc do_sysinfo
    mov $cs_display, %edi         # firmware framebuffer geometry
    call try_cmd
    jnc do_display
    mov $cs_cputest, %edi
    call try_cmd
    jnc do_cputest
    mov $cs_ramtest, %edi
    call try_cmd
    jnc do_ramtest
    mov $cs_hwtest, %edi
    call try_cmd
    jnc do_hwtest
    mov $cs_ehcitest, %edi
    call try_cmd
    jnc do_ehcitest
    mov $cs_smart, %edi
    call try_cmd
    jnc do_smart
    mov $cs_disktest, %edi
    call try_cmd
    jnc do_disktest
    mov $cs_temp, %edi
    call try_cmd
    jnc do_temp
    mov $cs_inbox, %edi
    call try_cmd
    jnc do_inbox
    mov $cs_nicdbg, %edi
    call try_cmd
    jnc do_nicdbg
    mov $cs_save, %edi
    call try_cmd
    jnc do_save
    mov $cs_load, %edi
    call try_cmd
    jnc do_load
    mov $cs_script, %edi         # execute an AgentFS slot as commands
    call try_cmd
    jnc do_script
    mov $cs_sleep, %edi          # script pacing
    call try_cmd
    jnc do_sleep
    mov $cs_if, %edi             # conditionals on task results
    call try_cmd
    jnc do_if
    mov $cs_setb, %edi           # the SECOND script register ('#')
    call try_cmd
    jnc do_setb
    mov $cs_set, %edi            # the script register ('$')
    call try_cmd
    jnc do_set
    mov $cs_repeat, %edi         # loop the current script slot
    call try_cmd
    jnc do_repeat
    mov $cs_ls, %edi
    call try_cmd
    jnc do_ls
    mov $cs_del, %edi
    call try_cmd
    jnc do_del
    mov $cs_diskon, %edi
    call try_cmd
    jnc do_diskon
    mov $cs_ahcibless, %edi
    call try_cmd
    jnc do_ahcibless
    mov $cs_persist, %edi
    call try_cmd
    jnc do_persist
    mov $cs_uptime, %edi
    call try_cmd
    jnc do_uptime
    mov $cs_dmesg, %edi
    call try_cmd
    jnc do_dmesg
    mov $cs_mem, %edi
    call try_cmd
    jnc do_mem
    mov $cs_clear, %edi
    call try_cmd
    jnc do_clear
    mov $cs_cls, %edi
    call try_cmd
    jnc do_clear
    mov $cs_hello, %edi
    call try_cmd
    jnc do_hello
    mov $cs_reboot, %edi
    call try_cmd
    jnc do_reboot
    mov $cs_halt, %edi
    call try_cmd
    jnc do_halt
    mov $cs_poweroff, %edi
    call try_cmd
    jnc do_poweroff

    mov $msg_unknown, %esi
    call puts
    jmp shell

# ---------------------------------------------------------------------
#  Command handlers
# ---------------------------------------------------------------------
do_help:
    mov $help_text, %esi
    call puts_more
    jmp shell

do_about:
    mov $about_text, %esi
    call puts_more
    jmp shell

do_clear:
    call cls
    jmp shell

do_echo:
    mov arg_ptr, %esi
    call puts
    call crlf
    jmp shell

# --- Heap demo: alloc <n> / free <hex> / heap --------------
do_alloc:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_dec
    jc al_usage
    test %eax, %eax
    jz al_usage
    push %eax                    # save requested size for the message
    call kmalloc
    test %eax, %eax
    jz al_full
    mov %eax, %ebx               # EBX = returned pointer
    mov $msg_alloc1, %esi
    call puts
    pop %eax
    call print_dec32
    mov $msg_alloc2, %esi
    call puts
    mov %ebx, %eax
    call phex32
    call crlf
    jmp shell
al_full:
    pop %eax
    mov $msg_heapfull, %esi
    call puts
    jmp shell
al_usage:
    mov $msg_alloc_usage, %esi
    call puts
    jmp shell

do_free:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_hex
    jc fr_usage
    call kfree
    cmp $1, %eax
    je fr_bad
    cmp $2, %eax
    je fr_double
    mov $msg_free_ok, %esi
    call puts
    jmp shell
fr_bad:
    mov $msg_free_bad, %esi
    call puts
    jmp shell
fr_double:
    mov $msg_free_dbl, %esi
    call puts
    jmp shell
fr_usage:
    mov $msg_free_usage, %esi
    call puts
    jmp shell

do_heap:
    mov $msg_heap_hdr, %esi
    call puts
    mov heap_base, %ebx          # EBX = walking pointer through the list
hp_loop:
    cmpl $0xA110C8ED, (%ebx)
    jne hp_corrupt
    mov $msg_heap_at, %esi
    call puts
    mov %ebx, %eax
    call phex32
    mov $msg_heap_sz, %esi
    call puts
    mov 4(%ebx), %eax
    call print_dec32
    mov $msg_heap_b, %esi
    call puts
    cmpl $1, 12(%ebx)
    je hp_free
    mov $msg_heap_used, %esi
    jmp hp_pr
hp_free:
    mov $msg_heap_fr, %esi
hp_pr:
    call puts
    call crlf
    mov 8(%ebx), %ebx
    test %ebx, %ebx
    jnz hp_loop
    jmp shell
hp_corrupt:
    mov $msg_heap_corr, %esi
    call puts
    mov %ebx, %eax
    call phex32
    call crlf
    jmp shell

# --- banner <text>: print the text inside a box frame --------------
do_banner:
    mov arg_ptr, %esi
    call skip_spaces
    cmpb $0, (%esi)
    je bn_usage
    mov %esi, %ebx               # EBX = start of the text
    xor %ecx, %ecx               # ECX = its length
bn_len:
    cmpb $0, (%esi)
    je bn_top
    inc %esi
    inc %ecx
    jmp bn_len
bn_top:
    call bn_border
    mov $0x7c, %al               # '|'
    call putc
    mov $0x20, %al
    call putc
    mov %ebx, %esi               # puts keeps EBX/ECX (contract)
    call puts
    mov $0x20, %al
    call putc
    mov $0x7c, %al               # '|'
    call putc
    call crlf
    call bn_border
    jmp shell
bn_usage:
    mov $msg_banner_usage, %esi
    call puts
    jmp shell

bn_border:                       # ECX = text length; draws +---...---+
    push %ecx
    mov $0x2b, %al               # '+'
    call putc
    add $2, %ecx                 # frame padding (one space each side)
bn_dash:
    mov $0x2d, %al               # '-'
    call putc
    loop bn_dash
    mov $0x2b, %al               # '+'
    call putc
    call crlf
    pop %ecx
    ret

# --- wish <text>: THE TannX OS idea made concrete ---------------------
#  This OS is built BY LLMs ON PROMPTS: whatever does not exist yet
#  (drivers, software, commands) gets wished for right here. The wish
#  is written through our own ATA driver into dedicated disk slots
#  (LBA 108-115, magic 'AW', next to the AgentFS) and survives in the
#  image. On the host, 'make wishes' hands the pending wishes to the
#  next LLM session as prompts - it builds them, one commit per wish.
do_wish:
    cmpb $0, fs_armed            # same write protection as save/del
    je fs_locked
    mov arg_ptr, %esi
    call skip_spaces
    cmpb $0, (%esi)
    je wish_usage
    mov %esi, %edx               # EDX = wish text
    mov $265, %ebx               # EBX = candidate LBA
wi_find:
    mov %ebx, %eax
    mov $fs_buf, %edi
    call ata_read
    jc disk_err
    cmpb $0x41, fs_buf           # 'A'
    jne wi_free
    cmpb $0x57, fs_buf+1         # 'W' - slot taken, try the next
    jne wi_free
    inc %ebx
    cmp $273, %ebx
    jb wi_find
    mov $msg_wish_full, %esi
    call puts
    jmp shell
wi_free:
    movb $0x41, fs_buf
    movb $0x57, fs_buf+1
    mov %edx, %esi               # copy the text (max. 200 chars)
    mov $fs_buf+3, %edi
    xor %ecx, %ecx
wi_cp:
    lodsb
    test %al, %al
    jz wi_cpd
    cmp $200, %ecx
    jae wi_cpd
    stosb
    inc %ecx
    jmp wi_cp
wi_cpd:
    mov %cl, fs_buf+2
    mov %ebx, %eax
    mov $fs_buf, %esi
    call ata_write
    jc disk_err
    mov $msg_wish_ok, %esi
    call puts
    jmp shell
wish_usage:
    mov $msg_wish_usage, %esi
    call puts
    jmp shell

# --- wishes: list the pending wishes from disk -----------------------
do_wishes:
    movb $0, anyflag
    mov $265, %ebx
wl_loop:
    mov %ebx, %eax
    mov $fs_buf, %edi
    call ata_read
    jc disk_err
    cmpb $0x41, fs_buf
    jne wl_next
    cmpb $0x57, fs_buf+1
    jne wl_next
    movb $1, anyflag
    mov $msg_wish_li, %esi
    call puts
    mov %ebx, %eax
    sub $265, %eax
    add $0x30, %al
    call putc
    mov $msg_load2, %esi         # "]: "
    call puts
    movzbl fs_buf+2, %ecx        # terminate + print the text
    movb $0, fs_buf+3(%ecx)
    mov $fs_buf+3, %esi
    call puts
    call crlf
wl_next:
    inc %ebx
    cmp $273, %ebx
    jb wl_loop
    cmpb $0, anyflag
    jne wl_done
    mov $msg_wish_none, %esi
    call puts
wl_done:
    jmp shell

# --- sendwishes: dump pending wishes as machine-readable lines on COM1
# . The serial console IS this OS's internet: puts already
#  mirrors to COM1, so wish-bridge.sh on the dev box just greps the
#  framed block. Format:  <<AGENTOS-WISHES  / WISH:<text>  / AGENTOS-END
do_sendwishes:
    mov $msg_sw_head, %esi
    call puts
    mov $265, %ebx
swi_loop:
    mov %ebx, %eax
    mov $fs_buf, %edi
    call ata_read
    jc disk_err
    cmpb $0x41, fs_buf           # 'A'
    jne swi_next
    cmpb $0x57, fs_buf+1         # 'W'
    jne swi_next
    mov $msg_sw_line, %esi       # "WISH:"
    call puts
    movzbl fs_buf+2, %ecx
    movb $0, fs_buf+3(%ecx)
    mov $fs_buf+3, %esi
    call puts
    call crlf
swi_next:
    inc %ebx
    cmp $273, %ebx
    jb swi_loop
    mov $msg_sw_tail, %esi
    call puts
    jmp shell

# --- net: show NIC status + MAC, or probe PCI for it ---
do_net:
    cmpb $0, net_present
    je net_probe
    mov $msg_net_up, %esi        # "NIC up ("
    call puts
    cmpb $2, net_present
    je nt_e1000
    cmpb $3, net_present
    je nt_r8168
    mov $msg_drv_rtl, %esi       # "RTL8139)"
    jmp nt_drv
nt_e1000:
    mov $msg_drv_e1000, %esi     # "e1000)"
    jmp nt_drv
nt_r8168:
    mov $msg_drv_r8168, %esi     # "RTL8168)"
nt_drv:
    call puts
    mov $msg_net_mac, %esi       # " MAC "
    call puts
    xor %ebx, %ebx               # print MAC as aa:bb:cc:dd:ee:ff
nt_mac:
    movzbl nic_mac(%ebx), %eax
    call phex8
    inc %ebx
    cmp $6, %ebx
    jae nt_macd
    mov $msg_colon, %esi
    call puts
    jmp nt_mac
nt_macd:
    call crlf
    jmp shell
# No driver matched: scan PCI and report every Ethernet controller so
# we learn what the real card is (read its vendor:device off the screen
# and the dev box builds the matching driver).
net_probe:
    mov $msg_net_none, %esi
    call puts
    movl $0, pci_last            # de-dup: single-function devices alias
    xor %ebx, %ebx               # EBX = BDF index (bus<<8 | dev<<3 | func)
np_scan:
    mov %ebx, %ebp               # full enumeration: onboard NICs often sit
    shl $8, %ebp                 # on a higher bus (behind a PCIe root port),
    or $0x80000000, %ebp         # not bus 0 - that is why scanning only bus 0
    mov %ebp, %eax               # found nothing.
    call pci_read                # EAX = device:vendor
    cmp $0xffffffff, %eax
    je np_next
    test %eax, %eax
    jz np_next
    push %eax                    # save vendor:device
    lea 0x08(%ebp), %eax         # class/subclass/prog-if/revision
    call pci_read
    shr $24, %eax                # AL = class code
    pop %edx                     # EDX = vendor:device (balance stack)
    cmp $2, %al                  # 0x02 = network controller
    jne np_next
    cmp %edx, pci_last           # same id as last print? (function alias)
    je np_next
    mov %edx, pci_last
    mov $msg_net_pci, %esi       # "  net @bus "
    call puts
    mov %ebx, %eax               # bus number (BDF >> 8)
    shr $8, %eax
    call print_dec32
    mov $msg_net_pci2, %esi      # "  PCI "
    call puts
    movzwl %dx, %eax             # vendor (low word)
    call phex16
    mov $msg_colon, %esi
    call puts
    mov %edx, %eax               # device (high word)
    shr $16, %eax
    call phex16
    call crlf
np_next:
    inc %ebx
    cmp $0x4000, %ebx            # buses 0-63
    jb np_scan
    jmp shell

# --- lspci: every PCI device (bus:dev.func vendor:device class), with the
#   storage subclass spelled out (IDE/SATA/AHCI/NVMe) so we know what disk
#   controller a machine has. Reuses the PCI config scan from net_probe.
do_lspci:
    movb $0x0f, cur_attr
    mov $msg_lspci, %esi
    call puts
    movb $0x0a, cur_attr
    xor %ebx, %ebx               # EBX = BDF (bus<<8 | dev<<3 | func)
lp_scan:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp
    mov %ebp, %eax
    call pci_read                # device:vendor
    cmp $0xffffffff, %eax
    je lp_next
    test %eax, %eax
    jz lp_next
    mov %eax, lp_vd
    lea 0x08(%ebp), %eax         # class/subclass/prog-if/rev
    call pci_read
    mov %eax, lp_class
    mov %ebx, %eax               # bus
    shr $8, %eax
    call phex8
    mov $msg_colon, %esi
    call puts
    mov %ebx, %eax               # dev
    shr $3, %eax
    and $0x1f, %eax
    call phex8
    mov $msg_dot, %esi
    call puts
    mov %ebx, %eax               # func
    and $7, %eax
    add $0x30, %al
    call putc
    mov $msg_sp, %esi
    call puts
    mov lp_vd, %eax              # vendor
    movzwl %ax, %eax
    call phex16
    mov $msg_colon, %esi
    call puts
    mov lp_vd, %eax              # device
    shr $16, %eax
    call phex16
    mov $msg_sp, %esi
    call puts
    mov lp_class, %eax           # class -> name
    shr $24, %eax
    mov %al, %dl
    call pci_classname
    call puts
    cmp $1, %dl                  # storage? append the subclass name
    jne lp_eol
    mov $msg_sp, %esi
    call puts
    mov lp_class, %eax
    shr $16, %eax
    mov %al, %dl
    call pci_storsub
    call puts
lp_eol:
    call crlf
lp_next:
    inc %ebx
    cmp $0x4000, %ebx
    jb lp_scan
    jmp shell

# pci_classname: DL = class code -> ESI = name string (DL preserved).
pci_classname:
    mov $pci_class_tbl, %esi
pcl_l:
    movzbl (%esi), %ecx
    cmp $0xff, %cl               # end / default entry
    je pcl_found
    cmp %cl, %dl
    je pcl_found
    inc %esi
pcl_sk:
    lodsb
    test %al, %al
    jnz pcl_sk
    jmp pcl_l
pcl_found:
    inc %esi
    ret
# pci_storsub: DL = storage subclass -> ESI = name (IDE/SATA/AHCI/NVMe/...).
pci_storsub:
    mov $pci_stor_tbl, %esi
    jmp pcl_l                    # same table-walk logic

# =====================================================================
#  AHCI driver - the test PC's disk is 8086:8c02 (SATA/AHCI, Lynx Point),
#  there is no legacy IDE, so this is the only way to reach it. The HBA
#  registers (ABAR) live in high MMIO -> mapped with a 4 MB PCD page; the
#  command list / FIS / command table / data buffer sit in identity-mapped
#  low RAM (the device DMAs to those physical addresses). One slot, one
#  PRDT, polled (no IRQ) - matching the rest of TannX OS.
#
#  ahci_find:   scan PCI for a SATA AHCI controller (class 0x0106).
#               -> EAX = ABAR phys (BAR5, masked), CF=1 if none.
ahci_find:
    push %ebx
    push %ebp
    mov $0x0106, %ax             # class 01 storage / subclass 06 SATA-AHCI
    xor %cl, %cl                 # the first such controller
    call pci_find_class          # -> EBP = config base, CF=1 if none
    jc af_none
    lea 0x04(%ebp), %eax         # PCI command reg: enable memory + bus master
    call pci_read
    or $0x06, %eax               # bit1 mem space, bit2 bus master
    mov %eax, %ecx
    lea 0x04(%ebp), %eax
    call pci_write
    lea 0x24(%ebp), %eax         # BAR5 = ABAR
    call pci_read
    and $0xfffffff0, %eax
    pop %ebp
    pop %ebx
    clc
    ret
af_none:
    pop %ebp
    pop %ebx
    stc
    ret

# pci_write: EAX = config addr, ECX = value. Clobbers EAX.
pci_write:
    push %edx
    mov $0xcf8, %dx
    out %eax, %dx
    mov $0xcfc, %dx
    mov %ecx, %eax
    out %eax, %dx
    pop %edx
    ret

# ahci_mapbar: EAX = ABAR phys -> map it (4 MB PCD page if high MMIO) and
#   store ahci_abar. Low (<32 MB) addresses are already identity-mapped.
ahci_mapbar:
    push %ecx
    push %edx
    mov %eax, ahci_abar
    cmp $0x2000000, %eax
    jb amb_done
    push %eax
    mov %eax, %ecx
    shr $22, %ecx
    and $0xffc00000, %eax
    or $0x93, %eax               # P|RW|PS|PCD - uncached MMIO
    mov %eax, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax               # CR4.PSE (idempotent)
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3               # flush TLB
    pop %eax
amb_done:
    pop %edx
    pop %ecx
    ret

# ahci_pstart: ahci_abar set -> enable AHCI, find the first active SATA
#   port (DET=3, SIG=disk), init it, store ahci_pbase. CF=1 if no disk.
ahci_pstart:
    push %ebx
    push %ecx
    mov ahci_abar, %edx
    mov 0x04(%edx), %eax         # GHC: set AE (AHCI enable, bit31)
    or $0x80000000, %eax
    mov %eax, 0x04(%edx)
    mov 0x0c(%edx), %ebx         # PI: ports-implemented bitmap
    xor %ecx, %ecx
aps_l:
    bt %ecx, %ebx
    jnc aps_n
    mov %ecx, %eax               # port base = ABAR + 0x100 + port*0x80
    shl $7, %eax
    add $0x100, %eax
    add ahci_abar, %eax
    mov %eax, %edi
    mov 0x28(%edi), %eax         # PxSSTS: DET (bits0-3) == 3 -> present+comm
    and $0x0f, %eax
    cmp $3, %eax
    jne aps_n
    mov 0x24(%edi), %eax         # PxSIG: 0x00000101 = SATA disk, 0xEB140101 =
    cmp $0x101, %eax             #   ATAPI (optical / packet device)
    je aps_hdd
    cmp $0xeb140101, %eax
    je aps_atapi
    jmp aps_n
aps_hdd:
    movb $0, ahci_devtype        # 0 = SATA hard disk
    jmp aps_found
aps_atapi:
    movb $1, ahci_devtype        # 1 = ATAPI
aps_found:
    mov %edi, ahci_pbase
    call ahci_port_init
    pop %ecx
    pop %ebx
    clc
    ret
aps_n:
    inc %ecx
    cmp $32, %ecx
    jb aps_l
    pop %ecx
    pop %ebx
    stc
    ret

# ahci_port_init: EDI = port base. Stop the engine, point it at our CLB/FIS,
#   clear them, restart. All wait loops are bounded so a sick controller
#   can never hang the boot.
ahci_port_init:
    push %eax
    push %ecx
    push %edi
    mov 0x18(%edi), %eax         # clear ST (bit0)
    and $0xfffffffe, %eax
    mov %eax, 0x18(%edi)
    mov $0x100000, %ecx
api_cr:
    mov 0x18(%edi), %eax         # wait CR (bit15) clear
    test $0x8000, %eax
    jz api_cr_d
    dec %ecx
    jnz api_cr
api_cr_d:
    mov 0x18(%edi), %eax         # clear FRE (bit4)
    and $0xffffffef, %eax
    mov %eax, 0x18(%edi)
    mov $0x100000, %ecx
api_fr:
    mov 0x18(%edi), %eax         # wait FR (bit14) clear
    test $0x4000, %eax
    jz api_fr_d
    dec %ecx
    jnz api_fr
api_fr_d:
    movl $AHCI_CLB, 0x00(%edi)   # PxCLB / PxFB
    movl $0, 0x04(%edi)
    movl $AHCI_FIS, 0x08(%edi)
    movl $0, 0x0c(%edi)
    mov $AHCI_CLB, %edi          # zero the command list (1 KB)
    xor %eax, %eax
    mov $256, %ecx
    rep stosl
    mov $AHCI_FIS, %edi          # zero the received-FIS area (256 B)
    mov $64, %ecx
    rep stosl
    pop %edi
    push %edi
    movl $0xffffffff, 0x30(%edi) # clear PxSERR
    mov 0x18(%edi), %eax         # FRE then ST
    or $0x10, %eax
    mov %eax, 0x18(%edi)
    or $0x01, %eax
    mov %eax, 0x18(%edi)
    pop %edi
    pop %ecx
    pop %eax
    ret

# ahci_exec: a CFIS is already built at AHCI_CT; EAX = byte count for the
#   single PRDT entry; ahci_wflag selects read/write. Builds the command
#   header (slot 0), issues it, polls to completion. CF=1 on error/timeout.
ahci_exec:
    push %ebx
    push %ecx
    push %edi
    mov ahci_pbase, %edi
    mov $AHCI_CLB, %ebx          # command header, slot 0
    mov $0x00010005, %ecx        # PRDTL=1 (<<16) | CFL=5 dwords
    cmpb $0, ahci_wflag
    je ae_nw
    or $0x40, %ecx               # W (write, bit6)
ae_nw:
    cmpb $0, ahci_aflag          # A (ATAPI packet command, bit5)
    je ae_na
    or $0x20, %ecx
ae_na:
    mov %ecx, 0x00(%ebx)
    movl $0, 0x04(%ebx)          # PRDBC
    movl $AHCI_CT, 0x08(%ebx)    # CTBA
    movl $0, 0x0c(%ebx)
    mov $AHCI_CT, %ebx           # PRDT[0] at CT + 0x80
    movl $AHCI_BUF, 0x80(%ebx)   # DBA
    movl $0, 0x84(%ebx)
    movl $0, 0x88(%ebx)
    dec %eax                     # DBC = byte count - 1 (22 bits)
    and $0x3fffff, %eax
    mov %eax, 0x8c(%ebx)
    mov $0x800000, %ecx          # wait while BSY|DRQ
ae_rdy:
    mov 0x20(%edi), %eax         # PxTFD
    test $0x88, %eax
    jz ae_go
    dec %ecx
    jnz ae_rdy
    jmp ae_err
ae_go:
    movl $0xffffffff, 0x10(%edi) # clear PxIS
    movl $1, 0x38(%edi)          # PxCI bit0 -> issue slot 0
    mov $0x4000000, %ecx
ae_wait:
    mov 0x38(%edi), %eax         # PxCI clear -> done
    test $1, %eax
    jz ae_check
    mov 0x10(%edi), %eax         # PxIS.TFES (bit30) -> task-file error
    test $0x40000000, %eax
    jnz ae_err
    dec %ecx
    jnz ae_wait
    jmp ae_err
ae_check:
    mov 0x20(%edi), %eax         # PxTFD.ERR (bit0)
    test $0x01, %eax
    jnz ae_err
    pop %edi
    pop %ecx
    pop %ebx
    clc
    ret
ae_err:
    pop %edi
    pop %ecx
    pop %ebx
    stc
    ret

# ahci_clrfis: zero the 128-byte CFIS/command-table header at AHCI_CT.
ahci_clrfis:
    push %eax
    push %ecx
    push %edi
    mov $AHCI_CT, %edi
    xor %eax, %eax
    mov $32, %ecx
    rep stosl
    pop %edi
    pop %ecx
    pop %eax
    ret

# ahci_identify: IDENTIFY -> 512 bytes at AHCI_BUF. Uses IDENTIFY DEVICE (0xEC)
#   for a SATA HDD, IDENTIFY PACKET DEVICE (0xA1) for an ATAPI device (both are
#   plain PIO data-in, not packet commands, so the normal path serves). CF err.
ahci_identify:
    call ahci_clrfis
    mov $AHCI_CT, %edi
    movb $0x27, 0(%edi)          # FIS type: Register H2D
    movb $0x80, 1(%edi)          # C = 1 (this is a command)
    movb $0xec, 2(%edi)          # IDENTIFY DEVICE (HDD)
    cmpb $0, ahci_devtype
    je ai_cmd
    movb $0xa1, 2(%edi)          # IDENTIFY PACKET DEVICE (ATAPI)
ai_cmd:
    movb $0, 7(%edi)             # device
    movb $0, ahci_wflag
    movb $0, ahci_aflag
    mov $512, %eax
    call ahci_exec
    ret

# ahci_read: EAX = LBA (low 32 bits) -> read 1 sector into AHCI_BUF.
#   READ DMA EXT (0x25), 48-bit LBA, LBA48 high bytes zero. CF on error.
ahci_read:
    push %edx
    mov %eax, %edx               # keep LBA
    call ahci_clrfis
    push %edi
    mov $AHCI_CT, %edi
    movb $0x27, 0(%edi)
    movb $0x80, 1(%edi)
    movb $0x25, 2(%edi)          # READ DMA EXT
    mov %dl, 4(%edi)             # LBA0
    mov %edx, %eax
    shr $8, %eax
    mov %al, 5(%edi)             # LBA1
    shr $8, %eax
    mov %al, 6(%edi)             # LBA2
    movb $0x40, 7(%edi)          # device: LBA mode
    mov %edx, %eax
    shr $24, %eax
    mov %al, 8(%edi)             # LBA3 (bits 24-31)
    movb $0, 9(%edi)             # LBA4 = 0
    movb $0, 10(%edi)            # LBA5 = 0
    movb $1, 12(%edi)            # sector count low = 1
    movb $0, 13(%edi)            # sector count high = 0
    movb $0, ahci_wflag
    pop %edi
    mov $512, %eax
    call ahci_exec
    pop %edx
    ret

# ahci_write: EAX = LBA (low 32 bits) -> write the 512 bytes at AHCI_BUF to
#   that sector. WRITE DMA EXT (0x35), 48-bit LBA. CF on error. Caller fills
#   AHCI_BUF first. Single sector, to match ata_write / the rest of the OS.
ahci_write:
    push %edx
    mov %eax, %edx
    call ahci_clrfis
    push %edi
    mov $AHCI_CT, %edi
    movb $0x27, 0(%edi)
    movb $0x80, 1(%edi)
    movb $0x35, 2(%edi)          # WRITE DMA EXT
    mov %dl, 4(%edi)             # LBA0
    mov %edx, %eax
    shr $8, %eax
    mov %al, 5(%edi)             # LBA1
    shr $8, %eax
    mov %al, 6(%edi)             # LBA2
    movb $0x40, 7(%edi)          # device: LBA mode
    mov %edx, %eax
    shr $24, %eax
    mov %al, 8(%edi)             # LBA3 (bits 24-31)
    movb $0, 9(%edi)             # LBA4 = 0
    movb $0, 10(%edi)            # LBA5 = 0
    movb $1, 12(%edi)            # sector count low = 1
    movb $0, 13(%edi)            # sector count high = 0
    movb $1, ahci_wflag          # this is a write
    pop %edi
    mov $512, %eax
    call ahci_exec
    pop %edx
    ret

# --- ATAPI (SCSI packet) path: for the optical/packet devices ----------------
# atapi_cdb_clear: zero the 16-byte ACMD (SCSI CDB) field at AHCI_CT+0x40.
atapi_cdb_clear:
    push %edi
    push %eax
    push %ecx
    mov $AHCI_CT+0x40, %edi
    xor %eax, %eax
    mov $4, %ecx
    rep stosl
    pop %ecx
    pop %eax
    pop %edi
    ret

# ahci_packet: a SCSI CDB is already at AHCI_CT+0x40; EAX = expected byte count
#   -> issue ATA PACKET (0xA0, DMA) with the A bit set and transfer into
#   AHCI_BUF. Only the 20-byte CFIS is rebuilt (the CDB at +0x40 is left). CF err.
ahci_packet:
    push %edx
    mov %eax, %edx               # save byte count
    push %edi
    mov $AHCI_CT, %edi           # clear only the 20-byte CFIS, not the CDB
    movl $0, 0(%edi)
    movl $0, 4(%edi)
    movl $0, 8(%edi)
    movl $0, 12(%edi)
    movl $0, 16(%edi)
    movb $0x27, 0(%edi)          # H2D register FIS
    movb $0x80, 1(%edi)          # C = 1
    movb $0xa0, 2(%edi)          # PACKET
    movb $0x01, 3(%edi)          # feature: DMA
    mov %dl, 5(%edi)             # byte-count limit (PIO; ignored for DMA)
    mov %edx, %eax
    shr $8, %eax
    mov %al, 6(%edi)
    pop %edi
    movb $0, ahci_wflag
    movb $1, ahci_aflag          # set the A (ATAPI) bit in the command header
    mov %edx, %eax               # PRDT byte count
    call ahci_exec
    movb $0, ahci_aflag
    pop %edx
    ret

# ahci_atapi_capacity: READ CAPACITY(10) -> AHCI_BUF[0..7] (last-LBA + block
#   size, both big-endian). CF=1 if the drive is not ready / has no media.
ahci_atapi_capacity:
    call atapi_cdb_clear
    movb $0x25, AHCI_CT+0x40      # SCSI READ CAPACITY(10)
    mov $8, %eax
    call ahci_packet
    ret

# ahci_atapi_read: EAX = LBA -> READ(10) one 2048-byte block into AHCI_BUF.
#   CF=1 on error (no media / bad LBA).
ahci_atapi_read:
    push %edx
    mov %eax, %edx
    call atapi_cdb_clear
    movb $0x28, AHCI_CT+0x40      # SCSI READ(10)
    mov %edx, %eax               # LBA -> CDB[2..5] big-endian
    bswap %eax
    mov %eax, AHCI_CT+0x42
    movw $0x0100, AHCI_CT+0x47    # transfer length = 1 block (BE: hi=0, lo=1)
    mov $2048, %eax
    call ahci_packet
    pop %edx
    ret

# ahci_up: ensure the controller is found, mapped and a port started.
#   CF=1 if there is no AHCI disk. Idempotent (skips if ahci_pbase set).
ahci_up:
    cmpl $0, ahci_pbase
    jne au_ok
    call ahci_find
    jc au_no
    call ahci_mapbar
    call ahci_pstart
    jc au_no
au_ok:
    clc
    ret
au_no:
    stc
    ret

# --- ahci: detect the SATA controller + IDENTIFY the disk (model, size) ---
do_ahci:
    movb $0x0f, cur_attr
    mov $msg_ahci_h, %esi
    call puts
    call ahci_find
    jc ah_none
    call ahci_mapbar
    call ahci_pstart
    jc ah_noport
    call ahci_identify
    jc ah_ierr
    movb $0x0a, cur_attr
    mov $msg_ahci_model, %esi
    call puts
    mov $AHCI_BUF+54, %esi       # model: words 27-46, byte-swapped
    mov $20, %ecx
ah_mdl:
    mov 1(%esi), %al
    call putc
    mov 0(%esi), %al
    call putc
    add $2, %esi
    loop ah_mdl
    cmpb $0, ahci_devtype        # ATAPI: no IDENTIFY capacity, just label it
    jne ah_atapi
    mov $msg_ahci_sect, %esi
    call puts
    mov AHCI_BUF+200, %eax       # 48-bit LBA count (low dword)
    test %eax, %eax
    jnz ah_haves
    mov AHCI_BUF+120, %eax       # fall back to 28-bit count
ah_haves:
    push %eax
    call print_dec32
    mov $msg_ahci_mb, %esi
    call puts
    pop %eax
    shr $11, %eax                # sectors / 2048 -> MB
    call print_dec32
    mov $msg_ahci_mbe, %esi
    call puts
    call ahci_log
    jmp shell
ah_atapi:
    mov $msg_ahci_atapi, %esi    # "  ATAPI (optical/packet device)\r\n"
    call puts
    call ahci_atapi_capacity     # READ CAPACITY(10): media present?
    jc ah_nomedia
    mov $msg_ahci_cap, %esi      # "  media: "
    call puts
    mov AHCI_BUF, %eax           # last LBA, big-endian -> block count
    bswap %eax
    inc %eax
    push %eax
    call print_dec32
    mov $msg_ahci_blocks, %esi   # " blocks ("
    call puts
    pop %eax
    shr $9, %eax                 # blocks * 2048 / 1 MB = blocks / 512
    call print_dec32
    mov $msg_ahci_mbe, %esi      # " MB)\r\n"
    call puts
    call ahci_log
    jmp shell
ah_nomedia:
    mov $msg_ahci_nomedia, %esi  # "  (no media / drive not ready)\r\n"
    call puts
    call ahci_log
    jmp shell
ah_none:
    mov $msg_ahci_no, %esi
    call puts
    jmp shell
ah_noport:
    mov $msg_ahci_np, %esi
    call puts
    jmp shell
ah_ierr:
    mov $msg_ahci_ie, %esi
    call puts
    jmp shell

# --- aread <lba>: read one sector over AHCI and hexdump the first 64 bytes
do_aread:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_hex
    jc are_use
    mov %eax, ahci_lba
    call ahci_up
    jc are_no
    mov ahci_lba, %eax
    call ahci_read
    jc are_err
    movb $0x0a, cur_attr
    mov $AHCI_BUF, %esi
    mov $4, %ebx                 # 4 rows x 16 bytes
ard_row:
    mov $16, %ecx
ard_b:
    mov (%esi), %al
    call phex8
    mov $0x20, %al
    call putc
    inc %esi
    loop ard_b
    call crlf
    dec %ebx
    jnz ard_row
    jmp shell
are_use:
    mov $msg_aread_u, %esi
    call puts
    jmp shell
are_no:
    mov $msg_ahci_no, %esi
    call puts
    jmp shell
are_err:
    mov $msg_aread_e, %esi
    call puts
    jmp shell

# --- awrite <lba> <hex32>: fill a sector with a repeating 32-bit pattern and
#   write it over AHCI. Manual/explicit only (never automatic) - writing to a
#   real disk is destructive, so the user drives this like dd, one sector.
do_awrite:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_hex               # LBA
    jc aw_use
    mov %eax, ahci_lba
    call skip_spaces
    call parse_hex               # 32-bit fill pattern
    jc aw_use
    mov %eax, %edx               # EDX = pattern
    mov $AHCI_BUF, %edi          # fill 512 bytes = 128 dwords
    mov %edx, %eax
    mov $128, %ecx
    rep stosl
    call ahci_up
    jc aw_no
    mov ahci_lba, %eax
    call ahci_write
    jc aw_err
    mov $msg_awrite_ok, %esi     # "awrite: sector written\r\n"
    call puts
    jmp shell
aw_use:
    mov $msg_awrite_u, %esi
    call puts
    jmp shell
aw_no:
    mov $msg_ahci_no, %esi
    call puts
    jmp shell
aw_err:
    mov $msg_aread_e, %esi
    call puts
    jmp shell

# --- cdread <lba>: read one 2048-byte block from the ATAPI/optical device via
#   SCSI READ(10) and hexdump the first 64 bytes. Read-only, like aread.
do_cdread:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_hex               # LBA
    jc cd_use
    mov %eax, ahci_lba
    call ahci_up
    jc cd_no
    cmpb $1, ahci_devtype        # must be an ATAPI device
    jne cd_nota
    mov ahci_lba, %eax
    call ahci_atapi_read
    jc cd_err
    movb $0x0a, cur_attr
    mov $AHCI_BUF, %esi
    mov $4, %ebx                 # 4 rows x 16 bytes
cd_row:
    mov $16, %ecx
cd_b:
    mov (%esi), %al
    call phex8
    mov $0x20, %al
    call putc
    inc %esi
    loop cd_b
    call crlf
    dec %ebx
    jnz cd_row
    jmp shell
cd_use:
    mov $msg_cdread_u, %esi
    call puts
    jmp shell
cd_no:
    mov $msg_ahci_no, %esi
    call puts
    jmp shell
cd_nota:
    mov $msg_cd_nota, %esi
    call puts
    jmp shell
cd_err:
    mov $msg_cd_err, %esi
    call puts
    jmp shell

# ahci_log: write an "ahci: <model> <MB> MB" line into the dmesg ring so the
#   dev box reads the disk IDENTIFY off the test PC over the wire (net-dmesg.sh).
ahci_log:
    mov $REPLY_SCRATCH, %edi
    mov $logp_ahci, %esi
    call bputs
    mov $AHCI_BUF+54, %esi       # model, 20 words, byte-swapped
    mov $20, %ecx
al_m:
    mov 1(%esi), %al
    stosb
    mov (%esi), %al
    stosb
    add $2, %esi
    loop al_m
    movb $0x20, %al
    stosb
    cmpb $0, ahci_devtype        # ATAPI has no IDENTIFY capacity -> just label it
    jne al_atapi
    mov AHCI_BUF+200, %eax
    test %eax, %eax
    jnz al_s
    mov AHCI_BUF+120, %eax
al_s:
    shr $11, %eax                # -> MB
    call bdec32
    mov $logp_mbz, %esi
    call bputs
    jmp al_emit
al_atapi:
    mov $logp_atapi, %esi        # "ATAPI\r\n"
    call bputs
al_emit:
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret

# log_ahci: boot-time probe - detect + IDENTIFY the AHCI disk and log it (or
#   "ahci: none") to dmesg, so the test PC self-reports its disk on every boot.
log_ahci:
    call ahci_find
    jc la_none
    call ahci_mapbar
    mov ahci_abar, %edx          # enable AHCI (GHC.AE) before reading ports
    mov 0x04(%edx), %eax
    or $0x80000000, %eax
    mov %eax, 0x04(%edx)
    # diagnostic line: PI bitmap + each implemented port's SSTS / SIG, so the
    #   test PC reports its raw link state over the wire (blind-HW debug, like nicdbg)
    mov $REPLY_SCRATCH, %edi
    mov $logp_ahci, %esi
    call bputs
    mov $logp_pi, %esi           # "PI "
    call bputs
    mov ahci_abar, %edx
    mov 0x0c(%edx), %eax         # PI = ports-implemented bitmap
    mov %eax, %ebx
    call bhex32
    xor %ecx, %ecx
ld_p:
    bt %ecx, %ebx
    jnc ld_n
    movb $0x20, %al              # " p<n>:"
    stosb
    movb $0x70, %al
    stosb
    mov %ecx, %eax
    add $0x30, %al
    stosb
    movb $0x3a, %al
    stosb
    mov %ecx, %eax               # port base = ABAR + 0x100 + port*0x80
    shl $7, %eax
    add $0x100, %eax
    add ahci_abar, %eax
    push %eax
    mov 0x28(%eax), %eax         # PxSSTS
    call bhex32
    movb $0x2f, %al              # "/"
    stosb
    pop %eax
    mov 0x24(%eax), %eax         # PxSIG
    call bhex32
ld_n:
    inc %ecx
    cmp $6, %ecx
    jb ld_p
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    call ahci_pstart             # active port? then IDENTIFY + (HDD) read
    jc la_done
    call ahci_identify
    jc la_done
    call ahci_log
    cmpb $0, ahci_devtype        # ATAPI: probe media via SCSI, not READ DMA EXT
    jne la_atapi_cap
    xor %eax, %eax               # read-path self-check: READ DMA EXT LBA 0
    call ahci_read
    jc la_rderr
    mov $REPLY_SCRATCH, %edi
    mov $logp_ard, %esi          # "ahci-rd: lba0 "
    call bputs
    mov AHCI_BUF, %eax           # first dword of the sector
    call bhex32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
la_atapi_cap:                     # ATAPI: log media state so the SCSI packet
    call ahci_atapi_capacity      #   path is verifiable over the wire (no-media
    jc la_nomedia                 #   on an empty drive still proves it round-trips)
    mov $REPLY_SCRATCH, %edi
    mov $logp_acap, %esi          # "atapi-cap: "
    call bputs
    mov AHCI_BUF, %eax            # last LBA (big-endian) -> block count
    bswap %eax
    inc %eax
    call bdec32
    mov $logp_blk, %esi           # " blocks\r\n"
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret
la_nomedia:
    mov $REPLY_SCRATCH, %edi
    mov $logp_acap, %esi
    call bputs
    mov $logp_nomed, %esi         # "no media\r\n"
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret
la_done:                          # the diag line already recorded the port state
    ret
la_rderr:
    mov $REPLY_SCRATCH, %edi
    mov $logp_ard, %esi
    call bputs
    mov $logp_rde, %esi          # "read FAILED\r\n"
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret
la_none:
    mov $REPLY_SCRATCH, %edi
    mov $logp_ahci, %esi
    call bputs
    mov $logp_ahn, %esi          # "none\r\n"
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret

# log_usb: scan PCI for USB host controllers (class 0x0C03) and log each one
#   (vendor:device, type from prog-if, BAR0) to dmesg, so the test PC reports its
#   USB hardware over the wire - the basis for the USB driver.
log_usb:
    push %ebx
    push %ebp
    xor %ebx, %ebx
lu_l:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp
    mov %ebp, %eax
    call pci_read                # vendor:device
    cmp $0xffffffff, %eax
    je lu_n
    test %eax, %eax
    jz lu_n
    mov %eax, lu_vd
    lea 0x08(%ebp), %eax         # class/subclass/prog-if/rev
    call pci_read
    mov %eax, lu_cl
    shr $16, %eax
    and $0xffff, %eax            # class<<8 | subclass
    cmp $0x0c03, %eax            # USB host controller?
    jne lu_n
    mov $REPLY_SCRATCH, %edi
    mov $logp_usb, %esi          # "usb: "
    call bputs
    mov %ebx, %eax               # bus:dev.func
    shr $8, %eax
    call bhex8
    mov $logp_colon, %esi
    call bputs
    mov %ebx, %eax
    shr $3, %eax
    and $0x1f, %eax
    call bhex8
    movb $0x2e, %al              # '.'
    stosb
    mov %ebx, %eax
    and $7, %eax
    add $0x30, %al
    stosb
    movb $0x20, %al
    stosb
    mov lu_vd, %eax              # vendor
    movzwl %ax, %eax
    call bhex16
    mov $logp_colon, %esi
    call bputs
    mov lu_vd, %eax              # device
    shr $16, %eax
    call bhex16
    movb $0x20, %al
    stosb
    mov lu_cl, %eax              # prog-if -> controller type
    shr $8, %eax
    and $0xff, %eax
    cmp $0x00, %al
    je lu_uhci
    cmp $0x10, %al
    je lu_ohci
    cmp $0x20, %al
    je lu_ehci
    cmp $0x30, %al
    je lu_xhci
    mov $logp_usb_q, %esi
    jmp lu_tp
lu_uhci:
    mov $logp_uhci, %esi
    jmp lu_tp
lu_ohci:
    mov $logp_ohci, %esi
    jmp lu_tp
lu_ehci:
    mov $logp_ehci, %esi
    jmp lu_tp
lu_xhci:
    mov $logp_xhci_t, %esi
lu_tp:
    call bputs
    mov $logp_usb_bar, %esi      # " bar0="
    call bputs
    lea 0x10(%ebp), %eax         # BAR0
    call pci_read
    call bhex32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
lu_n:
    inc %ebx
    cmp $0x4000, %ebx
    jb lu_l
    pop %ebp
    pop %ebx
    ret

# =====================================================================
#  xHCI USB host-controller driver (the test PC's keyboard/mouse are USB; the
#  BIOS only legacy-emulates the keyboard, so we drive USB ourselves).
#  Find the controller, map its MMIO, reset it, read MaxSlots/
#  MaxPorts and the per-port connect state -> dmesg. Memory structures
#  live at 0x300000 (identity-mapped, DMA-able, clear of everything).
# =====================================================================
.equ XHCI_DCBAA,   0x300000      # device-context base address array
.equ XHCI_CMDRING, 0x301000      # command ring
.equ XHCI_EVTRING, 0x302000      # event ring segment
.equ XHCI_ERST,    0x303000      # event ring segment table
.equ XHCI_INPCTX,  0x304000      # input context (enumeration)
.equ XHCI_DEVCTX,  0x305000      # device context
.equ XHCI_EP0RING, 0x306000      # control (EP0) transfer ring
.equ XHCI_INTRING, 0x307000      # interrupt-IN transfer ring
.equ XHCI_DATABUF, 0x308000      # descriptors / HID reports

# xhci_find: scan PCI for an xHCI controller (class 0x0C0330). Enables memory
#   + bus master, returns EAX = BAR0 (masked), CF=1 if none.
xhci_find:
    push %ebx
    push %ebp
    xor %ebx, %ebx
xf_l:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp
    mov %ebp, %eax
    call pci_read
    cmp $0xffffffff, %eax
    je xf_n
    test %eax, %eax
    jz xf_n
    lea 0x08(%ebp), %eax
    call pci_read
    shr $8, %eax
    and $0xffffff, %eax
    cmp $0x0c0330, %eax          # USB xHCI (class 0C, subclass 03, prog-if 30)
    jne xf_n
    lea 0x10(%ebp), %eax         # a 64-bit BAR placed above 4 GB (server boards:
    call pci_read                #   C620 xHCI at 0x383FFFF00000) is out of reach
    and $0x06, %eax              #   of this 32-bit kernel - its low dword pointed
    cmp $0x04, %eax              #   into the BIOS flash window and the reset loops
    jne xf_bar32                 #   crawled over SPI for minutes. Skip such a
    lea 0x14(%ebp), %eax         #   controller (the log says "none").
    call pci_read
    test %eax, %eax
    jnz xf_n
xf_bar32:
    lea 0x04(%ebp), %eax         # enable memory space + bus master
    call pci_read
    or $0x06, %eax
    mov %eax, %ecx
    lea 0x04(%ebp), %eax
    call pci_write
    lea 0x10(%ebp), %eax         # BAR0
    call pci_read
    and $0xfffffff0, %eax
    pop %ebp
    pop %ebx
    clc
    ret
xf_n:
    inc %ebx
    cmp $0x4000, %ebx
    jb xf_l
    pop %ebp
    pop %ebx
    stc
    ret

# xhci_map: EAX = BAR0 phys -> map it (4 MB PCD page if high MMIO), store
#   xhci_base and the operational-register base (xhci_op = base + CAPLENGTH).
xhci_map:
    mov %eax, xhci_base
    cmp $0x2000000, %eax
    jb xm_op
    push %ecx
    push %eax
    mov %eax, %ecx
    shr $22, %ecx
    and $0xffc00000, %eax
    or $0x93, %eax               # P|RW|PS|PCD (uncached MMIO)
    mov %eax, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3
    pop %eax
    pop %ecx
xm_op:
    mov xhci_base, %edx
    movzbl (%edx), %eax          # CAPLENGTH
    add %edx, %eax
    mov %eax, xhci_op
    ret

# xhci_reset: halt then reset the controller, wait for ready (bounded).
xhci_reset:
    pushal
    mov xhci_op, %edi
    mov (%edi), %eax             # USBCMD: clear R/S (halt)
    and $0xfffffffe, %eax
    mov %eax, (%edi)
    mov $0x1000000, %ecx
xr_halt:
    mov 4(%edi), %eax            # USBSTS.HCH (bit0)
    test $0x01, %eax
    jnz xr_rst
    dec %ecx
    jnz xr_halt
xr_rst:
    mov (%edi), %eax             # USBCMD.HCRST (bit1)
    or $0x02, %eax
    mov %eax, (%edi)
    mov $0x1000000, %ecx
xr_wait:
    mov (%edi), %eax
    test $0x02, %eax             # HCRST cleared?
    jnz xr_more
    mov 4(%edi), %eax            # USBSTS.CNR (bit11) cleared?
    test $0x800, %eax
    jz xr_done
xr_more:
    dec %ecx
    jnz xr_wait
xr_done:
    popal
    ret

# log_xhci: bring up the xHCI controller and report slots/ports + which ports
#   have a device connected, to dmesg (over the wire). Boot probe.
log_xhci:
    call xhci_find
    jc lx_none
    call xhci_map
    call xhci_reset
    mov $REPLY_SCRATCH, %edi
    mov $logp_xhci, %esi         # "xhci: slots="
    call bputs
    mov xhci_base, %edx
    mov 4(%edx), %ebx            # HCSPARAMS1
    mov %ebx, %eax
    and $0xff, %eax              # MaxSlots
    call bdec32
    mov $logp_xh_p, %esi         # " ports="
    call bputs
    mov %ebx, %eax
    shr $24, %eax                # MaxPorts
    mov %eax, %ebp               # keep the port count
    call bdec32
    mov xhci_op, %edx            # power every port (PORTSC.PP = bit9), preserving
    xor %ecx, %ecx               #   the RW1C change bits (bits 17-23)
lx_pwr:
    cmp %ebp, %ecx
    jae lx_pwrd
    mov %ecx, %eax
    shl $4, %eax
    add $0x400, %eax
    add %edx, %eax
    push %eax
    mov (%eax), %ebx
    and $0xff01ffff, %ebx        # write 0 to the RW1C change bits
    or $0x200, %ebx              # PP
    pop %eax
    mov %ebx, (%eax)
    inc %ecx
    jmp lx_pwr
lx_pwrd:
    mov $0x1000000, %ecx         # brief settle delay
lx_pwrw:
    dec %ecx
    jnz lx_pwrw
    mov $logp_xh_cc, %esi        # " conn="
    call bputs
    mov xhci_op, %edx
    xor %ecx, %ecx               # port index
lx_ploop:
    cmp %ebp, %ecx
    jae lx_pdone
    mov %ecx, %eax
    shl $4, %eax
    add $0x400, %eax             # PORTSC[port] = op + 0x400 + port*0x10
    add %edx, %eax
    mov (%eax), %eax
    test $0x01, %eax             # CCS: device connected?
    jz lx_p0
    movb $0x31, %al              # '1'
    stosb
    jmp lx_pn
lx_p0:
    movb $0x30, %al              # '0'
    stosb
lx_pn:
    inc %ecx
    jmp lx_ploop
lx_pdone:
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret
lx_none:
    mov $REPLY_SCRATCH, %edi
    mov $logp_xhci, %esi
    call bputs
    mov $logp_ahn, %esi          # "none\r\n" (reused)
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret

# log_ehci: READ-ONLY probe of every EHCI controller (class 0x0C0320). For each,
#   map its MMIO and report N_PORTS + per-port connect status to dmesg, WITHOUT
#   resetting/taking over (so the BIOS legacy keyboard keeps working). This is
#   how we find which EHCI port the mouse sits on, on a default-BIOS test PC.
log_ehci:
    push %ebx
    push %ebp
    xor %ebx, %ebx
le_l:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp
    mov %ebp, %eax
    call pci_read
    cmp $0xffffffff, %eax
    je le_n
    test %eax, %eax
    jz le_n
    lea 0x08(%ebp), %eax
    call pci_read
    shr $8, %eax
    and $0xffffff, %eax
    cmp $0x0c0320, %eax          # EHCI
    jne le_n
    lea 0x10(%ebp), %eax         # BAR0
    call pci_read
    and $0xfffffff0, %eax
    mov %eax, ehci_base
    cmp $0x2000000, %eax         # map BAR0 (4 MB PCD page) if high MMIO
    jb le_mapped
    push %ecx
    mov %eax, %ecx
    shr $22, %ecx
    and $0xffc00000, %eax
    or $0x93, %eax
    mov %eax, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3
    pop %ecx
le_mapped:
    mov $REPLY_SCRATCH, %edi
    mov $logp_ehci2, %esi        # "ehci: "
    call bputs
    mov %ebx, %eax               # bus:dev.func
    shr $8, %eax
    call bhex8
    mov $logp_colon, %esi
    call bputs
    mov %ebx, %eax
    shr $3, %eax
    and $0x1f, %eax
    call bhex8
    movb $0x2e, %al
    stosb
    mov %ebx, %eax
    and $7, %eax
    add $0x30, %al
    stosb
    mov $logp_eh_p, %esi         # " ports="
    call bputs
    mov ehci_base, %edx
    mov 4(%edx), %eax            # HCSPARAMS: N_PORTS (bits 0-3)
    and $0x0f, %eax
    mov %eax, %ebp               # port count (overwrites BDF copy - fine, BDF in EBX)
    call bdec32
    movzbl (%edx), %eax          # CAPLENGTH -> operational base
    add %edx, %eax
    mov %eax, %edx               # EDX = op base
    mov $logp_xh_cc, %esi        # " conn=" (reused)
    call bputs
    xor %ecx, %ecx
le_ploop:
    cmp %ebp, %ecx
    jae le_pdone
    mov %ecx, %eax
    shl $2, %eax
    add $0x44, %eax              # PORTSC[port] = op + 0x44 + port*4
    add %edx, %eax
    mov (%eax), %eax
    test $0x01, %eax             # CCS
    jz le_p0
    movb $0x31, %al
    stosb
    jmp le_pn
le_p0:
    movb $0x30, %al
    stosb
le_pn:
    inc %ecx
    jmp le_ploop
le_pdone:
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
le_n:
    inc %ebx
    cmp $0x4000, %ebx
    jb le_l
    pop %ebp
    pop %ebx
    ret

# =====================================================================
#  EHCI control-transfer core (toward driving the test PC's USB HID over the
#  default-BIOS EHCI path). Structures at 0x310000. Async schedule, one
#  queue head; control transfers via SETUP/DATA/STATUS qTDs.
# =====================================================================
.equ EHCI_QH,    0x310000
.equ EHCI_QTD0,  0x310080        # SETUP qTD
.equ EHCI_QTD1,  0x3100C0        # DATA qTD
.equ EHCI_QTD2,  0x310100        # STATUS qTD
.equ EHCI_SETUP, 0x310200        # 8-byte setup packet
.equ EHCI_BUF,   0x310400        # data buffer (mouse interrupt reports too)
.equ EHCI_INTQH2,0x3101C0        # second interrupt QH (keyboard), 32-aligned
.equ EHCI_BUF2,  0x310440        # keyboard interrupt report buffer

# ehci_find_dev: first EHCI controller with a connected port -> ehci_bdf,
#   ehci_base, ehci_op, ehci_port. CF=1 none.
ehci_find_dev:
    push %ebp
    push %esi
    xor %esi, %esi               # ESI = how many connected ports skipped so far
    xor %ebx, %ebx
efd_l:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp
    mov %ebp, %eax
    call pci_read
    cmp $0xffffffff, %eax
    je efd_n
    test %eax, %eax
    jz efd_n
    lea 0x08(%ebp), %eax
    call pci_read
    shr $8, %eax
    and $0xffffff, %eax
    cmp $0x0c0320, %eax
    jne efd_n
    lea 0x04(%ebp), %eax
    call pci_read
    or $0x06, %eax
    mov %eax, %ecx
    lea 0x04(%ebp), %eax
    call pci_write
    lea 0x10(%ebp), %eax
    call pci_read
    and $0xfffffff0, %eax
    mov %eax, ehci_base
    call ehci_map
    mov ehci_base, %edx
    movzbl (%edx), %eax
    add %edx, %eax
    mov %eax, ehci_op
    mov 4(%edx), %eax
    and $0x0f, %eax
    mov %eax, %ecx
    mov ehci_op, %edx
    xor %edi, %edi
efd_p:
    cmp %ecx, %edi
    jae efd_n
    mov %edi, %eax
    shl $2, %eax
    add $0x44, %eax
    add %edx, %eax
    mov (%eax), %eax
    test $0x01, %eax
    jz efd_pn
    cmp ehci_skip, %esi          # skip until we reach the requested controller
    je efd_take
    inc %esi
    jmp efd_pn
efd_take:
    mov %ebx, ehci_bdf
    mov %edi, ehci_port
    pop %esi
    pop %ebp
    clc
    ret
efd_pn:
    inc %edi
    jmp efd_p
efd_n:
    inc %ebx
    cmp $0x4000, %ebx
    jb efd_l
    pop %esi
    pop %ebp
    stc
    ret

ehci_map:
    push %eax
    push %ecx
    mov ehci_base, %eax
    cmp $0x2000000, %eax
    jb ehm_d
    mov %eax, %ecx
    shr $22, %ecx
    and $0xffc00000, %eax
    or $0x93, %eax
    mov %eax, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3
ehm_d:
    pop %ecx
    pop %eax
    ret

# ehci_takeover: BIOS->OS handoff via the Legacy Support ext cap (EECP).
ehci_takeover:
    push %ebx
    push %ecx
    push %edx
    push %esi
    push %ebp
    mov ehci_base, %edx
    mov 8(%edx), %eax            # HCCPARAMS
    shr $8, %eax
    and $0xff, %eax              # EECP
    cmp $0x40, %eax
    jb et_done
    mov %eax, %esi
    mov ehci_bdf, %ebx
    shl $8, %ebx
    or $0x80000000, %ebx
    lea (%ebx,%esi), %eax
    and $0xfffffffc, %eax
    mov %eax, %ebp               # config addr of USBLEGSUP
    mov %ebp, %eax
    call pci_read
    or $0x01000000, %eax         # HC OS Owned (bit24)
    mov %eax, %ecx
    mov %ebp, %eax
    call pci_write
    mov $0x100000, %ecx
et_w:
    mov %ebp, %eax
    call pci_read
    test $0x00010000, %eax       # BIOS Owned (bit16) cleared?
    jz et_done
    dec %ecx
    jnz et_w
et_done:
    # Post-handoff: capture USBLEGSUP (bit16 BIOS-owned should be 0, bit24
    #   OS-owned 1) and USBLEGCTLSTS (EECP+4) for diag ONLY. (The SMI-
    #   disable write here was a speculative keyboard fix that was never HW-
    #   tested and likely regressed the working mouse - reverted. Read-only.)
    mov %ebp, %eax
    call pci_read
    mov %eax, ehci_legsup           # USBLEGSUP snapshot
    lea 4(%ebp), %eax
    call pci_read
    mov %eax, ehci_legctl           # USBLEGCTLSTS snapshot
    mov $REPLY_SCRATCH, %edi
    mov $logp_leg, %esi             # "usb-leg sup="
    call bputs
    mov ehci_legsup, %eax
    call bhex32
    mov $logp_leg2, %esi            # " ctl="
    call bputs
    mov ehci_legctl, %eax
    call bhex32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit
    pop %ebp
    pop %esi
    pop %edx
    pop %ecx
    pop %ebx
    ret

# ehci_start: reset, point async list at our QH, route ports to EHCI, run.
ehci_start:
    pushal
    mov ehci_op, %edi
    mov (%edi), %eax
    and $0xfffffffe, %eax        # clear RS
    mov %eax, (%edi)
    mov $0x100000, %ecx
es_halt:
    mov 4(%edi), %eax
    test $0x1000, %eax           # HCHalted
    jnz es_rst
    dec %ecx
    jnz es_halt
es_rst:
    mov (%edi), %eax
    or $0x02, %eax               # HCRESET
    mov %eax, (%edi)
    mov $0x1000000, %ecx
es_rw:
    mov (%edi), %eax
    test $0x02, %eax
    jz es_cfg
    dec %ecx
    jnz es_rw
es_cfg:
    movl $0, 0x10(%edi)          # CTRLDSSEGMENT
    movl $EHCI_QH+2, EHCI_QH+0   # init an EMPTY valid async QH first, so the
    movl $0x0040e000, EHCI_QH+4  #   controller traverses a sane ring (else it
    movl $0x40000000, EHCI_QH+8  #   follows garbage -> Host System Error -> halt)
    movl $0, EHCI_QH+0x0c
    movl $1, EHCI_QH+0x10        # next qTD = T (terminate, empty)
    movl $1, EHCI_QH+0x14
    movl $0, EHCI_QH+0x18        # overlay token = not active
    movl $EHCI_QH, 0x18(%edi)    # ASYNCLISTADDR
    mov (%edi), %eax
    or $0x21, %eax               # ASE (bit5) | RS (bit0)
    mov %eax, (%edi)
    movl $1, 0x40(%edi)          # CONFIGFLAG.CF -> route ports to EHCI
    popal
    ret

# ehci_port_reset: reset ehci_port so the device enables.
ehci_port_reset:
    pushal
    mov ehci_op, %edi
    mov ehci_port, %eax
    shl $2, %eax
    add $0x44, %eax
    add %eax, %edi
    mov $0x4000000, %ecx         # after CF=1 the port re-detects the device:
prc_w:                           #   wait for connect (CCS) before resetting
    mov (%edi), %eax
    test $0x01, %eax
    jnz prc_ok
    dec %ecx
    jnz prc_w
prc_ok:
    mov (%edi), %eax
    and $0xff01fff5, %eax        # drop change bits + PED
    or $0x100, %eax              # PortReset
    mov %eax, (%edi)
    mov $0x4000000, %ecx
pr_hold:
    dec %ecx
    jnz pr_hold
    mov (%edi), %eax
    and $0xff01fef5, %eax        # clear PortReset
    mov %eax, (%edi)
    mov $0x1000000, %ecx
pr_w:
    mov (%edi), %eax
    test $0x100, %eax
    jz pr_done
    dec %ecx
    jnz pr_w
pr_done:
    popal
    ret

# ehci_ctrl: SETUP at EHCI_SETUP; EAX=data length (0=none); ECX=1 IN /0 OUT.
#   Data via EHCI_BUF. CF=1 on error.
ehci_ctrl:
    pushal
    mov %eax, ehci_dlen
    mov %ecx, ehci_din
    mov $EHCI_QTD0, %edi          # SETUP qTD
    movl $EHCI_QTD1, (%edi)
    cmpl $0, ehci_dlen
    jne sq_n
    movl $EHCI_QTD2, (%edi)
sq_n:
    movl $1, 4(%edi)
    movl $0x00080e80, 8(%edi)    # active|PID=SETUP(2)|CERR3|8 bytes|tog0
    movl $EHCI_SETUP, 0x0c(%edi)
    movl $0, 0x10(%edi)
    cmpl $0, ehci_dlen
    je dq_skip
    mov $EHCI_QTD1, %edi          # DATA qTD
    movl $EHCI_QTD2, (%edi)
    movl $1, 4(%edi)
    mov ehci_dlen, %eax
    shl $16, %eax
    or $0x80000c80, %eax         # active|CERR3|toggle1|len
    cmpl $0, ehci_din
    jne dq_in
    and $0xfffffcff, %eax        # PID OUT
    jmp dq_tok
dq_in:
    or $0x00000100, %eax         # PID IN
dq_tok:
    mov %eax, 8(%edi)
    movl $EHCI_BUF, 0x0c(%edi)
    movl $0, 0x10(%edi)
dq_skip:
    mov $EHCI_QTD2, %edi          # STATUS qTD
    movl $1, (%edi)
    movl $1, 4(%edi)
    mov $0x80008c80, %eax        # active|IOC|CERR3|toggle1|len0
    cmpl $0, ehci_dlen
    je st_in
    cmpl $0, ehci_din
    jne st_out
st_in:
    or $0x00000100, %eax         # PID IN
    jmp st_tok
st_out:
st_tok:
    mov %eax, 8(%edi)
    movl $0, 0x0c(%edi)
    mov $EHCI_QH, %edi            # QH
    movl $EHCI_QH+2, (%edi)       # horizontal link -> self | QH type
    mov ehci_qhchar, %eax
    mov %eax, 4(%edi)
    mov ehci_qhcaps, %eax        # caps: Mult + (for split) hub addr + port
    mov %eax, 8(%edi)
    movl $0, 0x0c(%edi)
    movl $EHCI_QTD0, 0x10(%edi)
    movl $1, 0x14(%edi)
    movl $0, 0x18(%edi)
    mov $0x4000000, %ecx
ec_poll:
    mov EHCI_QTD2+8, %eax
    test $0x80, %eax             # Active?
    jz ec_chk
    dec %ecx
    jnz ec_poll
    jmp ec_err
ec_chk:
    test $0x7c, %eax             # error bits?
    jnz ec_err
    popal
    clc
    ret
ec_err:
    popal
    stc
    ret

# --- ehcitest: bring up the first EHCI device, set address 1, read the device
#   descriptor, report idVendor:idProduct + class. Proof the core works.
do_ehcitest:
    movl $0x40000000, ehci_qhcaps   # default: no split transactions
    movl $0, ehci_skip
    movl $0, ehci_dport
    mov arg_ptr, %esi
    call skip_spaces
    call parse_dec
    jc et_go
    movzwl %ax, %eax
    mov %eax, ehci_skip
    call skip_spaces                # optional 2nd arg: downstream hub port
    call parse_dec
    jc et_go
    movzwl %ax, %eax
    mov %eax, ehci_dport
et_go:
    call ehci_run
    jmp shell

# ehci_run: the callable enumeration core (uses ehci_skip / ehci_dport). Called
#   by do_ehcitest AND by the remote EHCITEST trigger; rets instead of jmp shell.
ehci_run:
    movl $0x40000000, ehci_qhcaps
    call ehci_find_dev
    jc eht_none
    call ehci_takeover
    call ehci_start
    call ehci_port_reset
    movl $0x0040e000, ehci_qhchar  # addr0|EPS2|maxpkt64|DTC|H
    mov $EHCI_SETUP, %edi           # SET_ADDRESS(1)
    movl $0x00010500, (%edi)
    movl $0, 4(%edi)
    xor %eax, %eax
    xor %ecx, %ecx
    call ehci_ctrl
    call ehci_diag                  # always dump state to dmesg (blind debug)
    jc eht_err
    orl $1, ehci_qhchar             # QH now talks to address 1
    mov $EHCI_SETUP, %edi           # GET_DESCRIPTOR(device, 18)
    movl $0x01000680, (%edi)
    movl $0x00120000, 4(%edi)
    mov $18, %eax
    mov $1, %ecx
    call ehci_ctrl
    jc eht_err
    # The hub device line goes to dmesg + UDP only (no on-screen spam: USB bring-up
    #   happens silently in the background, the console stays clean).
    mov $REPLY_SCRATCH, %edi         # log to dmesg (read on the test PC over wire)
    mov $logp_ehd, %esi             # "ehci-dev: "
    call bputs
    movzwl EHCI_BUF+8, %eax
    call bhex16
    mov $logp_colon, %esi
    call bputs
    movzwl EHCI_BUF+10, %eax
    call bhex16
    mov $logp_ehcl, %esi            # " class "
    call bputs
    movzbl EHCI_BUF+4, %eax
    call bhex8
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    # is it a hub (class 09)? then enumerate its downstream ports.
    cmpb $0x09, EHCI_BUF+4
    jne eht_shell
    movl $0x00010900, EHCI_SETUP    # SET_CONFIGURATION(1)
    movl $0, EHCI_SETUP+4
    xor %eax, %eax
    xor %ecx, %ecx
    call ehci_ctrl
    jc eht_shell
    movl $0x290006a0, EHCI_SETUP    # GET hub descriptor (class, 8 bytes)
    movl $0x00080000, EHCI_SETUP+4
    mov $8, %eax
    mov $1, %ecx
    call ehci_ctrl
    jc eht_shell
    movzbl EHCI_BUF+2, %eax         # bNbrPorts
    mov %eax, ehci_hubports
    mov $REPLY_SCRATCH, %edi
    mov $logp_hub, %esi             # "usb-hub: ports="
    call bputs
    mov ehci_hubports, %eax
    call bdec32
    mov $logp_hub_c, %esi           # " conn="
    call bputs
    movl $0, ehci_connmask          # bitmap of connected downstream ports
    mov $1, %ebp                    # downstream ports are 1..nPorts
ehub_pl:
    cmp ehci_hubports, %ebp
    ja ehub_pd
    movl $0x00080323, EHCI_SETUP    # SET_FEATURE(PORT_POWER=8) on this port
    mov %ebp, EHCI_SETUP+4
    push %edi
    xor %eax, %eax
    xor %ecx, %ecx
    call ehci_ctrl
    pop %edi
    mov $0x4000000, %ecx           # ~100 ms power-settle delay
ehub_dly:
    dec %ecx
    jnz ehub_dly
    movl $0x000000a3, EHCI_SETUP    # GET_STATUS of the port (class, 4 bytes)
    mov %ebp, %eax
    or $0x00040000, %eax           # wLength = 4 in the high word
    mov %eax, EHCI_SETUP+4
    push %edi
    mov $4, %eax
    mov $1, %ecx
    call ehci_ctrl
    pop %edi
    movzbl EHCI_BUF, %eax          # port status byte0, bit0 = connect
    test $1, %eax
    jz ehub_p0
    bts %ebp, ehci_connmask        # remember this port has a device
    movb $0x31, %al
    stosb
    jmp ehub_pn
ehub_p0:
    movb $0x30, %al
    stosb
ehub_pn:
    inc %ebp
    jmp ehub_pl
ehub_pd:
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    # Enumerate the HID behind a downstream port via SPLIT transactions. An
    #   explicit ehci_dport (the trigger) does just that port; ehci_dport==0 (boot
    #   auto-scan) sweeps every connected port for a boot-protocol mouse. Splits
    #   downstream devices get unique addresses 2,3,... (RMH is 1) on this bus.
    call ehci_periodic_init          # build the (empty) periodic schedule first
    movb $2, ehci_nextaddr           # first downstream device -> address 2
    cmpl $0, ehci_dport
    je ehauto
    call ehci_try_dport             # explicit port from the trigger
    cmpb $0, ehci_epaddr
    je eht_shell
    cmpb $1, ehci_hidproto          # keyboard vs mouse
    je eht_setkbd
    call ehci_hid_setup
    jmp eht_shell
eht_setkbd:
    call ehci_kbd_setup
    jmp eht_shell
ehauto:
    mov $1, %ebp                    # scan connected ports for a mouse (proto 2)
escan:
    cmp ehci_hubports, %ebp
    ja eht_shell
    bt %ebp, ehci_connmask          # only probe ports that reported a device
    jnc escan_next
    mov %ebp, ehci_dport
    push %ebp
    call ehci_try_dport
    pop %ebp
    pushal                           # diag: what did this port yield?
    mov $REPLY_SCRATCH, %edi
    mov $logp_scan, %esi             # "usb-scan: skip="
    call bputs
    mov ehci_skip, %eax
    call bhex8
    mov $logp_scan_p, %esi           # " port="
    call bputs
    mov %ebp, %eax
    call bhex8
    mov $logp_scan_e, %esi           # " ep="
    call bputs
    movzbl ehci_epaddr, %eax
    call bhex8
    mov $logp_proto, %esi            # " proto="
    call bputs
    movzbl ehci_hidproto, %eax
    call bhex8
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit
    popal
    cmpb $0, ehci_epaddr
    je escan_next                   # nothing enumerable here
    cmpb $2, ehci_hidproto          # mouse -> arm the mouse QH
    jne escan_kbd
    call ehci_hid_setup
    jmp escan_next
escan_kbd:
    cmpb $1, ehci_hidproto          # keyboard -> arm the keyboard QH
    jne escan_next
    call ehci_kbd_setup
escan_next:                         # keep scanning so BOTH mouse and keyboard
    inc %ebp                        #   are found, whatever ports they sit on
    jmp escan
eht_shell:
    ret

# ehci_try_dport: reset hub port ehci_dport, give the device address 2, read its
#   descriptors, find the interrupt-IN endpoint, set boot protocol. On success
#   ehci_epaddr/ehci_hidproto/ehci_epmps are valid; on any failure ehci_epaddr=0.
ehci_try_dport:
    movl $0x0040e001, ehci_qhchar   # restore the HUB control QH (addr1|EPS=high|
    movl $0x40000000, ehci_qhcaps   #   maxpkt64|DTC|H, no split) - a prior port's
                                    #   device enum left this pointing at addr2+split,
                                    #   so the hub requests below would hit the wrong
                                    #   device and the 2nd port in a scan failed
    mov ehci_nextaddr, %al          # give THIS device a UNIQUE bus address - two
    mov %al, ehci_devaddr           #   devices sharing address 2 wedge each other
    incb ehci_nextaddr
    movl $0x00080323, EHCI_SETUP    # SET_FEATURE(PORT_POWER=8): re-power the port
    mov ehci_dport, %eax            #   first - enumerating an earlier port can leave
    mov %eax, EHCI_SETUP+4          #   THIS one unpowered (pstat=0001 -> ep=00), so
    xor %eax, %eax                  #   the second device in a multi-port scan failed
    xor %ecx, %ecx
    call ehci_ctrl
    mov $0x4000000, %ecx            # ~100 ms power settle
etd_pwr:
    dec %ecx
    jnz etd_pwr
    movl $0x00040323, EHCI_SETUP    # SET_FEATURE(PORT_RESET=4) on the hub port
    mov ehci_dport, %eax
    mov %eax, EHCI_SETUP+4
    xor %eax, %eax
    xor %ecx, %ecx
    call ehci_ctrl
    mov $0x4000000, %ecx            # ~50 ms reset
edr_dly:
    dec %ecx
    jnz edr_dly
    movl $0x000000a3, EHCI_SETUP    # GET_STATUS -> speed bits
    mov ehci_dport, %eax
    or $0x00040000, %eax
    mov %eax, EHCI_SETUP+4
    mov $4, %eax
    mov $1, %ecx
    call ehci_ctrl
    movzwl EHCI_BUF, %ebx           # wPortStatus
    push %ebx                       # broadcast the port status BEFORE the risky
    mov $REPLY_SCRATCH, %edi        #   split phase (so we see speed even on a hang)
    mov $logp_dn, %esi              # "ehci-dn: pstat="
    call bputs
    mov %ebx, %eax
    call bhex32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit
    pop %ebx
    mov ehci_dport, %eax            # split QH caps: Mult|hubaddr1<<16|port<<23
    shl $23, %eax
    or $0x40010000, %eax
    mov %eax, ehci_qhcaps
    movl $0, ehci_eps               # remember the device speed for the interrupt QH
    mov $0x0808c000, %eax           # H|DTC|maxpkt8|C(control), EPS=full
    test $0x0200, %ebx              # low-speed (bit9)?
    jz edr_eps
    or $0x1000, %eax                # EPS=1 (low speed)
    movl $0x1000, ehci_eps
edr_eps:
    mov %eax, ehci_qhchar
    movzbl ehci_devaddr, %eax       # SET_ADDRESS(devaddr)
    shl $16, %eax
    or $0x00000500, %eax
    mov %eax, EHCI_SETUP
    movl $0, EHCI_SETUP+4
    xor %eax, %eax
    xor %ecx, %ecx
    call ehci_ctrl
    call ehci_diag
    jc etd_fail
    movzbl ehci_devaddr, %eax        # the QH now talks to this device's address
    or %eax, ehci_qhchar
    movl $0x01000680, EHCI_SETUP    # GET_DESCRIPTOR(device, 18)
    movl $0x00120000, EHCI_SETUP+4
    mov $18, %eax
    mov $1, %ecx
    call ehci_ctrl
    jc etd_fail
    mov $REPLY_SCRATCH, %edi
    mov $logp_hid, %esi             # "usb-hid: "
    call bputs
    movzwl EHCI_BUF+8, %eax
    call bhex16
    mov $logp_colon, %esi
    call bputs
    movzwl EHCI_BUF+10, %eax
    call bhex16
    mov $logp_ehcl, %esi            # " class "
    call bputs
    movzbl EHCI_BUF+4, %eax
    call bhex8
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit                  # log + broadcast (caught live)
    # --- find the HID interrupt-IN endpoint, configure boot protocol ---
    movl $0x02000680, EHCI_SETUP    # GET_DESCRIPTOR(configuration, 64 bytes)
    movl $0x00400000, EHCI_SETUP+4
    mov $64, %eax
    mov $1, %ecx
    call ehci_ctrl
    jc etd_fail
    movzbl EHCI_BUF+5, %eax         # bConfigurationValue
    mov %al, ehci_cfgval
    movb $0, ehci_epaddr            # walk the descriptors for an interrupt IN EP
    movb $0, ehci_hidproto          # and the HID boot protocol (1 kbd / 2 mouse)
    mov $EHCI_BUF, %esi
    movzwl 2(%esi), %edx            # wTotalLength
    cmp $64, %edx
    jbe ep_lim
    mov $64, %edx
ep_lim:
    add %esi, %edx
ep_walk:
    cmp %edx, %esi
    jae ep_done
    movzbl (%esi), %eax            # bLength
    test %eax, %eax
    jz ep_done
    cmpb $4, 1(%esi)              # INTERFACE descriptor? grab bInterfaceProtocol
    jne ep_chk_ep
    mov 7(%esi), %al             # 1 = keyboard, 2 = mouse (boot subclass)
    mov %al, ehci_hidproto
    jmp ep_next
ep_chk_ep:
    cmpb $5, 1(%esi)              # ENDPOINT descriptor?
    jne ep_next
    movzbl 3(%esi), %ecx          # bmAttributes & 3 == interrupt?
    and $3, %ecx
    cmp $3, %ecx
    jne ep_next
    testb $0x80, 2(%esi)         # bEndpointAddress IN?
    jz ep_next
    mov 2(%esi), %al              # bEndpointAddress
    mov %al, ehci_epaddr
    movzwl 4(%esi), %eax          # wMaxPacketSize
    mov %ax, ehci_epmps
    mov 6(%esi), %al              # bInterval
    mov %al, ehci_epint
    jmp ep_done
ep_next:
    movzbl (%esi), %eax
    add %eax, %esi
    jmp ep_walk
ep_done:
    movzbl ehci_cfgval, %eax       # SET_CONFIGURATION(cfgval)
    shl $16, %eax
    or $0x00000900, %eax
    mov %eax, EHCI_SETUP
    movl $0, EHCI_SETUP+4
    xor %eax, %eax
    xor %ecx, %ecx
    call ehci_ctrl
    movl $0, EHCI_BUF               # GET_CONFIGURATION -> did SET_CONFIG take?
    movl $0x00000880, EHCI_SETUP    # bmRT=0x80,bReq=8(GET_CONFIG)
    movl $0x00010000, EHCI_SETUP+4  # wLength=1
    mov $1, %eax
    mov $1, %ecx
    call ehci_ctrl
    movzbl EHCI_BUF, %eax
    mov %al, ehci_curcfg
    movl $0x00000b21, EHCI_SETUP    # SET_PROTOCOL(boot=0): HID class request
    movl $0, EHCI_SETUP+4
    xor %eax, %eax
    xor %ecx, %ecx
    call ehci_ctrl
    # (a SET_IDLE(0) control transfer was here as a speculative keyboard
    #  fix. Never HW-tested and a likely cause of the mouse regression - some
    #  devices STALL SET_IDLE and could wedge the control endpoint. Reverted to
    #  the known-good enumeration; the keyboard echo needs a fresh approach.)
    mov $REPLY_SCRATCH, %edi        # broadcast the endpoint we will poll
    mov $logp_ep, %esi             # "usb-ep: ep="
    call bputs
    movzbl ehci_epaddr, %eax
    call bhex8
    mov $logp_ep_m, %esi           # " mps="
    call bputs
    movzwl ehci_epmps, %eax
    call bdec32
    mov $logp_ep_i, %esi           # " int="
    call bputs
    movzbl ehci_epint, %eax
    call bdec32
    mov $logp_ep_c, %esi           # " cfg=" (current config; 0 = SET_CONFIG failed)
    call bputs
    movzbl ehci_curcfg, %eax
    call bhex8
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit                  # usb-ep broadcast: enumeration succeeded
    ret
etd_fail:
    movb $0, ehci_epaddr            # enumeration failed: no endpoint to poll
    ret

# EHCI interrupt-IN via the periodic schedule (split transactions). DTC=0
#   (the qTD carries the toggle); overlays are armed active directly.
.equ EHCI_INTQH,    0x310140
.equ EHCI_INTQTD,   0x310180
.equ EHCI_FRAMELIST,0x312000
# ehci_hid_setup: build the interrupt QH for the just-enumerated HID, put it in
#   the periodic schedule, arm it active, and flag it live. Returns immediately;
#   ehci_hid_poll (idle loop) drains completions from here on.
# ehci_periodic_init: build the periodic schedule once per bring-up. The frame
#   list points at the mouse QH (EHCI_INTQH), which links to the keyboard QH
#   (EHCI_INTQH2), which ends the chain. Both QHs start as valid-but-idle
#   placeholders (addr 0, overlay inactive); ehci_hid_setup / ehci_kbd_setup fill
#   and arm them as devices are enumerated. Enables PSE.
ehci_periodic_init:
    movb $0, ehci_hid_active
    movb $0, ehci_kbd_active
    mov $EHCI_INTQH, %edi            # mouse QH placeholder -> links to kbd QH
    movl $EHCI_INTQH2+2, (%edi)
    movl $0, 4(%edi)
    movl $0, 8(%edi)
    movl $0, 0x0c(%edi)
    movl $1, 0x10(%edi)
    movl $1, 0x14(%edi)
    movl $0, 0x18(%edi)
    mov $EHCI_INTQH2, %edi           # keyboard QH placeholder -> end of chain (T)
    movl $1, (%edi)
    movl $0, 4(%edi)
    movl $0, 8(%edi)
    movl $0, 0x0c(%edi)
    movl $1, 0x10(%edi)
    movl $1, 0x14(%edi)
    movl $0, 0x18(%edi)
    mov $EHCI_FRAMELIST, %edi        # every frame-list entry -> the mouse QH
    mov $EHCI_INTQH+2, %eax
    mov $1024, %ecx
epi_fl:
    mov %eax, (%edi)
    add $4, %edi
    dec %ecx
    jnz epi_fl
    mov ehci_op, %edi
    movl $EHCI_FRAMELIST, 0x14(%edi) # PERIODICLISTBASE
    mov (%edi), %eax
    or $0x10, %eax                  # PSE
    mov %eax, (%edi)
    ret

# ehci_hid_setup: fill + arm the mouse QH (EHCI_INTQH) from the just-enumerated
#   device, keeping the chain to the keyboard QH.
ehci_hid_setup:
    cmpb $0, ehci_epaddr
    je ehs_ret
    mov $EHCI_INTQH, %edi
    movl $EHCI_INTQH2+2, (%edi)      # horizontal link -> keyboard QH
    call ehci_qh_fill               # char + split caps from the globals
    movzwl ehci_epmps, %eax
    mov %eax, ehci_mps_m
    movb $0, ehci_tog_m
    mov $EHCI_INTQH, %edi
    mov $EHCI_BUF, %esi
    mov ehci_mps_m, %ecx
    xor %edx, %edx
    call arm_qh
    movb $1, ehci_hid_active        # idle loop may poll the mouse QH
    movb $1, mouse_present          # busy-poll (no hlt) for a smooth cursor
ehs_ret:
    ret

# ehci_kbd_setup: fill + arm the keyboard QH (EHCI_INTQH2) from the device.
ehci_kbd_setup:
    cmpb $0, ehci_epaddr
    je eks_ret
    mov $EHCI_INTQH2, %edi
    movl $1, (%edi)                 # end of the chain
    call ehci_qh_fill
    movzwl ehci_epmps, %eax
    mov %eax, ehci_mps_k
    movb $0, ehci_tog_k
    mov $EHCI_INTQH2, %edi
    mov $EHCI_BUF2, %esi
    mov ehci_mps_k, %ecx
    xor %edx, %edx
    call arm_qh
    movb $1, ehci_kbd_active
    movl $EHCI_INTQH2+2, EHCI_INTQH  # make sure the mouse QH chains to us
    movb $1, mouse_present           # busy-poll so the keyboard QH is drained fast
.ifdef REMOTE_CTL
    movl $200, ehci_kbd_diag         # diag: broadcast the first 200 keyboard reports
.else
    movl $0, ehci_kbd_diag           # default build: no diagnostic broadcasts
.endif
    mov ticks, %eax
    add $18, %eax
    mov %eax, ehci_kbd_hbnext        # heartbeat once per second while NAKing
    mov $REPLY_SCRATCH, %edi         # confirm the keyboard QH is armed
    mov $logp_kbdep, %esi            # "usb-kbd-ep: ep="
    call bputs
    movzbl ehci_epaddr, %eax
    call bhex8
    mov $logp_ep_m, %esi             # " mps="
    call bputs
    movzwl ehci_epmps, %eax
    call bdec32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit
eks_ret:
    ret

# ehci_qh_fill: write the endpoint characteristics (offset 4) and split caps
#   (offset 8) of the QH at EDI from the just-enumerated device globals (DTC=0).
ehci_qh_fill:
    movzbl ehci_epaddr, %eax        # char: devaddr | EP<<8 | EPS | mps<<16
    and $0x0f, %eax
    shl $8, %eax
    or ehci_eps, %eax               # EPS per device speed (low 0x1000 / full 0)
    movzbl ehci_devaddr, %ecx
    or %ecx, %eax
    movzwl ehci_epmps, %ecx
    shl $16, %ecx
    or %ecx, %eax
    mov %eax, 4(%edi)
    mov ehci_dport, %eax            # caps: Mult1|hubaddr1|port<<23|smask01|cmaskFC
    shl $23, %eax
    or $0x4001fc01, %eax
    mov %eax, 8(%edi)
    movl $0, 0x0c(%edi)
    ret

# arm_qh: EDI = QH base, ESI = report buffer, ECX = maxpkt, DL = toggle (0/1).
#   Arms the QH overlay active for an interrupt-IN of ECX bytes.
arm_qh:
    movl $0, (%esi)
    movl $1, 0x10(%edi)             # overlay next qTD = T
    movl $1, 0x14(%edi)             # overlay alt = T
    mov %ecx, %eax
    shl $16, %eax
    or $0x00008d80, %eax            # active|IN|CERR3|IOC|len
    test %dl, %dl
    jz aq0
    or $0x80000000, %eax            # toggle 1
aq0:
    mov %eax, 0x18(%edi)            # overlay token
    mov %esi, 0x1c(%edi)            # overlay buffer
    ret

# ehci_hid_poll: drain BOTH interrupt QHs (mouse + keyboard), non-blocking. Called
#   from the idle loop. NAK at rest leaves a qTD active -> skip it. On a
#   completion: keep the hardware-advanced toggle, apply the report, re-arm.
#   MUST preserve all registers: the caller is readline's kgetch, which holds the
#   line-buffer write pointer in EDI across the call. arm_qh clobbers EDI, so
#   without this pushal readline writes/checks a garbage EDI and silently drops
#   every echoed key (keys reach the buffer but never appear on screen).
ehci_hid_poll:
    pushal
    cmpb $0, ehci_hid_active
    je ehp_kbd
    mov EHCI_INTQH+0x18, %eax
    test $0x80, %eax                # mouse still NAKing?
    jnz ehp_kbd
    mov EHCI_INTQH+0x18, %eax        # advanced toggle (bit 31)
    shr $31, %eax
    mov %al, ehci_tog_m
    call usb_mouse_report
    mov $EHCI_INTQH, %edi
    mov $EHCI_BUF, %esi
    mov ehci_mps_m, %ecx
    movzbl ehci_tog_m, %edx
    call arm_qh
ehp_kbd:
    cmpb $0, ehci_kbd_active
    je ehp_pret
    mov EHCI_INTQH2+0x18, %eax
    test $0x80, %eax                # keyboard still NAKing?
    jnz ehp_kbhb                    # yes -> heartbeat (diag: is the QH alive/stuck?)
    mov EHCI_INTQH2+0x18, %eax
    shr $31, %eax
    mov %al, ehci_tog_k
    call usb_kbd_report
    mov $EHCI_INTQH2, %edi
    mov $EHCI_BUF2, %esi
    mov ehci_mps_k, %ecx
    movzbl ehci_tog_k, %edx
    call arm_qh
    jmp ehp_pret
ehp_kbhb:                           # keyboard QH still active: once/sec show its token
.ifndef REMOTE_CTL
    jmp ehp_pret                    # default build: no per-second heartbeat broadcast
.endif
    mov ticks, %eax
    cmp ehci_kbd_hbnext, %eax
    jb ehp_pret
    add $18, %eax
    mov %eax, ehci_kbd_hbnext
    pushal
    mov $REPLY_SCRATCH, %edi
    mov $logp_kbhb, %esi            # "usb-kbd-hb: tok="
    call bputs
    mov EHCI_INTQH2+0x18, %eax
    call bhex32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit
    popal
ehp_pret:
    popal
    ret

# ehci_emit: the asciz at REPLY_SCRATCH -> both the dmesg ring AND a UDP
#   broadcast (:4711), so a USB result is caught live even if the EHCI take-over
#   wedges the box a moment later. Drop-in replacement for log_str here.
ehci_emit:
    push %esi
    push %ecx
    mov %esi, %ecx
ee_len:
    cmpb $0, (%ecx)
    je ee_done
    inc %ecx
    jmp ee_len
ee_done:
    sub %esi, %ecx
    test %ecx, %ecx
    jz ee_log
    call net_udp_bcast
ee_log:
    pop %ecx
    pop %esi
    call log_str
    ret

ehci_diag:                          # dump EHCI state to dmesg: PORTSC, USBSTS,
    pushal                          #   and the SETUP/STATUS qTD status tokens
    mov $REPLY_SCRATCH, %edi
    mov $logp_ehdbg, %esi           # "ehci-dbg: port="
    call bputs
    mov ehci_op, %edx
    mov ehci_port, %eax
    shl $2, %eax
    add $0x44, %eax
    add %edx, %eax
    mov (%eax), %eax
    call bhex32
    mov $logp_ehsts, %esi           # " sts="
    call bputs
    mov ehci_op, %edx
    mov 4(%edx), %eax
    call bhex32
    mov $logp_eht0, %esi            # " t0="
    call bputs
    mov EHCI_QTD0+8, %eax
    call bhex32
    mov $logp_eht2, %esi            # " t2="
    call bputs
    mov EHCI_QTD2+8, %eax
    call bhex32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit                  # log + broadcast the diag (caught live)
    popal
    ret
eht_none:
    cmpb $0, ehci_quiet
    jne eht_none_q
    mov $msg_eht_none, %esi
    call puts
eht_none_q:
    ret
eht_err:
    cmpb $0, ehci_quiet
    jne eht_err_q
    mov $msg_eht_err, %esi
    call puts
eht_err_q:
    ret

# usb_init: boot-time HID bring-up. Scan EHCI controller 0 then 1; on each,
#   ehci_run with ehci_dport=0 auto-scans that controller's connected RMH ports
#   for a boot-protocol mouse and arms its interrupt QH. Stops at the first mouse
#   found, so the cursor works no matter which physical port the mouse is in.
usb_init:
    movb $1, ehci_quiet              # a controller without a HID is normal here
    mov $3, %ebx                     # a few gentle passes: low-speed devices behind the
usbi_retry:                          #   RMH need a moment to settle after cold power-on
    movl $0, ehci_skip
usbi_ctrl:
    movl $0, ehci_dport              # 0 = auto-scan this controller's ports
    movb $0, ehci_epaddr
    pushal
    call ehci_run
    popal
    cmpb $0, ehci_hid_active         # did the scan arm a mouse QH?
    jne usbi_done
    incl ehci_skip
    cmpl $2, ehci_skip
    jb usbi_ctrl
    mov $0xC000000, %ecx             # no mouse yet: wait ~150 ms and rescan
usbi_dly:
    dec %ecx
    jnz usbi_dly
    dec %ebx
    jnz usbi_retry
usbi_done:
    movb $0, ehci_quiet
    ret

# --- netwish <text>: broadcast a wish over UDP ---------
#  No disk, no diskon - this is the diskless path. Builds the payload
#  "AGENTOS-WISH: <text>" and broadcasts it to 255.255.255.255:4711,
#  where wishd on the dev box catches it.
do_netwish:
    cmpb $0, net_present
    je nw_none
    mov arg_ptr, %esi
    call skip_spaces
    cmpb $0, (%esi)
    je nw_usage
    mov %esi, %ebx               # EBX = text
    mov $nw_prefix, %esi         # build "AGENTOS-WISH: " + text at NIC_PKT-256
    mov $REPLY_SCRATCH, %edi           # scratch just below the TX buffer
    push %edi
nw_pfx:
    lodsb
    test %al, %al
    jz nw_txt
    stosb
    jmp nw_pfx
nw_txt:
    mov %ebx, %esi
nw_cp:
    lodsb
    test %al, %al
    jz nw_send
    stosb
    jmp nw_cp
nw_send:
    pop %esi                     # ESI = payload start
    mov %esi, nw_pay             # stash payload ptr + length for the retries
    mov %edi, %ecx
    sub %esi, %ecx
    mov %ecx, nw_plen
    movb $0, wish_acked          # clear before the first send
    call net_udp_bcast           # ESI/ECX already point at the payload
    mov $msg_nw_ok, %esi         # "Wish broadcast..." right away (test + UX)
    call puts
    mov $3, %ebp                 # then wait for the dev box's ack, resending
nw_try:                          #   up to 3x (~1.5s each) - no hand-repeating
    mov ticks, %ebx
    add $27, %ebx                # ~1.5s window (18 ticks/s)
nw_wait:
    cmpb $1, wish_acked          # set by net_handle when AGENTOS-WISH-ACK lands
    je nw_acked
    mov ticks, %eax
    cmp %ebx, %eax
    jb nw_wait
    dec %ebp
    jz nw_noack
    mov nw_pay, %esi             # timed out -> resend and wait again
    mov nw_plen, %ecx
    call net_udp_bcast
    jmp nw_try
nw_acked:
    mov $msg_nw_ack, %esi        # "netwish: delivered (ack)"
    call puts
    jmp shell
nw_noack:
    mov $msg_nw_noack, %esi      # "netwish: no ack - is wishd running?"
    call puts
    jmp shell
nw_none:
    mov $msg_net_none, %esi
    call puts
    jmp shell
nw_usage:
    mov $msg_nw_usage, %esi
    call puts
    jmp shell

.ifndef MINIMAL                   # games (snake + invaders) are extras
# Snake and Space Invaders now live in ring-3 C userspace (user/snake.c and
# user/invaders.c, built into user.bin). The kernel 'snake'/'invaders'
# commands just launch the matching userspace program through run_start - the
# exact path 'run snake' / 'run invaders' take. Running them as ring-3 THREADS
# (alongside the shell idle loop) is ALSO what keeps the test PC's USB mouse alive
# during play: the shell's full-speed ehci_hid_poll busy-poll runs
# concurrently, whereas the old in-kernel games monopolised the foreground and
# could only poll once per slow frame, wedging the HID. Freeing the ~1.3 KLOC
# of in-kernel game code is what buys back the budget for the SMP work.
do_snake:
    mov $sa_snake, %esi
    jmp game_launch
do_invaders:
    mov $sa_invaders, %esi
game_launch:
    mov $USER_ARG, %edi          # stage the program name where the C dispatcher reads it
gl_cp:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je gl_go
    inc %esi
    inc %edi
    jmp gl_cp
gl_go:
    call run_start               # load + start the ring-3 program, then back to shell
    test %eax, %eax              # run_start failed (no free slot)? then DON'T grab input -
    jz gl_nostart                #   a stuck fg_prog with no game to clear it wedges the kbd
    movb $1, fg_prog             # the game owns the keyboard until it exits/dies
gl_nostart:
    jmp shell
sa_snake:    .asciz "snake"
sa_invaders: .asciz "invaders"
.endif                            # end games extras

# --- gui: launch the Dark Glass compositor (ring-3, user/gui.c). Unlike a
#   game it does NOT grab the keyboard (no fg_prog) - the shell keeps running
#   underneath and the compositor just renders. compositor_active stops the
#   kernel from drawing the FB so the two never fight over it.
do_gui:
    cmpb $0, compositor_active    # already running? a 2nd instance shares the
    jne dg_done                   #   program's .bss at 0x400000 -> corruption + #PF
    mov $sa_gui, %esi
    mov $USER_ARG, %edi
dg_cp:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je dg_go
    inc %esi
    inc %edi
    jmp dg_cp
dg_go:
    call run_start               # load + start the compositor as a ring-3 thread
    test %eax, %eax
    jz dg_done                   # no free slot -> don't claim the screen
    movb $1, compositor_active
dg_done:
    jmp shell
sa_gui:     .asciz "gui"

# --- fetch / forest: shell aliases for 'run fetch' / 'run forest' (ring-3,
#   user/fetch.c + user/forest.c). fetch prints and exits, so it never grabs
#   the keyboard. forest is a full-screen animation that quits on q/Esc, so
#   it owns the keyboard like a game (fg_prog) - without that the quit key
#   would also land in the shell line. Same launcher shape as do_gamelaunch.
do_fetch:
    mov $sa_fetch, %esi
    jmp df_cp
do_forest:
    mov $sa_forest, %esi
df_cp:
    push %esi                    # remember which one (fg_prog only for forest)
    mov $USER_ARG, %edi
df_cp1:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je df_go
    inc %esi
    inc %edi
    jmp df_cp1
df_go:
    call run_start               # load + start the program, then back to shell
    pop %esi                     # (run_start clobbers ESI)
    test %eax, %eax
    jz df_done                   # no free slot -> do not claim the keyboard
    cmp $sa_forest, %esi
    jne do_wait                  # fetch: block like 'wait' so the prompt follows the card
    movb $1, fg_prog             # forest owns the keyboard until it exits/dies
    cmpb $0, compositor_active   # and the whole framebuffer: borrow the compositor
    jne df_done                  #   gate so the kernel stops mirroring console
    movb $1, compositor_active   #   cells, the panel and the status line over the
    movzbl runprog_slot, %eax    #   animation. fx_release hands it back when
    inc %eax                     #   THIS thread (TID = slot + 1) goes away.
    mov %al, fb_owner
df_done:
    jmp shell
sa_fetch:   .asciz "fetch"
sa_forest:  .asciz "forest"

# fx_release: fg_release for the exit/kill/fault paths, EBX = TID of the
#   thread going away. The compositor gate can be borrowed by exactly one
#   thread (fb_owner: forest or a SYS_KBGRAB program); a real compositor
#   (gui) sets compositor_active without an owner and keeps it.
#   - nobody borrowed (fb_owner 0): plain fg_release (games, gui underneath)
#   - the owner exits: return the gate first, so screen_repaint (desktop +
#     a clean console) actually runs, then fg_release
#   - another thread exits while an owner holds screen + keyboard (e.g. a
#     background 'run' finishing under forest): touch neither - releasing
#     fg_prog / the gate here would let the kernel paint over the owner.
#   Idempotent: the gate is cleared once, fg_release is a no-op on fg_prog 0.
fx_release:
    push %eax
    movzbl fb_owner, %eax
    test %eax, %eax
    jz fxr_go
    cmp %ebx, %eax
    jne fxr_keep
    movb $0, fb_owner
    movb $0, compositor_active
fxr_go:
    pop %eax
    jmp fg_release
fxr_keep:
    pop %eax
    ret

# --- kbd <de|us>: switch the keyboard layout ------------------------
do_kbd:
    mov arg_ptr, %esi
    call skip_spaces
    mov $kb_de_str, %edi
    call starts_with
    jnc kbd_de
    mov $kb_us_str, %edi
    call starts_with
    jnc kbd_us
    mov $msg_kbd_usage, %esi
    call puts
    jmp shell
kbd_de:
    movl $kbmap_de, kbmap_ptr
    movl $kbmap_de_sh, kbmap_sh_ptr
    mov $msg_kbd_de, %esi
    call puts
    jmp shell
kbd_us:
    movl $kbmap, kbmap_ptr
    movl $kbmap_sh, kbmap_sh_ptr
    mov $msg_kbd_us, %esi
    call puts
    jmp shell

do_hello:
    mov $msg_hello, %esi
    call puts
    jmp shell


# --- color <1-f>: change the screen attribute -------------------------
do_color:
    mov arg_ptr, %esi
    call skip_spaces
    movzbl (%esi), %eax
    test %al, %al
    jz color_usage
    cmp $0x30, %al
    jb color_usage
    cmp $0x39, %al
    jbe col_dig
    or $0x20, %al
    cmp $0x61, %al
    jb color_usage
    cmp $0x66, %al
    ja color_usage
    sub $0x57, %al
    jmp col_set
col_dig:
    sub $0x30, %al
    test %al, %al
    jz color_usage
col_set:
    mov %al, cur_attr
    call cls
    mov $msg_color_ok, %esi
    call puts
    jmp shell
color_usage:
    mov $msg_color_usage, %esi
    call puts
    jmp shell

# pit_init: channel 0 to divisor 0 (= 65536) -> 18.2 Hz tick rate.
pit_init:
    push %eax
    mov $0x36, %al               # ch 0, lobyte/hibyte, mode 3
    out %al, $0x43
    xor %al, %al
    out %al, $0x40               # divisor low
    out %al, $0x40               # divisor high
    pop %eax
    ret

rand16:
    mov ticks, %eax
    xor %eax, rnd_seed
    mov rnd_seed, %eax
    imul $25173, %eax, %eax
    add $13849, %eax
    and $0xffff, %eax
    mov %eax, rnd_seed
    ret

do_rnd:
    mov $msg_rnd, %esi
    call puts
    call rand16
    xor %edx, %edx
    mov $100, %ecx
    div %ecx
    mov %edx, %eax
    call print_dec32
    call crlf
    jmp shell

# --- gfx: a graphics demo proving the line/circle primitives. Black canvas,
#     a starburst from the centre + concentric rings, all colour-cycled.
#     Any key returns to the shell.
do_gfx:
    cmpb $0, fb_active            # no framebuffer (pure text boot)? bail
    jne dgx_go
    mov $msg_gfx_notxt, %esi
    call puts
    jmp shell
dgx_go:
    xor %eax, %eax               # full black canvas
    xor %ebx, %ebx
    mov fb_w, %ecx
    mov fb_h, %edx
    xor %esi, %esi
    call gfx_fillrect
    mov fb_w, %eax ; shr $1, %eax ; mov %eax, gdcx
    mov fb_h, %eax ; shr $1, %eax ; mov %eax, gdcy
    xor %ebx, %ebx               # starburst: centre -> points along top & bottom
dgx_sb:
    mov gdcx, %eax ; mov %eax, gln_x0
    mov gdcy, %eax ; mov %eax, gln_y0
    mov %ebx, gln_x1
    mov %ebx, %eax ; shr $5, %eax ; and $7, %eax ; add $9, %eax   # bright colour
    mov vga_pal(,%eax,4), %eax ; mov %eax, gln_col
    movl $0, gln_y1
    call gfx_drawline                # to the top edge
    mov gdcx, %eax ; mov %eax, gln_x0
    mov gdcy, %eax ; mov %eax, gln_y0
    mov %ebx, gln_x1
    mov fb_h, %eax ; dec %eax ; mov %eax, gln_y1
    call gfx_drawline                # to the bottom edge
    add $40, %ebx
    cmp fb_w, %ebx
    jl dgx_sb
    movl $16, %ebx               # concentric rings out from the centre
dgx_ring:
    mov gdcx, %eax ; mov %eax, gcr_cx
    mov gdcy, %eax ; mov %eax, gcr_cy
    mov %ebx, gcr_r
    mov %ebx, %eax ; shr $4, %eax ; and $7, %eax ; add $9, %eax
    mov vga_pal(,%eax,4), %eax ; mov %eax, gln_col
    call gfx_circle
    add $22, %ebx
    cmp gdcy, %ebx
    jl dgx_ring
dgx_wait:
    call kgetch                  # any key -> back to the shell
    call cls
    jmp shell

# --- calc <expr>: integer calculator. + - * / and ( ) with precedence and
#     unary minus. Recursive descent over calc_ptr (the parse cursor); the
#     accumulators ride the stack across the recursive calls. Signed 32-bit.
do_calc:
    mov arg_ptr, %esi
    mov %esi, calc_ptr
    movb $0, calc_err
    call calc_expr               # EAX = result
    push %eax
    call calc_skipws             # anything left over -> syntax error ("2 3")
    mov calc_ptr, %esi
    cmpb $0, (%esi)
    je dca_ok
    movb $1, calc_err
dca_ok:
    cmpb $0, calc_err
    jne dca_err
    mov $msg_calc_eq, %esi       # "= "
    call puts
    pop %eax
    test %eax, %eax
    jns dca_pos
    push %eax                    # negative -> print '-' then the magnitude
    mov $0x2d, %al
    call putc
    pop %eax
    neg %eax
dca_pos:
    call print_dec32
    call crlf
    jmp shell
dca_err:
    pop %eax
    mov $msg_calc_err, %esi
    call puts
    jmp shell

calc_expr:                       # term (('+'|'-') term)*
    call calc_term
cex_l:
    push %eax
    call calc_peekop
    cmp $0x2b, %al               # '+'
    je cex_add
    cmp $0x2d, %al               # '-'
    je cex_sub
    pop %eax
    ret
cex_add:
    incl calc_ptr
    call calc_term
    pop %ebx
    add %ebx, %eax
    jmp cex_l
cex_sub:
    incl calc_ptr
    call calc_term
    pop %ebx
    sub %eax, %ebx
    mov %ebx, %eax
    jmp cex_l

calc_term:                       # factor (('*'|'/') factor)*
    call calc_factor
ctm_l:
    push %eax
    call calc_peekop
    cmp $0x2a, %al               # '*'
    je ctm_mul
    cmp $0x2f, %al               # '/'
    je ctm_div
    cmp $0x25, %al               # '%' modulo
    je ctm_mod
    pop %eax
    ret
ctm_mul:
    incl calc_ptr
    call calc_factor
    pop %ebx
    imul %ebx, %eax
    jmp ctm_l
ctm_div:
    incl calc_ptr
    call calc_factor             # EAX = divisor
    pop %ebx                     # EBX = dividend
    test %eax, %eax
    jz ctm_dz
    mov %eax, %ecx
    mov %ebx, %eax
    cmp $-1, %ecx                # INT_MIN / -1 overflows idiv -> #DE (a distinct
    jne cdiv_ok                  #   fault from divide-by-zero, which the test above
    cmp $0x80000000, %eax        #   missed). The quotient (+2^31) doesn't fit int32;
    je ctm_l                     #   return the wrapped result INT_MIN (already in EAX)
cdiv_ok:
    cdq
    idiv %ecx
    jmp ctm_l
ctm_mod:
    incl calc_ptr
    call calc_factor             # EAX = divisor
    pop %ebx                     # EBX = dividend
    test %eax, %eax
    jz ctm_dz
    mov %eax, %ecx
    mov %ebx, %eax
    cmp $-1, %ecx                # same idiv-overflow guard: INT_MIN % -1 = 0
    jne cmod_ok
    cmp $0x80000000, %eax
    jne cmod_ok
    xor %eax, %eax
    jmp ctm_l
cmod_ok:
    cdq
    idiv %ecx
    mov %edx, %eax               # remainder
    jmp ctm_l
ctm_dz:
    movb $1, calc_err            # divide by zero
    xor %eax, %eax
    jmp ctm_l

calc_factor:                     # number | '(' expr ')' | '-' factor | '+' factor
    call calc_skipws
    mov calc_ptr, %esi
    movb (%esi), %al
    cmp $0x28, %al               # '('
    je cf_paren
    cmp $0x2d, %al               # unary '-'
    je cf_neg
    cmp $0x2b, %al               # unary '+'
    je cf_pos
    jmp calc_number
cf_paren:
    incl calc_ptr
    call calc_expr               # EAX = paren value
    push %eax                    # keep it - the ')' check below clobbers AL
    call calc_skipws
    mov calc_ptr, %esi
    movb (%esi), %al
    cmp $0x29, %al               # ')'
    jne cfp_err
    incl calc_ptr
    pop %eax                     # restore the value
    ret
cfp_err:
    pop %eax
    jmp cf_err
cf_neg:
    incl calc_ptr
    call calc_factor
    neg %eax
    ret
cf_pos:
    incl calc_ptr
    jmp calc_factor
cf_err:
    movb $1, calc_err
    xor %eax, %eax
    ret

calc_number:                     # parse decimal digits at calc_ptr -> EAX
    call calc_skipws
    xor %eax, %eax
    xor %ecx, %ecx               # digit count
    mov calc_ptr, %esi
cn_l:
    movzbl (%esi), %edx
    cmp $0x30, %dl
    jb cn_done
    cmp $0x39, %dl
    ja cn_done
    imul $10, %eax
    sub $0x30, %edx
    add %edx, %eax
    inc %esi
    inc %ecx
    jmp cn_l
cn_done:
    mov %esi, calc_ptr
    test %ecx, %ecx
    jz cf_err                    # no digits where a number was expected
    ret

calc_peekop:                     # skip spaces, AL = current char (0 at end)
    call calc_skipws
    mov calc_ptr, %esi
    movzbl (%esi), %eax
    ret

calc_skipws:
    push %esi
    mov calc_ptr, %esi
csw_l:
    movb (%esi), %al
    cmp $0x20, %al
    jne csw_done
    inc %esi
    jmp csw_l
csw_done:
    mov %esi, calc_ptr
    pop %esi
    ret

# --- beep: 440 Hz for ~1/3 second via the PC speaker ------------------
#   With an HDA controller on the bus the ring-3 engine (user/chime.c, 'run
#   beep') plays it through the codec instead; the speaker stays the fallback.
do_beep:
    mov $0x0403, %ax             # class 04 subclass 03 = HD Audio
    xor %cl, %cl
    call pci_find_class
    jc beep_spk
    mov $cs_rbeep, %esi
    jmp llm_stage                # stage "beep" at USER_ARG, run_start, shell
beep_spk:
    mov $0xb6, %al               # PIT channel 2, mode 3
    out %al, $0x43
    mov $0x0a97, %ax             # 1193182 / 440 Hz
    out %al, $0x42
    mov %ah, %al
    out %al, $0x42
    in $0x61, %al                # speaker on (gate + data)
    or $3, %al
    out %al, $0x61
    mov ticks, %ebx              # wait ~1/3 second (6 ticks)
    add $6, %ebx
bp_wait:
    hlt
    mov ticks, %eax
    cmp %ebx, %eax
    jb bp_wait
    in $0x61, %al                # speaker off
    and $0xfc, %al
    out %al, $0x61
    mov $msg_beep, %esi
    call puts
    jmp shell

# --- play <notes>: PC-speaker melody. Letters a-g are notes (C-major around
#     middle C), anything else is a rest. No args -> a built-in jingle.
#     play_tone: AX = PIT divisor, CL = duration in ticks. Blocking.
play_tone:
    pushal
    push %eax
    mov $0xb6, %al               # PIT ch2, mode 3, lo/hi
    out %al, $0x43
    pop %eax
    out %al, $0x42               # divisor low
    mov %ah, %al
    out %al, $0x42               # divisor high
    in $0x61, %al
    or $3, %al
    out %al, $0x61               # speaker on
    movzbl %cl, %ebx
    add ticks, %ebx
pt_w:
    hlt
    mov ticks, %eax
    cmp %ebx, %eax
    jb pt_w
    in $0x61, %al
    and $0xfc, %al
    out %al, $0x61               # speaker off
    popal
    ret
do_play:
    mov arg_ptr, %esi
    cmpb $0, (%esi)
    jne dp_loop
    mov $play_jingle, %esi       # no notes given -> the built-in tune
dp_loop:
    movzbl (%esi), %eax
    test %al, %al
    je dp_done
    inc %esi
    cmp $0x41, %al               # uppercase -> lowercase
    jb dp_nolc
    cmp $0x5a, %al
    ja dp_nolc
    add $0x20, %al
dp_nolc:
    cmp $0x61, %al               # a-g = a note
    jb dp_rest
    cmp $0x67, %al
    ja dp_rest
    sub $0x61, %al
    movzbl %al, %eax
    movzwl note_div(,%eax,2), %eax
    mov $3, %cl                  # ~165 ms per note
    call play_tone
    jmp dp_gap
dp_rest:
    mov ticks, %ebx
    add $3, %ebx
dp_rw:
    hlt
    mov ticks, %eax
    cmp %ebx, %eax
    jb dp_rw
dp_gap:
    mov ticks, %ebx              # tiny gap so repeated notes are distinct
    inc %ebx
dp_gw:
    hlt
    mov ticks, %eax
    cmp %ebx, %eax
    jb dp_gw
    jmp dp_loop
dp_done:
    jmp shell

.ifndef MINIMAL                   # 2a: AC97 sound (extras - the lean core drops it)
# --- sound: AC97 PCM out (QEMU proving ground) ----------
#   Detect the Intel 82801AA AC97 controller (8086:2415; QEMU needs
#   -audiodev none,id=ad0 -device AC97,audiodev=ad0), bring the codec
#   up, fill 1 s of 440 Hz square wave (48 kHz 16-bit stereo) and run
#   the PCM-out bus master over a 2-entry BDL. Polling only, no ISR.
#   Headless-verifiable: CIV/PICB are printed straight from the bus-
#   master registers mid-play, so the gate asserts the DMA engine really
#   consumed samples without anyone hearing them.
.equ AC97_BDL, 0x104000           # BDL, free 1 MB region (after PEND_BUF)
.equ AC97_PCM, 0x105000           # 192000 B tone buffer (ends 0x133E00 < RAM test)
do_sound:
    xor %ebx, %ebx                # -- PCI scan bus 0 for 8086:2415 --
snd_scan:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp          # EBP = config base of this BDF
    mov %ebp, %eax
    call pci_read
    cmp $0x24158086, %eax         # device 2415, vendor 8086
    je snd_found
    inc %ebx
    cmp $0x100, %ebx              # bus 0, dev 0-31, all funcs
    jb snd_scan
    mov $msg_snd_none, %esi
    call puts
    jmp shell
snd_found:
    lea 4(%ebp), %eax             # PCI command: enable I/O decode + bus master
    call pci_read
    mov %eax, %ecx
    or $5, %ecx
    lea 4(%ebp), %eax
    call pci_write
    lea 0x10(%ebp), %eax          # BAR0 = NAM (mixer, I/O space)
    call pci_read
    and $0xfffc, %eax
    mov %eax, snd_nam
    lea 0x14(%ebp), %eax          # BAR1 = NABM (bus master, I/O space)
    call pci_read
    and $0xfffc, %eax
    mov %eax, snd_nabm
    mov $msg_snd_found, %esi      # "AC97: NAM 0x"
    call puts
    mov snd_nam, %eax
    call phex16
    mov $msg_snd_nabm, %esi       # " NABM 0x"
    call puts
    mov snd_nabm, %eax
    call phex16
    call crlf

    mov snd_nabm, %edx            # GLOB_CNT: release cold reset
    add $0x2c, %edx
    mov $2, %eax
    out %eax, %dx
    mov $0x10000, %ecx            # explicit timeout (pitfalls!)
snd_rdy:
    mov snd_nabm, %edx            # GLOB_STA: primary codec ready?
    add $0x30, %edx
    in %dx, %eax
    test $0x100, %eax
    jnz snd_rdy_ok
    dec %ecx
    jnz snd_rdy
    mov $msg_snd_nordy, %esi
    call puts
    jmp shell
snd_rdy_ok:
    mov snd_nam, %edx             # mixer register reset
    xor %ax, %ax
    out %ax, %dx
    mov snd_nam, %edx             # master volume: 0 dB attenuation
    add $2, %edx
    xor %ax, %ax
    out %ax, %dx
    mov snd_nam, %edx             # PCM-out volume: 0 dB
    add $0x18, %edx
    xor %ax, %ax
    out %ax, %dx

    mov $AC97_PCM, %edi           # -- fill 1 s of 440 Hz square wave --
    mov $48000, %ecx              # frames at 48 kHz
    mov $0x4000, %ax              # amplitude
    mov $54, %ebx                 # half period: 48000/440/2 ~ 54.5 frames
snd_fill:
    mov %ax, (%edi)               # left
    mov %ax, 2(%edi)              # right
    add $4, %edi
    dec %ebx
    jnz snd_f2
    neg %ax                       # square edge
    mov $54, %ebx
snd_f2:
    dec %ecx
    jnz snd_fill

    mov $AC97_BDL, %edi           # -- BDL: 2 entries of half a second each --
    movl $AC97_PCM, (%edi)        # entry 0: ptr
    movl $48000, 4(%edi)          #   48000 SAMPLES (16-bit words) = 0.5 s stereo
    movl $AC97_PCM+96000, 8(%edi) # entry 1: ptr (+48000 samples * 2 B)
    movl $0x4000bb80, 12(%edi)    #   48000 samples + BUP (silence on underrun)

    mov snd_nabm, %edx            # PCM-out channel reset (RR)
    add $0x1b, %edx
    mov $2, %al
    out %al, %dx
    mov $0x10000, %ecx
snd_rr:
    in %dx, %al
    test $2, %al
    jz snd_rr_ok
    dec %ecx
    jnz snd_rr
snd_rr_ok:
    mov snd_nabm, %edx            # BDBAR = BDL physical address
    add $0x10, %edx
    mov $AC97_BDL, %eax
    out %eax, %dx
    mov snd_nabm, %edx            # LVI = 1 (two entries)
    add $0x15, %edx
    mov $1, %al
    out %al, %dx
    mov $msg_snd_play, %esi
    call puts
    mov snd_nabm, %edx            # CR = RPBM: run the bus master
    add $0x1b, %edx
    mov $1, %al
    out %al, %dx

    mov ticks, %ebx               # let it play ~0.5 s, then show progress
    add $9, %ebx
snd_w1:
    hlt
    mov ticks, %eax
    cmp %ebx, %eax
    jb snd_w1
    mov $msg_snd_prog, %esi       # "AC97: progress civ="
    call puts
    mov snd_nabm, %edx
    add $0x14, %edx               # CIV: current BDL index
    in %dx, %al
    movzbl %al, %eax
    call print_dec32
    mov $msg_snd_picb, %esi       # " picb="
    call puts
    mov snd_nabm, %edx
    add $0x18, %edx               # PICB: samples left in the current entry
    in %dx, %ax
    movzwl %ax, %eax
    call print_dec32
    call crlf

    mov ticks, %ebx               # wait for the end (CELV), max ~2 s more
    add $36, %ebx
snd_w2:
    hlt
    mov snd_nabm, %edx
    add $0x16, %edx               # SR: bit1 = current equals last valid
    in %dx, %ax
    test $2, %ax
    jnz snd_done
    mov ticks, %eax
    cmp %ebx, %eax
    jb snd_w2
snd_done:
    mov snd_nabm, %edx            # stop the bus master
    add $0x1b, %edx
    xor %al, %al
    out %al, %dx
    mov $msg_snd_done, %esi       # "AC97: done, sr=0x"
    call puts
    mov snd_nabm, %edx
    add $0x16, %edx
    in %dx, %ax
    movzwl %ax, %eax
    call phex16
    call crlf
    jmp shell
.endif                            # 2a: end AC97 extras

# spk_blip: start a SHORT, NON-BLOCKING PC-speaker tone for game SFX. AX = PIT
#   channel-2 divisor (1193182 / freq_hz). The tone auto-silences ~1 tick later
#   via spk_tick (called from the timer ISR), so a shoot/hit/eat blip never
#   stalls the game frame. The test PC has an audible PC speaker ('beep' works).
spk_blip:
    push %eax
    push %ebx
    movzwl %ax, %ebx             # EBX = divisor (BL lo, BH hi)
    mov $0xb6, %al               # PIT ch2, mode 3, lobyte/hibyte
    out %al, $0x43
    mov %bl, %al
    out %al, $0x42
    mov %bh, %al
    out %al, $0x42
    in $0x61, %al                # speaker on (gate + data)
    or $3, %al
    out %al, $0x61
    mov ticks, %eax
    inc %eax                     # silence on the next tick (~0-55 ms blip)
    mov %eax, spk_off
    pop %ebx
    pop %eax
    ret

# spk_tick: called every timer tick. When a blip's deadline passes, cut the
#   speaker. No-op (one memory compare) while idle.
spk_tick:
    cmpl $0, spk_off
    je spk_t_ret
    push %eax
    mov ticks, %eax
    cmp spk_off, %eax
    jb spk_t_pop
    movl $0, spk_off
    in $0x61, %al                # speaker off (clear gate + data)
    and $0xfc, %al
    out %al, $0x61
spk_t_pop:
    pop %eax
spk_t_ret:
    ret

# --- lines: print 30 numbered lines (scroll test) ---------------------
do_lines:
    xor %ebx, %ebx
dl_loop:
    mov $msg_line, %esi
    call puts
    mov %ebx, %eax
    inc %eax
    call print_dec32
    call crlf
    inc %ebx
    cmp $30, %ebx
    jb dl_loop
    jmp shell

# --- task <type> <args>: put a task into the queue ------------------
do_task:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_type
    jc task_usage
    mov %al, task_type_tmp
    xor %ebx, %ebx
tq_find:
    call task_ptr
    cmpb $0, (%edi)
    je tq_free
    inc %ebx
    cmp $8, %ebx
    jb tq_find
    mov $msg_task_full, %esi
    call puts
    jmp shell
tq_free:
    mov %bl, task_id_tmp
    movb $1, (%edi)
    mov task_type_tmp, %al
    mov %al, 1(%edi)
    movb $0, 2(%edi)
    movb $0xff, 3(%edi)
    movb $0xff, 9(%edi)          # dependency = none by default
    movl $0, 12(%edi)
    mov task_type_tmp, %al
    cmp $0, %al
    je tq_math
    cmp $1, %al
    je tq_scan
    cmp $6, %al
    je tq_gcd
    cmp $7, %al
    je tq_added                  # fault: no args, just trigger #UD in ring 3
    call skip_spaces             # count/prime: <n>  or  @<task> (pipeline)
    cmpb $0x40, (%esi)           # '@' -> take another task's result as input
    je tq_dep
    call parse_dec
    jc tq_argerr
    movl %eax, 4(%edi)           # full 32 bits (count/prime use no b field
    jmp tq_added                 #   at +6) - else 'prime 65537' wraps to 1
tq_dep:
    inc %esi                     # skip '@'
    call parse_dec               # the producer task index
    jc tq_argerr
    cmp $8, %ax
    jae tq_argerr
    mov %al, 9(%edi)             # remember the dependency
    movw $0, 4(%edi)             # input filled in when the producer finishes
    movb $4, 2(%edi)            # status = blocked (sys_claim skips it)
    jmp tq_added
tq_math:
    call skip_spaces
    call parse_dec
    jc tq_argerr
    mov %ax, 4(%edi)
    call skip_spaces
    mov (%esi), %al
    test %al, %al
    jz tq_argerr
    mov %al, 8(%edi)
    inc %esi
    call skip_spaces
    call parse_dec
    jc tq_argerr
    mov %ax, 6(%edi)
    jmp tq_added
tq_scan:
    call skip_spaces
    call parse_hex
    jc tq_argerr
    movl %eax, 4(%edi)           # full 32 bits! (overlaps b field +6,
    jmp tq_added                 # which scan does not use) - otherwise
                                 # b8000 gets truncated to 8000 and never faults
tq_gcd:
    call skip_spaces
    call parse_dec
    jc tq_argerr
    mov %ax, 4(%edi)
    call skip_spaces
    call parse_dec
    jc tq_argerr
    mov %ax, 6(%edi)
    jmp tq_added
tq_argerr:
    movb $0, (%edi)
    mov $msg_task_usage, %esi
    call puts
    jmp shell
tq_added:
    mov $msg_task_added, %esi
    call puts
    movzbl task_id_tmp, %eax
    add $0x30, %al
    call putc
    mov $msg_task_added2, %esi
    call puts
    call draw_status
    jmp shell
task_usage:
    mov $msg_task_usage, %esi
    call puts
    jmp shell

do_tasks:
    call print_tasks
    jmp shell

# --- spawn <type>: start an agent with a capability ----------------
do_spawn:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_type
    jc spawn_usage
    cmp $5, %al                  # 'spawn ask' -> NOT a kernel agent_main
    je do_askd                   #   thread: launch the ring-3 askd daemon
    mov %al, spawn_type
    xor %ebx, %ebx
sp_loop:
    call slot_ptr
    cmpb $0, (%edi)
    je sp_found
    inc %ebx
    cmp $8, %ebx
    jb sp_loop
    mov $msg_full, %esi
    call puts
    jmp shell
sp_found:
    movb $1, (%edi)
    mov spawn_type, %al
    mov %al, 1(%edi)
    movb $0, 2(%edi)
    movb $0xff, 3(%edi)
    movw $0, 4(%edi)
    movb $0, 6(%edi)
    # --- start a real thread: synthetic stack frame that looks
    #     as if the thread had just been interrupted by the timer.
    #     popal+iret in the scheduler then "resume" it.
    lea 1(%ebx), %ecx            # thread ID = slot + 1
    mov %ecx, %eax               # user stack top: USER_STACKS + TID*0x1000
    shl $12, %eax
    add $USER_STACKS, %eax
    mov %eax, %edx               # EDX = ESP for ring 3
    mov %ecx, %eax               # KERNEL stack top: KERN_STACKS + TID*0x1000
    shl $12, %eax                # (the frame lives on the kernel stack -
    add $KERN_STACKS, %eax           #  iret descends from there to ring 3)
    sub $4, %eax
    movl $0x23, (%eax)           # SS  = user data, RPL 3
    sub $4, %eax
    mov %edx, (%eax)             # ESP = user stack
    sub $4, %eax
    movl $0x202, (%eax)          # EFLAGS (IF=1, IOPL=0: no I/O!)
    sub $4, %eax
    movl $0x1b, (%eax)           # CS  = user code, RPL 3 -> RING 3!
    sub $4, %eax
    movl $agent_main, (%eax)     # EIP: this is where it "continues"
    sub $4, %eax
    movl $0, (%eax)              # EAX
    sub $4, %eax
    movl $0, (%eax)              # ECX
    sub $4, %eax
    movl $0, (%eax)              # EDX
    sub $4, %eax
    mov %ebx, (%eax)             # EBX = agent slot for agent_main
    sub $4, %eax
    movl $0, (%eax)              # ESP placeholder (popal ignores it)
    sub $4, %eax
    movl $0, (%eax)              # EBP
    sub $4, %eax
    movl $0, (%eax)              # ESI
    sub $4, %eax
    movl $0, (%eax)              # EDI
    mov %eax, tcb_esp(,%ecx,4)
    movb $0xFF, tcb_running(%ecx) # fresh slot: owned by no core (clear any stale id from
                                  #   a previous tenant, else the run-queue scan skips it)
    movb $1, tcb_state(%ecx)     # LAST: from now on the scheduler sees it
    mov $msg_agent_l, %esi
    call puts
    mov %ebx, %eax
    add $0x30, %al
    call putc
    mov $msg_spawn2, %esi
    call puts
    call name_ptr
    call puts
    mov $msg_spawn_t, %esi
    call puts
    movzbl spawn_type, %eax
    mov type_names(,%eax,4), %esi
    call puts
    mov $msg_spawn3, %esi
    call puts
    call draw_status
    jmp shell
spawn_usage:
    mov $msg_spawn_usage, %esi
    call puts
    jmp shell

# --- run: launch a ring-3 USERSPACE program (ABI v2) ----------------
#   Load the gcc-built C program from the userspace blob (disk LBA 300,
#   appended to the image by the Makefile) into USER_PROG_BASE and start
#   a ring-3 thread there. The disk is trusted ONLY if it carries the
#   TannX OS medium marker (LBA 256) - never execute a foreign disk's
#   sectors. No marker / no disk (e.g. PXE boot) -> fall back to the
#   embedded hand-asm stub. Unlike spawn, run does NOT mark the agent
#   busy and arms no watchdog, so the program runs as long as it likes
#   (stop it with `kill <n>`).
do_run:
    mov arg_ptr, %esi            # copy 'run <arg>' to USER_ARG so the program can
    call skip_spaces             #   pick which app to run (e.g. 'run net')
    mov $USER_ARG, %edi
    mov $240, %ecx               # whole LINEMAX line fits (USER_ARG is a page)
dru_cp:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je dru_go
    inc %esi
    inc %edi
    dec %ecx
    jnz dru_cp
    movb $0, (%edi)
dru_go:
    call run_start               # shell 'run': start the program, back to shell
    jmp shell

# --- llm <prompt> / llmscript <slot> <prompt>  --
#   Same machinery as 'run', but stages "llm <args>" / "llms <args>" at
#   USER_ARG so the C dispatcher routes to llm_main / llmscript_main
#   (user/net.c): plain HTTP to the dev-box proxy (llm-proxy.py :4080),
#   which talks to the LLMs. llmscript writes the answer into an AgentFS
#   slot (SYS_WRITESEC) so 'script <slot>' can execute it.
do_llmscript:
    incl atp_round               # one LLM round-trip (= one autopilot round)
    call capture_mission         # stash the mission text for STATUS
    mov $sa_llms, %esi           # prefix "llms" + ' ' ...
    jmp llm_stage

# capture_mission: arg_ptr = "<slot> autopilot <mission>" for the autopilot.
#   Scan for the keyword "autopilot " and copy what follows into atp_mission
#   (so nh_report can broadcast mis=<text>). No keyword -> clear it. EDX holds
#   the scan position; control chars (CR/LF/NUL) end the copy.
capture_mission:
    pushal
    mov arg_ptr, %esi
cm_scan:
    cmpb $0, (%esi)
    je cm_none
    mov %esi, %edx               # remember this scan position
    mov $atp_kw, %edi
cm_cmp:
    movb (%edi), %bl
    test %bl, %bl
    je cm_hit                    # whole keyword matched -> ESI past it
    movb (%esi), %al
    cmp %al, %bl
    jne cm_next
    inc %esi
    inc %edi
    jmp cm_cmp
cm_next:
    mov %edx, %esi               # restore + advance one char
    inc %esi
    jmp cm_scan
cm_hit:
    mov $atp_mission, %edi
    mov $47, %ecx
cm_copy:
    movb (%esi), %al
    cmp $0x20, %al               # stop at any control char (CR/LF/NUL)
    jb cm_end
    mov %al, (%edi)
    inc %esi
    inc %edi
    loop cm_copy
cm_end:
    movb $0, (%edi)
    popal
    ret
cm_none:
    movb $0, atp_mission
    popal
    ret
atp_kw: .asciz "autopilot "

# --- spawn ask: the LLM agent (typ 5) --------------------------------
#   Launches the ring-3 askd daemon (user/net.c) through run_start,
#   then patches its agent slot from typ 4 (prog) to typ 5 (ask) so
#   sys_claim matches 'task ask <slot>' work. A C program with the full
#   TCP stack on the real agent ABI: it phones the LLM.
do_askd:
    mov $cs_askd, %esi
    mov $USER_ARG, %edi
adk_cp:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je adk_go
    inc %esi
    inc %edi
    jmp adk_cp
adk_go:
    call run_start
    test %eax, %eax              # no free slot -> message already printed
    jz adk_out
    movzbl runprog_slot, %ebx
    lea agents_tbl(,%ebx,8), %edi
    movb $5, 1(%edi)             # typ: ask (run_start stamped 4 = prog)
adk_out:
    jmp shell
cs_askd:   .asciz "askd"
cs_rbeep:  .asciz "beep"
do_hda:
    mov $cs_hda, %esi            # ring-3 HDA driver (user/hda.c)
    jmp llm_stage
do_vgpu:
    mov $cs_vgpu, %esi           # ring-3 virtio-gpu probe (user/vgpu.c)
    jmp llm_stage
do_nvme:
    mov $cs_nvme, %esi           # ring-3 NVMe block driver (user/nvme.c)
    jmp llm_stage
do_httpd:
    mov $cs_httpd, %esi          # ring-3 HTTP server (user/net.c httpd_main)
    jmp llm_stage
do_usb:
    mov $cs_usb, %esi            # ring-3 xHCI/USB driver (user/xhci.c)
    jmp llm_stage
do_vblk:
    mov $cs_vblk, %esi           # ring-3 virtio-blk driver (user/vblk.c)
    jmp llm_stage
.ifdef BOOT_CHIME
llm_stage_only:                  # ESI = program name: stage it bare, run, return
    mov $USER_ARG, %edi
lso_p:
    movb (%esi), %al
    mov %al, (%edi)
    inc %esi
    inc %edi
    test %al, %al
    jne lso_p
    jmp run_start                # run_start rets -> back to the boot sequence
cs_chime:  .asciz "chime"
.endif
do_llm:
    mov $cs_llm, %esi            # prefix "llm" + ' ' ...
llm_stage:
    mov $USER_ARG, %edi
dlm_p:
    movb (%esi), %al
    test %al, %al
    je dlm_sp
    mov %al, (%edi)
    inc %esi
    inc %edi
    jmp dlm_p
dlm_sp:
    movb $0x20, (%edi)
    inc %edi
    mov arg_ptr, %esi            # ... + the prompt (arg_ptr is past the spaces)
    mov $240, %ecx               # whole LINEMAX line fits (http_xfer bounds
                                 #   the POST body at 512 on its own)
dlm_cp:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je dlm_go
    inc %esi
    inc %edi
    dec %ecx
    jnz dlm_cp
    movb $0, (%edi)
dlm_go:
    call run_start
    jmp shell

# 'offload <job>': stage "offload <args>" at USER_ARG via the
#   shared llm_stage path, then launch the ring-3 client (offload_main).
do_offload:
    mov $cs_offload, %esi
    jmp llm_stage

# run_start: the callable core of 'run' - used by the shell command AND
#   by the remote RUN trigger from the idle loop (so the C program can be
#   launched over the wire on the test PC, with no keyboard). Rets instead of
#   jmp shell. Same context as do_ehcitest / the remote EHCITEST path.
run_start:
    mov $256, %eax               # is this a genuine TannX OS medium?
    mov $fs_buf, %edi
    call ata_read
    jc run_checkram              # no ATA disk (PXE) -> try the RAM-staged blob
    mov $marker_str, %esi
    mov $fs_buf, %edi
    mov $14, %ecx
    repe cmpsb
    jne run_checkram             # foreign disk -> never trust its bytes
    mov $USER_PROG_BASE, %edi    # stream the blob: LBA 300 -> 0x400000
    mov $USER_BLOB_LBA, %eax
    mov $USER_BLOB_SECTORS, %ecx
run_load:
    call ata_read                # AX=LBA, EDI=dst; preserves GPRs, CF=error
    jc run_checkram
    add $512, %edi               # ata_read restores EDI, so advance it here
    inc %eax
    loop run_load
    cmpl $0, USER_PROG_BASE      # blob slot empty (no program flashed)? -> check RAM
    jne run_slot
run_checkram:
    # No disk blob. Maybe one is already staged at USER_PROG_BASE - the
    # PXE boot path copies the C program there (pxe_blob_load). Use it
    # before falling back to the embedded stub, so we never overwrite it.
    cmpl $0, USER_PROG_BASE
    jne run_slot
run_embed:
    cld                          # last resort: copy the embedded stub to the base
    mov $user_stub, %esi
    mov $USER_PROG_BASE, %edi
    mov $user_stub_end, %ecx
    sub $user_stub, %ecx
    rep movsb
run_slot:
    xor %ebx, %ebx               # find a free agent/thread slot
run_loop:
    call slot_ptr
    cmpb $0, (%edi)
    je run_found
    inc %ebx
    cmp $8, %ebx
    jb run_loop
    mov $msg_full, %esi
    call puts
    xor %eax, %eax               # no free slot -> return failure (EAX=0)
    ret
run_found:
    movb $1, (%edi)              # used
    mov %bl, runprog_slot        # remember it: 'wait' blocks until this exits
    movb $4, 1(%edi)             # type 4 = "prog"
    movb $0, 2(%edi)             # idle (NOT busy: no watchdog)
    movb $0xff, 3(%edi)
    movw $0, 4(%edi)
    movb $0, 6(%edi)
    mov ticks, %eax              # heartbeat baseline so 'wait' can detect a
    mov %eax, wd_start(,%ebx,4)  #   stuck program (no sys_progress for WAIT_BUDGET)
    # synthetic ring-3 frame (same shape as do_spawn) but EIP = the
    #   userspace base and ESP = the top of the 16 MB user-stack region.
    lea 1(%ebx), %ecx            # thread ID = slot + 1
    mov %ecx, %eax               # kernel stack top: KERN_STACKS + TID*0x1000
    shl $12, %eax
    add $KERN_STACKS, %eax
    sub $4, %eax
    movl $0x23, (%eax)           # SS  = user data, RPL 3
    sub $4, %eax
    mov %ecx, %edx               # ESP = USER_STACK_TOP - TID*0x40000: each program
    shl $18, %edx                #   gets its OWN 256 KB stack. Programs used to all
    neg %edx                     #   share USER_STACK_TOP, so a background program
    add $USER_STACK_TOP, %edx    #   (the compositor) and a foreground game grew the
    mov %edx, (%eax)             #   SAME stack and smashed each other.
    sub $4, %eax
    movl $0x202, (%eax)          # EFLAGS (IF=1, IOPL=0)
    sub $4, %eax
    movl $0x1b, (%eax)           # CS  = user code, RPL 3 -> RING 3!
    sub $4, %eax
    movl $USER_PROG_BASE, (%eax) # EIP = 0x400000
    sub $4, %eax
    movl $0, (%eax)              # EAX
    sub $4, %eax
    movl $0, (%eax)              # ECX
    sub $4, %eax
    movl $0, (%eax)              # EDX
    sub $4, %eax
    movl $0, (%eax)              # EBX
    sub $4, %eax
    movl $0, (%eax)              # ESP placeholder
    sub $4, %eax
    movl $0, (%eax)              # EBP
    sub $4, %eax
    movl $0, (%eax)              # ESI
    sub $4, %eax
    movl $0, (%eax)              # EDI
    mov %eax, tcb_esp(,%ecx,4)
    movl $USER_HEAP_BASE, user_brk   # fresh heap break for this run
    movb $0xFF, tcb_running(%ecx) # fresh slot: owned by no core (clear any stale id from
                                  #   a previous tenant, else the run-queue scan skips it)
    push %ecx
    mov $msg_run_l, %esi         # announce BEFORE the thread can run: printed
    call puts                    #   after, a fast program's first SYS_WRITE could
    pop %ecx                     #   land in the middle of this line on serial
    movb $1, tcb_state(%ecx)     # LAST: now the scheduler sees the thread
    call draw_status
    mov $1, %eax                 # started OK -> return success (EAX=1)
    ret

# user_stub: the fallback ring-3 program, used when no TannX OS disk blob
#   is present (e.g. PXE boot). Assembled into the kernel but EXECUTED at
#   USER_PROG_BASE after do_run copies it there, so any self-reference
#   uses the fixed runtime base (no relocations). Proves the bridge end
#   to end: INT 0x30 SYS_WRITE (visible on COM1) + SYS_EXIT.
user_stub:
    mov $USER_PROG_BASE + (us_msg - user_stub), %ebx
    mov $us_msglen, %ecx
    mov $5, %eax                 # SYS_WRITE
    int $0x30
    xor %ebx, %ebx               # exit code 0
    mov $4, %eax                 # SYS_EXIT
    int $0x30
us_spin:                         # belt-and-braces: never fall off the end
    jmp us_spin
us_msg:
    .ascii "[run] hello from ring3 via INT 0x30\r\n"
    .equ us_msglen, . - us_msg
user_stub_end:

# --- kill <0-7>: terminate an agent ---------------------------------
do_kill:
    mov arg_ptr, %esi
    call skip_spaces
    movzbl (%esi), %eax
    test %al, %al
    jz kill_usage
    sub $0x30, %al
    cmp $8, %al
    jae kill_usage
    movzbl %al, %ebx
    call slot_ptr
    cmpb $0, (%edi)
    je kill_none
    cmpb $1, 2(%edi)             # was it busy?
    jne kill_free
    movzbl 3(%edi), %eax         # put the running task back to 'waiting'
    cmp $0xff, %al
    je kill_free
    push %edi
    mov %eax, %edi
    shl $4, %edi
    add $tasks_tbl, %edi
    movb $0, 2(%edi)
    movb $0xff, 3(%edi)
    pop %edi
kill_free:
    inc %ebx                     # fx_release wants the TID (slot + 1)
    call fx_release              # a killed full-screen program releases
    dec %ebx                     #   input + the FB gate it borrowed, repaints
    movb $0, (%edi)
    movb $0, tcb_state+1(%ebx)   # remove the thread (slot+1) from the scheduler
    mov $msg_agent_l, %esi
    call puts
    mov %ebx, %eax
    add $0x30, %al
    call putc
    mov $msg_kill2, %esi
    call puts
    call draw_status
    jmp shell
kill_usage:
    mov $msg_kill_usage, %esi
    call puts
    jmp shell
kill_none:
    mov $msg_nosuch, %esi
    call puts
    jmp shell

# --- reap: A3 lifecycle hygiene. Free every IDLE agent (busy ones keep
#   working) and clear every finished task (done/ERROR), so the 8 agent
#   and 8 task slots stay clean. Freed slots are reused by spawn/task.
do_reap:
    xor %ebx, %ebx
    xor %ebp, %ebp               # EBP = idle agents reaped
reap_a:
    call slot_ptr
    cmpb $0, (%edi)              # used?
    je reap_an
    cmpb $1, 2(%edi)             # busy? -> leave it working
    je reap_an
    movb $0, (%edi)              # free the idle agent
    movb $0, tcb_state+1(%ebx)   # remove its thread from the scheduler
    inc %ebp
reap_an:
    inc %ebx
    cmp $8, %ebx
    jb reap_a
    xor %ebx, %ebx               # clear finished tasks (done / ERROR)
reap_t:
    call task_ptr
    cmpb $0, (%edi)
    je reap_tn
    movzbl 2(%edi), %eax
    cmp $2, %eax
    je reap_tc
    cmp $3, %eax
    jne reap_tn
reap_tc:
    movb $0, (%edi)
reap_tn:
    inc %ebx
    cmp $8, %ebx
    jb reap_t
    mov %ebp, %eax               # report (save count across the first puts)
    push %eax
    mov $msg_reap, %esi          # "reaped "
    call puts
    pop %eax
    call print_dec32
    mov $msg_reap2, %esi         # " idle agent(s); cleared finished tasks.\r\n"
    call puts
    call draw_status
    jmp shell

# --- agents / ps: agents with type, status and statistics ----------
do_agents:
    call print_agents
    jmp shell

# print_agents: print the agent table (also used by 'top') -----------
print_agents:
    movb $0, anyflag
    xor %ebx, %ebx
ag_loop:
    call slot_ptr
    cmpb $0, (%edi)
    je ag_next
    movb $1, anyflag
    mov $msg_li1, %esi
    call puts
    mov %ebx, %eax
    add $0x30, %al
    call putc
    mov $msg_li2, %esi
    call puts
    call name_ptr
    call puts
    mov $msg_sp_paren, %esi
    call puts
    movzbl 1(%edi), %eax
    mov type_names(,%eax,4), %esi
    call puts
    mov $msg_paren_sp, %esi
    call puts
    movzbl 2(%edi), %eax
    mov astate_names(,%eax,4), %esi
    call puts
    cmpb $1, 2(%edi)             # busy? -> show progress
    jne ag_noprog
    mov $msg_sp, %esi
    call puts
    movzbl 6(%edi), %eax
    call print_dec32
    mov $msg_pct, %esi
    call puts
ag_noprog:
    mov $msg_li4, %esi
    call puts
    movzwl 4(%edi), %eax
    call print_dec32
    call crlf
ag_next:
    inc %ebx
    cmp $8, %ebx
    jb ag_loop
    cmpb $0, anyflag
    jne ag_done
    mov $msg_noagents, %esi
    call puts
ag_done:
    ret

# --- top: live agent view, 1-s cadence via ticks, 'q' quits --------
do_top:
    mov $msg_top_hdr, %esi
    call puts
top_loop:
    mov $msg_top_sep, %esi
    call puts
    call print_agents
    mov ticks, %eax              # deadline: now + 18 ticks (~1 s)
    add $18, %eax
    mov %eax, top_until
top_wait:
    mov kb_tail, %al             # key/byte available? (do not block!)
    cmp kb_head, %al
    je top_zzz
    call kgetch
    cmp $0x71, %al               # 'q' quits
    je top_done
top_zzz:
    hlt                          # sleep until the next interrupt
    mov ticks, %eax
    cmp top_until, %eax
    jb top_wait
    jmp top_loop
top_done:
    jmp shell

# --- tick / run: snapshot of the queue (work runs by itself) --------
do_tick:
    mov $msg_tick, %esi
    call puts
    call print_tasks
    jmp shell

# --- auto: DEPRECATED no-op, kept so old scripts still run - the agents
#   always run in the background (preemptive threads) --------------------
do_auto:
    mov $msg_auto_info, %esi
    call puts
    jmp shell

# =====================================================================
#  AGENT THREAD: every agent is a REAL thread with its own
#  stack - this code runs preemptively, the timer takes the CPU
#  away from it. EBX = agent slot (comes from the synthetic frame
#  built by spawn). Threads NEVER print text themselves - they work
#  quietly on the tables; the shell does the displaying.
# =====================================================================
agent_main:
    mov %ebx, %ebp               # EBP = my slot (only for the record now)
am_idle:
    mov $1, %eax                 # SYS_CLAIM: the kernel searches + claims
    int $0x30
    cmp $8, %eax                 # < 8: task index. Otherwise: nothing there.
    jb am_got
    xor %eax, %eax               # SYS_YIELD: kernel sleeps one tick
    int $0x30                    # (hlt itself would be #GP - we are ring 3!)
    jmp am_idle
am_got:
    mov %eax, %edi               # EDI = my task index
    xor %edx, %edx               # EDX = progress (register only -
    mov ticks, %ecx              #  the tables are READ-ONLY for us)
am_work:
    xor %eax, %eax               # SYS_YIELD: wait one tick
    int $0x30
    mov ticks, %eax              # READING ticks is allowed (U=1, W=0)
    cmp %ecx, %eax
    je am_work
    sub %ecx, %eax
    mov ticks, %ecx
    shl $2, %eax                 # 4 percent per tick
    add %eax, %edx
    cmp $100, %edx
    jb am_pub
    mov $100, %edx
am_pub:
    mov %edx, %ebx               # SYS_PROGRESS: kernel writes the %
    push %eax
    mov $2, %eax
    int $0x30
    pop %eax
    cmp $100, %edx
    jb am_work
    # --- compute: entirely in ring 3, tables READ only ---
    mov %edi, %esi
    shl $4, %esi
    add $tasks_tbl, %esi         # ESI -> my task (read access)
    mov 1(%esi), %al             # type
    cmp $0, %al
    je am_math
    cmp $1, %al
    je am_scan
    cmp $3, %al
    je am_prime
    cmp $6, %al
    je am_gcd
    cmp $7, %al
    je am_fault
    mov 4(%esi), %ecx            # count: sum 1..n (full 32-bit arg)
    xor %ebx, %ebx
am_cs:
    test %ecx, %ecx              # (no jecxz: only 8-bit range,
    jz am_fin                    #  am_fin past am_prime is too far)
    add %ecx, %ebx
    dec %ecx
    jmp am_cs
am_math:
    movzwl 4(%esi), %ebx
    movzwl 6(%esi), %ecx
    mov 8(%esi), %al
    cmp $0x2b, %al
    je am_add
    cmp $0x2d, %al
    je am_sub
    cmp $0x2a, %al
    je am_mul
    cmp $0x2f, %al
    je am_div
    cmp $0x25, %al
    je am_mod                    # '%' modulo
    jmp am_zero
am_add:
    add %ecx, %ebx
    jmp am_fin
am_sub:
    cmp %ecx, %ebx
    jb am_zero
    sub %ecx, %ebx
    jmp am_fin
am_mul:
    mov %ebx, %eax
    mul %ecx
    mov %eax, %ebx
    jmp am_fin
am_div:
    test %ecx, %ecx
    jz am_zero
    mov %ebx, %eax
    xor %edx, %edx
    div %ecx
    mov %eax, %ebx
    jmp am_fin
am_mod:
    test %ecx, %ecx
    jz am_zero
    mov %ebx, %eax
    xor %edx, %edx
    div %ecx
    mov %edx, %ebx               # remainder
    jmp am_fin
am_zero:
    xor %ebx, %ebx
    jmp am_fin
am_scan:
    mov 4(%esi), %edx            # target address (32 bits) - read in RING 3!
    xor %ebx, %ebx               # kernel/device addresses -> #PF ->
    mov $16, %ecx                # the MMU shoots US down, nothing else
am_ss:
    movzbl (%edx), %eax
    add %eax, %ebx
    inc %edx
    loop am_ss
    jmp am_fin
am_prime:                        # n-th prime via trial division
    mov 4(%esi), %ecx            # ECX = how many primes still to go (32-bit)
    xor %ebx, %ebx               # n=0 -> result 0
    test %ecx, %ecx
    jz am_fin
    mov $1, %ebx                 # EBX = candidate
ap_cand:
    inc %ebx
    push %ecx
    mov $2, %ecx                 # ECX = divisor
ap_div:
    xor %edx, %edx
    mov %ebx, %eax
    div %ecx                     # EAX = quotient, EDX = remainder
    cmp %ecx, %eax               # quotient < divisor? Then the divisor
    jb ap_prime                  # is already past sqrt(candidate): prime!
    test %edx, %edx              # (order matters: otherwise 2/2
    jz ap_comp                   #  would rate 2 as composite)
    inc %ecx
    jmp ap_div
ap_comp:
    pop %ecx
    jmp ap_cand
ap_prime:
    pop %ecx
    loop ap_cand                 # not the n-th yet -> keep searching
    jmp am_fin
am_gcd:                          # Euclid over two 16-bit inputs
    movzwl 4(%esi), %ebx
    movzwl 6(%esi), %ecx
am_gcd_loop:
    test %ecx, %ecx
    jz am_fin
    mov %ebx, %eax
    xor %edx, %edx
    div %ecx
    mov %ecx, %ebx
    mov %edx, %ecx
    jmp am_gcd_loop
am_fault:
    ud2                          # diagnostic: prove #UD kills only this agent
am_fin:
    mov $3, %eax                 # SYS_FINISH: EBX = result
    int $0x30
    jmp am_idle

# print_tasks: all tasks with type, input, status and result ---------
print_tasks:
    movb $0, anyflag
    xor %ebx, %ebx
pt_loop:
    call task_ptr
    cmpb $0, (%edi)
    je pt_next
    movb $1, anyflag
    mov $msg_li1, %esi
    call puts
    mov %ebx, %eax
    add $0x30, %al
    call putc
    mov $msg_li2, %esi
    call puts
    movzbl 1(%edi), %eax
    mov type_names(,%eax,4), %esi
    call puts
    mov $msg_sp, %esi
    call puts
    mov 1(%edi), %al
    cmp $0, %al
    je pt_math
    cmp $1, %al
    je pt_scan
    cmp $6, %al
    je pt_gcd
    cmp $7, %al
    je pt_status
    mov $msg_n, %esi
    call puts
    mov 4(%edi), %eax            # count/prime: full 32-bit input arg
    call print_dec32
    jmp pt_status
pt_math:
    movzwl 4(%edi), %eax
    call print_dec32
    mov $msg_sp, %esi
    call puts
    movzbl 8(%edi), %eax
    call putc
    mov $msg_sp, %esi
    call puts
    movzwl 6(%edi), %eax
    call print_dec32
    jmp pt_status
pt_scan:
    mov $msg_at, %esi
    call puts
    mov 4(%edi), %eax
    call phex32
    jmp pt_status
pt_gcd:
    movzwl 4(%edi), %eax
    call print_dec32
    mov $msg_sp, %esi
    call puts
    movzwl 6(%edi), %eax
    call print_dec32
pt_status:
    mov $msg_arrow, %esi
    call puts
    movzbl 2(%edi), %eax
    mov tstate_names(,%eax,4), %esi
    call puts
    cmpb $4, 2(%edi)             # blocked? show the producer it waits on
    jne pt_running
    mov $msg_dep, %esi           # " <-t"
    call puts
    movzbl 9(%edi), %eax
    add $0x30, %al
    call putc
pt_running:
    cmpb $1, 2(%edi)             # running? -> the agent's progress
    jne pt_chkdone
    mov $msg_pp1, %esi
    call puts
    movzbl 3(%edi), %eax
    shl $3, %eax
    movzbl agents_tbl+6(%eax), %eax
    call print_dec32
    mov $msg_pp2, %esi
    call puts
pt_chkdone:
    cmpb $2, 2(%edi)
    jne pt_eol
    mov $msg_res, %esi
    call puts
    mov 12(%edi), %eax
    call print_dec32
pt_eol:
    call crlf
pt_next:
    inc %ebx
    cmp $8, %ebx
    jb pt_loop
    cmpb $0, anyflag
    jne pt_done
    mov $msg_notasks, %esi
    call puts
pt_done:
    ret

# --- time / date: real clock from the RTC/CMOS (BCD) ------------------
do_time:
    call cmos_wait
    mov $msg_time, %esi
    call puts
    mov $0x04, %bl
    call cmos_read
    call print_bcd
    mov $msg_colon, %esi
    call puts
    mov $0x02, %bl
    call cmos_read
    call print_bcd
    mov $msg_colon, %esi
    call puts
    mov $0x00, %bl
    call cmos_read
    call print_bcd
    call crlf
    jmp shell

do_date:
    call cmos_wait
    mov $msg_date, %esi
    call puts
    mov $0x07, %bl
    call cmos_read
    call print_bcd
    mov $msg_dot, %esi
    call puts
    mov $0x08, %bl
    call cmos_read
    call print_bcd
    mov $msg_dot, %esi
    call puts
    mov $msg_20, %esi
    call puts
    mov $0x09, %bl
    call cmos_read
    call print_bcd
    call crlf
    jmp shell

# --- dump <hex>: 128 bytes from address - now full 32-bit addresses! --
do_dump:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_hex               # EAX = address (up to 8 hex digits)
    jc dump_usage
    mov %eax, %ebx
    mov $8, %dl
dump_row:
    mov %ebx, %eax
    call phex32
    mov $msg_colon_sp, %esi
    call puts
    mov $16, %cl
    push %ebx
dump_hex:
    movzbl (%ebx), %eax
    call phex8
    mov $0x20, %al
    call putc
    inc %ebx
    dec %cl
    jnz dump_hex
    mov $msg_bar, %esi
    call puts
    pop %ebx
    mov $16, %cl
dump_asc:
    movzbl (%ebx), %eax
    cmp $0x20, %al
    jb dump_dot
    cmp $0x7e, %al
    ja dump_dot
    jmp dump_pc
dump_dot:
    mov $0x2e, %al
dump_pc:
    call putc
    inc %ebx
    dec %cl
    jnz dump_asc
    mov $msg_bar, %esi
    call puts
    call crlf
    dec %dl
    jnz dump_row
    jmp shell
dump_usage:
    mov $msg_dump_usage, %esi
    call puts
    jmp shell

# --- cpu: CPU core/thread count + TannX OS's scheduling model -----------
do_cpu:
    mov $msg_cpu_lp, %esi         # "CPU logical processors: "
    call puts
    mov $1, %eax
    cpuid                         # EDX bit28 = HTT (then EBX[23:16] = count)
    test $0x10000000, %edx
    jz dcpu_one
    shr $16, %ebx
    and $0xff, %ebx
    test %ebx, %ebx
    jnz dcpu_show
dcpu_one:
    mov $1, %ebx
dcpu_show:
    mov %ebx, %eax
    call print_dec32
    call crlf
    mov $msg_cpu_smp, %esi        # how TannX OS uses them
    call puts
    jmp shell

# lapic_map: map the local APIC MMIO (0xFEE00000) with a 4 MB supervisor page,
#   ALWAYS (even single-core) so any core can read its own APIC ID for the
#   per-core scheduler. The base must be 4 MB-aligned (0xFEC00000 covers it).
lapic_map:
    pushal
    mov %cr4, %eax
    or $0x10, %eax               # PSE
    mov %eax, %cr4
    mov $0x3FB, %ecx             # 0xFEE00000 >> 22
    movl $0xFEC00083, PAGE_DIR(,%ecx,4)
    mov $0x30000, %eax
    mov %eax, %cr3
    popal
    ret

# my_core: EAX = this core's APIC ID (= per-core index 0..7). LAPIC pre-mapped.
my_core:
    mov 0xFEE00020, %eax
    shr $24, %eax
    ret

# spin_lock / spin_unlock: EAX = lock address. The run-queue lock so two cores
#   never grab the same runnable thread. Uncontended on a single core. xchg
#   carries an implicit LOCK.
spin_lock:
    push %ecx
sl_try:
    mov $1, %ecx
    xchg %ecx, (%eax)
    test %ecx, %ecx
    jz sl_got
    pause
    jmp sl_try
sl_got:
    pop %ecx
    ret
spin_unlock:
    movl $0, (%eax)
    ret

# cur_thr: EBX = this core's current thread; preserves EAX. (Code-size saver
#   vs inlining my_core + the indexed load at every scheduler site.)
cur_thr:
    push %eax
    call my_core
    movzbl cur_thread(%eax), %ebx
    pop %eax
    ret

# =====================================================================
#  SMP: wake the other cores. INIT-SIPI-SIPI to each Application Processor;
#  each runs ap_tramp (real mode -> our GDT/paging -> 32-bit ap_entry32),
#  bumps ap_online, does locked work to PROVE parallel execution, then halts.
#  Gated on >=2 cores AND a relocated heap (so 0x50000-0x8FFFF is free for the
#  trampoline + AP stacks). LAPIC at the default 0xFEE00000. A buggy AP only
#  hangs that core - the BSP is never at risk; single-core boots no-op.
# =====================================================================
smp_init:
    pushal
    cmpl $0x50000, heap_base     # heap NOT relocated -> 0x50000 still live, skip
    je smp_ret
    mov $1, %eax
    cpuid
    test $0x10000000, %edx       # HTT? (logical-count field valid)
    jz smp_ret
    shr $16, %ebx
    and $0xff, %ebx              # EBX = logical processor count
    cmp $2, %ebx
    jb smp_ret                   # single core - nothing to wake
    mov %ebx, cpu_count          # (the LAPIC is already mapped by lapic_map)
    mov $0x1B, %ecx              # IA32_APIC_BASE: global LAPIC enable (bit 11)
    rdmsr
    or $0x800, %eax
    wrmsr
    movl $0x1FF, 0xFEE000F0       # SVR: software-enable + spurious vector 0xFF
    mov $0x51000, %edi           # build the AP IDT (256 gates -> ap_isr) @0x51000
    mov $256, %ecx
sib_l:
    movl $ap_isr, %edx
    mov %dx, (%edi)              # offset 15:0
    movw $0x08, 2(%edi)         # selector = kernel code
    movb $0, 4(%edi)
    movb $0x8E, 5(%edi)         # 32-bit interrupt gate, present
    shr $16, %edx
    mov %dx, 6(%edi)            # offset 31:16
    add $8, %edi
    loop sib_l
    movw $2047, ap_idtr          # AP IDTR: limit + base
    movl $0x51000, ap_idtr+2
    # the AP IDT defaults to ap_isr everywhere; override the gates an AP
    # needs to run ring-3 AGENT THREADS - faults, the DPL-3 syscall door, and the
    # LAPIC-timer scheduler tick. (The wake IPI vector 0x40 keeps ap_isr.)
    mov $0x0D, %eax ; mov $gp_handler, %edx  ; mov $0x8E, %cl ; call set_apgate
    mov $0x0E, %eax ; mov $pf_handler, %edx  ; mov $0x8E, %cl ; call set_apgate
    mov $0x30, %eax ; mov $syscall_isr, %edx ; mov $0xEE, %cl ; call set_apgate
    mov $0x41, %eax ; mov $ap_timer_isr,%edx ; mov $0x8E, %cl ; call set_apgate
    mov $ap_tramp, %esi          # stage the trampoline at 0x50000 (SIPI vector 0x50)
    mov $0x50000, %edi
    mov $ap_tramp_end, %ecx
    sub $ap_tramp, %ecx
    rep movsb
    movl $0, ap_online
    mov 0xFEE00020, %eax         # BSP's own APIC ID (don't IPI ourselves)
    shr $24, %eax
    mov %eax, bsp_apic
    xor %ebx, %ebx               # walk APIC IDs 0..count-1
smp_wake:
    cmp cpu_count, %ebx
    jae smp_wait
    mov bsp_apic, %eax
    cmp %eax, %ebx
    je smp_skip
    mov %ebx, %eax               # INIT IPI to this AP
    shl $24, %eax
    mov %eax, 0xFEE00310
    movl $0x00004500, 0xFEE00300
    call smp_delay_long          # ~10 ms
    mov %ebx, %eax               # SIPI (vector 0x50)
    shl $24, %eax
    mov %eax, 0xFEE00310
    movl $0x00004650, 0xFEE00300
    call smp_delay_short
    mov %ebx, %eax               # SIPI again (the standard double-kick)
    shl $24, %eax
    mov %eax, 0xFEE00310
    movl $0x00004650, 0xFEE00300
    call smp_delay_short
smp_skip:
    inc %ebx
    jmp smp_wake
smp_wait:
    call smp_delay_long          # give the APs time to come online + work
    call smp_delay_long
smp_ret:
    popal
    ret
smp_delay_long:
    push %ecx
    mov $0x2000000, %ecx
sdl_l:
    dec %ecx
    jnz sdl_l
    pop %ecx
    ret
smp_delay_short:
    push %ecx
    mov $0x40000, %ecx
sds_l:
    dec %ecx
    jnz sds_l
    pop %ecx
    ret

# set_apgate: install one gate in the AP IDT (at 0x51000). EAX=vector,
#   EDX=handler offset, CL=attr (0x8E ring-0 int gate, 0xEE ring-3). Clobbers EDI.
set_apgate:
    push %edi
    push %edx
    lea 0x51000(,%eax,8), %edi
    mov %dx, (%edi)              # offset 15:0
    movw $0x08, 2(%edi)          # selector = kernel code
    movb $0, 4(%edi)
    mov %cl, 5(%edi)             # type + DPL + present
    shr $16, %edx
    mov %dx, 6(%edi)             # offset 31:16
    pop %edx
    pop %edi
    ret

# AP startup trampoline (copied to physical 0x50000). Real mode -> protected
# mode + paging on the kernel's GDT/CR3 -> 32-bit ap_entry32. Internal refs are
# DS-relative; gdt/PAGE_DIR/ap_entry32 are absolute (survive the copy).
.code16
ap_tramp:
    cli
    xor %ax, %ax
    mov %cs, %ax
    mov %ax, %ds
    lgdtl (ap_tgdtr - ap_tramp)
    mov $0x30000, %eax           # CR3 = kernel page directory
    mov %eax, %cr3
    mov %cr4, %eax
    or $0x10, %eax               # PSE (the PD has 4 MB pages)
    mov %eax, %cr4
    mov %cr0, %eax
    or $0x80000001, %eax         # PG | PE (WP stays 0: ring 0 must still write
                                 #   pages that are read-only for ring 3)
    mov %eax, %cr0
    ljmpl $0x08, $ap_entry32
.align 4
ap_tgdtr:
    .word 103
    .long gdt
ap_tramp_end:
.code32
ap_entry32:
    mov $0x10, %ax               # flat data segments
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov 0xFEE00020, %eax         # our APIC ID -> a private stack in the freed
    shr $24, %eax                #   old-heap region (0x60000 + id*0x8000)
    mov %eax, %ecx
    shl $15, %ecx
    mov $0x60000, %esp
    add %ecx, %esp
    add $0x8000, %esp
    lidt ap_idtr                 # the AP's own IDT (just a wake-IPI handler)
    movl $0x1FF, 0xFEE000F0       # software-enable this core's local APIC
    mov 0xFEE00020, %eax         # load THIS core's TSS (0x28 + id*8) for ring3->0
    shr $24, %eax
    shl $3, %eax
    add $0x28, %eax
    ltr %ax
    lock incl ap_online          # "I'm alive in 32-bit kernel land"
    # per-AP LAPIC timer so this core can PREEMPTIVELY schedule ring-3
    # agent threads (not just the pbench worker pool). Periodic, vector 0x41.
    movl $0x3, 0xFEE003E0         # timer divide config = divide by 16
    movl $0x00020041, 0xFEE00320 # LVT timer: periodic (bit 17) | vector 0x41
    movl $0x800000, 0xFEE00380    # initial/reload count (~tens of Hz on real silicon)
# ap_idle: the AP's idle context (cur_thread = 0xFF: not a TCB thread). Services
# the pbench worker pool (lock-free job slot) with interrupts OFF so a running job
# is never preempted; otherwise sti;hlt - the LAPIC timer (ap_timer_isr) preempts
# the hlt to run any runnable ring-3 agent thread, and routes back here when none.
ap_idle:
    call my_core
    movb $0xFF, cur_thread(%eax)  # (re)assert idle: on entry and every scheduler return
ap_idle_l:
    cli
    mov 0xFEE00020, %eax         # my APIC ID = my pbench slot index
    shr $24, %eax
    mov %eax, %ebx
    cmpl $1, ap_go(,%ebx,4)      # a pbench job for me?
    je ap_dojob
    sti                          # idle: the LAPIC timer / wake IPI fire here
    hlt                          #   (sti;hlt is race-free; a pending int fires after)
    jmp ap_idle_l
ap_dojob:
    mov ap_lo(,%ebx,4), %esi     # count primes in [lo, hi] - cli held, not preempted
    mov ap_hi(,%ebx,4), %edi
    push %ebx
    call count_primes            # ESI=lo, EDI=hi -> EAX = prime count
    pop %ebx
    mov %eax, ap_res(,%ebx,4)
    movl $0, ap_go(,%ebx,4)      # consume the job, then signal done LAST
    movl $1, ap_done(,%ebx,4)
    jmp ap_idle_l
# ap_isr: an AP's only interrupt is the BSP's wake IPI. EOI and return - the
# loop re-checks the job slot. (All 256 AP IDT gates point here.)
ap_isr:
    push %eax
    movl $0, 0xFEE000B0          # LAPIC EOI
    pop %eax
    iret

# ap_timer_isr: an AP's LAPIC-timer tick = its preemptive scheduler. Save the
# running agent's context (unless this core was idle), release it back to the
# run-queue, then pick the next runnable+free AGENT (slots 1..8 only - thread 0,
# the shell, is BSP-pinned). Nothing runnable -> this core's idle context.
ap_timer_isr:
    pushal
    cld
    movl $0, 0xFEE000B0          # LAPIC EOI
    call my_core
    movzbl cur_thread(%eax), %ebx
    cmp $0xFF, %ebx              # was this core idle? then there is nothing to save
    je apt_pick
    mov %esp, tcb_esp(,%ebx,4)   # save the preempted agent's kernel ESP
    cmpb $1, tcb_state(%ebx)     # still runnable? release it so any core may take it
    jne apt_pick
    movb $0xFF, tcb_running(%ebx)
apt_pick:
    mov $sched_lock, %eax
    call spin_lock
    cmp $9, %ebx                 # clamp idle(0xFF)/shell(0) start index to 0
    jb apt_scan
    xor %ebx, %ebx
apt_scan:
    mov $8, %ecx                 # scan the 8 agent slots, round-robin from here
apt_next:
    inc %ebx
    cmp $9, %ebx
    jb apt_chk
    mov $1, %ebx                 # wrap 9 -> 1 (never select thread 0 on an AP)
apt_chk:
    dec %ecx
    js apt_idle                  # scanned them all, nothing for me -> idle
    cmpb $1, tcb_state(%ebx)     # runnable?
    jne apt_next
    cmpb $0xFF, tcb_running(%ebx) # not already running on another core?
    jne apt_next
    push %ebx ; call my_core ; pop %ebx   # CLAIM it under the lock (close the window
    mov %al, tcb_running(%ebx)            #   where another core also picks the same thread)
    mov $sched_lock, %eax        # found one
    call spin_unlock
    jmp thread_resume
apt_idle:
    mov $sched_lock, %eax
    call spin_unlock
    mov $0xFF, %ebx              # the idle marker -> thread_resume routes to ap_idle
    jmp thread_resume

# count_primes: ESI=lo, EDI=hi -> EAX = number of primes in [lo,hi].
# CPU-bound trial division (the parallel benchmark's unit of work). Clobbers
# EAX/EBX/ECX/EDX/ESI/EDI/EBP - callers save what they need.
count_primes:
    xor %ebp, %ebp               # count
cp_loop:
    cmp %edi, %esi
    ja cp_ret
    cmp $2, %esi
    jb cp_skip                   # 0,1 not prime
    je cp_isp                    # 2 is prime
    mov $2, %ebx                 # trial divisor
cp_div:
    mov %ebx, %eax
    imul %eax, %eax              # d*d
    cmp %esi, %eax
    ja cp_isp                    # d*d > n -> n is prime
    mov %esi, %eax
    xor %edx, %edx
    div %ebx                     # n / d
    test %edx, %edx
    jz cp_skip                   # divisible -> composite
    inc %ebx
    jmp cp_div
cp_isp:
    inc %ebp
cp_skip:
    inc %esi
    jmp cp_loop
cp_ret:
    mov %ebp, %eax
    ret

# --- smpon: wake the other CPU cores (deliberately not a boot step) ----
#   Deliberately opt-in: on real silicon a faulting AP triple-faults the
#   whole box into a reboot loop, so the BOOT path stays single-core and
#   SMP arms only on explicit command (try 'smp'/'pbench' after).
do_smpon:
    cmpl $1, cpu_count
    ja smpon_already
    call smp_init
    cmpl $1, cpu_count
    jbe smpon_none
    mov $msg_smpon, %esi
    call puts
    jmp shell
smpon_already:
    mov $msg_smpon2, %esi
    call puts
    jmp shell
smpon_none:
    mov $msg_smpon3, %esi
    call puts
    jmp shell

do_smp:
    mov $msg_smp1, %esi          # "SMP: cores "
    call puts
    mov cpu_count, %eax
    call print_dec32
    mov $msg_smp2, %esi          # "  online "
    call puts
    mov ap_online, %eax
    inc %eax                     # + the BSP itself
    call print_dec32
    call crlf
    mov $msg_smp4, %esi          # hint about pbench
    call puts
    mov $msg_smp5, %esi          # per-core thread-resume counts
    call puts
    xor %ebx, %ebx
ds_pc:
    cmp cpu_count, %ebx
    jae ds_done
    mov $0x5b, %al ; call putc    # '['
    mov %ebx, %eax ; call print_dec32
    mov $0x5d, %al ; call putc    # ']'
    mov core_runs(,%ebx,4), %eax
    call print_dec32
    mov $0x20, %al ; call putc    # ' '
    inc %ebx
    jmp ds_pc
ds_done:
    call crlf
    jmp shell

# --- pbench [N]: count primes up to N, single-core then across all cores,
#     and report the speed-up. The parallel scheduler in action.
do_pbench:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_dec               # EAX = N (0 if none)
    test %eax, %eax
    jnz dpb_n
    mov $300000, %eax            # default
dpb_n:
    mov %eax, pb_n
    # --- single-core baseline ---
    mov $msg_pb1, %esi
    call puts
    mov pb_n, %eax
    call print_dec32
    call crlf
    mov ticks, %eax
    mov %eax, pb_t0
    mov $2, %esi
    mov pb_n, %edi
    call count_primes
    mov %eax, pb_total1          # primes (ground truth)
    mov ticks, %eax
    sub pb_t0, %eax
    mov %eax, pb_t1
    mov $msg_pb2, %esi           # "  1 core:  primes="
    call puts
    mov pb_total1, %eax
    call print_dec32
    mov $msg_pb3, %esi           # "  ticks="
    call puts
    mov pb_t1, %eax
    call print_dec32
    call crlf
    # --- parallel: split [2,N] into cpu_count chunks, one per APIC id ---
    cmpl $2, cpu_count
    jb dpb_done                  # single core - nothing to parallelise
    mov pb_n, %eax               # chunk = (N-2)/cpu_count
    sub $2, %eax
    xor %edx, %edx
    div cpu_count
    mov %eax, pb_chunk
    xor %ebx, %ebx               # core index i
dpb_setup:
    cmp cpu_count, %ebx
    jae dpb_kick
    mov pb_chunk, %eax           # lo = 2 + i*chunk
    imul %ebx, %eax
    add $2, %eax
    mov %eax, ap_lo(,%ebx,4)
    mov %ebx, %eax               # last core takes the remainder up to N
    inc %eax
    cmp cpu_count, %eax
    je dpb_lasthi
    mov pb_chunk, %eax           # hi = 2 + (i+1)*chunk - 1
    mov %ebx, %ecx
    inc %ecx
    imul %ecx, %eax
    add $1, %eax
    mov %eax, ap_hi(,%ebx,4)
    jmp dpb_clr
dpb_lasthi:
    mov pb_n, %eax
    mov %eax, ap_hi(,%ebx,4)
dpb_clr:
    movl $0, ap_done(,%ebx,4)
    inc %ebx
    jmp dpb_setup
dpb_kick:
    mov ticks, %eax
    mov %eax, pb_t0
    xor %ebx, %ebx               # raise go for every AP (not the BSP)
dpb_go:
    cmp cpu_count, %ebx
    jae dpb_self
    mov bsp_apic, %eax
    cmp %eax, %ebx
    je dpb_gnext
    movl $1, ap_go(,%ebx,4)       # post the job, then wake the idle AP by IPI
    mov %ebx, %eax
    shl $24, %eax
    mov %eax, 0xFEE00310
    movl $0x00004040, 0xFEE00300  # fixed IPI, vector 0x40 -> ap_isr
dpb_gnext:
    inc %ebx
    jmp dpb_go
dpb_self:
    mov bsp_apic, %ebx           # the BSP runs its own chunk inline
    mov ap_lo(,%ebx,4), %esi
    mov ap_hi(,%ebx,4), %edi
    call count_primes
    mov bsp_apic, %ebx           # reload - count_primes clobbered EBX
    mov %eax, ap_res(,%ebx,4)
    movl $1, ap_done(,%ebx,4)
    # --- wait for every core's done, then sum ---
    xor %ebx, %ebx
    xor %ebp, %ebp               # running total (EBP survives the spin)
dpb_reap:
    cmp cpu_count, %ebx
    jae dpb_report
dpb_wait:
    cmpl $1, ap_done(,%ebx,4)
    jne dpb_wait
    add ap_res(,%ebx,4), %ebp
    inc %ebx
    jmp dpb_reap
dpb_report:
    mov ticks, %eax
    sub pb_t0, %eax
    mov %eax, pb_t2
    mov $msg_pb4, %esi           # "  N cores: primes="
    call puts
    mov %ebp, %eax
    call print_dec32
    mov $msg_pb3, %esi           # "  ticks="
    call puts
    mov pb_t2, %eax
    call print_dec32
    call crlf
dpb_done:
    jmp shell

do_cpuid:
    mov $msg_cpu, %esi
    call puts
    xor %eax, %eax
    cpuid
    mov $cpu_buf, %edi
    mov %ebx, (%edi)
    mov %edx, 4(%edi)
    mov %ecx, 8(%edi)
    movb $0, 12(%edi)
    mov $cpu_buf, %esi
    call puts
    call crlf
    mov $0x80000000, %eax
    cpuid
    cmp $0x80000004, %eax
    jb cpuid_done
    mov $msg_model, %esi
    call puts
    mov $cpu_buf, %edi
    mov $0x80000002, %eax
    cpuid
    call store4
    mov $0x80000003, %eax
    cpuid
    call store4
    mov $0x80000004, %eax
    cpuid
    call store4
    movb $0, (%edi)
    mov $cpu_buf, %esi
    call puts
    call crlf
cpuid_done:
    mov $1, %eax                 # leaf 1: logical CPUs (EBX) + features (EDX/ECX)
    cpuid
    mov %ecx, feat_ecx
    mov %edx, feat_edx
    mov $msg_cores, %esi         # "  logical CPUs "
    call puts
    shr $16, %ebx                # EBX bits 16-23 = logical processors/package
    movzbl %bl, %eax
    call print_dec32
    mov $msg_feat, %esi          # "  features:"
    call puts
    mov feat_edx, %eax
    mov %eax, feat_val
    mov $edx_tbl, %esi
    call print_feats
    mov feat_ecx, %eax
    mov %eax, feat_val
    mov $ecx_tbl, %esi
    call print_feats
    call crlf
    jmp shell

# print_feats: ESI = table of {.byte bit, .asciz name}, end byte 0xFF.
#   Prints " <name>" for each bit set in feat_val. (CPU feature flags.)
print_feats:
pf_l:
    movzbl (%esi), %ecx          # bit number
    cmp $0xff, %cl
    je pf_d
    inc %esi                     # -> name
    mov $1, %eax
    shl %cl, %eax                # 1 << bit
    test feat_val, %eax
    jz pf_sk
    push %esi
    mov $msg_sp, %esi
    call puts                    # space
    pop %esi
    push %esi
    call puts                    # the flag name
    pop %esi
pf_sk:
    lodsb                        # skip past this name's NUL
    test %al, %al
    jnz pf_sk
    jmp pf_l
pf_d:
    ret

# draw_bar: AL = percent (0-100). Redraws a 30-cell progress bar in
#   place ("\r[######      ] 60%") - green fill, on the current line.
draw_bar:
    pushal
    movzbl %al, %ebp             # EBP = percent
    movb $0x0a, cur_attr         # bar in green
    mov $0x0d, %al               # carriage return: back to column 0
    call putc
    mov $0x5b, %al               # '['
    call putc
    mov %ebp, %eax               # filled = percent * 30 / 100
    mov $30, %ecx
    mul %ecx
    mov $100, %ecx
    xor %edx, %edx
    div %ecx
    mov %eax, %esi               # ESI = filled count
    mov %eax, %edi               # EDI = working counter
db_fill:
    test %edi, %edi
    jz db_filld
    mov $0x23, %al               # '#'
    call putc
    dec %edi
    jmp db_fill
db_filld:
    mov $30, %edi
    sub %esi, %edi               # empty = 30 - filled
db_empty:
    test %edi, %edi
    jz db_emptyd
    mov $0x20, %al               # ' '
    call putc
    dec %edi
    jmp db_empty
db_emptyd:
    mov $0x5d, %al               # ']'
    call putc
    mov $0x20, %al
    call putc
    mov %ebp, %eax               # percent number + '%'
    call print_dec32
    mov $0x25, %al
    call putc
    popal
    ret

# --- cputest: 500,000,000-iteration ALU benchmark in 10 chunks, shown
#   as a live progress bar. Measures cycles via RDTSC AND wall-time via
#   timer ticks -> cycle count, MHz estimate, result checksum. RDTSC
#   keeps it honest even if the timer is off (then MHz reads '?').
do_cputest:
    mov arg_ptr, %esi            # optional arg: number of 50M-iteration chunks
    call skip_spaces
    call parse_dec
    jc ct_defn
    movzwl %ax, %eax
    test %eax, %eax
    jz ct_defn
    cmp $2000, %eax              # cap (2000 x 50M = 100 billion)
    jbe ct_setn
    mov $2000, %eax
ct_setn:
    mov %eax, ct_chunks
    jmp ct_go
ct_defn:
    movl $10, ct_chunks          # default 10 chunks = 500M iterations
ct_go:
    mov $0x0e, %al
    mov $msg_ct1, %esi
    call putsc                   # heading in yellow
    mov ticks, %eax
    mov %eax, ct_ticks0
    rdtsc
    mov %eax, ct_start
    xor %ebx, %ebx               # checksum accumulator
    mov ct_chunks, %edi          # configurable chunk count
ct_chunk:
    mov $50000000, %ecx          # 50 million per chunk
ct_loop:
    mov %ecx, %eax
    imul $2654435761, %eax, %eax # Knuth hash multiply - real ALU work
    add %eax, %ebx
    rol $7, %ebx
    xor %ecx, %ebx
    dec %ecx
    jnz ct_loop
    dec %edi                     # one chunk done
    mov ct_chunks, %eax          # progress = (total - remaining) * 100 / total
    sub %edi, %eax
    imul $100, %eax, %eax
    xor %edx, %edx
    mov ct_chunks, %ecx
    div %ecx
    call draw_bar
    test %edi, %edi
    jnz ct_chunk
    rdtsc
    sub ct_start, %eax           # EAX = cycle delta
    mov %eax, ct_cycles
    mov ticks, %eax
    sub ct_ticks0, %eax          # EAX = elapsed ticks
    mov %eax, ct_ticksd
    mov %ebx, ct_csum            # stash the checksum for printing
    mov $msg_ct_cyc, %esi        # "\r\n  "
    call puts
    mov ct_chunks, %eax          # iterations = chunks * 50 million
    imul $50, %eax, %eax
    call print_dec32
    mov $msg_ct_it, %esi         # "M iters, "
    call puts
    mov ct_cycles, %eax
    call print_dec32
    mov $msg_ct_cyc2, %esi       # " cycles, ~"
    call puts
    mov ct_ticksd, %ecx          # MHz = cycles * 18 / ticks / 1e6
    test %ecx, %ecx
    jz ct_nomhz
    mov ct_cycles, %eax
    mov $18, %ecx
    mul %ecx                     # EDX:EAX = cycles * 18 (64-bit)
    mov ct_ticksd, %ecx
    div %ecx                     # EAX = cycles*18 / ticks
    xor %edx, %edx
    mov $1000000, %ecx
    div %ecx                     # EAX = MHz
    call print_dec32
    mov $msg_ct_mhz, %esi        # " MHz, checksum 0x"
    call puts
    jmp ct_csump
ct_nomhz:
    mov $msg_ct_qmhz, %esi       # "? MHz (no timer), checksum 0x"
    call puts
ct_csump:
    mov ct_csum, %eax
    call phex32
    call crlf
    call cpu_membw               # also measure memory read bandwidth
    jmp shell

# cpu_membw: stream-read 64 MB (4 x 16 MB at 0x200000) and report MB/s, so
#   cputest characterizes the memory subsystem too, not just the ALU.
cpu_membw:
    mov ticks, %ebp              # t0
    mov $4, %ebx                 # 4 passes x 16 MB = 64 MB streamed
membw_pass:
    mov $0x200000, %esi
    mov $0x400000, %ecx          # 4M dwords = 16 MB
    xor %eax, %eax
membw_r:
    add (%esi), %eax             # read every dword (sum -> not elidable)
    add $4, %esi
    dec %ecx
    jnz membw_r
    dec %ebx
    jnz membw_pass
    mov ticks, %eax
    sub %ebp, %eax
    mov %eax, ct_ticksd
    mov $msg_ct_bw, %esi         # "  memory: "
    call puts
    mov ct_ticksd, %ecx
    test %ecx, %ecx
    jz membw_fast
    mov $64, %eax                # MB/s = 64 MB * 18 ticks/s / elapsed ticks
    mov $18, %edx
    imul %edx, %eax
    xor %edx, %edx
    div %ecx
    call print_dec32
    mov $msg_ct_bw2, %esi        # " MB/s read\r\n"
    call puts
    ret
membw_fast:
    mov $msg_ct_bwf, %esi        # "fast (<1 tick)\r\n"
    call puts
    ret

# --- ramtest: write/verify 5 patterns over 16 MB of RAM (0x200000-
#   0x11FFFFF, well clear of the kernel). Four bit patterns plus an
#   address-in-address test (catches stuck data AND address lines),
#   a dot per pass. Reports MB tested + error count, PASS/FAIL.
do_ramtest:
    mov arg_ptr, %esi            # optional arg: MB to test (default 16)
    call skip_spaces
    call parse_dec
    jc rt_defmb
    movzwl %ax, %eax
    test %eax, %eax
    jnz rt_capmb
rt_defmb:
    mov $16, %eax
rt_capmb:
    mov (E820_TOTAL), %ecx       # cap to real RAM minus a 4 MB margin (test @2MB)
    test %ecx, %ecx
    jz rt_setmb
    shr $20, %ecx                # MB available
    sub $4, %ecx
    cmp %ecx, %eax
    jbe rt_setmb
    mov %ecx, %eax
rt_setmb:
    test %eax, %eax
    jnz rt_okmb
    mov $1, %eax
rt_okmb:
    mov %eax, rt_mb
    call rt_maphigh              # map 4 MB pages for the test range above 32 MB
    mov $0x0e, %al
    mov $msg_rt1, %esi
    call putsc
    xor %edi, %edi               # EDI = total error count
    xor %eax, %eax               # pass 1: all zeros
    call rt_pattern
    mov $11, %al
    call draw_bar
    mov $0xffffffff, %eax        # pass 2: all ones
    call rt_pattern
    mov $22, %al
    call draw_bar
    mov $0xaaaaaaaa, %eax        # pass 3: 1010...
    call rt_pattern
    mov $33, %al
    call draw_bar
    mov $0x55555555, %eax        # pass 4: 0101...
    call rt_pattern
    mov $44, %al
    call draw_bar
    mov $0xaa55aa55, %eax        # pass 5: mixed
    call rt_pattern
    mov $55, %al
    call draw_bar
    mov $0x55aa55aa, %eax        # pass 6: mixed inverted
    call rt_pattern
    mov $66, %al
    call draw_bar
    call rt_addrtest             # pass 7: each dword = its own address
    mov $77, %al
    call draw_bar
    call rt_movinv               # pass 8: moving inversions (coupling faults)
    mov $100, %al
    call draw_bar
    mov $msg_rt2, %esi           # "\r\nRAM test: "
    call puts
    mov rt_mb, %eax
    call print_dec32
    mov $msg_rt_mb, %esi         # " MB, errors: "
    call puts
    mov %edi, %eax
    call print_dec32
    test %edi, %edi
    jnz rt_bad
    mov $0x0a, %al               # 0 errors -> green PASS
    mov $msg_rt_ok, %esi
    call putsc
    jmp shell
rt_bad:
    mov $0x0c, %al               # errors -> red FAIL
    mov $msg_rt_bad, %esi
    call putsc
    jmp shell

# rt_pattern: EAX = pattern. Write then verify 16 MB; add mismatches to
#   EDI, print a progress dot. (EAX kept, ESI/ECX scratch)
rt_pattern:
    mov $0x200000, %esi          # test region starts at 2 MB
    mov rt_mb, %ecx
    shl $18, %ecx                # MB * 256K dwords
rt_w:
    mov %eax, (%esi)
    add $4, %esi
    dec %ecx
    jnz rt_w
    mov $0x200000, %esi
    mov rt_mb, %ecx
    shl $18, %ecx
rt_r:
    cmp %eax, (%esi)
    je rt_rok
    inc %edi
rt_rok:
    add $4, %esi
    dec %ecx
    jnz rt_r
    ret

# rt_maphigh: the identity map only covers 0-32 MB (4 KB page tables). To
#   test beyond that, add 4 MB-page PDEs (PSE) for the part of the test
#   range above 32 MB. Low indices 0-7 stay as they are; only RAM the E820
#   cap already confirmed exists gets mapped. Persisting these is harmless.
rt_maphigh:
    mov rt_mb, %eax
    shl $20, %eax
    add $0x200000, %eax
    dec %eax                     # last byte of the test range
    shr $22, %eax                # last 4 MB PDE index
    mov %eax, %ecx
    cmp $8, %ecx                 # all within 32 MB? nothing to map
    jb rt_mhd
    mov %cr4, %eax
    or $0x10, %eax
    mov %eax, %cr4               # CR4.PSE
    mov $8, %ebx                 # from index 8 (32 MB) up
rt_mh:
    cmp %ecx, %ebx
    ja rt_mhf
    mov %ebx, %eax
    shl $22, %eax
    or $0x83, %eax               # present | rw | PS (4 MB page)
    mov %eax, PAGE_DIR(,%ebx,4)
    inc %ebx
    jmp rt_mh
rt_mhf:
    mov $PAGE_DIR, %eax
    mov %eax, %cr3               # flush TLB
rt_mhd:
    ret

# rt_addrtest: write each dword = its own address, verify. Catches
#   address-line faults. Adds mismatches to EDI. (ESI/ECX/EAX scratch)
rt_addrtest:
    mov $0x200000, %esi
    mov rt_mb, %ecx
    shl $18, %ecx
ra_w:
    mov %esi, (%esi)
    add $4, %esi
    dec %ecx
    jnz ra_w
    mov $0x200000, %esi
    mov rt_mb, %ecx
    shl $18, %ecx
ra_r:
    mov (%esi), %eax
    cmp %esi, %eax
    je ra_rok
    inc %edi
ra_rok:
    add $4, %esi
    dec %ecx
    jnz ra_r
    ret

# rt_movinv: moving-inversions test - the gold standard. Fill with 0 ascending;
#   ascending: verify 0, write 0xFFFFFFFF; descending: verify 0xFFFFFFFF,
#   write 0. Catches coupling/transition faults that static patterns miss.
#   Adds mismatches to EDI. (ESI/ECX/EAX scratch)
rt_movinv:
    mov $0x200000, %esi          # phase 1: write 0 ascending
    mov rt_mb, %ecx
    shl $18, %ecx
mi_1:
    movl $0, (%esi)
    add $4, %esi
    dec %ecx
    jnz mi_1
    mov $0x200000, %esi          # phase 2: ascending - verify 0, write all-ones
    mov rt_mb, %ecx
    shl $18, %ecx
mi_2:
    cmpl $0, (%esi)
    je mi_2ok
    inc %edi
mi_2ok:
    movl $0xffffffff, (%esi)
    add $4, %esi
    dec %ecx
    jnz mi_2
    mov rt_mb, %ecx              # phase 3: descending - verify all-ones, write 0
    shl $18, %ecx
    mov %ecx, %eax
    dec %eax
    shl $2, %eax                 # (count-1)*4 = last dword offset
    lea 0x200000(%eax), %esi
mi_3:
    cmpl $0xffffffff, (%esi)
    je mi_3ok
    inc %edi
mi_3ok:
    movl $0, (%esi)
    sub $4, %esi
    dec %ecx
    jnz mi_3
    ret

# =====================================================================
#  hwtest: the full hardware diagnostic. CPU integer torture with fault
#  detection + throughput, a cache/memory read-bandwidth ladder (reveals
#  L1/L2/L3/RAM), then the full multi-pattern RAM test. Results also go to
#  dmesg, so the test PC self-reports the whole run over the wire (net-dmesg.sh).
#    hwtest [MB]   - MB is the RAM-test size (default 64, capped to real RAM)
# =====================================================================
do_hwtest:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_dec
    jc hw_defmb
    movzwl %ax, %eax
    test %eax, %eax
    jnz hw_capmb
hw_defmb:
    mov $64, %eax
hw_capmb:
    mov (E820_TOTAL), %ecx
    test %ecx, %ecx
    jz hw_setmb
    shr $20, %ecx
    sub $4, %ecx
    cmp %ecx, %eax
    jbe hw_setmb
    mov %ecx, %eax
hw_setmb:
    test %eax, %eax
    jnz hw_okmb
    mov $1, %eax
hw_okmb:
    mov %eax, rt_mb
    movb $0x0f, cur_attr
    mov $msg_hw_hdr, %esi         # "=== TannX OS hardware test ===\r\n"
    call puts
    call hw_cpu                  # 1) CPU torture + fault check + throughput
    call hw_bw                   # 2) cache/memory bandwidth ladder
    call hw_ram                  # 3) full multi-pattern RAM test
    movb $0x0a, cur_attr
    mov $msg_hw_done, %esi       # "=== hardware test complete ===\r\n"
    call puts
    call hw_log                  # mirror a summary into dmesg (over the wire)
    jmp shell

# hw_torture: ECX = iterations -> EAX = checksum. A deterministic mix of
#   multiply/add/rotate/xor: same input -> same output, so two runs that
#   disagree mean the CPU miscomputed.
hw_torture:
    xor %eax, %eax
    mov $0x12345678, %edx
ht_l:
    imul $1103515245, %edx, %edx
    add $12345, %edx
    rol $7, %edx
    xor %edx, %eax
    add %ecx, %eax
    dec %ecx
    jnz ht_l
    ret

# hw_cpu: time the torture over >=4 ticks for a reliable Miter/s and MHz, then
#   run a fixed length twice and compare checksums to catch a flaky CPU.
hw_cpu:
    mov $0x0b, %al
    mov $msg_hw_cpu, %esi        # "CPU:    "
    call putsc
    mov ticks, %eax
hc_align:
    mov ticks, %ebp
    cmp %eax, %ebp
    je hc_align
    rdtsc
    mov %eax, %esi               # cycle start
    xor %edi, %edi               # iterations counted, in millions
hc_chunk:
    mov $10000000, %ecx
    call hw_torture
    add $10, %edi
    mov ticks, %eax
    sub %ebp, %eax
    cmp $4, %eax
    jb hc_chunk
    rdtsc
    sub %esi, %eax
    mov %eax, ct_cycles
    mov ticks, %eax
    sub %ebp, %eax
    mov %eax, ct_ticksd          # elapsed ticks
    mov %edi, %eax               # Miter/s = millions * 18 / ticks
    mov $18, %ecx
    mul %ecx
    xor %edx, %edx
    divl ct_ticksd
    mov %eax, hw_miters
    call print_dec32
    mov $msg_hw_mi, %esi         # " Miter/s, "
    call puts
    mov ct_cycles, %eax          # MHz = cycles * 18 / ticks / 1e6
    mov $18, %ecx
    mul %ecx
    divl ct_ticksd
    xor %edx, %edx
    mov $1000000, %ecx
    div %ecx
    mov %eax, cpu_mhz
    call print_dec32
    mov $msg_hw_mhz, %esi        # " MHz, "
    call puts
    mov $5000000, %ecx           # fault check: identical runs must agree
    call hw_torture
    mov %eax, %ebx
    mov $5000000, %ecx
    call hw_torture
    cmp %eax, %ebx
    jne hc_fault
    mov $0x0a, %al
    mov $msg_hw_stable, %esi     # "compute STABLE\r\n"
    call putsc
    ret
hc_fault:
    mov $0x0c, %al
    mov $msg_hw_fault, %esi      # "compute FAULT!\r\n"
    call putsc
    movb $1, hw_cpu_fault
    ret

# hw_bw: read-bandwidth ladder. Stream-read a region of each size enough times
#   to total 64 MB, time with rdtsc, MB/s = bytes * MHz / cycles. The four
#   sizes fall in L1 / L2 / L3 / main memory and show the hierarchy.
hw_bw:
    mov $0x0b, %al
    mov $msg_hw_bw, %esi         # "cache/mem read bandwidth:\r\n"
    call putsc
    mov $0x4000, %eax            # 16 KB  -> L1
    mov $msg_bw_l1, %esi
    call hw_bw_one
    mov hw_bw_last, %eax
    mov %eax, hw_bw_res+0
    mov $0x40000, %eax           # 256 KB -> L2
    mov $msg_bw_l2, %esi
    call hw_bw_one
    mov hw_bw_last, %eax
    mov %eax, hw_bw_res+4
    mov $0x400000, %eax          # 4 MB   -> L3
    mov $msg_bw_l3, %esi
    call hw_bw_one
    mov hw_bw_last, %eax
    mov %eax, hw_bw_res+8
    mov $0x1000000, %eax         # 16 MB  -> RAM (fits the 0-32MB identity map)
    mov $msg_bw_ram, %esi
    call hw_bw_one
    mov hw_bw_last, %eax
    mov %eax, hw_bw_res+12
    ret

# hw_bw_one: EAX = region size (bytes), ESI = label. Total 64 MB read.
hw_bw_one:
    pushal
    mov %esi, hw_bw_lbl
    mov %eax, %ebx               # region size (bytes)
    mov $0x4000000, %eax         # 64 MB total work
    xor %edx, %edx
    div %ebx                     # EAX = number of passes
    mov %eax, %ebp               # passes
    rdtsc
    mov %eax, %edi               # cycle start
    cmpb $0, sse_ok              # SSE -> 16-byte loads (saturates L1); else scalar
    je hbw_pass_s
hbw_pass:
    mov $0x200000, %esi          # region base (2 MB, 16-byte aligned)
    mov %ebx, %ecx
    shr $6, %ecx                 # 64-byte (4x movaps) blocks
hbw_r:
    movaps (%esi), %xmm0         # four independent 16-byte loads per iteration
    movaps 16(%esi), %xmm1
    movaps 32(%esi), %xmm2
    movaps 48(%esi), %xmm3
    add $64, %esi
    dec %ecx
    jnz hbw_r
    dec %ebp
    jnz hbw_pass
    jmp hbw_timed
hbw_pass_s:
    mov $0x200000, %esi          # scalar fallback (no SSE)
    mov %ebx, %ecx
    shr $2, %ecx
    xor %eax, %eax
hbw_rs:
    add (%esi), %eax
    add $4, %esi
    dec %ecx
    jnz hbw_rs
    dec %ebp
    jnz hbw_pass_s
hbw_timed:
    rdtsc
    sub %edi, %eax               # cycle delta
    mov %eax, %ecx               # ECX = cycles
    mov hw_bw_lbl, %esi
    call puts
    test %ecx, %ecx
    jz hbw_fast
    mov $0x4000000, %eax         # MB/s = bytes(64MB) * MHz / cycles (MHz folds in 1e6)
    mov cpu_mhz, %edx
    mul %edx                     # EDX:EAX = bytes * MHz
    div %ecx                     # / cycles -> MB/s directly
    mov %eax, hw_bw_last
    call print_dec32
    mov $msg_hw_mbs, %esi        # " MB/s\r\n"
    call puts
    popal
    ret
hbw_fast:
    mov $msg_hw_bwfast, %esi
    call puts
    popal
    ret

# hw_ram: the full multi-pattern RAM test (reuses the ramtest passes) over
#   rt_mb, accumulating the error count into hw_ram_err.
hw_ram:
    mov $0x0b, %al
    mov $msg_hw_ram, %esi        # "RAM:    testing "
    call putsc
    mov rt_mb, %eax
    call print_dec32
    mov $msg_hw_rammb, %esi      # " MB  "
    call puts
    call rt_maphigh
    xor %edi, %edi               # error count
    xor %eax, %eax
    call rt_pattern
    mov $0xffffffff, %eax
    call rt_pattern
    mov $0xaaaaaaaa, %eax
    call rt_pattern
    mov $0x55555555, %eax
    call rt_pattern
    call rt_addrtest
    call rt_movinv
    mov %edi, hw_ram_err
    mov $msg_hw_ramerr, %esi     # "  errors: "
    call puts
    mov %edi, %eax
    call print_dec32
    test %edi, %edi
    jnz hr_bad
    mov $0x0a, %al
    mov $msg_hw_rampass, %esi    # "  PASS\r\n"
    call putsc
    ret
hr_bad:
    mov $0x0c, %al
    mov $msg_hw_ramfail, %esi    # "  FAIL\r\n"
    call putsc
    ret

# hw_log: write a one-line hwtest summary into the dmesg ring so the test PC
#   self-reports the result over the wire (like cpu-bench / ram-test do).
hw_log:
    mov $REPLY_SCRATCH, %edi
    mov $logp_hw, %esi           # "hwtest: cpu "
    call bputs
    mov hw_miters, %eax
    call bdec32
    mov $logp_hw_mi, %esi        # " Miter/s "
    call bputs
    mov cpu_mhz, %eax
    call bdec32
    mov $logp_hw_mhz, %esi       # " MHz "
    call bputs
    cmpb $0, hw_cpu_fault
    je hl_ok
    mov $logp_hw_flt, %esi       # "FAULT "
    call bputs
    jmp hl_ram
hl_ok:
    mov $logp_hw_stab, %esi      # "stable "
    call bputs
hl_ram:
    mov $logp_hw_ram, %esi       # "ram "
    call bputs
    mov rt_mb, %eax
    call bdec32
    mov $logp_hw_mb, %esi        # "MB err "
    call bputs
    mov hw_ram_err, %eax
    call bdec32
    mov $logp_hw_bw, %esi        # " bw(MB/s) L1/L2/L3/RAM "
    call bputs
    mov hw_bw_res+0, %eax
    call bdec32
    mov $logp_slash, %esi
    call bputs
    mov hw_bw_res+4, %eax
    call bdec32
    mov $logp_slash, %esi
    call bputs
    mov hw_bw_res+8, %eax
    call bdec32
    mov $logp_slash, %esi
    call bputs
    mov hw_bw_res+12, %eax
    call bdec32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret

# hwtest_remote: the full hwtest run from the idle loop on a remote SELFTEST,
#   so the dev box pulls the whole diagnostic (incl. the cache/RAM bandwidth
#   ladder) off the test PC over the wire. Prints to the screen too.
hwtest_remote:
    pushal
    movb $0, selftest_req
    mov $32, %eax                # RAM phase: 32 MB, capped to real RAM
    mov (E820_TOTAL), %ecx
    test %ecx, %ecx
    jz hwr_set
    shr $20, %ecx
    sub $4, %ecx
    cmp %ecx, %eax
    jbe hwr_set
    mov %ecx, %eax
hwr_set:
    test %eax, %eax
    jnz hwr_ok
    mov $1, %eax
hwr_ok:
    mov %eax, rt_mb
    movb $0, hw_cpu_fault
    movb $0x0a, cur_attr
    mov $msg_hw_hdr, %esi
    call puts
    call hw_cpu
    call hw_bw
    call hw_ram
    call hw_log
    popal
    ret

# --- display: firmware framebuffer geometry ---------------------------
#   Reports the linear framebuffer the firmware (UEFI GOP / BIOS VBE)
#   handed us at UEFI_INFO: resolution, pixels-per-scanline, the FB
#   physical base, and the computed size (scanline * vres * 4, 32bpp).
#   Read-only - it just formats what fb_init already adopted; no mode
#   switch (that needs boot services, gone after ExitBootServices).
#   Remotely queryable like sysinfo:  net-exec.sh "display".
do_display:
    cmpl $0x49464555, UEFI_INFO      # magic "UEFI" (set on either boot path)?
    jne disp_none
    mov $msg_disp1, %esi             # "display: "
    call puts
    mov UEFI_INFO+0x10, %eax         # horizontal resolution
    call print_dec32
    mov $msg_disp_x, %esi            # " x "
    call puts
    mov UEFI_INFO+0x14, %eax         # vertical resolution
    call print_dec32
    mov $msg_disp_sl, %esi           # ", "
    call puts
    mov UEFI_INFO+0x18, %eax         # pixels per scanline
    call print_dec32
    mov $msg_disp_pl, %esi           # " px/line, fb @0x"
    call puts
    mov UEFI_INFO+8, %eax            # framebuffer physical base
    call phex32
    mov $msg_disp_sl, %esi           # ", "
    call puts
    mov UEFI_INFO+0x18, %eax         # size = scanline * vres * 4 bytes
    mull UEFI_INFO+0x14              #   (edx:eax; a <4 GB FB fits in eax)
    shr $8, %eax                     # px * 4 / 1024 = px / 256 -> KB
    call print_dec32
    mov $msg_disp_kb, %esi           # " KB (32bpp)\r\n"
    call puts
    # available GOP modes, enumerated read-only by the UEFI loader into
    # UEFI_INFO+0x1c (count) + 0x20 (list of (h<<16)|w). 0/garbage count =
    # the BIOS/VBE path, which enumerates none.
    mov UEFI_INFO+0x1c, %eax         # mode count
    test %eax, %eax
    jz disp_done
    cmp $24, %eax                    # sanity guard against an uninitialised count
    ja disp_done
    mov $msg_disp_modes, %esi        # "  modes:"
    call puts
    mov UEFI_INFO+0x1c, %ecx         # count
    xor %edx, %edx                   # index
disp_ml:
    push %ecx
    push %edx
    mov UEFI_INFO+0x20(,%edx,4), %eax  # entry = (height<<16) | width
    test %eax, %eax
    jz disp_mn                       # empty slot -> skip
    push %eax
    mov $msg_disp_sp, %esi           # " "
    call puts
    mov (%esp), %eax
    movzwl %ax, %eax                 # width
    call print_dec32
    mov $msg_disp_xx, %esi           # "x"
    call puts
    mov (%esp), %eax
    shr $16, %eax                    # height
    call print_dec32
    pop %eax                         # discard the saved entry
disp_mn:
    pop %edx
    pop %ecx
    inc %edx
    dec %ecx
    jnz disp_ml
    call crlf
disp_done:
    jmp shell
disp_none:
    mov $msg_disp_none, %esi         # text mode / no linear framebuffer
    call puts
    jmp shell

# --- sysinfo: what is this machine? CPU via cpuid, board + RAM via the
#   SMBIOS/DMI tables the firmware leaves in the 0xF0000-0xFFFFF area.
#   On the test PC it prints the actual CPU model, mainboard maker
#   and product, and installed RAM (type + speed) - read off the box
#   without opening it. Pure scanning, no ACPI.
do_sysinfo:
    movb $0x0f, cur_attr          # sysinfo in bright white (next prompt resets)
    mov $0x0b, %al                # labels in cyan
    mov $msg_si_cpu, %esi         # CPU vendor (cpuid 0)
    call putsc
    xor %eax, %eax
    cpuid
    mov $cpu_buf, %edi
    mov %ebx, (%edi)
    mov %edx, 4(%edi)
    mov %ecx, 8(%edi)
    movb $0, 12(%edi)
    mov $cpu_buf, %esi
    call puts
    mov $msg_si_sp, %esi
    call puts
    mov $0x80000000, %eax         # CPU brand string (cpuid 0x80000002-4)
    cpuid
    cmp $0x80000004, %eax
    jb si_cpudone
    mov $cpu_buf, %edi
    mov $0x80000002, %eax
    cpuid
    call store4
    mov $0x80000003, %eax
    cpuid
    call store4
    mov $0x80000004, %eax
    cpuid
    call store4
    movb $0, (%edi)
    mov $cpu_buf, %esi
    call puts
    mov $1, %eax                 # logical processor count (cpuid 1 EBX[23:16])
    cpuid
    shr $16, %ebx
    and $0xff, %ebx
    test %ebx, %ebx
    jz si_cpudone
    mov $msg_si_thr, %esi        # " ("
    call puts
    mov %ebx, %eax
    call print_dec32
    mov $msg_si_thr2, %esi       # " threads)"
    call puts
si_cpudone:
    call crlf
    # --- SMBIOS / DMI ---
    call smbios_find             # sets smb_addr/smb_cnt; EAX=1 ok / 0 none
    test %eax, %eax
    jz si_nosmb
    mov $0, %bl                  # Type 0 = BIOS
    call smb_find_type
    test %esi, %esi
    jz si_sys
    mov %esi, %ebp
    mov $0x0b, %al
    mov $msg_si_bios, %esi
    call putsc
    movzbl 4(%ebp), %eax         # BIOS vendor
    call smb_str
    call puts
    mov $msg_si_sp, %esi
    call puts
    movzbl 5(%ebp), %eax         # BIOS version
    call smb_str
    call puts
    call crlf
si_sys:
    mov $1, %bl                  # Type 1 = System
    call smb_find_type
    test %esi, %esi
    jz si_board
    mov %esi, %ebp
    mov $0x0b, %al
    mov $msg_si_sys, %esi
    call putsc
    movzbl 4(%ebp), %eax         # manufacturer
    call smb_str
    call puts
    mov $msg_si_sp, %esi
    call puts
    movzbl 5(%ebp), %eax         # product name
    call smb_str
    call puts
    call crlf
si_board:
    mov $2, %bl                  # Type 2 = Baseboard (mainboard)
    call smb_find_type
    test %esi, %esi
    jz si_ramsmb
    mov %esi, %ebp
    mov $0x0b, %al
    mov $msg_si_board, %esi
    call putsc
    movzbl 4(%ebp), %eax
    call smb_str
    call puts
    mov $msg_si_sp, %esi
    call puts
    movzbl 5(%ebp), %eax
    call smb_str
    call puts
    call crlf
si_ramsmb:
    # sum all Type 17 (memory device) sizes; grab type+speed of DIMM 1
    xor %edi, %edi               # EDI = total MB
    xor %ebp, %ebp               # EBP = memory type of first populated DIMM
    movl $0, ram_speed
    mov smb_addr, %esi
    mov smb_cnt, %ecx
si_ramloop:
    test %ecx, %ecx
    jz si_ramshow
    cmpb $127, (%esi)            # end-of-table -> stop summing
    je si_ramshow
    cmpb $17, (%esi)
    jne si_ramnext
    movzwl 0x0c(%esi), %eax      # Size field
    test %eax, %eax
    jz si_ramnext
    cmp $0xffff, %eax
    je si_ramnext
    cmp $0x7fff, %eax            # 0x7FFF -> real size in extended dword
    jne si_rammb
    mov 0x1c(%esi), %eax
    jmp si_ramadd
si_rammb:
    test $0x8000, %eax           # bit15 set -> size in KB, else MB
    jz si_ramadd
    and $0x7fff, %eax
    shr $10, %eax
si_ramadd:
    add %eax, %edi
    test %ebp, %ebp              # capture type+speed from the first DIMM
    jnz si_ramnext
    movzbl 0x12(%esi), %ebp      # memory type (0x18=DDR3 ...)
    movzwl 0x15(%esi), %eax      # speed (MT/s)
    mov %eax, ram_speed
si_ramnext:
    call smb_next                # ESI -> next structure
    dec %ecx
    jmp si_ramloop
si_ramshow:
    test %edi, %edi
    jz si_ramcmos                # no Type 17 -> fall back to CMOS
    mov $0x0b, %al
    mov $msg_si_ram, %esi
    call putsc
    mov %edi, %eax
    call print_dec32
    mov $msg_si_mb, %esi
    call puts
    test %ebp, %ebp
    jz si_done
    mov $msg_si_comma, %esi
    call puts
    mov %ebp, %eax               # decode a few common DDR generations
    cmp $0x13, %al
    je si_ddr2
    cmp $0x18, %al
    je si_ddr3
    cmp $0x1a, %al
    je si_ddr4
    mov $msg_ddr_x, %esi         # unknown: just say "RAM"
    jmp si_rtype
si_ddr2:
    mov $msg_ddr2, %esi
    jmp si_rtype
si_ddr3:
    mov $msg_ddr3, %esi
    jmp si_rtype
si_ddr4:
    mov $msg_ddr4, %esi
si_rtype:
    call puts
    mov ram_speed, %eax
    test %eax, %eax
    jz si_done
    mov $msg_si_at, %esi
    call puts
    mov ram_speed, %eax
    call print_dec32
    mov $msg_si_mhz, %esi
    call puts
si_done:
    call crlf
    jmp si_disks
si_nosmb:
    mov $msg_si_nosmb, %esi
    call puts
si_ramcmos:                      # RAM fallback: CMOS extended memory
    mov $0x0b, %al
    mov $msg_si_ram, %esi
    call putsc
    mov $0x30, %bl
    call cmos_read
    mov %al, %cl
    mov $0x31, %bl
    call cmos_read
    mov %al, %ch
    movzwl %cx, %eax
    add $1024, %eax              # + the first MB CMOS does not count
    shr $10, %eax                # KB -> MB (approx; CMOS caps ~64 MB)
    call print_dec32
    mov $msg_si_mbx, %esi
    call puts
si_disks:                        # ATA drives via IDENTIFY (primary chan)
    mov $0xa0, %bl               # primary master
    call si_one_disk
    mov $0xb0, %bl               # primary slave
    call si_one_disk
    mov $msg_si_gpu, %esi         # H4/H5: display controller (generic class)
    mov $0x03ff, %bx             # class 03 display, any subclass
    call si_pci_line
    mov $msg_si_nic, %esi         # network controller
    mov $0x02ff, %bx             # class 02 network, any subclass
    call si_pci_line
    jmp shell

# si_pci_line: print "<label><vendor>:<device>" for the first PCI device whose
#   class:subclass matches BX (low byte 0xFF = any subclass), else "none".
#   ESI = label. H4/H5: a generic hardware-report line built on pci_find_class -
#   reused for GPU + NIC here, ready for storage/audio. Over the wire it is just
#   `net-exec.sh "sysinfo"`, so the dev box sees what a new machine carries.
si_pci_line:
    mov $0x0b, %al               # cyan label (putsc preserves EBX)
    call putsc
    mov %bx, %ax                 # AX = wanted class:subclass
    xor %cl, %cl                 # the first such device
    call pci_find_class
    jc spl_none
    mov %ebp, %eax
    call pci_read                # EAX = device<<16 | vendor
    mov %eax, %edx
    movzwl %dx, %eax             # vendor (low word)
    call phex16
    mov $msg_colon, %esi
    call puts
    mov %edx, %eax
    shr $16, %eax                # device (high word)
    call phex16
    call crlf
    ret
spl_none:
    mov $msg_si_none, %esi
    call puts
    call crlf
    ret

# smbios_find: scan 0xF0000-0xFFFFF (16-byte steps, as the spec wants -
#   that also skips unaligned look-alike strings) for an SMBIOS entry
#   point. Handles both the 2.1 "_SM_" (count at +0x1C, table at +0x18)
#   and the 3.0 "_SM3_" (no count -> walk to the type-127 end; table at
#   +0x10). Sets smb_addr/smb_cnt. EAX = 1 found / 0 none. (clobbers EAX)
smbios_find:
    push %edx
    mov $0xf0000, %edx
smf_loop:
    cmpl $0x5f4d535f, (%edx)      # "_SM_" (SMBIOS 2.1)
    je smf_21
    cmpl $0x334d535f, (%edx)      # "_SM3" + ...
    jne smf_step
    cmpb $0x5f, 4(%edx)           # ... "_" => "_SM3_" (SMBIOS 3.0)
    je smf_30
smf_step:
    add $16, %edx
    cmp $0x100000, %edx
    jb smf_loop
    xor %eax, %eax                # not found
    jmp smf_ret
smf_21:
    mov 0x18(%edx), %eax          # 2.1: structure table address
    cmp $0x2000000, %eax
    jae smf_step                  # implausible -> keep scanning
    mov %eax, smb_addr
    movzwl 0x1c(%edx), %eax       # structure count
    mov %eax, smb_cnt
    mov $1, %eax
    jmp smf_ret
smf_30:
    mov 0x10(%edx), %eax          # 3.0: table address (low dword of qword)
    cmp $0x2000000, %eax
    jae smf_step
    mov %eax, smb_addr
    movl $2000, smb_cnt           # 3.0 has no count: walk until type 127
    mov $1, %eax
smf_ret:
    pop %edx
    ret

# smb_find_type: BL = wanted type. Uses smb_addr/smb_cnt. ESI = first
#   matching structure or 0. (clobbers EAX, ECX, ESI)
smb_find_type:
    mov smb_addr, %esi
    mov smb_cnt, %ecx
sft_loop:
    test %ecx, %ecx
    jz sft_none
    cmpb $127, (%esi)            # end-of-table structure -> stop
    je sft_none
    cmpb %bl, (%esi)
    je sft_done
    call smb_next
    dec %ecx
    jmp sft_loop
sft_none:
    xor %esi, %esi
sft_done:
    ret

# smb_next: ESI -> current structure; advance ESI past it (formatted
#   area + the double-null-terminated string set). (clobbers EAX)
smb_next:
    movzbl 1(%esi), %eax         # formatted area length
    add %eax, %esi
smn_str:
    cmpw $0, (%esi)              # double null = end of string set
    je smn_end
    inc %esi
    jmp smn_str
smn_end:
    add $2, %esi
    ret

# smb_str: EBP = structure, AL = 1-based string index. ESI -> that
#   string (or empty). (clobbers EAX, ECX, ESI; preserves EBP)
smb_str:
    test %al, %al
    jz sstr_empty
    mov %ebp, %esi
    movzbl 1(%esi), %ecx         # skip the formatted area
    add %ecx, %esi
sstr_skip:
    cmp $1, %al
    je sstr_done
sstr_c:
    cmpb $0, (%esi)
    je sstr_n
    inc %esi
    jmp sstr_c
sstr_n:
    inc %esi
    dec %al
    jmp sstr_skip
sstr_done:
    ret
sstr_empty:
    mov $empty_str, %esi
    ret

# ata_identify: BL = drive select (0xA0 master / 0xB0 slave). Issues
#   ATA IDENTIFY DEVICE and reads 256 words into fs_buf. CF=1 if no
#   such drive (or ATAPI/error). Bounded waits, never hangs.
ata_identify:
    push %eax
    push %ecx
    push %edx
    push %edi
    mov $0x1f6, %dx              # select the drive
    mov %bl, %al
    out %al, %dx
    mov $0x1f7, %dx             # ~400 ns settle: read status a few times
    in %dx, %al
    in %dx, %al
    in %dx, %al
    in %dx, %al
    cmp $0xff, %al              # floating bus => nothing there
    je ai_none
    test %al, %al              # status 0 => no drive
    jz ai_none
    mov $0x1f2, %dx            # sector count + LBA registers = 0
    xor %al, %al
    out %al, %dx
    inc %edx
    out %al, %dx
    inc %edx
    out %al, %dx
    inc %edx
    out %al, %dx
    mov $0x1f7, %dx            # IDENTIFY DEVICE
    mov $0xec, %al
    out %al, %dx
    in %dx, %al
    test %al, %al
    jz ai_none
    mov $0x100000, %ecx        # wait for BSY clear (bounded)
ai_bsy:
    in %dx, %al
    test $0x80, %al
    jz ai_rdy
    loop ai_bsy
    jmp ai_none
ai_rdy:
    test $0x01, %al            # ERR (e.g. ATAPI) -> treat as none
    jnz ai_none
    test $0x08, %al            # DRQ must be set
    jz ai_none
    mov $fs_buf, %edi          # read the 256-word identify block
    mov $0x1f0, %dx
    mov $256, %ecx
    rep insw
    clc
    jmp ai_out
ai_none:
    stc
ai_out:
    pop %edi
    pop %ecx
    pop %edx
    pop %eax
    ret

# ata_model: swap+copy the model string (identify words 27-46, big-endian
#   byte pairs) from fs_buf into cpu_buf, trimmed and null-terminated.
ata_model:
    push %eax
    push %ecx
    push %esi
    push %edi
    mov $fs_buf+54, %esi
    mov $cpu_buf, %edi
    mov $20, %ecx
am_sw:
    mov (%esi), %ax            # AL=byte0, AH=byte1 -> store swapped
    mov %ah, (%edi)
    mov %al, 1(%edi)
    add $2, %esi
    add $2, %edi
    loop am_sw
    movb $0, (%edi)
    mov $cpu_buf+39, %edi       # trim trailing spaces
am_trim:
    cmp $cpu_buf, %edi
    jb am_done
    cmpb $0x20, (%edi)
    jne am_done
    movb $0, (%edi)
    dec %edi
    jmp am_trim
am_done:
    pop %edi
    pop %esi
    pop %ecx
    pop %eax
    ret

# si_one_disk: BL = drive select. If present, print "Disk: <model> (<MB>)".
si_one_disk:
    push %ebx
    call ata_identify
    jc sod_out
    mov $0x0b, %al
    mov $msg_si_disk, %esi
    call putsc
    call ata_model
    mov $cpu_buf, %esi
    call puts
    mov $msg_si_dsz, %esi       # " ("
    call puts
    mov fs_buf+120, %eax        # LBA28 total sectors
    shr $11, %eax               # sectors -> MB (/2048)
    call print_dec32
    mov $msg_si_mb, %esi        # " MB"
    call puts
    mov $msg_si_dsz2, %esi      # ")"
    call puts
    call crlf
sod_out:
    pop %ebx
    ret

# =====================================================================
#  AgentFS: 8 text slots (LBA 257-264) via our OWN ATA driver
# =====================================================================
fs_slot_arg:
    mov arg_ptr, %esi
    call skip_spaces
    movzbl (%esi), %eax
    sub $0x30, %al
    cmp $8, %al
    jae fsa_err
    mov %al, %bl
    movzbl %al, %eax
    add $257, %eax               # LBA = 257 + slot (marker at 256)
    inc %esi
    clc
    ret
fsa_err:
    stc
    ret

do_save:
    cmpb $0, fs_armed
    je fs_locked
    call fs_slot_arg
    jc save_usage
    push %eax
    call skip_spaces
    movb $0x41, fs_buf
    movb $0x46, fs_buf+1
    mov $fs_buf+3, %edi
    xor %ecx, %ecx
sv_cp:
    lodsb
    test %al, %al
    jz sv_cpd
    cmp $200, %ecx
    jae sv_cpd
    stosb
    inc %ecx
    jmp sv_cp
sv_cpd:
    mov %cl, fs_buf+2
    pop %eax
    mov $fs_buf, %esi
    call ata_write
    jc disk_err
    mov $msg_saved, %esi
    call puts
    jmp shell
fs_locked:
    mov $msg_locked, %esi
    call puts
    jmp shell
save_usage:
    mov $msg_save_usage, %esi
    call puts
    jmp shell

do_load:
    call fs_slot_arg
    jc load_usage
    mov $fs_buf, %edi
    call ata_read
    jc disk_err
    cmpb $0x41, fs_buf
    jne slot_empty
    cmpb $0x46, fs_buf+1
    jne slot_empty
    mov $msg_load1, %esi
    call puts
    movzbl %bl, %eax
    add $0x30, %al
    call putc
    mov $msg_load2, %esi
    call puts
    movzbl fs_buf+2, %ecx
    mov $fs_buf+3, %esi
ld_out:
    test %ecx, %ecx
    jz ld_done
    lodsb
    call putc
    dec %ecx
    jmp ld_out
ld_done:
    call crlf
    jmp shell
slot_empty:
    mov $msg_slot_empty, %esi
    call puts
    jmp shell
load_usage:
    mov $msg_load_usage, %esi
    call puts
    jmp shell
disk_err:
    mov $msg_diskio, %esi
    call puts
    jmp shell

# --- script <slot>: the agents language -----------
#   Execute an AgentFS slot as shell commands. Newlines become ';' and
#   the whole text goes through the existing chain machinery (PEND_BUF/
#   pending_ptr), so EVERY shell command is a script statement: spawn/
#   task pipelines, llm, sleep, even 'script' itself - a slot whose last
#   line calls itself is a loop (ESC aborts, see sh_chain). Replaces
#   whatever remained of the current chain. Write scripts with
#   'save <slot> cmd, cmd, ...' (commas - a typed ';' is eaten by the
#   chainer before save runs) or one command per line over the wire.
do_script:
    call fs_slot_arg
    jc script_usage
    mov %bl, script_slot          # remember it: 'repeat <n>' re-stages this slot
script_stage:                     # EAX = slot LBA; stages the text + jmp shell
    mov $fs_buf, %edi
    call ata_read
    jc disk_err
    cmpb $0x41, fs_buf            # 'A''F' slot magic
    jne slot_empty
    cmpb $0x46, fs_buf+1
    jne slot_empty
    movzbl fs_buf+2, %ecx         # text length (<= 506 < the 4 KB PEND_BUF page)
    mov $fs_buf+3, %esi
    mov $PEND_BUF, %edi
scr_cp:
    test %ecx, %ecx
    jz scr_done
    lodsb
    cmp $0x0a, %al                # newline -> ';' (one statement per line)
    je scr_sep
    cmp $0x2c, %al                # ',' -> ';' too: typed 'save's go through the
    je scr_sep                    #   ';' chainer FIRST, so ';' can't survive a
    jmp scr_n1                    #   typed save - commas are the typed separator
scr_sep:
    mov $0x3b, %al
scr_n1:
    cmp $0x0d, %al                # CR -> space (CRLF-saved texts)
    jne scr_n2
    mov $0x20, %al
scr_n2:
    stosb
    dec %ecx
    jmp scr_cp
scr_done:
    xor %al, %al
    stosb
    movl $PEND_BUF, pending_ptr   # hand the script to the ';' chainer
    jmp shell
script_usage:
    mov $msg_script_usage, %esi
    call puts
    jmp shell

# --- if <task> =|! <n> <cmd>: script conditionals --------------------
#   Compares task <task>'s RESULT (tasks_tbl +12, what 'tasks' prints
#   after '= ') against <n>; on '=' equal / '!' not-equal the rest of
#   the line is executed as a command (re-entering the dispatcher), else
#   the chain just continues. Pipelines compute async - sleep first.
#   Example: spawn prime; task prime 100; sleep 45; if 0 = 541 beep
# if <left> <op> <right> <cmd> : left/right are a task index, or '$'/'#' (the
#   script registers), or '@<task>' (right only). op = = ! < >. So the register
#   arithmetic can now be branched on directly: 'set + 1; if $ < 10 <cmd>'.
do_if:
    mov arg_ptr, %esi
    call skip_spaces
    movzbl (%esi), %eax
    cmp $0x24, %al               # '$' -> left operand = register A
    je if_l_a
    cmp $0x23, %al               # '#' -> left operand = register B
    je if_l_b
    call parse_dec               # else a task index
    jc if_usage
    cmp $8, %eax
    jae if_usage
    shl $4, %eax
    mov tasks_tbl+12(%eax), %eax # EAX = that task's result
    jmp if_l_have
if_l_a:
    inc %esi
    mov sreg, %eax
    jmp if_l_have
if_l_b:
    inc %esi
    mov sreg2, %eax
if_l_have:
    mov %eax, if_left            # stash the left operand value
    call skip_spaces
    movzbl (%esi), %ebx          # operator: '=' '!' '<' '>'
    inc %esi
    call skip_spaces
    push %ebx                     # save the operator across the operand parse
    movzbl (%esi), %eax
    cmp $0x40, %al               # '@<task2>' -> compare against task2's result
    je if_val_at
    cmp $0x24, %al               # '$' -> right operand = register A
    je if_val_a
    cmp $0x23, %al               # '#' -> right operand = register B
    je if_val_b
    call parse_dec               # else a literal value
    pop %ebx
    jc if_usage
    jmp if_have_val
if_val_at:
    inc %esi                     # skip '@'
    call parse_dec               # EAX = task2 index
    pop %ebx
    jc if_usage
    cmp $8, %eax
    jae if_usage
    shl $4, %eax
    mov tasks_tbl+12(%eax), %eax # EAX = task2's result
    jmp if_have_val
if_val_a:
    inc %esi
    pop %ebx
    mov sreg, %eax
    jmp if_have_val
if_val_b:
    inc %esi
    pop %ebx
    mov sreg2, %eax
if_have_val:
    mov if_left, %ecx            # ECX = left operand value
    cmp $0x3d, %bl               # '=' equal
    je if_eq
    cmp $0x21, %bl               # '!' not-equal
    je if_ne
    cmp $0x3c, %bl               # '<' result below n
    je if_lt
    cmp $0x3e, %bl               # '>' result above n
    je if_gt
    jmp if_usage
if_eq:
    cmp %eax, %ecx               # results are unsigned (count 70000 > 2^31), so the
    je if_run                    #   ordering tests use jb/ja, not jl/jg
    jmp shell                    # false -> on to the next chain statement
if_ne:
    cmp %eax, %ecx
    jne if_run
    jmp shell
if_lt:
    cmp %eax, %ecx               # ECX (result) < EAX (n)?
    jb if_run
    jmp shell
if_gt:
    cmp %eax, %ecx               # ECX (result) > EAX (n)?
    ja if_run
    jmp shell
if_run:
    call skip_spaces             # consequent = the rest of the line;
    cmpb $0, (%esi)              #   slide it to the front of linebuf and
    je shell                     #   re-enter the dispatcher (dst < src,
    mov $linebuf, %edi           #   so the forward copy is safe)
if_cp:
    movb (%esi), %al
    mov %al, (%edi)
    inc %esi
    inc %edi
    test %al, %al
    jnz if_cp
    jmp dispatch
if_usage:
    mov $msg_if_usage, %esi
    call puts
    jmp shell

# --- repeat <n>: run the current script slot n times in total ---------
#   Put it as the LAST line of a script. First encounter arms rep_count
#   with the remaining runs and re-stages the slot; each later encounter
#   counts down. ESC/Ctrl+C clears the counter (sh_abort/wait_abort).
do_repeat:
    movzbl script_slot, %ebx
    cmp $8, %ebx                 # only meaningful inside 'script <slot>'
    jae repeat_usage
    mov arg_ptr, %esi
    call skip_spaces
    call parse_dec               # EAX = total runs wanted
    jc repeat_usage
    cmp $999, %eax               # sanity cap
    jbe rep_n
    mov $999, %eax
rep_n:
    mov rep_count, %ecx
    test %ecx, %ecx
    jnz rep_down                 # mid-loop: just count down
    test %eax, %eax              # fresh encounter: arm with n-1 remaining
    jz shell                     # repeat 0 -> no-op
    dec %eax
    mov %eax, rep_count
    jmp rep_chk
rep_down:
    dec %ecx
    mov %ecx, rep_count
rep_chk:
    cmpl $0, rep_count
    je shell                     # that was the last run - fall through
    lea 257(%ebx), %eax          # re-stage the slot (same LBA base as
    jmp script_stage             #   fs_slot_arg) and run it again
repeat_usage:
    mov $msg_repeat_usage, %esi
    call puts
    jmp shell

# --- waitall: block until ALL agent tasks are done (fan-out join) -----
#   The companion to waittask: fan out several agents, then join on the
#   whole queue with one barrier. Blocks until no tasks_tbl slot is still
#   waiting/running (each done/ERROR or unused). The timeout resets every
#   time the pending count DROPS (a task finished = progress), so a long
#   fan-out never trips while work completes; only a full stall of
#   WAIT_BUDGET with zero completions bails (self-heal). ESC/Ctrl+C or
#   AGENTOS-ABORT drop the chain. Reuses waittask's wt_* handlers.
#   Example: task prime 100; task prime 200; task count 50; waitall; tasks
do_waitall:
    mov ticks, %eax
    mov %eax, wt_start           # timeout base (shared with waittask)
    movl $9, wa_prev             # previous pending count (>8 -> first scan resets)
wa_l:
    xor %ebx, %ebx               # task index
    xor %edx, %edx               # EDX = pending count this scan
wa_scan:
    mov %ebx, %ecx
    shl $4, %ecx                 # tasks_tbl byte offset (index * 16)
    cmpb $0, tasks_tbl(%ecx)     # unused slot -> not pending
    je wa_next
    cmpb $2, tasks_tbl+2(%ecx)   # status >= 2 (done/ERROR) -> not pending
    jae wa_next
    inc %edx
wa_next:
    inc %ebx
    cmp $8, %ebx
    jb wa_scan
    test %edx, %edx
    jz wt_done                   # nothing pending -> all done, chain continues
    cmp wa_prev, %edx            # fewer pending than last scan? progress -> reset budget
    jae wa_noprog
    mov ticks, %eax
    mov %eax, wt_start
wa_noprog:
    mov %edx, wa_prev
    cmpb $0, abort_req
    jne wt_remote_abort
    mov ticks, %ecx
    sub wt_start, %ecx
    cmp $WAIT_BUDGET, %ecx
    jae wa_timeout
    mov kb_tail, %al             # ESC / Ctrl+C: abort the chain
    cmp kb_head, %al
    je wa_z
    movzbl kb_tail, %eax
    movzwl kbuf(,%eax,2), %eax
    cmp $0x1b, %al
    je wt_abort
    cmp $3, %al
    je wt_abort
wa_z:
    hlt
    jmp wa_l
wa_timeout:
    mov $msg_waitall_to, %esi
    call puts
    jmp shell

# --- waittask <n>: block until agent task <n> is done ----------------
#   The deterministic counterpart to 'sleep' in a pipeline: instead of
#   guessing how long an agent needs, block until tasks_tbl[n] reaches
#   done/ERROR (status >=2) or its slot frees. Reuses the wait watchdog -
#   the assigned agent's wd_start heartbeat (sys_progress) means a busy
#   agent never trips, but a stuck/unclaimed task bails after WAIT_BUDGET
#   so the autopilot self-heals (no kill - the agent is persistent). ESC/
#   Ctrl+C or AGENTOS-ABORT drop the chain.
#   Example: spawn prime; task prime 100; waittask 0; if 0 = 541 beep
do_waittask:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_dec               # EAX = task index
    jc waittask_usage
    cmp $8, %eax
    jae waittask_usage
    mov %eax, %ebx               # EBX = task index (kept raw across the loop)
    mov ticks, %eax
    mov %eax, wt_start           # fallback timeout base (pre-claim window)
wt_l:
    mov %ebx, %edx
    shl $4, %edx                 # EDX = tasks_tbl byte offset (index * 16)
    cmpb $0, tasks_tbl(%edx)     # +0 used == 0 -> task gone / never existed
    je wt_done
    cmpb $2, tasks_tbl+2(%edx)   # +2 status: 2 done / 3 ERROR -> finished
    jae wt_done
    cmpb $0, abort_req           # remote AGENTOS-ABORT -> drop the chain
    jne wt_remote_abort
    mov wt_start, %eax           # timeout base: the agent's heartbeat if claimed,
    movzbl tasks_tbl+3(%edx), %ecx   # +3 = agent index (0xFF = unclaimed)
    cmp $8, %ecx
    jae wt_have_base
    mov wd_start(,%ecx,4), %eax       #   else the pre-claim fallback
wt_have_base:
    mov ticks, %ecx
    sub %eax, %ecx
    cmp $WAIT_BUDGET, %ecx
    jae wt_timeout
    mov kb_tail, %al             # ESC / Ctrl+C: abort wait AND the chain
    cmp kb_head, %al
    je wt_z
    push %ebx
    movzbl kb_tail, %ebx
    movzwl kbuf(,%ebx,2), %eax
    pop %ebx
    cmp $0x1b, %al
    je wt_abort
    cmp $3, %al
    je wt_abort
wt_z:
    hlt                          # agents keep running meanwhile
    jmp wt_l
wt_abort:
    mov kb_tail, %al
    inc %al
    and $63, %al
    mov %al, kb_tail
    movl $0, pending_ptr
    movl $0, rep_count
    mov $msg_chain_abort, %esi
    call puts
wt_done:
    jmp shell                    # chain continues - the result is ready to read
wt_remote_abort:
    movb $0, abort_req
    movl $0, pending_ptr
    movl $0, rep_count
    mov $msg_wait_abort, %esi
    call puts
    jmp shell
wt_timeout:                      # not done in time: note it, but let the chain go on
    mov $msg_waittask_to, %esi   #   (the result just is not ready; the agent persists)
    call puts
    jmp shell
waittask_usage:
    mov $msg_waittask_usage, %esi
    call puts
    jmp shell

# --- wait: block until the last 'run'-style program exits -------------
#   The missing link for chains like 'llmscript 7 x, wait, script 7':
#   run_start launches ring-3 programs in the BACKGROUND (the shell gets
#   the prompt back), so a chained statement after llmscript would race
#   the fetch and run the OLD slot. ESC/Ctrl+C aborts the whole chain.
do_wait:
    movzbl runprog_slot, %ebx
    cmp $8, %ebx                 # nothing ever ran -> no-op
    jae wait_done
wait_l:
    lea agents_tbl(,%ebx,8), %esi
    cmpb $0, (%esi)              # slot freed (sys_exit/kill/#PF teardown)?
    je wait_done
    cmpb $0, abort_req           # remote AGENTOS-ABORT? kill the stuck prog + bail
    jne wait_remote_abort        #   (no reboot needed - autopilot recovers)
    mov ticks, %eax              # self-heal: the program made no progress (no
    sub wd_start(,%ebx,4), %eax  #   sys_progress) for WAIT_BUDGET -> it's stuck.
    cmp $WAIT_BUDGET, %eax        #   A legit slow LLM call heartbeats via recv_tcp,
    jae wait_timeout             #   so it never trips this.
    mov kb_tail, %al             # ESC / Ctrl+C: abort wait AND the chain
    cmp kb_head, %al
    je wait_z
    push %ebx
    movzbl kb_tail, %ebx
    movzwl kbuf(,%ebx,2), %eax
    pop %ebx
    cmp $0x1b, %al
    je wait_abort
    cmp $3, %al
    je wait_abort
wait_z:
    hlt                          # programs/agents keep running meanwhile
    jmp wait_l
wait_abort:
    mov kb_tail, %al
    inc %al
    and $63, %al
    mov %al, kb_tail
    movl $0, pending_ptr
    movl $0, rep_count           # a 'repeat' loop dies with its chain
    mov $msg_chain_abort, %esi
    call puts
wait_done:
    jmp shell
wait_remote_abort:               # AGENTOS-ABORT over the wire: free the stuck
    movb $0, abort_req           #   program and drop the chain, no power-cycle
    movb $0, (%esi)              # esi = agents_tbl[runprog_slot] -> free the slot
    lea 1(%ebx), %eax            # TID = slot + 1
    movb $0, tcb_state(%eax)     # stop its thread in the scheduler
    movl $0, pending_ptr
    movl $0, rep_count
    mov $msg_wait_abort, %esi
    call puts
    jmp shell
wait_timeout:                    # the program is stuck (no heartbeat) - same
    movb $0, (%esi)              #   teardown, but the autopilot self-heals with no
    lea 1(%ebx), %eax            #   human/abort needed
    movb $0, tcb_state(%eax)
    movl $0, pending_ptr
    movl $0, rep_count
    mov $msg_wait_timeout, %esi
    call puts
    jmp shell

# --- autopilot [mission]: the OS flies itself ------------------------
#   Stages the chain  llmscript 7 autopilot <mission>; wait; script 7
#   The proxy's autopilot contract makes the model end every script it
#   writes with that same llmscript/wait/script tail - so the OS asks
#   the LLM what to do next, does it, and asks again. Forever, until
#   ESC/Ctrl+C. Slot 7 is the autopilot's scratch slot. Needs diskon.
do_autopilot:                    # (atp_, not ap_ - that's the SMP namespace)
    movl $0, atp_round           # fresh round count for this autopilot session
    movb $0, atp_mission         # clear any stale mission until round 1
    mov $atp_chain, %esi         # "llmscript 7 autopilot "
    mov $PEND_BUF, %edi
atp_p:
    movb (%esi), %al
    test %al, %al
    je atp_arg
    mov %al, (%edi)
    inc %esi
    inc %edi
    jmp atp_p
atp_arg:
    mov arg_ptr, %esi            # + the mission text (may be empty)
    mov $224, %ecx               #   capped so the 22-byte prefix + mission
                                 #   segment stays under LINEMAX (254)
atp_cp:
    movb (%esi), %al
    test %al, %al
    je atp_tail
    mov %al, (%edi)
    inc %esi
    inc %edi
    dec %ecx
    jnz atp_cp
atp_tail:
    mov $atp_chain2, %esi        # + ";wait;script 7"
atp_t2:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je atp_go
    inc %esi
    inc %edi
    jmp atp_t2
atp_go:
    movl $PEND_BUF, pending_ptr
    jmp shell
atp_chain:  .asciz "llmscript 7 autopilot "
atp_chain2: .asciz ";wait;script 7"

# --- set <n> | set @<task> | set + <n>: the script REGISTER -----------
#   One 32-bit register for scripts. '$' in ANY dispatched statement is
#   replaced by its decimal value first (subst_reg), so every command
#   can be parametrized: set @0; task count $; echo round $ done.
#   'set @t' loads task t's result, 'set + n' adds (loop counters with
#   repeat), bare 'set' shows it.
# 'set'/'setb' share one body via set_ptr (-> sreg or sreg2). All the
#   arithmetic operates on (set_ptr), so a second register is free of code
#   duplication; EDI holds the pointer, loaded fresh right before each store
#   (parse_dec may clobber it, and set_div needs EDX for the divide).
do_setb:
    movl $sreg2, set_ptr         # '#' register
    jmp set_go
do_set:
    movl $sreg, set_ptr          # '$' register
set_go:
    mov arg_ptr, %esi
    call skip_spaces
    movzbl (%esi), %eax
    cmp $0x40, %al               # '@<task>' -> that task's result
    je set_at
    cmp $0x2b, %al               # '+ <n>'   -> add to the register
    je set_add
    cmp $0x2d, %al               # '- <n>'   -> subtract
    je set_sub
    cmp $0x2a, %al               # '* <n>'   -> multiply
    je set_mul
    cmp $0x2f, %al               # '/ <n>'   -> divide (guarded)
    je set_div
    test %al, %al                # bare 'set'/'setb' -> show it
    jz set_show
    call parse_dec
    jc set_usage
    mov set_ptr, %edi
    mov %eax, (%edi)
    jmp shell
set_at:
    inc %esi
    call parse_dec
    jc set_usage
    cmp $8, %eax
    jae set_usage
    shl $4, %eax
    mov tasks_tbl+12(%eax), %eax
    mov set_ptr, %edi
    mov %eax, (%edi)
    jmp shell
set_add:
    inc %esi
    call skip_spaces
    call parse_dec
    jc set_usage
    mov set_ptr, %edi
    add %eax, (%edi)
    jmp shell
set_sub:
    inc %esi
    call skip_spaces
    call parse_dec
    jc set_usage
    mov set_ptr, %edi
    sub %eax, (%edi)             # (reg) - n
    jmp shell
set_mul:
    inc %esi
    call skip_spaces
    call parse_dec
    jc set_usage
    mov set_ptr, %edi
    imul (%edi), %eax            # eax = n * reg (low 32 bits, wraps like add)
    mov %eax, (%edi)
    jmp shell
set_div:
    inc %esi
    call skip_spaces
    call parse_dec
    jc set_usage
    test %eax, %eax
    jz set_usage                 # divide by zero -> usage, register unchanged
    mov %eax, %ecx
    mov set_ptr, %edi
    mov (%edi), %eax
    xor %edx, %edx
    div %ecx                     # unsigned: reg / n
    mov %eax, (%edi)
    jmp shell
set_show:
    mov $msg_set, %esi
    call puts
    mov set_ptr, %edi
    mov (%edi), %eax
    call print_dec32
    call crlf
    jmp shell
set_usage:
    mov $msg_set_usage, %esi
    call puts
    jmp shell

# subst_reg: replace every '$' in linebuf with sreg's decimal digits.
#   Expands into fs_buf (idle between commands, 512 B - the expansion is
#   bounded so many '$'s can't overrun it), copies back capped at
#   LINEMAX chars. A line without '$' costs one scan and nothing else.
subst_reg:
    pushal
    # An 'if' line keeps its '$'/'#' operands LITERAL so do_if can read the
    #   registers itself (else '$' would expand to a value that do_if misreads
    #   as a task index). do_if re-dispatches its consequent through 'dispatch',
    #   which runs subst_reg again - so '$'/'#' in the consequent still expand.
    #   No-op for existing 'if <task#> ...' lines (they carry no '$'/'#').
    cmpb $0x69, linebuf          # 'i'
    jne sr_go
    cmpb $0x66, linebuf+1        # 'f'
    jne sr_go
    cmpb $0x20, linebuf+2        # 'if ' -> skip substitution on this line
    je sr_out
sr_go:
    mov $linebuf, %esi
sr_scan:
    lodsb
    test %al, %al
    je sr_out                    # no '$' or '#' anywhere - done
    cmp $0x24, %al               # '$' = register A (sreg)
    je sr_found
    cmp $0x23, %al               # '#' = register B (sreg2)
    jne sr_scan
sr_found:
    mov $linebuf, %esi           # found one: expand the whole line
    mov $fs_buf, %edi
sr_cp:
    cmp $fs_buf+500, %edi        # bound the expansion: a token adds up to 10
    jae sr_full                  #   digits, so stopping at +500 keeps every
    lodsb                        #   write inside the 512-B fs_buf
    cmp $0x24, %al
    je sr_dollar
    cmp $0x23, %al
    je sr_hash
    stosb
    test %al, %al
    jnz sr_cp
sr_copyback:
    mov $fs_buf, %esi            # copy back, bounded to the segment cap
    mov $linebuf, %edi
    mov $LINEMAX, %ecx
sr_back:
    lodsb
    stosb
    test %al, %al
    jz sr_out
    dec %ecx
    jnz sr_back
    movb $0, (%edi)
sr_out:
    popal
    ret
sr_hash:
    mov sreg2, %eax              # '#' -> register B, then the shared emit
    jmp sr_emit
sr_dollar:
    mov sreg, %eax               # '$' -> register A
sr_emit:
    mov $10, %ebx                # decimal digits via the stack (reversed)
    xor %ecx, %ecx
sr_div:
    xor %edx, %edx
    divl %ebx
    add $0x30, %dl
    push %edx
    inc %ecx
    test %eax, %eax
    jnz sr_div
sr_pop:
    pop %eax
    stosb
    dec %ecx
    jnz sr_pop
    jmp sr_cp
sr_full:
    xor %al, %al                 # over-long expansion: force-terminate and
    stosb                        #   hand the truncated line to the copy-back
    jmp sr_copyback

# --- sleep <n>: pause ~n ticks (18/s) - the script pacing primitive ---
#   Lets a script wait for agents/the watchdog/the wire between steps:
#   'spawn prime; task prime 100; sleep 36; tasks'. hlt keeps the CPU
#   cool; the timer keeps ticking, agents keep running meanwhile.
do_sleep:
    mov arg_ptr, %esi
    call skip_spaces
    call parse_dec
    jc sleep_usage
    cmp $1080, %eax               # cap at ~60 s (a typo must not wedge the box)
    jbe slp_ok
    mov $1080, %eax
slp_ok:
    add ticks, %eax
    mov %eax, %ebx
slp_w:
    hlt
    mov ticks, %eax
    cmp %ebx, %eax
    jb slp_w
    jmp shell
sleep_usage:
    mov $msg_sleep_usage, %esi
    call puts
    jmp shell

do_ls:
    xor %ebx, %ebx
ls_loop:
    push %ebx
    mov %ebx, %eax
    add $257, %eax
    mov $fs_buf, %edi
    call ata_read
    pop %ebx
    jc disk_err
    mov $msg_li1, %esi
    call puts
    mov %ebx, %eax
    add $0x30, %al
    call putc
    mov $msg_li2, %esi
    call puts
    cmpb $0x41, fs_buf
    jne ls_empty
    cmpb $0x46, fs_buf+1
    jne ls_empty
    movzbl fs_buf+2, %ecx
    cmp $40, %ecx
    jbe ls_show
    mov $40, %ecx
ls_show:
    mov $fs_buf+3, %esi
ls_out:
    test %ecx, %ecx
    jz ls_eol
    lodsb
    call putc
    dec %ecx
    jmp ls_out
ls_empty:
    mov $msg_ls_empty, %esi
    call puts
ls_eol:
    call crlf
    inc %ebx
    cmp $8, %ebx
    jb ls_loop
    jmp shell

do_del:
    cmpb $0, fs_armed
    je fs_locked
    call fs_slot_arg
    jc del_usage
    movb $0, fs_buf
    movb $0, fs_buf+1
    movb $0, fs_buf+2
    mov $fs_buf, %esi
    call ata_write
    jc disk_err
    mov $msg_deleted, %esi
    call puts
    jmp shell
del_usage:
    mov $msg_del_usage, %esi
    call puts
    jmp shell

# diskon only arms on a marked TannX OS medium: on real
# hardware the ATA driver talks to the FIRST INTERNAL disk - not the
# USB stick we booted from. Without the "AGENTOS-MEDIUM" marker at
# LBA 256 (written by the image build / usb targets) arming would
# point save/wish at somebody's GRUB. So: no marker, no writes.
do_diskon:
    mov $256, %eax
    mov $fs_buf, %edi
    call ata_read
    jc dk_ram                    # no disk at all -> RAM-backed slots
    mov $marker_str, %esi
    mov $fs_buf, %edi
    mov $14, %ecx
    repe cmpsb
    jne dk_ram                   # foreign disk -> RAM-backed slots (disk untouched)
    movb $1, fs_armed
    movb $0, fs_ram
    mov $msg_armed, %esi
    call puts
    jmp shell
dk_ram:                          # no TannX OS medium - slots live in RAM (volatile)
    movb $1, fs_armed            #   so llmscript/script/autopilot run with no disk;
    movb $1, fs_ram              #   the foreign internal disk is never written
    mov $msg_ramfs, %esi
    call puts
    jmp shell

# --- persist agent results across a reboot. The auto-update loop
#   reboots the box; on a disk-booted TannX OS medium the task results
#   (with their numbers) are written to TASKS_LBA and reloaded at boot, so
#   `tasks` survives. On PXE / a foreign disk there is no medium, so this
#   is a safe no-op (fs_armed=0; the boot reload checks the LBA 256 marker
#   before trusting anything - never restores from someone else's disk).
.equ TASKS_LBA, 273              # free sector after AgentFS (257-264) + wishes (265-272)
persist_tasks:                   # write magic "AT" + tasks_tbl to disk. CF=error.
    movb $0x41, fs_buf           # 'A'
    movb $0x54, fs_buf+1         # 'T'
    mov $tasks_tbl, %esi
    mov $fs_buf+2, %edi
    mov $128, %ecx               # tasks_tbl = 8 x 16 bytes
    rep movsb
    cmpb $0, ahci_persist        # blessed AHCI disk takes precedence over ATA
    jne pt_ahci
    mov $TASKS_LBA, %eax
    mov $fs_buf, %esi
    call ata_write
    ret
pt_ahci:                         # copy the sector into AHCI_BUF and WRITE DMA EXT
    mov $fs_buf, %esi
    mov $AHCI_BUF, %edi
    mov $128, %ecx
    rep movsl
    mov $TASKS_LBA, %eax
    call ahci_write
    ret
do_persist:
    cmpb $0, ahci_persist        # a blessed AHCI disk also counts as a medium
    jne dp_go
    cmpb $0, fs_armed            # else need an armed ATA medium (run diskon)
    je fs_locked
dp_go:
    call persist_tasks
    jc disk_err
    mov $msg_persisted, %esi
    call puts
    jmp shell

# --- ahcibless [confirm]: dedicate a SATA disk to TannX OS persistence by
#   writing the AGENTOS-MEDIUM marker to LBA 256. This is the ONLY automatic
#   gate to writing the AHCI disk - destructive, deliberate, opt-in: it needs
#   the literal 'confirm' token and a SATA HDD (never an ATAPI / data disk by
#   accident). After blessing, persist/reboot save the task table to it and
#   the next boot restores it (blessed marker checked, like the ATA medium).
do_ahcibless:
    mov arg_ptr, %esi
    call skip_spaces             # ESI = the argument
    mov $cs_confirm, %edi        # require the literal word "confirm"
    mov $7, %ecx
    repe cmpsb
    jne abl_warn
    call ahci_up
    jc abl_no
    cmpb $0, ahci_devtype        # SATA HDD only - ATAPI is read-only optical
    jne abl_nothdd
    mov $AHCI_BUF, %edi          # build the marker sector (zeroed + marker)
    xor %eax, %eax
    mov $128, %ecx
    rep stosl
    mov $marker_str, %esi
    mov $AHCI_BUF, %edi
    mov $14, %ecx
    rep movsb
    mov $256, %eax                # write the marker to LBA 256 of the SATA disk
    call ahci_write
    jc abl_err
    movb $1, ahci_persist
    mov $msg_abless_ok, %esi
    call puts
    jmp shell
abl_warn:
    mov $msg_abless_warn, %esi
    call puts
    jmp shell
abl_no:
    mov $msg_ahci_no, %esi
    call puts
    jmp shell
abl_nothdd:
    mov $msg_abless_nothdd, %esi
    call puts
    jmp shell
abl_err:
    mov $msg_aread_e, %esi
    call puts
    jmp shell

# load_persisted: at boot, restore the saved task results - but ONLY from a
#   genuine TannX OS medium (LBA 256 marker). Reads are harmless on any disk;
#   the marker + magic gate stop us trusting a foreign disk's bytes.
load_persisted:
    mov $256, %eax                # is this a TannX OS medium (ATA)?
    mov $fs_buf, %edi
    call ata_read
    jc lp_try_ahci               # no ATA disk / error -> try AHCI
    mov $marker_str, %esi
    mov $fs_buf, %edi
    mov $14, %ecx
    repe cmpsb
    jne lp_try_ahci              # not ours -> try AHCI
    mov $TASKS_LBA, %eax         # read the persisted tasks (ATA)
    mov $fs_buf, %edi
    call ata_read
    jc lp_try_ahci
    cmpb $0x41, fs_buf           # valid ATA magic? else this disk has the marker
    jne lp_try_ahci              #   but no saved tasks -> fall through to AHCI
    cmpb $0x54, fs_buf+1
    jne lp_try_ahci
    jmp lp_restore
lp_try_ahci:                     # a blessed AHCI SATA disk? (reads are harmless;
    call ahci_up                 #   the marker + magic gate stop foreign-disk trust)
    jc lp_ret
    cmpb $0, ahci_devtype        # only a SATA HDD can be a persistence medium
    jne lp_ret
    mov $256, %eax
    call ahci_read               # marker sector -> AHCI_BUF
    jc lp_ret
    mov $marker_str, %esi
    mov $AHCI_BUF, %edi
    mov $14, %ecx
    repe cmpsb
    jne lp_ret                   # not blessed -> skip (never wrote anything)
    movb $1, ahci_persist        # remember: persist back to this AHCI disk
    mov $TASKS_LBA, %eax         # read the persisted tasks (AHCI)
    call ahci_read
    jc lp_ret
    mov $AHCI_BUF, %esi          # AHCI lands in AHCI_BUF; mirror into fs_buf so
    mov $fs_buf, %edi            #   the rest of the routine is backend-agnostic
    mov $128, %ecx
    rep movsl
    cmpb $0x41, fs_buf           # magic 'A'
    jne lp_ret
    cmpb $0x54, fs_buf+1         # 'T'
    jne lp_ret
lp_restore:
    mov $fs_buf+2, %esi          # restore tasks_tbl
    mov $tasks_tbl, %edi
    mov $128, %ecx
    rep movsb
    xor %ebx, %ebx               # sanitize: keep only done/ERROR (final results),
lp_san:                          #   drop anything that was mid-flight at save time
    mov %ebx, %eax
    shl $4, %eax
    lea tasks_tbl(%eax), %eax
    cmpb $0, (%eax)
    je lp_san_n
    movzbl 2(%eax), %edx
    cmp $2, %edx                 # done
    je lp_san_n
    cmp $3, %edx                 # ERROR
    je lp_san_n
    movb $0, (%eax)              # was running/waiting/blocked -> clear
lp_san_n:
    inc %ebx
    cmp $8, %ebx
    jb lp_san
    mov $logm_restore, %esi      # note it in the kernel log
    call log_str
lp_ret:
    ret

# --- uptime / mem ------------------------------------------------------
do_uptime:
    mov $msg_up1, %esi
    call puts
    mov ticks, %eax
    call print_dec32
    mov $msg_up2, %esi
    call puts
    mov ticks, %eax
    xor %edx, %edx
    mov $18, %ecx
    div %ecx
    call print_dec32
    mov $msg_up3, %esi
    call puts
    jmp shell

do_mem:
    mov $msg_mem1, %esi
    call puts
    mov $0x15, %bl               # CMOS: base memory KB
    call cmos_read
    mov %al, %cl
    mov $0x16, %bl
    call cmos_read
    mov %al, %ch
    movzwl %cx, %eax
    call print_dec32
    mov $msg_mem2, %esi
    call puts
    mov $0x30, %bl               # CMOS: extended memory KB (>1MB)
    call cmos_read
    mov %al, %cl
    mov $0x31, %bl
    call cmos_read
    mov %al, %ch
    movzwl %cx, %eax
    call print_dec32
    mov $msg_mem3, %esi
    call puts
    movl (E820_TOTAL), %eax      # C3: real usable RAM (E820), beats the ~64MB CMOS cap
    test %eax, %eax
    jz mem_heap
    shr $20, %eax                # bytes -> MB
    push %eax
    mov $msg_mem_e820, %esi      # "  usable (E820): "
    call puts
    pop %eax
    call print_dec32
    mov $msg_mem_mb, %esi        # " MB\r\n"
    call puts
mem_heap:
    mov $msg_mem_heap, %esi      # "  kernel heap: "
    call puts
    mov heap_top, %eax           # heap_top - heap_base, in MB
    sub heap_base, %eax
    shr $20, %eax
    call print_dec32
    mov $msg_mem_mb, %esi
    call puts
    mov $msg_mem_atp, %esi       # the autopilot's live round + mission
    call puts
    mov atp_round, %eax
    call print_dec32
    mov $msg_mem_mis2, %esi
    call puts
    mov $atp_mission, %esi
    call puts
    call crlf
    mov $ksentinel, %esi         # the last-sector sentinel - proves all
    call puts                    #   256 kernel sectors loaded on this boot path
mem_done:
    jmp shell

do_reboot:
    cmpb $0, ahci_persist        # auto-save results on a blessed medium so
    jne rb_save                  #   they survive the reboot (no-op on PXE)
    cmpb $0, fs_armed
    je rb_go
rb_save:
    call persist_tasks
rb_go:
    mov $msg_reboot, %esi
    call puts
    mov $0xfe, %al               # 8042: reset pulse to the CPU
    out %al, $0x64
    mov $0x100000, %ecx
rb_wait:
    loop rb_wait
    lidt null_idtr               # fallback: empty IDT + interrupt
    int $3                       #  -> triple fault -> reset
null_idtr:
    .word 0
    .long 0

# --- poweroff: ACPI S5 soft-off. Find the RSDP (0xE0000-0xFFFFF, in our
#   identity map), walk RSDT -> FADT -> PM1a_CNT + DSDT, parse \_S5_ for
#   SLP_TYPa, best-effort enable ACPI, then outw SLP_TYPa|SLP_EN. Port and
#   value come from the firmware tables, so it is portable (not the QEMU-
#   only hardcoded 0x604). ACPI tables usually sit above our 32 MB map, so
#   po_map identity-maps their 4 MB page on demand (>= 32 MB only - never
#   the low NULL-guarded page). Anything missing -> fall through to halt.
map4m:                            # EAX = phys addr >= 32 MB -> identity-map its
    push %ecx                     #   4 MB page (present|rw|PS). PD edits are fine:
    push %edx                     #   poweroff never returns to an "after".
    push %eax
    mov %eax, %ecx
    shr $22, %ecx
    and $0xffc00000, %eax
    or $0x83, %eax
    mov %eax, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax                # CR4.PSE (idempotent)
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3                # flush TLB
    pop %eax
    pop %edx
    pop %ecx
    ret
po_map:                           # EAX = phys; map it only if it is high RAM
    cmp $0x2000000, %eax
    jb po_map_ret
    call map4m
po_map_ret:
    ret
do_poweroff:
    mov $msg_poweroff, %esi
    call puts
    mov $0xe0000, %esi            # find RSDP: "RSD PTR " on a 16-byte boundary
po_find:
    cmp $0x100000, %esi
    jae po_halt
    cmpl $0x20445352, (%esi)      # 'R','S','D',' '
    jne po_fn
    cmpl $0x20525450, 4(%esi)     # 'P','T','R',' '
    je po_rsdp
po_fn:
    add $16, %esi
    jmp po_find
po_rsdp:
    mov 16(%esi), %eax            # RsdtAddress (RSDP+16)
    test %eax, %eax
    jz po_halt
    call po_map
    mov %eax, %esi                # ESI = RSDT
    mov 4(%esi), %ecx             # RSDT length
    cmp $36, %ecx
    jbe po_halt
    sub $36, %ecx
    shr $2, %ecx                  # entry count (4 bytes each)
    lea 36(%esi), %ebx
po_fadt:
    test %ecx, %ecx
    jz po_halt
    mov (%ebx), %eax              # candidate table pointer
    call po_map
    cmpl $0x50434146, (%eax)      # "FACP" (FADT)?
    je po_havefadt
    add $4, %ebx
    dec %ecx
    jmp po_fadt
po_havefadt:
    mov %eax, %edi                # EDI = FADT
    mov 64(%edi), %ebp            # PM1a_CNT_BLK (I/O port)
    test %ebp, %ebp
    jz po_halt
    mov 40(%edi), %eax            # DSDT
    test %eax, %eax
    jz po_halt
    call po_map
    mov %eax, %esi                # ESI = DSDT
    mov 4(%esi), %ecx             # DSDT length -> end pointer
    add %esi, %ecx
    add $36, %esi                 # skip the 36-byte header
po_s5:
    cmp %ecx, %esi
    jae po_halt
    cmpl $0x5f35535f, (%esi)      # "_S5_"
    je po_s5ck
    inc %esi
    jmp po_s5
po_s5ck:
    cmpb $0x12, 4(%esi)           # must be followed by a PackageOp
    jne po_s5n
    lea 5(%esi), %esi             # past "_S5_" + PackageOp
    movzbl (%esi), %eax           # PkgLength lead byte
    shr $6, %eax                  # top 2 bits = extra length bytes
    add $2, %eax                  # + lead byte + NumElements
    add %eax, %esi
    cmpb $0x0a, (%esi)            # BytePrefix? skip it
    jne po_slpa
    inc %esi
po_slpa:
    movzbl (%esi), %eax           # SLP_TYPa
    shl $10, %eax
    or $0x2000, %eax              # | SLP_EN (bit 13)
    mov %eax, slp_val
    mov %ebp, pm1a_port
    mov %ebp, %edx                # already enabled (SCI_EN)?
    in %dx, %ax
    test $1, %ax
    jnz po_sleep
    mov 48(%edi), %edx            # else best-effort enable: ACPI_ENABLE -> SMI_CMD
    test %edx, %edx
    jz po_sleep
    movzbl 52(%edi), %eax
    out %al, %dx
    mov $0x400000, %ecx
po_enw:
    mov pm1a_port, %edx
    in %dx, %ax
    test $1, %ax
    jnz po_sleep
    loop po_enw
po_sleep:
    mov slp_val, %eax
    mov pm1a_port, %edx
    out %ax, %dx                  # outw SLP_TYPa|SLP_EN -> power off
    jmp po_halt
po_s5n:
    inc %esi                      # false "_S5_" match -> keep scanning
    jmp po_s5
po_halt:
do_halt:
    mov $msg_halt, %esi
    call puts
    cli
halt_loop:
    hlt
    jmp halt_loop

# =====================================================================
#  IDT SETUP + PIC REMAP + CPU EXCEPTIONS
# =====================================================================

# set_gate: EBX = vector, EAX = handler address -> interrupt gate
set_gate:
    push %ecx
    push %eax
    lea IDT_BASE(,%ebx,8), %ecx   # IDT lives at IDT_BASE
    mov %ax, (%ecx)              # offset 0..15
    movw $0x08, 2(%ecx)          # code selector
    movb $0, 4(%ecx)
    movb $0x8e, 5(%ecx)          # present, ring 0, 32-bit interrupt gate
    shr $16, %eax
    mov %ax, 6(%ecx)             # offset 16..31
    pop %eax
    pop %ecx
    ret

# set_gate3: like set_gate, but DPL=3 - ONLY for the syscall gate!
#   Any other gate with DPL 3 would be a ring-3 break-in door.
set_gate3:
    push %ecx
    push %eax
    lea IDT_BASE(,%ebx,8), %ecx
    mov %ax, (%ecx)
    movw $0x08, 2(%ecx)
    movb $0, 4(%ecx)
    movb $0xee, 5(%ecx)          # present, DPL 3, interrupt gate
    shr $16, %eax
    mov %ax, 6(%ecx)
    pop %eax
    pop %ecx
    ret

idt_setup:
    pushal
    mov $default_int, %eax       # first all 256 to the default handler
    xor %ebx, %ebx
is_all:
    call set_gate
    inc %ebx
    cmp $256, %ebx
    jb is_all
    xor %ebx, %ebx               # vectors 0-31: exception stubs
is_exc:
    mov exc_table(,%ebx,4), %eax
    call set_gate
    inc %ebx
    cmp $32, %ebx
    jb is_exc
    mov $13, %ebx                # #GP (protection violation): like #PF
    mov $gp_handler, %eax        # it only kills the guilty thread
    call set_gate
    mov $14, %ebx                # exception 14 (#PF) gets its own
    mov $pf_handler, %eax        # handler: fault isolation!
    call set_gate
    # ring-3-triggerable faults (no error code) - isolate like #GP/#PF
    # instead of halting the whole kernel via exc_common:
    mov $0, %ebx                 # #DE divide error
    mov $exc_isolate, %eax
    call set_gate
    mov $4, %ebx                 # #OF overflow (into)
    mov $exc_isolate, %eax
    call set_gate
    mov $5, %ebx                 # #BR bound range exceeded
    mov $exc_isolate, %eax
    call set_gate
    mov $6, %ebx                 # #UD invalid opcode
    mov $exc_isolate, %eax
    call set_gate
    mov $0x30, %ebx              # syscall gate for ring 3 (DPL=3!)
    mov $syscall_isr, %eax
    call set_gate3
    mov $0x20, %ebx              # IRQ0: timer
    mov $timer_isr, %eax
    call set_gate
    mov $0x21, %ebx              # IRQ1: keyboard
    mov $kbd_isr, %eax
    call set_gate
    mov $0x24, %ebx              # IRQ4: COM1
    mov $com1_isr, %eax
    call set_gate
    mov $0x2c, %ebx              # IRQ12: PS/2 mouse
    mov $mouse_isr, %eax
    call set_gate
    lidt idtr
    popal
    ret

# pic_remap: initialize the 8259 PICs, IRQ0-7 -> INT 0x20-0x27,
#   IRQ8-15 -> INT 0x28-0x2F. Without the remap IRQs collide with the
#   CPU exceptions (IRQ0 == #DF etc.) - the classic.
pic_remap:
    push %eax
    mov $0x11, %al               # ICW1: init + ICW4 follows
    out %al, $0x20
    call io_wait
    out %al, $0xa0
    call io_wait
    mov $0x20, %al               # ICW2 master: base vector 0x20
    out %al, $0x21
    call io_wait
    mov $0x28, %al               # ICW2 slave: base vector 0x28
    out %al, $0xa1
    call io_wait
    mov $0x04, %al               # ICW3 master: slave on IRQ2
    out %al, $0x21
    call io_wait
    mov $0x02, %al               # ICW3 slave: cascade ID 2
    out %al, $0xa1
    call io_wait
    mov $0x01, %al               # ICW4: 8086 mode
    out %al, $0x21
    call io_wait
    out %al, $0xa1
    call io_wait
    mov $0xec, %al               # master mask: only IRQ0,1,4 allowed
    out %al, $0x21
    mov $0xff, %al               # slave mask: everything off
    out %al, $0xa1
    pop %eax
    ret

io_wait:                         # short port write as a delay
    push %eax
    xor %al, %al
    out %al, $0x80
    pop %eax
    ret

# tss_init: fill in the TSS descriptor (GDT slot 0x28) at runtime and
#   load the task register. The TSS gives the CPU the kernel stack
#   (SS0:ESP0) on EVERY ring-3->0 transition. The scheduler sets ESP0
#   freshly before each switch to a ring-3 thread.
# sse_init: enable SSE so the hwtest bandwidth loop can use 16-byte movaps
#   loads (a scalar loop can't saturate L1, so the cache levels look flat).
#   Guarded by CPUID; nothing else in the OS uses XMM, so no save/restore.
sse_init:
    push %eax
    push %ebx
    push %ecx
    push %edx
    mov $1, %eax
    cpuid
    test $0x02000000, %edx        # SSE (EDX bit 25)?
    jz sse_done
    mov %cr0, %eax
    and $0xfffffffb, %eax         # clear EM (no x87 emulation)
    or $0x02, %eax                # set MP
    mov %eax, %cr0
    mov %cr4, %eax
    or $0x600, %eax               # OSFXSR | OSXMMEXCPT
    mov %eax, %cr4
    movb $1, sse_ok
sse_done:
    pop %edx
    pop %ecx
    pop %ebx
    pop %eax
    ret

tss_init:
    pushal
    xor %ecx, %ecx               # fill all 8 per-core TSS descriptors + structs
tsi_l:
    lea gdt+0x28(,%ecx,8), %edi   # EDI -> core ecx's TSS descriptor
    mov %ecx, %eax
    imul $104, %eax
    add $tss, %eax               # EAX = core ecx's TSS base
    mov %ax, 2(%edi)             # desc base 0..15
    push %eax
    shr $16, %eax
    mov %al, 4(%edi)             # base 16..23
    mov %ah, 7(%edi)             # base 24..31
    movw $0x67, (%edi)           # limit 104
    movb $0x89, 5(%edi)          # type: 32-bit TSS, present
    pop %eax
    movw $0x10, 8(%eax)          # SS0 = kernel data
    movw $0x68, 102(%eax)        # I/O bitmap base outside: no ring-3 I/O
    inc %ecx
    cmp $8, %ecx
    jb tsi_l
    call my_core                 # the BSP loads ITS own TSS (0x28 + id*8)
    shl $3, %eax
    add $0x28, %eax
    ltr %ax
    popal
    ret

# --- CPU exceptions: 32 stubs pass their number in EAX and report via
#  a guaranteed-good panic stack (see exc_common). The vector goes in
#  EAX, NOT pushed: if the live ESP is trashed (a ring transition gone
#  wrong, handler recursion) a push would fault again -> double ->
#  triple fault -> silent reboot. EAX needs zero stack access.
.macro EXC n
exc\n:
    cli
    mov $\n, %eax
    jmp exc_common
.endm
EXC 0
EXC 1
EXC 2
EXC 3
EXC 4
EXC 5
EXC 6
EXC 7
EXC 8
EXC 9
EXC 10
EXC 11
EXC 12
EXC 13
EXC 14
EXC 15
EXC 16
EXC 17
EXC 18
EXC 19
EXC 20
EXC 21
EXC 22
EXC 23
EXC 24
EXC 25
EXC 26
EXC 27
EXC 28
EXC 29
EXC 30
EXC 31

exc_common:                      # EAX = vector (from the stub)
    mov $0x1d000, %esp           # panic stack: report even if ESP was junk
    push %eax
    mov $0x10, %ax               # and kernel data segs: report even if a
    mov %ax, %ds                 # nulled/foreign DS got us here
    mov %ax, %es
    pop %eax
    mov %eax, %ebx               # EBX = vector
    mov $msg_exc, %esi
    call puts
    mov %ebx, %eax
    call print_dec32
    mov $msg_exc_thr, %esi       # which world died? (0 = shell)
    call puts
    call my_core ; movzbl cur_thread(%eax), %eax
    call print_dec32
    mov $msg_exc2, %esi
    call puts
exc_halt:
    cli
    hlt
    jmp exc_halt

exc_table:
    .long exc0, exc1, exc2, exc3, exc4, exc5, exc6, exc7
    .long exc8, exc9, exc10, exc11, exc12, exc13, exc14, exc15
    .long exc16, exc17, exc18, exc19, exc20, exc21, exc22, exc23
    .long exc24, exc25, exc26, exc27, exc28, exc29, exc30, exc31

# default_int: silently acknowledge unexpected interrupts
default_int:
    push %eax
    mov $0x20, %al
    out %al, $0x20
    out %al, $0xa0
    pop %eax
    iret

# =====================================================================
#  PAGING: our own page tables, identity mapping 0-32 MB
#  in 4-KB pages. Page 0 stays DELIBERATELY unmapped - every
#  NULL access immediately triggers a page fault (#PF), which we
#  catch. Page directory at PAGE_DIR, 8 page tables from PAGE_TABLES.
# =====================================================================
paging_init:
    pushal
    mov $PAGE_DIR, %edi           # clear the page directory
    xor %eax, %eax
    mov $1024, %ecx
    rep stosl
    mov $PAGE_TABLES, %edi           # 8 page tables: 8192 pages identity
    mov $0x00000003, %eax        # present | writable
    mov $8192, %ecx
pg_pt:
    stosl
    add $0x1000, %eax
    loop pg_pt
    movl $0, PAGE_TABLES             # page 0 out: the NULL guard!
    mov $PAGE_DIR, %edi           # PD entries 0..7 -> the page tables
    mov $0x31007, %eax           # PDE: user bit on - the PTEs gate finely
    mov $8, %ecx
pg_pd:
    stosl
    add $0x1000, %eax
    loop pg_pd
    # Ring-3 view: kernel image (pages 7-0xD) READABLE, but
    # not writable (U=1, W=0). Ring 0 still writes - CR0.WP=0!
    mov $PAGE_TABLES+7*4, %edi
    mov $0x00007005, %eax
    mov $33, %ecx                # pages 7-0x27 (kernel up to ~0x27E00)
pg_img:
    stosl
    add $0x1000, %eax
    loop pg_img
    # User stacks (pages 0x141-0x148): fully writable for ring 3 (moved
    #   out of the kernel's new footprint, USER_STACKS = 0x141000)
    mov $PAGE_TABLES+0x141*4, %edi
    mov $0x00141007, %eax
    mov $8, %ecx
pg_ust:
    stosl
    add $0x1000, %eax
    loop pg_ust
    mov $PAGE_DIR, %eax
    mov %eax, %cr3               # root of the tables
    mov %cr0, %eax
    and $0xfffeffff, %eax        # WP OFF! UEFI firmware leaves it set;
    or $0x80000000, %eax         # ring 0 may write our U=1/W=0 pages
    mov %eax, %cr0               # only with WP=0 (see paging_init). Paging ON
    popal
    ret

# user_pages_init (ABI v2): make the 4 MB-32 MB identity region
#   user-accessible (U=1) so ring-3 C programs can run/heap/stack there.
#   The PTEs (pages 0x400..0x1FFF) are already present|writable from
#   paging_init; we only OR in the USER bit. Driver DMA lives <=0x312FFF
#   (pages 0..0x312) and stays supervisor - untouched here.
user_pages_init:
    pushal
    mov $PAGE_TABLES+0x400*4, %edi   # first PTE for 0x400000
    mov $0x1C00, %ecx                # pages 0x400..0x1FFF (4 MB .. 32 MB)
upi_l:
    orl $0x4, (%edi)                 # set U=1 (present|writable already on)
    add $4, %edi
    loop upi_l
    mov $PAGE_DIR, %eax
    mov %eax, %cr3                   # flush the TLB
    popal
    ret

# pxe_stage: the FIRST thing pm_go does. On the network-boot path the
#   whole pxe.img is in RAM at 0x7C00, so the userspace program AND the
#   M-JPEG clip ride along high in the image:
#     RAM 0x28200 (file sector 259): header "AGUP" + prog_len + clip_sectors
#     RAM 0x28400 (file sector 260): program body (up to USER_BLOB_SECTORS)
#     RAM 0x58400 (after the 384-sector program region): the video clip
#   moved up past the 256-sector kernel (0x27e00) AND past UEFI_INFO
#   (0x28000, written in real mode BEFORE this runs - the header must clear it).
#   Those load addresses overlap kernel structures the boot is about to
#   build (IDT 0x2F000, page tables 0x30000+, kernel stacks 0x41000+),
#   so we must rescue them BEFORE any of that runs.
#   We copy program-region + clip in one shot to PXE_STASH (>18 MB, above
#   the boot RAM self-test, identity-mapped). pxe_blob_load later stages
#   the program to 0x400000; sys_readsec serves the clip as a RAM disk.
#   Magic-gated -> clean no-op on the BIOS-HDD / UEFI paths.
.equ PXE_BLOB_HDR, 0x28200        # header landing (file sector 259)
.equ PXE_BLOB_BODY, 0x28400       # program-region landing (file sector 260)
.equ PXE_STASH,    0x01300000     # 19 MB: safe rescue area (above the 2-18 MB RAM test)
.equ PXE_CLIP_RAM, 0x01330000     # PXE_STASH + USER_BLOB_SECTORS*512 (clip inside the stash)
pxe_stage:
    pushal
    cmpl $0x50554741, PXE_BLOB_HDR   # "AGUP" little-endian?
    jne pst_done
    mov PXE_BLOB_HDR+4, %eax          # program length in bytes
    cmp $0x30000, %eax                # sanity cap 192 KB (= USER_BLOB_SECTORS*512)
    ja pst_done
    mov %eax, pxe_prog_len
    mov PXE_BLOB_HDR+8, %eax          # clip length in sectors
    cmp $2048, %eax                   # sanity cap 1 MB
    jbe pst_cs
    xor %eax, %eax                    # absurd -> treat as no clip
pst_cs:
    mov %eax, ramdisk_sectors
    add $USER_BLOB_SECTORS, %eax      # total = program-region + clip sectors
    shl $7, %eax                      # sectors -> dwords (512/4 = 128)
    mov %eax, %ecx
    cld
    mov $PXE_BLOB_BODY, %esi          # program region at 0x27E00, clip right after
    mov $PXE_STASH, %edi
    rep movsl
    movl $1, pxe_prog_present
pst_done:
    popal
    ret

# pxe_blob_load: stage the rescued program from PXE_STASH to USER_PROG_BASE.
#   Runs after run_selftest (the RAM test would wipe 0x400000); the stash
#   sits above the test region so it survives. No-op unless pxe_stage
#   found a program in the boot image.
pxe_blob_load:
    pushal
    cmpl $1, pxe_prog_present
    jne pbl_done
    mov pxe_prog_len, %ecx
    test %ecx, %ecx
    jz pbl_done
    cld
    mov $PXE_STASH, %esi
    mov $USER_PROG_BASE, %edi
    rep movsb
pbl_done:
    popal
    ret

# ramdisk_read: EBX=LBA, EDI=dst(512 B). Serves the PXE video clip as a
#   read-only RAM disk based at VIDEO_LBA (1024). CF=0 + copies one
#   sector if the LBA is inside the clip, else CF=1 (caller falls back /
#   stops). Lets sys_readsec play the clip on a diskless PXE boot.
ramdisk_read:
    push %eax
    push %ecx
    push %esi
    push %edi
    mov ramdisk_sectors, %ecx
    test %ecx, %ecx
    jz rdr_no
    mov %ebx, %eax
    sub $1024, %eax                   # VIDEO_LBA base
    jb rdr_no                         # LBA < 1024 -> not the clip
    cmp %ecx, %eax
    jae rdr_no                        # LBA >= 1024 + clip_sectors
    shl $9, %eax                      # offset = (LBA-1024) * 512
    add $PXE_CLIP_RAM, %eax
    mov %eax, %esi
    mov $128, %ecx                    # 512 bytes = 128 dwords
    cld
    rep movsl                         # copy clip sector -> dst (EDI)
    pop %edi
    pop %esi
    pop %ecx
    pop %eax
    clc
    ret
rdr_no:
    pop %edi
    pop %esi
    pop %ecx
    pop %eax
    stc
    ret

# =====================================================================
#  KERNEL HEAP: kmalloc/kfree on the arena HEAP_BASE-HEAP_END.
#  First-fit over a singly linked list; every block carries a
#  16-byte header:
#    +0 magic (0xA110C8ED)  +4 size (payload bytes)
#    +8 next (0 = end)      +12 free flag (1=free, 0=used)
#  The arena pages are mapped supervisor-only - ring-3 agents
#  cannot even reach the heap in the first place.
#  Register contracts:
#    heap_init: -                 (preserves everything)
#    kmalloc:   EAX=size          -> EAX=pointer or 0  (preserves rest)
#    kfree:     EAX=pointer       -> EAX=0 ok / 1 no block / 2 double
#                                    free  (preserves rest)
# =====================================================================
# highmem_init: paging_init only mapped 0-32 MB (4 KB pages). Map the RAM
#   ABOVE 32 MB with 4 MB supervisor pages, up to the E820 total (capped at
#   1 GB, safely below any MMIO hole), and relocate the kernel heap into it:
#   256 KB -> tens/hundreds of MB. Needs >=96 MB RAM, else the heap stays low.
highmem_init:
    pushal
    mov (E820_TOTAL), %edx        # detected usable RAM (bytes)
    cmp $0x06000000, %edx         # < 96 MB? keep the small low heap, no highmem
    jb hm_ret
    cmp $0x40000000, %edx         # cap the mapping at 1 GB
    jbe hm_cap
    mov $0x40000000, %edx
hm_cap:
    mov %cr4, %eax
    or $0x10, %eax                # PSE (idempotent)
    mov %eax, %cr4
    shr $22, %edx                 # EDX = number of 4 MB PDEs to cover
    mov $8, %ecx                  # PDE 8 = 32 MB (0..7 done by paging_init)
    mov $0x02000083, %eax         # phys 32 MB | P|W|PS (supervisor)
hm_map:
    cmp %ecx, %edx
    jbe hm_flush
    mov %eax, PAGE_DIR(,%ecx,4)
    add $0x00400000, %eax
    inc %ecx
    jmp hm_map
hm_flush:
    mov $PAGE_DIR, %eax
    mov %eax, %cr3                # reload to pick up the new PDEs
    # relocate the heap: base 64 MB, top = min(total - 16 MB, base + 256 MB)
    movl $0x04000000, heap_base
    mov (E820_TOTAL), %edx
    sub $0x01000000, %edx         # reserve the top 16 MB
    mov $0x14000000, %eax         # cap heap_top at base + 256 MB
    cmp %eax, %edx
    jbe hm_settop
    mov %eax, %edx
hm_settop:
    mov %edx, heap_top
hm_ret:
    popal
    ret

heap_init:
    push %edi
    push %eax
    mov heap_base, %edi
    movl $0xA110C8ED, (%edi)     # one single free block spanning the arena
    mov heap_top, %eax           # size = (top - base) - 16-byte header
    sub %edi, %eax
    sub $16, %eax
    mov %eax, 4(%edi)
    movl $0, 8(%edi)
    movl $1, 12(%edi)
    pop %eax
    pop %edi
    ret

kmalloc:
    push %ebx
    push %ecx
    push %edx
    test %eax, %eax
    jz km_fail
    add $15, %eax                # round up to 16 bytes: that way the
    jc km_fail                   # ...but a near-4GB size wraps here to a tiny
                                 #   demand - reject it instead of handing back a
                                 #   0-byte block that aliases the next header
    and $0xFFFFFFF0, %eax        # headers always stay aligned
    mov %eax, %ecx               # ECX = demand
    mov heap_base, %ebx          # EBX = walking pointer (header)
km_walk:
    cmpl $0xA110C8ED, (%ebx)     # broken list? better return 0
    jne km_fail
    cmpl $1, 12(%ebx)
    jne km_next                  # used -> continue
    cmp %ecx, 4(%ebx)
    jb km_next                   # too small -> continue
    mov 4(%ebx), %edx            # hit. Is a split worth it?
    sub %ecx, %edx
    cmp $32, %edx                # remainder needs header + min. 16 bytes
    jb km_take
    lea 16(%ebx,%ecx), %eax      # place a new free header behind it
    movl $0xA110C8ED, (%eax)
    sub $16, %edx
    mov %edx, 4(%eax)
    mov 8(%ebx), %edx
    mov %edx, 8(%eax)
    movl $1, 12(%eax)
    mov %eax, 8(%ebx)            # link it in, shrink the block
    mov %ecx, 4(%ebx)
km_take:
    movl $0, 12(%ebx)            # mark as used
    lea 16(%ebx), %eax           # pointer to the payload
    jmp km_done
km_next:
    mov 8(%ebx), %ebx
    test %ebx, %ebx
    jnz km_walk
km_fail:
    xor %eax, %eax
km_done:
    pop %edx
    pop %ecx
    pop %ebx
    ret

kfree:
    push %ebx
    push %edx
    lea -16(%eax), %ebx          # back to the header
    cmp heap_base, %ebx          # header must be INSIDE the arena, else
    jb kf_bad                    # the magic check itself would fault
    push %edx                    # (e.g. 'free 123' -> page 0!)
    mov heap_top, %edx
    sub $16, %edx
    cmp %edx, %ebx
    pop %edx
    ja kf_bad
    cmpl $0xA110C8ED, (%ebx)
    jne kf_bad
    cmpl $1, 12(%ebx)
    je kf_double                 # was already free: double free!
    movl $1, 12(%ebx)
kf_merge:                        # merge with free SUCCESSORS
    mov 8(%ebx), %edx
    test %edx, %edx
    jz kf_ok
    cmpl $1, 12(%edx)
    jne kf_ok
    mov 8(%edx), %eax            # swallow the successor: take over next,
    mov %eax, 8(%ebx)            # add sizes + its header,
    mov 4(%edx), %eax
    add $16, %eax
    add %eax, 4(%ebx)
    movl $0, (%edx)              # erase the swallowed magic
    jmp kf_merge
kf_ok:
    xor %eax, %eax
    jmp kf_done
kf_bad:
    mov $1, %eax
    jmp kf_done
kf_double:
    mov $2, %eax
kf_done:
    pop %edx
    pop %ebx
    ret

# =====================================================================
#  PAGE FAULT (#PF, vector 14) - fault isolation like the grown-ups:
#  * If an AGENT faults: only its thread is killed, its task goes
#    to ERROR, the scheduler carries on with the others.
#  * If the SHELL faults: message + jump back to the prompt via the
#    ESP rescue anchor. The system NEVER halts because of a wild pointer.
#  (We never return to the offender, so the error code pushed by
#  the CPU does not need to be cleaned up.)
# =====================================================================
exc_isolate:                     # #DE/#OF/#BR/#UD: no error code, but
    movb $0x0c, cur_attr         # faults shout in red (prompt resets it)
    mov $msg_exc_iso, %esi       # pf_common discards the faulting stack
    call puts                    # anyway -> same kill-the-thread cure
    jmp pf_common
gp_handler:
    movb $0x0c, cur_attr
    mov $msg_gp1, %esi           # protection violation: same cure as #PF
    call puts
    jmp pf_common
pf_handler:
    movb $0x0c, cur_attr
    mov %cr2, %ebx               # CR2 = the faulting address
    mov $msg_pf1, %esi
    call puts
    mov %ebx, %eax
    call phex32
pf_common:
    # Recover-vs-shell is decided purely on cur_thread (0 = the shell), NOT on
    # the saved CPL. This is safe ONLY because kernel code running in agent
    # context - the syscall handlers - never faults: every one validates its
    # ring-3 pointers with sc_chkbuf and otherwise touches only kernel tables
    # between lock acquire/release. If a future syscall path can fault at CPL 0
    # while cur_thread != 0, add a CPL check here (else it would shoot the agent
    # down and abandon the kernel stack, leaking any held tbl_lock/sched_lock).
    push %eax ; call my_core ; cmpb $0, cur_thread(%eax) ; pop %eax
    je pf_shell
    # --- shoot down the agent thread ---
    mov $msg_pf_ag1, %esi
    call puts
    call cur_thr
    dec %ebx                     # EBX = agent slot
    mov %ebx, %eax
    add $0x30, %al
    call putc
    mov $msg_spawn2, %esi        # "] '"
    call puts
    mov agent_names(,%ebx,4), %esi
    call puts
    mov $msg_pf_ag2, %esi
    call puts
    mov %ebx, %esi               # set the agent's task to ERROR
    shl $3, %esi
    add $agents_tbl, %esi
    movzbl 3(%esi), %eax
    cmp $0xff, %al
    je pf_freeslot
    mov %eax, %edi
    shl $4, %edi
    add $tasks_tbl, %edi
    movb $3, 2(%edi)             # status 3 = ERROR
pf_freeslot:
    inc %ebx                     # fx_release wants the TID (slot + 1)
    call fx_release              # a faulting full-screen program releases
    dec %ebx                     #   input + the FB gate it borrowed, repaints
    movb $0, (%esi)              # release the agent slot
    call cur_thr
    movb $0, tcb_state(%ebx)     # remove the thread from the scheduler
    movb $0xFF, tcb_running(%ebx) # and free its core slot (it's dead)
    push %eax ; call my_core ; cmp bsp_apic, %eax ; pop %eax ; jne pf_ap_idle
    push %eax ; mov $sched_lock, %eax ; call spin_lock ; pop %eax
    mov $9, %ecx
pf_next:
    inc %ebx                     # look for the next runnable+free thread
    cmp $9, %ebx
    jb pf_chk
    xor %ebx, %ebx
pf_chk:
    dec %ecx
    js pf_fallback
    cmpb $1, tcb_state(%ebx)
    jne pf_next
    cmpb $0xFF, tcb_running(%ebx)
    jne pf_next
    jmp pf_found
pf_fallback:
    xor %ebx, %ebx               # the shell
pf_found:
    push %ebx ; call my_core ; pop %ebx   # claim under the lock (double-pick race)
    mov %al, tcb_running(%ebx)
    push %eax ; mov $sched_lock, %eax ; call spin_unlock ; pop %eax
    jmp thread_resume            # resume that one's world
pf_ap_idle:
    mov $0xFF, %ebx              # AP: the faulting agent is torn down -> idle this core
    jmp thread_resume
pf_shell:
    mov $msg_pf_sh, %esi
    call puts
    movl $0, pending_ptr         # abort any ';' command chain in progress
    mov shell_safe_esp, %esp     # stack back onto the rescue anchor
    sti
    jmp shell

# =====================================================================
#  TIMER (IRQ0 / INT 0x20) - uptime, status line AND:
#  PREEMPTIVE CONTEXT SWITCH. pushal puts all registers on the
#  stack of the interrupted thread; we save its ESP, look for
#  the next runnable thread (round-robin) and load its ESP.
#  popal+iret then resume THAT one's world - the interrupted
#  thread notices nothing. Thread 0 (shell) is always runnable.
# =====================================================================
timer_isr:
    pushal
    cld
    incl ticks
    call spk_tick                # silence a finished game blip (non-blocking SFX)
    decb stat_cnt
    jnz t_curs
    movb $18, stat_cnt           # ~1x per second
    call draw_status
    call net_poll                # check the network return channel (8 inbox)
    call watchdog_check          # A4: kill agents stuck running too long
t_curs:
    call cursor_tick             # draw the cursor LAST, on top of everything
t_switch:
    call cur_thr      # save the current thread's context
    mov %esp, tcb_esp(,%ebx,4)
    cmpb $1, tcb_state(%ebx)     # release the current thread (if still runnable)
    jne t_lock                   #   so another core may pick it up
    movb $0xFF, tcb_running(%ebx)
t_lock:
    push %eax ; mov $sched_lock, %eax ; call spin_lock ; pop %eax
    mov $9, %ecx                 # scan at most 9 slots, then fall back to shell
t_next:
    inc %ebx
    cmp $9, %ebx
    jb t_check
    xor %ebx, %ebx
t_check:
    dec %ecx
    js t_fallback                # nothing runnable+free -> thread 0
    cmpb $1, tcb_state(%ebx)     # runnable?
    jne t_next
    cmpb $0xFF, tcb_running(%ebx) # not already running on another core?
    jne t_next
    jmp t_found
t_fallback:
    xor %ebx, %ebx               # the shell (always runnable, BSP-pinned)
t_found:
    push %ebx ; call my_core ; pop %ebx   # claim under the lock (close the double-pick
    mov %al, tcb_running(%ebx)            #   race now that APs also run this scheduler)
    push %eax ; mov $sched_lock, %eax ; call spin_unlock ; pop %eax
    mov $0x20, %al               # EOI - before the switch
    out %al, $0x20
    jmp thread_resume

# thread_resume: EBX = next thread. For ring-3 threads first set
#   TSS.ESP0 to that thread's kernel stack top (that is where the
#   CPU lands on every ring-3->0 transition). Then load ESP; popal+iret
#   resume its world - with CS-RPL=3 iret automatically switches
#   back to ring 3, including the user stack.
#
#   We also load the right DATA segments for the target ring BEFORE the
#   iret. This is the bare-metal triple-fault fix: on iret to
#   ring 3 a real CPU NULLs any DS/ES/FS/GS that still holds a DPL-0
#   selector (privilege-leak guard). The kernel ran with 0x10 (DPL 0),
#   so the agent would wake with null segments -> the first memory
#   access (it, or an ISR firing from ring 3) #GPs -> storm -> triple
#   fault -> reboot. QEMU does not null, so it only bit on real silicon.
#   Giving ring-3 threads the user data segs (0x23, DPL 3) means iret
#   leaves them intact; ring-0 threads get 0x10. Both are base-0 4 GB,
#   so kernel code reaches all memory through either.
thread_resume:
    cmp $0xFF, %ebx              # the idle marker (APs only): no TCB to load - go idle
    je tr_idle
    call my_core ; mov %bl, cur_thread(%eax)
    mov %al, tcb_running(%ebx)   # this core now owns thread EBX (multi-core sched)
    incl core_runs(,%eax,4)      # SMP telemetry: count resumes per core (proves AP work)
    test %ebx, %ebx
    jz tr_shell
    mov %ebx, %eax
    shl $12, %eax
    add $KERN_STACKS, %eax           # this thread's kernel stack top
    mov %eax, %edx               # EDX = ESP0; write it to THIS core's TSS.ESP0
    push %ebx                    # (preserve the thread index)
    call my_core
    imul $104, %eax
    add $tss, %eax
    mov %edx, 4(%eax)
    pop %ebx
    mov $0x23, %ax               # ring-3 thread: user data segments
    jmp tr_segs
tr_shell:
    mov $0x10, %ax               # shell / ring-0 thread: kernel data segs
tr_segs:
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
tr_load:
    mov tcb_esp(,%ebx,4), %esp
    popal
    iret
# tr_idle: an AP with nothing to run. Abandon the current (saved) frame, reset to
# this core's private idle stack, and re-enter ap_idle (sti;hlt until the next
# LAPIC tick re-runs the scheduler). Only ever reached on an AP.
tr_idle:
    call my_core
    movb $0xFF, cur_thread(%eax)
    mov 0xFEE00020, %eax         # ESP = 0x60000 + apic_id*0x8000 + 0x8000 (stack top)
    shr $24, %eax
    shl $15, %eax
    mov $0x60000, %esp
    add %eax, %esp
    add $0x8000, %esp
    jmp ap_idle

# =====================================================================
#  SYSCALLS (INT 0x30, DPL=3) - the only door from ring 3 back
#  into the kernel. EAX = number, EBX = argument, return in EAX
#  (written into the saved EAX slot of the pushal frame).
#    0 = yield    sleep one tick (hlt is forbidden in ring 3)
#    1 = claim    find + assign a waiting task of my type
#    2 = progress publish progress 0-100
#    3 = finish   EBX = result; task done, agent idle again
#  Interrupt gate => IF=0 meanwhile: claim/finish are atomic.
# =====================================================================
syscall_isr:
    pushal
    cld                          # interrupt gates clear IF/TF but NOT DF; ring-3
                                 #   sets DF, and the rep movs/stos handlers (15/
                                 #   19-22) would then run BACKWARDS out of the
                                 #   sc_chkbuf-validated window into kernel RAM.
                                 #   Mirror timer_isr - forward string ops always.
    cmp $0, %eax
    je sys_yield
    cmp $1, %eax
    je sys_claim
    cmp $2, %eax
    je sys_progress
    cmp $3, %eax
    je sys_finish
    cmp $4, %eax
    je sys_exit                  # ABI v2 (ring-3 C userspace): teardown
    cmp $5, %eax
    je sys_write                 #   buf, len  -> bytes (putc, COM1-mirrored)
    cmp $6, %eax
    je sys_putc                  #   char      -> 0
    cmp $7, %eax
    je sys_fbinfo                #   dst[16]   -> base,w,h,ppsl
    cmp $8, %eax
    je sys_getkey                #   -         -> ascii / 0 (nonblocking)
    cmp $9, %eax
    je sys_uptime                #   -         -> ticks
    cmp $10, %eax
    je sys_readsec               #   lba,cnt,dst -> sectors / -1
    cmp $11, %eax
    je sys_sbrk                  #   inc       -> old break / -1
    cmp $12, %eax
    je sys_net_tx                #   buf,len   -> sent bytes / -1 (raw Eth frame)
    cmp $13, %eax
    je sys_net_rx                #   buf,max   -> frame len / 0 (one raw frame)
    cmp $14, %eax
    je sys_net_mac               #   buf(6)    -> 0/-1 (our MAC + link state in [6])
    cmp $15, %eax
    je sys_writesec              #   slot,src(512) -> 0/-1 (AgentFS slots ONLY)
    cmp $16, %eax
    je sys_pci                   #   cfgaddr,val,op -> dword (ring-3 PCI access)
    cmp $17, %eax
    je sys_mmiomap               #   phys -> addr/-1 (map 4MB PCD user page)
    cmp $18, %eax
    je sys_taskinfo              #   task idx -> a|b<<16 (its input words)
    cmp $19, %eax
    je sys_console               #   buf(4004) -> [cur_x,cur_y,0,0] + 80x25 grid
    cmp $20, %eax
    je sys_agents                #   buf(192) -> agents_tbl(64) + tasks_tbl(128)
    cmp $21, %eax
    je sys_atp                   #   buf(52)  -> atp_round(4) + atp_mission(48)
    cmp $22, %eax
    je sys_setmission            #   buf,len  -> set atp_mission (max 47 bytes)
    cmp $23, %eax
    je sys_sysinfo               #   buf(64)  -> RAM, MHz, cores, flags, version
    cmp $24, %eax
    je sys_kbgrab                #   -        -> 0: this program owns the keyboard (fg_prog)
    cmp $25, %eax
    je sys_fgrab                 #   1/0      -> 0: own / release the keyboard (fg_prog)
    cmp $26, %eax
    je sys_shell                 #   buf,len  -> 0/-1: type a command line into the shell
    jmp sys_out
sys_yield:
    sti                          # the timer may switch us away here
    hlt
    jmp sys_out
sys_claim:
    mov $tbl_lock, %eax          # two cores in claim/finish at once would
    call spin_lock               #   double-assign a task; IF=0 here, so the
                                 #   hold is bounded (no preemption deadlock)
    push %eax ; call my_core ; movzbl cur_thread(%eax), %edx ; pop %eax
    dec %edx                     # EDX = my agent slot
    mov %edx, %esi
    shl $3, %esi
    add $agents_tbl, %esi
    xor %ebx, %ebx
sc_scan:
    mov %ebx, %edi
    shl $4, %edi
    add $tasks_tbl, %edi
    cmpb $0, (%edi)
    je sc_next
    cmpb $0, 2(%edi)
    jne sc_next
    mov 1(%esi), %al
    cmp 1(%edi), %al
    je sc_take
sc_next:
    inc %ebx
    cmp $8, %ebx
    jb sc_scan
    movl $0xffffffff, 28(%esp)   # nothing found: EAX = -1
    jmp sc_rel
sc_take:
    movb $1, 2(%edi)             # task: running
    mov %dl, 3(%edi)
    movb $1, 2(%esi)             # agent: busy
    mov %bl, 3(%esi)
    movb $0, 6(%esi)
    mov %ebx, 28(%esp)           # EAX = task index
    mov ticks, %eax              # A4: stamp the watchdog start tick
    mov %eax, wd_start(,%edx,4)
sc_rel:
    mov $tbl_lock, %eax
    call spin_unlock
    jmp sys_out
sys_progress:
    cmp $100, %ebx
    jbe sp_ok
    mov $100, %ebx
sp_ok:
    push %eax ; call my_core ; movzbl cur_thread(%eax), %edx ; pop %eax
    dec %edx
    mov ticks, %eax              # progress doubles as a watchdog HEARTBEAT:
    mov %eax, wd_start(,%edx,4)  #   an agent reporting progress is no runaway
    shl $3, %edx                 #   (the ask agent waits minutes on the LLM)
    mov %bl, agents_tbl+6(%edx)
    jmp sys_out
sys_finish:
    mov $tbl_lock, %eax          # same lock as claim: the table mutation
    call spin_lock               #   below must not interleave across cores
    push %eax ; call my_core ; movzbl cur_thread(%eax), %edx ; pop %eax
    dec %edx
    mov %edx, %esi
    shl $3, %esi
    add $agents_tbl, %esi
    movzbl 3(%esi), %eax
    cmp $0xff, %al
    je sf_rel
    mov %eax, %edi
    shl $4, %edi
    add $tasks_tbl, %edi
    mov %ebx, 12(%edi)           # result
    movb $2, 2(%edi)             # done
    call resolve_deps            # unblock any task piped from this one
    mov %edi, notify_task        # remember the task for the notification
    movb $0, 2(%esi)             # agent: idle
    movb $0xff, 3(%esi)
    incw 4(%esi)                 # completed++
    mov $tbl_lock, %eax          # tables consistent - drop the lock BEFORE
    call spin_unlock             #   the slow notification/network path
    # --- tell the user, background-job style: the agent finished and
    #     the result is right here, no need to type 'tasks'.
    #     (popal restores the agent's registers, so we clobber freely.)
    movb $0x0e, cur_attr         # notification in bright yellow
    mov $msg_done1, %esi         # "\r\n>> Agent ["
    call puts
    call my_core ; movzbl cur_thread(%eax), %eax
    dec %eax
    add $0x30, %al
    call putc                    # agent slot digit
    mov $msg_done2, %esi         # "] "
    call puts
    mov notify_task, %edi
    movzbl 1(%edi), %eax         # task type -> name
    mov type_names(,%eax,4), %esi
    call puts
    mov $msg_done3, %esi         # " done = "
    call puts
    mov notify_task, %edi
    mov 12(%edi), %eax           # result
    call print_dec32
    mov $msg_done4, %esi         # "\r\n"
    call puts
    movb $0x0a, cur_attr         # back to body green
    call nh_pushdone             # push the result to the dev box too
    jmp sys_out
sf_rel:                          # finish with no task: just drop the lock
    mov $tbl_lock, %eax
    call spin_unlock
sys_out:
    popal
    iret

# =====================================================================
#  ABI v2 syscall handlers (ring-3 C userspace). Entered after pushal
#  with the user's args still live in EBX/ECX/EDX. Return value goes
#  into the saved-EAX slot 28(%esp); every handler ends `jmp sys_out`.
#  pushal frame: 0=EDI 4=ESI 8=EBP 12=ESP 16=EBX 20=EDX 24=ECX 28=EAX.
# =====================================================================

# sc_chkbuf: EAX=ptr, ECX=len. CF=1 unless [ptr, ptr+len) lies wholly
#   inside [USER_PROG_BASE, USER_STACK_TOP). Mandatory on every user
#   pointer - without it a ring-3 program hands a kernel pointer to
#   READ_SECTORS and overwrites the kernel (priv-esc). Preserves GPRs.
sc_chkbuf:
    push %edx
    cmp $USER_PROG_BASE, %eax
    jb scb_bad
    mov %eax, %edx
    add %ecx, %edx               # end = ptr + len
    jc scb_bad                   # 32-bit wrap
    cmp $USER_STACK_TOP, %edx
    ja scb_bad
    pop %edx
    clc
    ret
scb_bad:
    pop %edx
    stc
    ret

# 4 = EXIT: tear this ring-3 thread down (free its agent slot, drop it
#   from the scheduler) and switch back to the shell. Never returns.
sys_exit:
    call cur_thr
    test %ebx, %ebx
    jz sys_out                   # the shell itself never exits
    call fx_release              # EBX = TID: release input + the borrowed FB gate, repaint
    lea -1(%ebx), %eax           # agent slot = TID - 1
    shl $3, %eax
    movb $0, agents_tbl(%eax)    # free the agent slot
    movb $0, tcb_state(%ebx)     # remove the thread from the scheduler
    call my_core                 # which core am I exiting on?
    cmp bsp_apic, %eax
    jne se_idle
    xor %ebx, %ebx               # BSP: resume the shell (thread 0, always runnable)
    jmp thread_resume
se_idle:
    mov $0xFF, %ebx              # AP: go idle - its timer picks up the next agent
    jmp thread_resume

# 5 = WRITE: EBX=buf, ECX=len -> EAX=bytes written (-1 on bad buffer).
sys_write:
    mov %ebx, %eax
    call sc_chkbuf               # validate [EBX, EBX+ECX)
    jc scw_bad
    mov %ecx, %edx               # EDX = length (return value; ECX is the counter)
scw_loop:
    test %ecx, %ecx
    jz scw_done
    movzbl (%ebx), %eax
    cmp $0x01, %al               # 0x01 <attr>: colour escape, same as puts_attr
    jne scw_put                  #   (lets ring-3 'fetch' paint the console; the
    cmp $1, %ecx                 #   program restores the attribute it found via
    jbe scw_done                 #   SYSINFO). A lone trailing 0x01 is dropped.
    movb 1(%ebx), %al
    mov %al, cur_attr
    add $2, %ebx
    sub $2, %ecx
    jmp scw_loop
scw_put:
    call putc                    # putc preserves all GPRs (pushfl/pushal)
    inc %ebx
    dec %ecx
    jmp scw_loop
scw_done:
    mov %edx, 28(%esp)           # EAX = bytes written = original length
    jmp sys_out
scw_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 6 = PUTC: EBX=char -> 0.
sys_putc:
    movzbl %bl, %eax
    call putc
    movl $0, 28(%esp)
    jmp sys_out

# 7 = FBINFO: EBX=dst(16 bytes) -> [base, width, height, ppsl]; 0/-1.
sys_fbinfo:
    mov %ebx, %eax
    mov $16, %ecx
    call sc_chkbuf
    jc fbi_bad
    mov fb_base, %eax
    mov %eax, (%ebx)
    mov fb_w, %eax
    mov %eax, 4(%ebx)
    mov fb_h, %eax
    mov %eax, 8(%ebx)
    mov fb_ppsl, %eax
    mov %eax, 12(%ebx)
    movl $0, 28(%esp)
    jmp sys_out
fbi_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 19 = CONSOLE: snapshot the text console for the ring-3 compositor. EBX = a
#   >=4004-byte user buffer; we write [0]=cur_x, [1]=cur_y, [2..3]=0, then the
#   80x25x2 char/attr grid from 0xB8000. The VGA buffer itself stays
#   supervisor-only (the 'scan b8000' protection), so the compositor reads the
#   console through this copy instead of mapping 0xB8000 into ring 3.
sys_console:
    mov %ebx, %eax
    mov $4004, %ecx
    call sc_chkbuf
    jc scon_bad
    movzbl cur_x, %eax
    mov %al, (%ebx)
    movzbl cur_y, %eax
    mov %al, 1(%ebx)
    movzbl fg_prog, %eax         # byte 2 = a foreground game owns the screen?
    mov %al, 2(%ebx)             #   the compositor steps aside (stops drawing) so
    movb $0, 3(%ebx)             #   the game has the FB; redraws when it exits
    mov $CONSOLE_SHADOW, %esi     # the readable mirror, not graphics-mode 0xB8000
    lea 4(%ebx), %edi
    mov $1000, %ecx              # 4000 bytes = 1000 dwords
    rep movsl
    movl $0, 28(%esp)
    jmp sys_out
scon_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 20 = AGENTS: snapshot the agent + task tables for the compositor's live
#   "AGENTS" panel. EBX = >=192-byte user buffer. agents_tbl (8x8 = 64 B) is
#   immediately followed by tasks_tbl (8x16 = 128 B), so one 192-byte copy
#   gives ring-3 every agent's type/status/task and every task's result.
sys_agents:
    mov %ebx, %eax
    mov $192, %ecx
    call sc_chkbuf
    jc sag_bad
    mov $agents_tbl, %esi
    mov %ebx, %edi
    mov $48, %ecx                # 192 bytes = 48 dwords
    rep movsl
    movl $0, 28(%esp)
    jmp sys_out
sag_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 21 = ATP: copy the autopilot telemetry (round count + current mission)
#   to ring 3, so httpd can report the loop's liveness over HTTP like the
#   UDP STATUS reply does. buf(52) = [round:4][mission:48].
sys_atp:
    mov %ebx, %eax
    mov $52, %ecx
    call sc_chkbuf
    jc sag_bad
    mov atp_round, %eax
    mov %eax, (%ebx)             # +0 round count
    mov $atp_mission, %esi
    lea 4(%ebx), %edi
    mov $48, %ecx
    rep movsb                    # +4 mission text (48 bytes, NUL-padded)
    movl $0, 28(%esp)
    jmp sys_out

# 22 = SETMISSION: EBX=buf, ECX=len -> set current mission text, 0/-1.
#   The mission buffer is 48 bytes including the NUL; longer inputs are refused
#   by callers that care about preserving the complete text. Kernel-side we
#   clamp defensively, validate the copied slice, then NUL-pad the whole field.
sys_setmission:
    cmp $47, %ecx
    jbe ssm_len_ok
    mov $47, %ecx
ssm_len_ok:
    push %ecx                    # keep clamped length across sc_chkbuf
    mov %ebx, %eax
    call sc_chkbuf
    jc ssm_bad_pop
    mov $atp_mission, %edi
    mov $48, %ecx
    xor %eax, %eax
    rep stosb
    pop %ecx
    mov %ebx, %esi
    mov $atp_mission, %edi
    rep movsb
    movl $0, 28(%esp)
    jmp sys_out
ssm_bad_pop:
    pop %ecx
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 23 = SYSINFO: EBX = >=64-byte user buffer -> 0/-1. The read-only facts a
#   ring-3 system card (user/fetch.c) cannot get on its own: ring 3 may not
#   read E820_TOTAL or the kernel's variables, and cpuid gives no RAM size.
#     +0  usable RAM bytes (E820)      +4  cpu_mhz (0 until hwtest/cputest)
#     +8  cpu_count (SMP, 1 = off)     +12 cur_attr (console colour to restore)
#     +13 boot path: 0 BIOS, 1 UEFI, 2 PXE   +14 net_present (0 none, NIC id)
#     +15 fs_armed (diskon)            +16 kernel content bytes (__content_end)
#     +20 ticks since boot             +24..+63 version/name string (NUL-padded,
#                                        from nh_rep_pfx: "AgentOS/32 vX.YZ ")
sys_sysinfo:
    mov %ebx, %eax
    mov $64, %ecx
    call sc_chkbuf
    jc sag_bad
    mov %ebx, %edi
    xor %eax, %eax
    mov $16, %ecx
    rep stosl                    # zero the whole block first
    mov (E820_TOTAL), %eax
    mov %eax, (%ebx)
    mov cpu_mhz, %eax
    mov %eax, 4(%ebx)
    mov cpu_count, %eax
    mov %eax, 8(%ebx)
    mov cur_attr, %al
    mov %al, 12(%ebx)
    xor %eax, %eax
    cmpb $0, boot_uefi
    je ssi_nouefi
    mov $1, %al
ssi_nouefi:
    cmpl $0, pxe_prog_present
    je ssi_nopxe
    mov $2, %al
ssi_nopxe:
    mov %al, 13(%ebx)
    mov net_present, %al
    mov %al, 14(%ebx)
    mov fs_armed, %al
    mov %al, 15(%ebx)
    movl $__content_end - 0x7c00, 16(%ebx)
    mov ticks, %eax
    mov %eax, 20(%ebx)
    mov $nh_rep_pfx, %esi
    lea 24(%ebx), %edi
    mov $18, %ecx                # "AgentOS/32 v2.87 " + NUL (18 bytes)
    rep movsb
    movl $0, 28(%esp)
    jmp sys_out

# 24 = KBGRAB: the calling ring-3 program takes the keyboard, exactly like
#   the 'snake' launcher does for a game (fg_prog): keys go ONLY to the
#   SYS_GETKEY ring, not to the shell's line editor - otherwise everything
#   typed into a full-screen program (chat, edit, sysmon) would also be run
#   as shell commands. sys_exit/kill/#PF release it again via fx_release,
#   which also repaints the desktop. No release syscall: a program that
#   wants the keyboard back in the shell's hands simply exits.
#   It also takes the FRAMEBUFFER: while the program runs the kernel must not
#   mirror console text, the status line or the desktop panels into the FB
#   (the old games get overdrawn by them). That gate already exists for the
#   ring-3 compositor (compositor_active), so the grab sets it when nobody
#   holds it and records the borrowing thread in fb_owner (shared with the
#   'forest' launcher); fx_release returns the gate only when THAT thread
#   goes away. If the Dark Glass compositor (or forest) already holds the
#   gate, the grab just shares it and releases nothing on exit.
sys_kbgrab:
    movb $1, fg_prog
    cmpb $0, compositor_active
    jne skg_done
    call cur_thr                 # EBX = TID of the caller
    mov %bl, fb_owner
    movb $1, compositor_active
skg_done:
    movl $0, 28(%esp)
    jmp sys_out

# 25 = FGRAB: EBX=1 -> the same grab as 24 KBGRAB (keyboard + framebuffer
#   gate, owner recorded in fb_owner) - FGRAB(1) IS KBGRAB, one mechanism.
#   EBX=0 -> give both back early (the app keeps running, e.g. www/files/cast
#   before printing their quit line): fx_release with the caller's TID, so
#   only the owner releases the gate, then fg_release repaints. Exit, kill and
#   #PF release through the same fx_release anyway.
sys_fgrab:
    test %ebx, %ebx
    jnz sys_kbgrab
    call cur_thr                 # EBX = TID of the caller
    call fx_release
    movl $0, 28(%esp)
    jmp sys_out

# 26 = SHELL: EBX=buf, ECX=len (<= 60) -> type the bytes plus Enter into the
#   shell's keyboard buffer, exactly as if a user had typed them: readline
#   echoes and the shell executes the line. This is how the guided tour runs
#   real commands ('spawn prime', 'task prime 100') and then reads the result
#   back through SYS_CONSOLE. Bypasses the ring-3 key ring (fg_prog). 0 / -1.
sys_shell:
    cmp $60, %ecx
    ja ssh_bad
    mov %ebx, %eax
    call sc_chkbuf
    jc ssh_bad
    mov %ebx, %esi
ssh_loop:
    test %ecx, %ecx
    jz ssh_cr
    lodsb
    call ssh_push
    dec %ecx
    jmp ssh_loop
ssh_cr:
    mov $0x0d, %al
    call ssh_push
    movl $0, 28(%esp)
    jmp sys_out
ssh_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out
ssh_push:                        # AL -> kbuf (AH = 0: no scancode); dropped when full
    movzbl kb_head, %ebx
    mov %bl, %dl
    inc %dl
    and $63, %dl
    cmp kb_tail, %dl
    je ssh_full
    xor %ah, %ah
    mov %ax, kbuf(,%ebx,2)
    mov %dl, kb_head
ssh_full:
    ret

# 8 = GETKEY: nonblocking pop from the ring-3 key ring -> ASCII / 0.
sys_getkey:
    movzbl kr_tail, %ebx
    mov kr_head, %al
    cmp %bl, %al
    je gk_empty
    movzbl key_ring(%ebx), %eax
    inc %bl
    and $63, %bl
    mov %bl, kr_tail
    mov %eax, 28(%esp)
    jmp sys_out
gk_empty:
    movl $0, 28(%esp)
    jmp sys_out

# 9 = UPTIME: -> timer ticks.
sys_uptime:
    mov ticks, %eax
    mov %eax, 28(%esp)
    jmp sys_out

# 10 = READ_SECTORS: EBX=LBA, ECX=count, EDX=dst -> sectors read / -1.
sys_readsec:
    cmp $0x10000, %ecx           # cap count at 64K sectors (32 MB):
    jae rs_bad                   #   without this, count*512 overflows 32-bit ->
    push %ecx                    #   sc_chkbuf validates a tiny/zero size while
    mov %ecx, %eax               #   rs_loop still reads the huge original count
    shl $9, %eax                 # count * 512 bytes (no overflow now: count<64K)
    mov %eax, %ecx
    mov %edx, %eax               # EAX = dst pointer
    call sc_chkbuf
    pop %ecx
    jc rs_bad
    push %ebp
    xor %ebp, %ebp               # EBP = sectors read
rs_loop:
    test %ecx, %ecx
    jz rs_done
    mov %ebx, %eax               # AX = LBA (ata_read takes a 16-bit LBA)
    mov %edx, %edi               # EDI = destination
    call ata_read                # preserves all GPRs; CF=1 on error
    jnc rs_next
    call ramdisk_read            # no disk -> try the PXE video RAM disk (EBX,EDI)
    jc rs_done                   #   not in the RAM disk either -> stop
rs_next:
    inc %ebx                     # next sector
    add $512, %edx               # next 512-byte slot
    inc %ebp
    dec %ecx
    jmp rs_loop
rs_done:
    mov %ebp, %edx               # EDX = sectors read (return value)
    pop %ebp                     # restore EBP first - stack back to normal so
    mov %edx, 28(%esp)           #   28(%esp) is the saved-EAX slot again
    jmp sys_out
rs_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 11 = SBRK: EBX=increment -> old break / -1. Bump allocator inside
#   [USER_HEAP_BASE, USER_HEAP_END).
sys_sbrk:
    mov user_brk, %eax           # EAX = old break (the return value)
    mov %eax, %edx
    add %ebx, %edx               # EDX = new break
    jc sb_bad                    # wrap
    cmp $USER_HEAP_END, %edx
    ja sb_bad
    cmp $USER_HEAP_BASE, %edx
    jb sb_bad                    # shrank below the arena
    mov %edx, user_brk
    mov %eax, 28(%esp)
    jmp sys_out
sb_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 12 = NET_TX: EBX=frame buf, ECX=len -> bytes sent / -1. Sends a raw Ethernet
#   frame the userspace stack built (ARP/IP/TCP all live in Ring 3).
sys_net_tx:
    cmpb $0, net_present
    je snt_bad
    cmp $14, %ecx                # at least an Ethernet header
    jb snt_bad
    cmp $1600, %ecx
    ja snt_bad
    mov %ebx, %eax
    call sc_chkbuf               # validate [EBX, EBX+ECX)
    jc snt_bad
    mov ticks, %eax              # tell net_poll to yield the RX ring to us
    mov %eax, net_last_syscall
    mov %ebx, %eax               # net_send: EAX=frame, ECX=len
    call net_send
    mov %ecx, 28(%esp)           # return the length sent
    jmp sys_out
snt_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 13 = NET_RX: EBX=buf, ECX=maxlen (>=1600) -> frame len / 0 (nonblocking).
#   Pops one raw Ethernet frame from the NIC ring into the user buffer.
sys_net_rx:
    cmp $1600, %ecx              # buffer must hold a full frame
    jb snr_zero
    mov %ebx, %eax
    call sc_chkbuf
    jc snr_zero
    mov ticks, %eax
    mov %eax, net_last_syscall
    mov %ebx, %edi
    call net_rx_one              # EAX = frame length or 0
    mov %eax, 28(%esp)
    jmp sys_out
snr_zero:
    movl $0, 28(%esp)
    jmp sys_out

# 14 = NET_MAC: EBX=buf(7) -> 0/-1. [0..5]=our MAC, [6]=1 if a NIC is present.
sys_net_mac:
    mov %ebx, %eax
    mov $7, %ecx
    call sc_chkbuf
    jc snm_bad
    mov nic_mac, %eax            # 6 MAC bytes (4+2)
    mov %eax, (%ebx)
    movzwl nic_mac+4, %eax
    mov %ax, 4(%ebx)
    movb $0, 6(%ebx)
    cmpb $0, net_present
    je snm_ok
    movb $1, 6(%ebx)
snm_ok:
    movl $0, 28(%esp)
    jmp sys_out
snm_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 15 = WRITE_SLOT: EBX=AgentFS slot 0-7, ECX=src (512 B) -> 0 / -1.
#   The ONLY disk-write door for ring 3, deliberately narrow: requires
#   the diskon latch (fs_armed, same protection as save/del), exactly
#   one sector, and only the 8 AgentFS slot LBAs (257+slot; the medium
#   marker sits at 256). Exists so llmscript can persist an LLM-written
#   script that 'script <slot>' then executes - the LLM writes software
#   directly into the running OS.
sys_writesec:
    cmpb $0, fs_armed
    je ws_bad
    cmp $8, %ebx
    jae ws_bad
    mov %ecx, %esi               # ESI = user source buffer
    mov %ecx, %eax               # validate [src, src+512)
    mov $512, %ecx
    call sc_chkbuf
    jc ws_bad
    lea 257(%ebx), %eax          # AX = LBA (same base as fs_slot_arg)
    call ata_write               # CF=1 on error
    jc ws_bad
    movl $0, 28(%esp)
    jmp sys_out
ws_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 16 = PCI_CFG: EBX=config addr (0x80000000|bus<<16|dev<<11|fn<<8|reg),
#   ECX=value, EDX=1 write / 0 read -> EAX=dword read / 0. Lets a ring-3
#   driver (HDA in C) probe and program PCI devices. Pragmatic door:
#   user programs ship inside the OS image, they are not foreign code.
sys_pci:
    test $0x80000000, %ebx       # must be a config-space address
    jz spc_bad
    mov %ebx, %eax
    cmp $1, %edx
    je spc_w
    call pci_read
    mov %eax, 28(%esp)
    jmp sys_out
spc_w:
    call pci_write               # EAX=addr, ECX=value
    movl $0, 28(%esp)
    jmp sys_out
spc_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 17 = MMIO_MAP: EBX=phys MMIO addr -> EAX=usable addr / -1. Maps the
#   containing 4 MB page uncached (PCD, like ahci_mapbar) and USER-
#   accessible, so the ring-3 HDA driver can reach its BAR0. Refuses
#   anything below 32 MB - that is RAM and holds the kernel.
sys_mmiomap:
    mov (E820_TOTAL), %eax        # reject any page INSIDE mapped system RAM: the kernel
    cmp $0x40000000, %eax         #   maps RAM 0..min(total,1GB) (paging_init+highmem_init)
    jbe smm_rt                    #   incl. the relocated high heap (heap_base 64 MB). A
    mov $0x40000000, %eax         #   ring-3 sys_mmiomap(<heap-phys>) would otherwise map
smm_rt:                           #   the kernel heap US=1/RW = isolation break (audit finding).
    cmp $0x2000000, %eax          # keep a 32 MB minimum floor so tiny-RAM VMs (whose RAM
    jae smm_fl                    #   ends below 32 MB) still map device BARs >= 32 MB.
    mov $0x2000000, %eax
smm_fl:
    cmp %eax, %ebx               # device BARs live in the PCI hole ABOVE RAM -> allowed
    jb smm_bad
    mov %ebx, %ecx
    shr $22, %ecx
    mov %ebx, %eax
    and $0xffc00000, %eax
    or $0x97, %eax               # P|RW|US|PS|PCD - uncached user MMIO
    mov %eax, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax               # CR4.PSE (idempotent)
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3               # flush TLB
    mov %ebx, 28(%esp)
    jmp sys_out
smm_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# 18 = TASK_INFO: EBX=task idx -> EAX = a | b<<16 (the task's input
#   words). The ring-3 ask agent fetches its claimed task's slot arg
#   this way (tasks_tbl moves with every build, so no hardcoded reads).
sys_taskinfo:
    cmp $8, %ebx
    jae ti_bad
    mov %ebx, %eax
    shl $4, %eax
    mov tasks_tbl+4(%eax), %eax
    mov %eax, 28(%esp)
    jmp sys_out
ti_bad:
    movl $0xffffffff, 28(%esp)
    jmp sys_out

# resolve_deps: agent pipelines. AL = the task that just finished,
#   BX = its result. Any task blocked (status 4) waiting on it gets the
#   result as its input (+4) and becomes runnable (status 0) - so the
#   next agent picks it up automatically. One producer can feed many.
resolve_deps:
    pushal
    movzbl %al, %ecx              # ECX = producer task index
    xor %eax, %eax
rd_l:
    mov %eax, %edx
    shl $4, %edx
    lea tasks_tbl(%edx), %edx
    cmpb $1, (%edx)               # used?
    jne rd_n
    cmpb $4, 2(%edx)              # blocked?
    jne rd_n
    movzbl 9(%edx), %esi          # its dependency
    cmp %ecx, %esi
    jne rd_n
    mov %bx, 4(%edx)              # input = producer's result (low word)
    movb $0xff, 9(%edx)           # dependency satisfied
    movb $0, 2(%edx)              # -> waiting (an agent can claim it now)
rd_n:
    inc %eax
    cmp $8, %eax
    jb rd_l
    popal
    ret

# watchdog_check: A4. Once a second (from the timer ISR) scan busy agents;
#   if one has been running its task longer than WD_BUDGET ticks it is a
#   runaway (infinite loop in ring 3 - preemption keeps the box alive but
#   the agent never finishes). Kill it: task -> ERROR, free the agent,
#   drop its thread from the scheduler (next switch skips it). Like the
#   #PF/#GP isolation, but for "never returns" instead of "faulted".
.equ WD_BUDGET, 540              # ~30 s at 18 ticks/s (normal tasks: ~25 ticks)
.equ WAIT_BUDGET, 540            # 'wait' kills a program that goes ~30 s with no
                                 #   sys_progress heartbeat (a slow LLM call heartbeats)
watchdog_check:
    pushal
    xor %ebx, %ebx
wd_l:
    lea agents_tbl(,%ebx,8), %esi
    cmpb $1, (%esi)              # used?
    jne wd_n
    cmpb $1, 2(%esi)             # busy (running a task)?
    jne wd_n
    mov ticks, %eax
    sub wd_start(,%ebx,4), %eax  # ticks since it claimed the task
    cmp $WD_BUDGET, %eax
    jb wd_n
    movzbl 3(%esi), %eax         # its task -> ERROR
    cmp $0xff, %al
    je wd_ka
    push %ebx
    mov %eax, %ebx
    shl $4, %ebx
    movb $3, tasks_tbl+2(%ebx)
    movb $0xff, tasks_tbl+3(%ebx)
    pop %ebx
wd_ka:
    movb $0, (%esi)              # free the agent slot
    movb $0xff, 3(%esi)
    lea 1(%ebx), %ecx            # its thread = slot+1
    movb $0, tcb_state(%ecx)     # remove from the scheduler
    movb $0x0c, cur_attr         # notify in red
    mov $msg_wd1, %esi           # "\r\n!! Agent ["
    call puts
    mov %ebx, %eax
    add $0x30, %al
    call putc
    mov $msg_wd2, %esi           # "] watchdog-killed (ran too long).\r\n"
    call puts
    movb $0x0a, cur_attr
    mov $logm_wd, %esi           # record it in the kernel log
    call log_str
wd_n:
    inc %ebx
    cmp $8, %ebx
    jb wd_l
    popal
    ret

# =====================================================================
#  KEYBOARD DRIVER (IRQ1 / INT 0x21, port 0x60)
# =====================================================================
kbd_isr:
    pushal
    in $0x60, %al
    cmp $0xe0, %al
    jne kb_noe0
    movb $1, kb_e0
    jmp kb_eoi
kb_noe0:
    test $0x80, %al
    jz kb_make
    and $0x7f, %al
    cmp $0x2a, %al
    je kb_shup
    cmp $0x36, %al
    je kb_shup
    cmp $0x1d, %al               # left Ctrl released
    je kb_ctup
    movb $0, kb_e0
    jmp kb_eoi
kb_shup:
    movb $0, kb_shift
    movb $0, kb_e0
    jmp kb_eoi
kb_ctup:
    movb $0, kb_ctrl
    movb $0, kb_e0
    jmp kb_eoi
kb_make:
    cmpb $0, kb_e0
    je kb_norm
    movb $0, kb_e0
    cmp $0x48, %al               # E0 arrows: up/left/right/down (C1)
    je kb_arrow
    cmp $0x4b, %al               # left
    je kb_arrow
    cmp $0x4d, %al               # right
    je kb_arrow
    cmp $0x50, %al               # down
    je kb_arrow
    cmp $0x47, %al               # Home, End, PgUp, PgDn, Delete: the editor
    je kb_arrow                  #   keys, delivered scancode-only like the
    cmp $0x4f, %al               #   arrows (readline ignores them, the ring-3
    je kb_arrow                  #   key ring gets 0x80|scancode)
    cmp $0x49, %al
    je kb_arrow
    cmp $0x51, %al
    je kb_arrow
    cmp $0x53, %al
    je kb_arrow
    cmp $0x35, %al               # keypad '/'
    jne kb_eoi
    mov $0x2f, %al
    jmp kb_pushchar
kb_arrow:
    mov %al, %ah                 # AH = scancode (0x48/0x4b/0x4d/0x50), AL = 0
    xor %al, %al                 #   readline uses 0x48 for history; games read
    jmp kb_push                  #   the scancode for steering
kb_norm:
    cmp $0x2a, %al
    je kb_shdn
    cmp $0x36, %al
    je kb_shdn
    cmp $0x1d, %al               # left Ctrl pressed
    je kb_ctdn
    cmp $0x48, %al
    je kb_arrow
    cmp $0x4a, %al               # keypad '-'
    je kb_minus
    cmp $0x4e, %al               # keypad '+'
    je kb_plus
    cmp $0x3a, %al
    jae kb_eoi
    mov %al, %ah                 # remember the scancode
    movzbl %al, %ebx
    cmpb $0, kb_shift
    je kb_tbl
    mov kbmap_sh_ptr, %edx       # active layout ('kbd de|us')
    mov (%edx,%ebx), %al
    jmp kb_have
kb_tbl:
    mov kbmap_ptr, %edx
    mov (%edx,%ebx), %al
kb_have:
    test %al, %al
    jz kb_eoi
    cmpb $0, kb_ctrl             # Ctrl+letter -> the control code (^S = 0x13,
    je kb_push                   #   ^Q = 0x11) - but ONLY for a foreground
    cmpb $0, fg_prog             #   ring-3 program (edit/chat); the shell's
    je kb_push                   #   line editor never sees control bytes
    mov %al, %cl
    or $0x20, %cl                # fold case
    cmp $0x61, %cl
    jb kb_push
    cmp $0x7a, %cl
    ja kb_push
    sub $0x60, %cl
    mov %cl, %al
    jmp kb_push
kb_minus:
    mov $0x2d, %al
    jmp kb_pushchar
kb_plus:
    mov $0x2b, %al
    jmp kb_pushchar
kb_shdn:
    movb $1, kb_shift
    jmp kb_eoi
kb_ctdn:
    movb $1, kb_ctrl
    jmp kb_eoi
kb_pushchar:
    mov $0, %ah
kb_push:
    call push_key
kb_eoi:
    mov $0x20, %al
    out %al, $0x20
    popal
    iret

# =====================================================================
#  PS/2 MOUSE DRIVER (IRQ12 / INT 0x2C, 8042 aux device) + a framebuffer
#  cursor. The mouse ISR assembles 3-byte packets and updates mouse_x/y;
#  the timer ISR blits a 16x16 arrow at that position (erasing the old
#  one by re-rendering the console cells from 0xB8000, or painting black
#  outside the text grid). All 8042 waits are bounded, so a box with no
#  PS/2 mouse simply leaves mouse_present=0 and no cursor.
# =====================================================================
ms_wait_in:                      # wait until the 8042 input buffer is empty
    push %ecx
    mov $0x100000, %ecx
mwi_l:
    in $0x64, %al
    test $0x02, %al
    jz mwi_ok
    dec %ecx
    jnz mwi_l
    pop %ecx
    stc
    ret
mwi_ok:
    pop %ecx
    clc
    ret
ms_wait_out:                     # wait until the output buffer is full
    push %ecx
    mov $0x100000, %ecx
mwo_l:
    in $0x64, %al
    test $0x01, %al
    jnz mwo_ok
    dec %ecx
    jnz mwo_l
    pop %ecx
    stc
    ret
mwo_ok:
    pop %ecx
    clc
    ret
ms_cmd64:                        # send command AL to port 0x64
    mov %al, %ah
    call ms_wait_in
    mov %ah, %al
    out %al, $0x64
    ret
ms_write60:                      # write data AL to port 0x60
    mov %al, %ah
    call ms_wait_in
    mov %ah, %al
    out %al, $0x60
    ret
ms_read:                         # read a byte from 0x60 into AL (CF=timeout)
    call ms_wait_out
    jc msr_to
    in $0x60, %al
    clc
    ret
msr_to:
    stc
    ret
ms_send:                         # send command AL to the mouse (0xD4), eat ACK
    mov %al, %ah
    push %ax
    movb $0xd4, %al
    call ms_cmd64
    pop %ax
    mov %ah, %al
    call ms_write60
    call ms_read
    ret
ms_flush:                        # drain any pending output bytes (bounded)
    push %ecx
    mov $32, %ecx
msf_l:
    in $0x64, %al
    test $0x01, %al
    jz msf_d
    in $0x60, %al
    dec %ecx
    jnz msf_l
msf_d:
    pop %ecx
    ret

mouse_init:
    pushal
    movb $0, mouse_present
    in $0x64, %al                # no 8042 at all (legacy-free server boards):
    cmp $0xff, %al               #   status floats to 0xFF = "data ready" forever,
    je mi_fail                   #   mouse_poll would spin on it in the idle loop
    call ms_flush
    movb $0xa8, %al              # enable the auxiliary (mouse) device
    call ms_cmd64
    movb $0xff, %al              # reset the mouse (real HW often needs it):
    call ms_send                 #   eats the 0xFA ACK
    call ms_read                 #   0xAA self-test result
    call ms_read                 #   0x00 device id
    movb $0x20, %al              # read controller config byte
    call ms_cmd64
    call ms_read
    jc mi_fail
    or  $0x02, %al               # bit1: enable the IRQ12 (aux) interrupt
    and $0xdf, %al               # bit5=0: enable the mouse clock
    mov %al, ms_cfg
    movb $0x60, %al              # write controller config byte
    call ms_cmd64
    mov ms_cfg, %al
    call ms_write60
    movb $0xf6, %al              # mouse: set defaults
    call ms_send
    movb $0xf4, %al              # mouse: enable data reporting
    call ms_send
    in $0x21, %al                # unmask the cascade IRQ2 on the master PIC
    and $0xfb, %al
    out %al, $0x21
    in $0xa1, %al                # unmask IRQ12 (bit4) on the slave PIC
    and $0xef, %al
    out %al, $0xa1
    movb $1, mouse_present
    movb $0, mouse_phase
    mov fb_w, %eax               # center the cursor
    shr $1, %eax
    mov %eax, mouse_x
    mov fb_h, %eax
    shr $1, %eax
    mov %eax, mouse_y
    movl $0xffffffff, mouse_px   # sentinel: force the first draw
mi_fail:
    popal
    ret

mouse_isr:                       # IRQ12 path (when the controller raises it)
    pushal
    incl mouse_irqs
    in $0x64, %al                # byte still there? the idle-loop poller may have
    test $0x01, %al              #   taken it already - a blind read then returns a
    jz mi_eoi                    #   stale byte and desyncs the 3-byte packets
    in $0x60, %al
    call mouse_byte
mi_eoi:
    mov $0x20, %al               # EOI to slave then master (IRQ12 is on slave)
    out %al, $0xa0
    mov $0x20, %al
    out %al, $0x20
    popal
    iret

# mouse_poll: drain any pending aux (mouse) bytes from the 8042. Used because
#   the test PC's BIOS USB-legacy emulation does NOT raise IRQ12 - it just fills the
#   output buffer, so we poll fast (from the idle loop) to not lose bytes.
mouse_poll:
    push %eax
mp_l:
    in $0x64, %al
    cmp $0xff, %al               # controller gone/absent: never spin on 0xFF
    je mp_done
    test $0x01, %al              # output buffer full?
    jz mp_done
    test $0x20, %al              # bit5 set = aux (mouse) byte
    jz mp_kbd                    # OBF set but not aux-flagged
    incl poll_aux
    in $0x60, %al
    call mouse_byte
    jmp mp_l
mp_kbd:
    incl poll_kbd                # diagnostic: OBF data without the aux bit
    jmp mp_done                  # leave it for the keyboard IRQ
mp_done:
    pop %eax
    ret

# mouse_byte: AL = one PS/2 packet byte. Runs the 3-byte state machine and, on
#   a complete packet, updates mouse_x/y (clamped), buttons, and latches a left
#   click. Preserves EBX/ECX/EDX so it is safe from the ISR and the poller.
mouse_byte:
    push %ebx
    push %ecx
    push %edx
    movzbl mouse_phase, %ebx
    test %ebx, %ebx
    jne mb_b1
    test $0x08, %al              # byte 0: bit3 is the sync bit
    jz mb_done                   # out of sync -> drop
    mov %al, mouse_flags
    movb $1, mouse_phase
    jmp mb_done
mb_b1:
    cmp $1, %ebx
    jne mb_b2
    mov %al, mouse_dx            # byte 1: X movement
    movb $2, mouse_phase
    jmp mb_done
mb_b2:
    mov %al, %dl                 # byte 2: Y movement -> apply the packet
    movb $0, mouse_phase
    incl mouse_pkts              # complete packets (IRQ or polled)
    movzbl mouse_dx, %eax        # dx, sign from flags bit4
    movzbl mouse_flags, %ecx
    test $0x10, %cl
    jz mb_xp
    or $0xffffff00, %eax
mb_xp:
    add %eax, mouse_x
    movzbl %dl, %eax             # dy, sign from flags bit5 (screen Y inverted)
    test $0x20, %cl
    jz mb_yp
    or $0xffffff00, %eax
mb_yp:
    sub %eax, mouse_y
mb_clamp:                        # shared by PS/2 and USB: clamp + button/click
    mov mouse_x, %eax            # clamp X to [0, fb_w-16]
    test %eax, %eax
    jns mb_cx1
    xor %eax, %eax
mb_cx1:
    mov fb_w, %edx
    sub $16, %edx
    cmp %edx, %eax
    jle mb_cx2
    mov %edx, %eax
mb_cx2:
    mov %eax, mouse_x
    mov mouse_y, %eax            # clamp Y to [0, fb_h-16]
    test %eax, %eax
    jns mb_cy1
    xor %eax, %eax
mb_cy1:
    mov fb_h, %edx
    sub $16, %edx
    cmp %edx, %eax
    jle mb_cy2
    mov %edx, %eax
mb_cy2:
    mov %eax, mouse_y
    movzbl mouse_flags, %eax     # buttons (bits 0..2)
    and $0x07, %eax
    mov %al, mouse_btn
    test $0x01, %al              # left button down now?
    jz mb_up
    cmpb $0, mouse_btn_prev      # press edge?
    jne mb_done
    mov mouse_x, %eax            # latch the click for the GUI
    mov %eax, click_x
    mov mouse_y, %eax
    mov %eax, click_y
    movb $1, click_pending
    movb $1, mouse_btn_prev
    jmp mb_done
mb_up:
    movb $0, mouse_btn_prev
mb_done:
    pop %edx
    pop %ecx
    pop %ebx
    ret

# usb_mouse_report: apply a 4-byte HID boot mouse report at EHCI_BUF to the
#   cursor. byte0 = buttons (bits 0-2 = left/right/middle, SAME layout as the
#   PS/2 flags), byte1 = X delta (signed), byte2 = Y delta (signed; for USB
#   positive is DOWN, which already matches screen Y - so ADD, unlike PS/2).
#   Shares the clamp + click-latch tail (mb_clamp). Preserves EBX/ECX/EDX.
usb_mouse_report:
    push %ebx
    push %ecx
    push %edx
    movb $1, mouse_present
    incl mouse_pkts
    movzbl EHCI_BUF, %eax         # byte0: buttons -> flags (bit layout matches)
    mov %al, mouse_flags
    movsbl EHCI_BUF+1, %eax       # byte1: X delta, sign-extended
    add %eax, mouse_x
    movsbl EHCI_BUF+2, %eax       # byte2: Y delta, sign-extended (down = screen down)
    add %eax, mouse_y
    jmp mb_clamp

# usb_kbd_report: an 8-byte HID boot keyboard report at EHCI_BUF2. byte0 =
#   modifiers (bit1 LShift, bit5 RShift), byte1 reserved, bytes 2..7 = up to 6
#   held keycodes. Emit each key that is newly down (present now, absent in the
#   previous report) as ASCII via push_key. US layout; held keys do not repeat.
usb_kbd_report:
    pushal
    cmpl $0, ehci_kbd_diag       # diag: broadcast the first N raw reports
    je ukr_nodiag
    decl ehci_kbd_diag
    mov $REPLY_SCRATCH, %edi
    mov $logp_kbd, %esi          # "usb-kbd: "
    call bputs
    mov EHCI_BUF2, %eax
    call bhex32
    movb $0x20, (%edi)
    inc %edi
    mov EHCI_BUF2+4, %eax
    call bhex32
    mov $logp_push, %esi          # " p=" keys fed to push_key so far
    call bputs
    mov kbd_pushes, %eax
    call bdec32
    mov $logp_ht, %esi            # " ht=" keyboard ring head/tail (does the shell drain?)
    call bputs
    movzbl kb_head, %eax
    call bdec32
    movb $0x2f, (%edi)
    inc %edi
    movzbl kb_tail, %eax
    call bdec32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit
ukr_nodiag:
    movzbl EHCI_BUF2, %ebx        # EBX = shift state (LShift 0x02 | RShift 0x20)
    and $0x22, %ebx
    xor %ecx, %ecx               # ECX = current-report slot 0..5
ukr_l:
    movzbl EHCI_BUF2+2(%ecx), %eax
    test %eax, %eax
    jz ukr_n                     # empty slot
    cmp $0x39, %eax
    jae ukr_n                    # caps-lock and above: ignore
    mov %eax, %esi               # ESI = the keycode under test
    xor %edx, %edx               # scan the PREVIOUS report for it
ukr_held:
    movzbl usb_kbd_prev+2(%edx), %eax
    cmp %eax, %esi
    je ukr_n                     # was already down last time -> not a new press
    inc %edx
    cmp $6, %edx
    jb ukr_held
    test %ebx, %ebx              # new press: translate with/without shift
    jz ukr_uns
    movzbl hid2ascii_shift(%esi), %eax
    jmp ukr_emit
ukr_uns:
    movzbl hid2ascii(%esi), %eax
ukr_emit:
    test %eax, %eax
    jz ukr_n                     # no ASCII mapping for this key
    incl kbd_pushes              # diag: count keys actually fed to the shell buffer
    cmpl $0, ehci_kbd_diag       # diag: broadcast the translated ASCII + ring state
    je ukr_push                  #   (same window as the raw-report diag)
    pushal
    mov %eax, %ebx               # EBX = the ascii we are about to push
    mov $REPLY_SCRATCH, %edi
    mov $logp_ukey, %esi         # "usb-key a="
    call bputs
    mov %ebx, %eax
    call bhex32
    mov $logp_ht, %esi           # " ht=" head/tail BEFORE the push
    call bputs
    movzbl kb_head, %eax
    call bdec32
    movb $0x2f, (%edi)
    inc %edi
    movzbl kb_tail, %eax
    call bdec32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call ehci_emit
    popal
ukr_push:
    call push_key                # AL=ASCII, AH=0 (eax is zero-extended)
ukr_n:
    inc %ecx
    cmp $6, %ecx
    jb ukr_l
    mov EHCI_BUF2, %eax          # remember this report for next-press detection
    mov %eax, usb_kbd_prev
    mov EHCI_BUF2+4, %eax
    mov %eax, usb_kbd_prev+4
    popal
    ret

# cursor_tick: called every timer tick. Re-blit the cursor only when it moved.
cursor_tick:
    cmpb $0, fb_active
    je ck_ret
    cmpb $0, mouse_present
    je ck_ret
    mov mouse_x, %eax
    cmp mouse_px, %eax
    jne ck_move
    mov mouse_y, %eax
    cmp mouse_py, %eax
    je ck_ret
ck_move:
    call cursor_restore          # put back the pixels under the OLD position
    mov mouse_x, %eax
    mov %eax, mouse_px
    mov mouse_y, %eax
    mov %eax, mouse_py
    call cursor_save             # save the pixels under the NEW position
    call cursor_draw             # draw the cursor on top
ck_ret:
    ret

# cursor_save: copy the 16x16 framebuffer block at mouse_px/py into the
#   save-under buffer (so cursor_restore can put the background back).
cursor_save:
    pushal
    mov mouse_px, %ebx
    mov mouse_py, %ebp
    mov $cursor_save_buf, %edi
    xor %edx, %edx
cs_row:
    mov %ebp, %eax
    add %edx, %eax
    imul fb_ppsl, %eax
    add %ebx, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, %esi
    mov $16, %ecx
    rep movsl
    inc %edx
    cmp $16, %edx
    jb cs_row
    popal
    ret

# cursor_restore: write the saved-under block back (skips the first time).
#   Preserves ALL registers (cursor_hide is called between argument setup and
#   drawing in the desktop code).
cursor_restore:
    push %eax
    mov mouse_px, %eax
    cmp $0xffffffff, %eax
    je crs_ret
    pushal
    mov mouse_px, %ebx
    mov mouse_py, %ebp
    mov $cursor_save_buf, %esi
    xor %edx, %edx
crs_row:
    mov %ebp, %eax
    add %edx, %eax
    imul fb_ppsl, %eax
    add %ebx, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, %edi
    mov $16, %ecx
    rep movsl
    inc %edx
    cmp $16, %edx
    jb crs_row
    popal
crs_ret:
    pop %eax
    ret

# cursor_hide: remove the cursor and invalidate it, so a framebuffer-moving
#   op (scroll/clear/panel redraw) can't bake it in; the next tick redraws it.
#   cli-guarded because it runs from the main thread too.
cursor_hide:
    cmpb $0, mouse_present
    je chd_ret
    pushfl
    cli
    call cursor_restore
    movl $0xffffffff, mouse_px
    popfl
chd_ret:
    ret

# cursor_draw: blit the 16x16 arrow at mouse_px/py (1=black, 2=white, 0=clear).
cursor_draw:
    pushal
    mov mouse_px, %ebx
    mov mouse_py, %ebp
    mov $cursor_img, %esi
    xor %edx, %edx               # row
cur_row:
    xor %ecx, %ecx               # col
cur_col:
    movzbl (%esi), %eax
    inc %esi
    test %eax, %eax
    jz cur_skip
    push %eax
    mov %ebp, %eax
    add %edx, %eax               # y + row
    imul fb_ppsl, %eax
    mov %ebx, %edi
    add %ecx, %edi               # x + col
    add %edi, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, %edi
    pop %eax
    cmp $2, %eax
    je cur_white
    xor %eax, %eax               # 1 -> black
    jmp cur_put
cur_white:
    mov $0x00ffffff, %eax        # 2 -> white
cur_put:
    mov %eax, (%edi)
cur_skip:
    inc %ecx
    cmp $16, %ecx
    jb cur_col
    inc %edx
    cmp $16, %edx
    jb cur_row
    popal
    ret

# push_key: AX (AH=scancode, AL=ASCII) into the shared buffer.
push_key:
    push %ebx
    push %ecx
    cmpb $0, fg_prog             # a foreground ring-3 game owns the keyboard?
    jne pk_ring                  #   then feed ONLY its key ring, not the shell's
    mov kb_head, %cl             #   kbuf - otherwise gameplay keys leak into the
    inc %cl                      #   shell command line (e.g. 'q' -> 'qwish ...')
    and $63, %cl
    cmp kb_tail, %cl
    je pk_full
    movzbl kb_head, %ebx
    mov %ax, kbuf(,%ebx,2)
    mov %cl, kb_head
pk_ring:
    # ABI v2: also feed the ring-3 key ring (SYS_GETKEY). ASCII goes through
    #   as is; a scancode-only key (AL=0: arrows, Home/End/PgUp/PgDn/Del from
    #   the PS/2 E0 path or the serial ESC-[ decoder) is delivered as
    #   0x80|scancode (0xC8 up, 0xD0 down, 0xCB left, 0xCD right, 0xC7 home,
    #   0xCF end, 0xC9 pgup, 0xD1 pgdn, 0xD3 del) so full-screen programs
    #   can navigate; see user/ui.h for the ring-3 side of this table.
    test %al, %al
    jnz pk_ascii
    test %ah, %ah
    jz pk_full
    mov %ah, %al
    or $0x80, %al
pk_ascii:
    movzbl kr_head, %ebx
    mov %bl, %cl
    inc %cl
    and $63, %cl
    cmp kr_tail, %cl
    je pk_full                   # ring full -> drop (kbuf already has it)
    mov %al, key_ring(%ebx)
    mov %cl, kr_head
pk_full:
    pop %ecx
    pop %ebx
    ret

# kgetch: blocks until a key/byte is available. AL=ASCII, AH=scancode.
kgetch:
    push %ebx
kg_wait:
    mov kb_tail, %al
    cmp kb_head, %al
    jne kg_have
    cmpb $0, click_pending        # a GUI mouse click waiting? (button / wish field)
    je kg_nclick
    movb $0, click_pending
    cmpb $0, compositor_active    # the compositor owns the screen - ignore clicks
    jne kg_wait                   #   on the (hidden) old desktop's hit regions
    call gui_handle_click
    jmp kg_wait
kg_nclick:
.ifdef REMOTE_CTL                 # remote EHCITEST / RUNPROG / EXEC (REMOTE_CTL only)
    cmpb $0, ehcitest_req         # remote EHCITEST pending? run the USB enumeration
    je kg_nck2                    #   (driven over the wire, no keyboard needed)
    movb $0, ehcitest_req
    pushal
    call ehci_run
    popal
    jmp kg_wait
kg_nck2:
    cmpb $0, run_req              # remote RUNPROG pending? launch the ring-3 program
    je kg_nck_exec                #   (drives 'run' over the wire, no keyboard)
    movb $0, run_req
    pushal
    call run_start
    popal
    jmp kg_wait
kg_nck_exec:
    cmpb $0, exec_req             # remote EXEC pending? hand readline the abort
    je kg_nck_flush               #   key (0xEE) so the shell loop can stage it
    mov $0xEE00, %eax
    pop %ebx
    ret
kg_nck_flush:                     # an EXEC that launched a program (hda/games)
    cmpb $0, exec_cap             #   is captured in SHELL context (safe vs the
    je kg_nck_self                #   netwish TX loop - never from an ISR). Ship it
    mov ticks, %eax               #   when the program exits OR a ~10 s deadline hits
    sub exec_deadline, %eax       #   (the test PC's real HDA codec can wedge the driver).
    jns kg_doflush
    movzbl runprog_slot, %eax
    cmpb $0, agents_tbl(,%eax,8)  # program still running? keep capturing
    jne kg_nck_self
kg_doflush:
    pushal
    call exec_flush
    popal
    jmp kg_wait
.endif
kg_nck_self:                      # (the local 'selftest' command also queues this)
    cmpb $0, selftest_req         # remote SELFTEST pending? run the full hwtest
    je kg_usbauto                 #   while idle (shell context - heavy is ok)
    call hwtest_remote
kg_usbauto:
    cmpb $0, usb_autostart        # one-shot USB bring-up ~3 s after boot, from this
    je kg_idle                    #   settled idle context (boot-init enumeration is
    mov ticks, %eax               #   too early: the split transfers fail and wedge the
    cmp $54, %eax                 #   RMH). Same context as the proven remote trigger.
    jb kg_idle
    movb $0, usb_autostart
    pushal
    call usb_init
    popal
    jmp kg_wait
kg_idle:
    cmpb $0, mouse_present        # with a mouse, busy-poll it (IRQ12 doesn't fire
    je kg_hlt                     #   on the test PC) so no packet bytes are lost
    call ehci_hid_poll            # USB HID: drain any pending interrupt report (full
    cli                           #   speed here - the busy loop doesn't hlt)
    call mouse_poll               # atomic vs the timer's own cursor_tick
    call cursor_tick              # redraw the cursor live (only if it moved)
    sti
    call desk_hover               # WP2: menu / chip hover, dropdown switching
    jmp kg_wait
kg_hlt:
    hlt
    jmp kg_wait
kg_have:
    movzbl kb_tail, %ebx
    movzwl kbuf(,%ebx,2), %eax
    mov kb_tail, %bl
    inc %bl
    and $63, %bl
    mov %bl, kb_tail
    call menu_key                 # WP2: a key closes an open dropdown (Esc eaten)
    test %eax, %eax
    jz kg_wait
    pop %ebx
    ret

# =====================================================================
#  SERIAL DRIVER (COM1, IRQ4 / INT 0x24)
# =====================================================================
serial_init:
    push %eax
    push %edx
    mov $0x3f9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x3fb, %dx
    mov $0x80, %al
    out %al, %dx
    mov $0x3f8, %dx
    mov $1, %al                  # divisor 1 -> 115200 baud
    out %al, %dx
    mov $0x3f9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x3fb, %dx
    mov $0x03, %al               # 8N1
    out %al, %dx
    mov $0x3fa, %dx
    mov $0xc7, %al               # FIFO on + clear
    out %al, %dx
    mov $0x3fc, %dx
    mov $0x0b, %al               # DTR+RTS+OUT2
    out %al, %dx
    mov $0x3f9, %dx
    mov $0x01, %al               # receive IRQ on
    out %al, %dx
    pop %edx
    pop %eax
    ret

# =====================================================================
#  NETWORK: RTL8139 NIC + minimal IPv4/UDP
#  The dev box hosts the LLM; the OS just needs a wire to it. RTL8139
#  is the simplest PIO NIC and built into QEMU (-device rtl8139), so
#  it is headless-testable like everything else (filter-dump -> pcap).
#  TX: 'netwish' broadcasts a UDP datagram to
#  255.255.255.255:4711 - broadcast needs no ARP, no IP address, no
#  TCP. A wishd one-liner on the dev box catches it. (RX/inbox: later.)
#  Buffers in identity-mapped low RAM (DMA uses physical addresses):
#    0x39000 RX ring (8K+16+slack)   0x49000 TX   0x4A000 frame build
# =====================================================================
.equ NIC_RXBUF, 0x39000        # RTL8139 RX ring
.equ NIC_TXBUF, 0x49000        # RTL8139 TX buffer
.equ NIC_PKT,   0x4A000        # shared Ethernet/IP/UDP frame build area
# NIC DMA rings moved into the free 1 MB region (0x13B000+) so the
#   kernel can grow to 256 sectors (0x7e00..0x27e00). Still identity-mapped
#   0-32 MB (DMA-able); the physical addr is symbol-relative at NIC init.
.equ E1000_TXRING, 0x13B000    # e1000 TX descriptor ring (8 x 16, 128-aligned)
.equ E1000_TXBUF,  0x13C000    # e1000 TX packet buffer
.equ R8168_TXRING, 0x13D000    # RTL8168 TX descriptor ring (256-aligned)
.equ R8168_RXRING, 0x13D800    # RTL8168 RX descriptor ring (256-aligned)
.equ R8168_TXBUF,  0x13E000    # RTL8168 TX packet buffer
.equ R8168_RXBUF,  0x100000    # RTL8168 RX buffers (4 x 2 KB) - moved to the free
                               #   1 MB region so the kernel can grow past 0x10000
# virtio-net (legacy I/O) split virtqueues + buffers, in the genuinely free
#   0x149000-0x300000 bank (above the agent stacks at USER_STACKS=0x141000,
#   below the kernel xHCI structs at 0x300000; clear of the AC97 PCM buffer
#   0x104000-0x133E00, the kernel heap 0x50000, and the SMP trampoline). Each
#   vring (qsz 256): desc@+0 / avail@+0x1000 / used@+0x2000 (legacy 4 KB
#   align). QEMU-only (-device virtio-net-pci).
.equ VNET_RXVQ,  0x150000      # RX virtqueue (12 KB)
.equ VNET_TXVQ,  0x154000      # TX virtqueue (12 KB)
.equ VNET_RXBUF, 0x158000      # 16 x 2 KB RX buffers (32 KB)
.equ VNET_TXBUF, 0x160000      # TX buffer (10-byte virtio_net_hdr + frame)
# --- D2: named memory-map regions (single source of truth; mirrors the
#   docs/ARCHITECTURE.md memory map). GAS resolves these as absolute symbols; forward refs ok. ---
.equ UEFI_INFO,    0x28000     # UEFI boot-info handoff block - moved
                               #   just above the 256-sector kernel (0x27e00), still
                               #   real-mode reachable (ES=0x2800), below AHCI 0x29000
.equ USER_STACKS,  0x141000    # ring-3 stacks, TID n at +n*0x1000 - moved out
                               #   of the kernel's new footprint into the 1 MB region
.equ IDT_BASE,     0x2F000     # IDT (256 gates, built at runtime)
.equ PAGE_DIR,     0x30000     # page directory
.equ PAGE_TABLES,  0x31000     # 8 page tables
.equ KERN_STACKS,  0x41000     # ring-0 stacks, TID n at +n*0x1000
# --- ABI v2 ring-3 C-userspace address layout (in the identity-mapped
#     0-32 MB region, all above the driver DMA at <=0x312FFF) ---
.equ USER_PROG_BASE, 0x00400000   # C image (.text/.rodata/.data/.bss)
.equ USER_HEAP_BASE, 0x00800000   # sbrk arena base (grows up)
.equ USER_HEAP_END,  0x01000000   # sbrk arena cap
.equ USER_STACK_TOP, 0x02000000   # ring-3 ESP start (grows down)
.equ USER_BLOB_LBA,  300          # userspace program blob on disk (Makefile appends it)
.equ USER_BLOB_SECTORS, 384       # load up to 192 KB of program text/data (LBA 300-683,
                                  #   below the video clip at 1024; Makefile checks the size)
.equ USER_ARG,       0x007FF000   # 'run <arg>' string for the program (user-mapped,
                                  #   in the gap below the heap; the program reads it)
.equ AHCI_CLB,     0x29000     # AHCI command list (1 KB, 1KB-aligned)
.equ AHCI_FIS,     0x29400     # AHCI received-FIS area (256 B, 256-aligned)
.equ AHCI_CT,      0x29800     # AHCI command table (CFIS+PRDT, 128-aligned)
.equ AHCI_BUF,     0x2A000     # AHCI sector data buffer (1 sector, page-aligned)
.equ HEAP_BASE,    0x50000     # kernel heap arena start (kmalloc/kfree)
.equ HEAP_END,     0x8FFFF     # kernel heap arena end
.equ REPLY_SCRATCH, 0x49F00    # return-channel/netwish payload build (below NIC_PKT)
.equ E820_TOTAL,   0x4000      # C3: usable RAM bytes from INT 15h E820 (real mode -> PM)

# pci_read: EAX = config address (0x80000000|dev<<11|reg) -> EAX = dword
pci_read:
    push %edx
    mov $0xcf8, %dx
    out %eax, %dx
    mov $0xcfc, %dx
    in %dx, %eax
    pop %edx
    ret

# pci_find_class - generic "find the CL-th device of a PCI class".
#   In:  AX = class<<8 | subclass  (subclass 0xFF = match the whole class,
#                                   any subclass); CL = index to skip (0=first).
#   Out: CF=0 and EBP = the device's config base (0x80000000|BDF<<8) on a hit,
#        so the caller can read its BARs; CF=1 if no such device exists.
#   Clobbers EAX/EBX/EBP; preserves the rest. The data-driven counterpart to the
#   hardcoded ahci_find/log_usb scans - reused by NIC/GPU/audio probes.
pci_find_class:
    push %edx
    push %esi
    push %edi
    movzwl %ax, %esi             # ESI = wanted class:subclass
    movzbl %cl, %edi             # EDI = matches left to skip
    xor %ebx, %ebx               # EBX = BDF index (bus<<8|dev<<3|func)
pfc_l:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp         # EBP = this function's config base
    mov %ebp, %eax
    call pci_read                # device:vendor
    cmp $0xffffffff, %eax        # no device responding here
    je pfc_n
    test %eax, %eax
    jz pfc_n
    lea 0x08(%ebp), %eax         # reg 0x08 = class:subclass:progif:rev
    call pci_read
    shr $16, %eax                # -> class<<8 | subclass
    mov %esi, %edx               # EDX = wanted
    cmp $0xff, %dl               # wanted subclass 0xFF -> compare class only
    jne pfc_cmp
    shr $8, %eax
    shr $8, %edx
pfc_cmp:
    cmp %dx, %ax
    jne pfc_n
    test %edi, %edi              # a match - is it the one we were asked for?
    jz pfc_hit
    dec %edi                     # no, skip this earlier match
pfc_n:
    inc %ebx
    cmp $0x4000, %ebx            # buses 0-63
    jb pfc_l
    pop %edi
    pop %esi
    pop %edx
    stc                          # not found
    ret
pfc_hit:
    pop %edi
    pop %esi
    pop %edx
    clc                          # EBP = matched device's config base
    ret

net_init:
    pushal
    xor %ebx, %ebx               # EBX = BDF index: bus<<8 | dev<<3 | func
ni_scan:                         # config addr = 0x80000000 | BDF<<8 lays
    mov %ebx, %ebp               # bus in [23:16], dev [15:11], func [10:8]
    shl $8, %ebp
    or $0x80000000, %ebp         # EBP = this function's config base (reg 0)
    mov %ebp, %eax
    call pci_read                # EAX = device<<16 | vendor
    mov $nic_tbl, %esi           # H1: table-driven match (vendor:device -> setup)
ni_match:
    mov (%esi), %edx
    test %edx, %edx              # 0 dword = end of table -> not a known NIC
    jz ni_next
    cmp %edx, %eax
    je ni_hit
    add $8, %esi
    jmp ni_match
ni_hit:
    jmp *4(%esi)                 # tail-call the chip setup (uses EBP; ends popal;ret)
ni_next:
    inc %ebx
    cmp $0x4000, %ebx            # all of buses 0-63 (32 devs x 8 funcs each)
    jb ni_scan
    popal                        # no known card - net_present stays 0
    ret

# H1: NIC driver table - one row per supported chip: the vendor:device dword
# (device<<16 | vendor, exactly as pci_read returns it) followed by the chip's
# setup routine. Each setup expects EBP = the device's PCI config base and ends
# with popal;ret. Adding a card is now ONE line here (H2), no code duplication.
# A 0,0 row terminates the table.
.balign 4
nic_tbl:
    .long 0x813910ec, rtl_setup      # Realtek RTL8139 (QEMU -nic rtl8139)
    .long 0x816810ec, rtl8168_setup  # Realtek RTL8111/8168 Gigabit (the test PC)
    .long 0x816910ec, rtl8168_setup  # Realtek RTL8169 Gigabit
    .long 0x100e8086, e1000_setup    # Intel 82540EM e1000 (QEMU default)
    .long 0x100f8086, e1000_setup    # Intel 82545EM e1000
    .long 0x10d38086, e1000_setup    # Intel 82574L e1000e (QEMU -device e1000e;
                                     #   onboard on many business PCs) - the
                                     #   legacy 8254x TX descriptor path drives it
    .long 0x10001af4, virtio_net_setup # virtio-net (transitional, legacy I/O) -
                                     #   every cloud VM / hypervisor; QEMU -device
                                     #   virtio-net-pci (1af4:1000)
    .long 0, 0                       # end of table

# --- Intel e1000 (82540/82545): MMIO + TX descriptor ring -----------
e1000_setup:
    lea 0x10(%ebp), %eax         # BAR0 = MMIO base (memory BAR)
    call pci_read
    and $0xfffffff0, %eax
    mov %eax, e1000_mmio
    lea 0x04(%ebp), %eax         # command reg: memory space + bus master
    call pci_read
    or $0x06, %eax
    mov %eax, %esi
    mov %ebp, %eax
    or $0x04, %eax
    mov $0xcf8, %dx
    out %eax, %dx
    mov $0xcfc, %dx
    mov %esi, %eax
    out %eax, %dx
    mov e1000_mmio, %edx         # map the MMIO BAR (lives ~0xFEBxxxxx,
    mov %edx, %ecx               # above our identity map) as one 4 MB
    shr $22, %ecx                # uncached page - same trick as the framebuffer
    and $0xffc00000, %edx        # framebuffer, but PCD+PWT for MMIO
    or $0x9b, %edx               # present|rw|PS|PWT|PCD
    mov %edx, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax               # PSE (already on if a FB was mapped)
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3               # flush the TLB
    mov e1000_mmio, %ebx         # EBX = MMIO base for the rest
    mov 0x0000(%ebx), %eax       # CTRL: set link up + auto-speed detect
    or $0x60, %eax               # SLU | ASDE
    mov %eax, 0x0000(%ebx)
    mov 0x5400(%ebx), %eax       # MAC from RAL/RAH (QEMU fills from EEPROM)
    mov %eax, nic_mac
    mov 0x5404(%ebx), %eax
    mov %ax, nic_mac+4
    mov $E1000_TXRING, %edi      # zero the TX descriptor ring (128 bytes)
    xor %eax, %eax
    mov $32, %ecx
    rep stosl
    movl $E1000_TXRING, 0x3800(%ebx)  # TDBAL
    movl $0, 0x3804(%ebx)             # TDBAH
    movl $128, 0x3808(%ebx)           # TDLEN (8 desc x 16)
    movl $0, 0x3810(%ebx)             # TDH
    movl $0, 0x3818(%ebx)             # TDT
    movl $0x000400fa, 0x0400(%ebx)    # TCTL: EN|PSP|CT=0x0F|COLD=0x40
    movl $0x0060200a, 0x0410(%ebx)    # TIPG (recommended for 82540)
    movb $2, net_present              # 2 = e1000
    popal
    ret

# --- virtio-net (legacy/transitional, I/O BAR) ----------------------
#   The modern NIC every VM uses. Legacy virtio is I/O-port based (like the
#   RTL8139) which keeps this in the kernel's existing style: device-init
#   handshake, two split virtqueues (0=RX, 1=TX) in fixed DMA RAM, the PFN
#   written to the device. RX is prefilled with 16 buffers. QEMU-only.
#   Register map (off I/O base): 00 dev-features, 04 guest-features, 08 queue
#   PFN, 0c queue-size, 0e queue-select, 10 queue-notify, 12 status, 14 config.
virtio_net_setup:
    lea 0x10(%ebp), %eax          # BAR0 = I/O base (legacy virtio)
    call pci_read
    and $0xfffffffc, %eax
    mov %eax, vnet_io
    lea 0x04(%ebp), %eax          # enable I/O space + bus master
    call pci_read
    or $0x05, %eax
    mov %eax, %esi
    mov %ebp, %eax
    or $0x04, %eax
    mov $0xcf8, %dx
    out %eax, %dx
    mov $0xcfc, %dx
    mov %esi, %eax
    out %eax, %dx
    mov vnet_io, %ebx             # EBX = I/O base
    lea 0x12(%ebx), %edx          # device status: reset, then ACK | DRIVER
    xor %al, %al ; out %al, %dx
    mov $1, %al ; out %al, %dx
    mov $3, %al ; out %al, %dx
    mov %ebx, %edx                # device features (+0x00)
    in %dx, %eax
    and $0x20, %eax              # keep only VIRTIO_NET_F_MAC (bit5)
    push %eax
    lea 0x04(%ebx), %edx          # guest features (+0x04)
    out %eax, %dx
    lea 0x0e(%ebx), %edx          # queue_select = 0 (RX)
    xor %ax, %ax ; out %ax, %dx
    lea 0x0c(%ebx), %edx          # queue_size
    in %dx, %ax
    cmp $256, %ax                 # the vring layout assumes qsz 256 (QEMU's)
    jne vns_bail
    mov $VNET_RXVQ, %edi          # zero the RX vring (12 KB)
    xor %eax, %eax ; mov $0xC00, %ecx ; rep stosl
    lea 0x08(%ebx), %edx          # queue PFN = phys >> 12
    mov $(VNET_RXVQ>>12), %eax ; out %eax, %dx
    lea 0x0e(%ebx), %edx          # queue_select = 1 (TX)
    mov $1, %ax ; out %ax, %dx
    mov $VNET_TXVQ, %edi
    xor %eax, %eax ; mov $0xC00, %ecx ; rep stosl
    lea 0x08(%ebx), %edx
    mov $(VNET_TXVQ>>12), %eax ; out %eax, %dx
    lea 0x12(%ebx), %edx          # DRIVER_OK (ACK|DRIVER|DRIVER_OK)
    mov $7, %al ; out %al, %dx
    pop %eax                      # MAC feature negotiated?
    test %eax, %eax
    jz vns_nomac
    lea 0x14(%ebx), %edx          # device config: MAC[6]
    mov $6, %ecx ; mov $nic_mac, %edi
vns_macl:
    in %dx, %al ; mov %al, (%edi) ; inc %edi ; inc %edx ; loop vns_macl
vns_nomac:
    xor %ecx, %ecx               # prefill 16 RX descriptors -> avail
vns_rxd:
    mov %ecx, %eax ; shl $4, %eax
    lea VNET_RXVQ(%eax), %ebx    # &desc[i]
    mov %ecx, %eax ; shl $11, %eax ; add $VNET_RXBUF, %eax
    mov %eax, (%ebx)             # desc[i].addr (low)
    movl $0, 4(%ebx)            # addr high
    movl $2048, 8(%ebx)         # len
    movw $2, 12(%ebx)           # flags = VRING_DESC_F_WRITE (device writes)
    movw $0, 14(%ebx)           # next
    mov %ecx, %eax
    mov %cx, VNET_RXVQ+0x1004(,%eax,2)   # avail.ring[i] = i
    inc %ecx
    cmp $16, %ecx
    jb vns_rxd
    movw $16, VNET_RXVQ+0x1002    # avail.idx = 16
    movl $16, vnet_rx_avail
    movl $0, vnet_rx_used
    movl $0, vnet_tx_avail
    mov vnet_io, %ebx            # notify queue 0 so the device takes the buffers
    lea 0x10(%ebx), %edx
    xor %ax, %ax ; out %ax, %dx
    movb $4, net_present         # 4 = virtio-net
    popal
    ret
vns_bail:
    popal
    ret

# --- RTL8139: I/O ports + linear RX ring ----------------------------
rtl_setup:
    lea 0x10(%ebp), %eax         # BAR0 (reg 0x10) = I/O base
    call pci_read
    and $0xfffffffc, %eax
    mov %eax, nic_io
    lea 0x04(%ebp), %eax         # command reg: I/O space + bus master
    call pci_read
    or $0x05, %eax
    mov %eax, %esi
    mov %ebp, %eax
    or $0x04, %eax
    mov $0xcf8, %dx
    out %eax, %dx
    mov $0xcfc, %dx
    mov %esi, %eax
    out %eax, %dx
    mov nic_io, %ebx             # EBX = I/O base for the rest
    lea 0x52(%ebx), %edx         # CONFIG1: power on
    xor %al, %al
    out %al, %dx
    lea 0x37(%ebx), %edx         # CR: software reset, poll bit 4
    mov $0x10, %al
    out %al, %dx
ni_rst:
    in %dx, %al
    test $0x10, %al
    jnz ni_rst
    lea 0x30(%ebx), %edx         # RBSTART = RX buffer (physical)
    mov $NIC_RXBUF, %eax
    out %eax, %dx
    lea 0x44(%ebx), %edx         # RCR: accept all+phys+multi+bcast, wrap
    mov $0x8f, %eax
    out %eax, %dx
    lea 0x37(%ebx), %edx         # CR: enable TX + RX
    mov $0x0c, %al
    out %al, %dx
    lea 0x38(%ebx), %edx         # CAPR = 0xFFF0 (read ptr = -16, offset 0)
    mov $0xfff0, %ax
    out %ax, %dx
    movl $0, rtl_rxoff
    lea 0(%ebx), %edx            # read the MAC from IDR0..5
    mov $6, %ecx
    mov $nic_mac, %edi
ni_mac:
    in %dx, %al
    mov %al, (%edi)
    inc %edi
    inc %edx
    loop ni_mac
    movb $1, net_present
    popal
    ret

# net_send: EAX = frame pointer, ECX = length. Dispatches to the driver
# of whichever NIC net_init found (both routines end in ret).
net_send:
    cmpb $1, net_present
    je rtl8139_send
    cmpb $2, net_present
    je e1000_send
    cmpb $3, net_present
    je rtl8168_send
    cmpb $4, net_present
    je virtio_net_send
    ret

# virtio-net TX: prepend a 10-byte virtio_net_hdr, post one descriptor on the
# TX virtqueue (queue 1), notify, and poll the used ring for completion.
virtio_net_send:
    pushal
    mov %eax, %esi               # frame source
    mov %ecx, %ebp               # frame length
    mov $VNET_TXBUF, %edi        # 10-byte zero header + frame
    xor %eax, %eax
    mov $10, %ecx
    rep stosb
    mov %ebp, %ecx
    rep movsb
    mov $VNET_TXVQ, %ebx         # TX desc[0]
    movl $VNET_TXBUF, 0(%ebx)
    movl $0, 4(%ebx)
    lea 10(%ebp), %eax           # len = 10 + framelen
    mov %eax, 8(%ebx)
    movw $0, 12(%ebx)           # flags = 0 (device reads)
    movw $0, 14(%ebx)
    mov vnet_tx_avail, %eax      # avail.ring[idx % 256] = desc 0
    mov %eax, %ecx
    and $255, %ecx
    movw $0, VNET_TXVQ+0x1004(,%ecx,2)
    inc %eax
    mov %eax, vnet_tx_avail
    movw %ax, VNET_TXVQ+0x1002    # avail.idx
    mov vnet_io, %ebx            # notify queue 1
    lea 0x10(%ebx), %edx
    mov $1, %ax ; out %ax, %dx
    mov $0x800000, %ecx          # poll TX used.idx (bounded)
vns_txw:
    movzwl VNET_TXVQ+0x2002, %eax
    movzwl vnet_tx_avail, %edx
    cmp %ax, %dx
    je vns_txd
    dec %ecx
    jnz vns_txw
vns_txd:
    popal
    ret

# RTL8139 transmit. The chip has FOUR TX descriptors that MUST be used in
# round-robin order - reusing descriptor 0 only sends the first frame and
# then silently stalls (the kernel never noticed: it only ever sent single
# packets; the userspace TCP stack sends many). rtl_txd cycles 0..3.
rtl8139_send:
    pushal
    mov %eax, %esi               # copy frame into the TX buffer (DMA src)
    mov $NIC_TXBUF, %edi
    mov %ecx, %ebp               # EBP = length
    push %ecx
    rep movsb
    pop %ecx
    mov nic_io, %ebx
    movzbl rtl_txd, %eax         # current TX descriptor 0..3 -> register offset
    lea 0(,%eax,4), %eax
    mov %eax, %ecx               # ECX = descriptor*4
    lea 0x20(%ebx,%ecx), %edx    # TSAD[i] = TX buffer (physical)
    mov $NIC_TXBUF, %eax
    out %eax, %dx
    lea 0x10(%ebx,%ecx), %edx    # TSD[i] = length -> starts transmission
    mov %ebp, %eax
    and $0x1fff, %eax
    out %eax, %dx
    mov $0x100000, %ecx          # poll TOK (bit 15), bounded
nse_wait:
    in %dx, %eax
    test $0x8000, %eax
    jnz nse_done
    loop nse_wait
nse_done:
    movzbl rtl_txd, %eax         # advance to the next descriptor (round-robin)
    inc %eax
    and $3, %eax
    mov %al, rtl_txd
    popal
    ret

# e1000 transmit: fill the descriptor at TDT, bump TDT, poll STA.DD.
e1000_send:
    pushal
    mov %eax, %esi               # copy frame into the TX buffer (DMA src)
    mov $E1000_TXBUF, %edi
    mov %ecx, %ebp               # EBP = length
    push %ecx
    rep movsb
    pop %ecx
    mov e1000_mmio, %ebx
    mov 0x3818(%ebx), %eax       # EAX = TDT (next free descriptor index)
    mov %eax, %edi               # EDI = index (for the TDT bump)
    shl $4, %eax
    add $E1000_TXRING, %eax      # EAX = &descriptor
    movl $E1000_TXBUF, (%eax)    # buffer address (low 32)
    movl $0, 4(%eax)             # buffer address (high 32)
    mov %bp, 8(%eax)             # length (low 16 bits of +8)
    movb $0, 10(%eax)            # CSO
    movb $0x0b, 11(%eax)         # CMD = RS | IFCS | EOP
    movb $0, 12(%eax)            # STA (hardware sets DD when done)
    movb $0, 13(%eax)            # reserved
    movw $0, 14(%eax)            # special
    inc %edi                     # advance TDT (ring of 8)
    and $7, %edi
    mov %edi, 0x3818(%ebx)
    mov $0x100000, %ecx          # poll DD on our descriptor, bounded
e1s_wait:
    movb 12(%eax), %dl
    test $1, %dl
    jnz e1s_done
    loop e1s_wait
e1s_done:
    popal
    ret

# put16be: store AX big-endian at (EDI). Clobbers AX. (value < 65536)
put16be:
    xchg %al, %ah
    mov %ax, (%edi)
    ret

# --- Realtek RTL8111/8168 (r8169 family): MMIO + descriptor rings ----
#  The common onboard Gigabit NIC (10EC:8168). QEMU does NOT emulate it,
#  so this is written from the r8169 spec and verified on bare metal,
#  not in QEMU. Written DEFENSIVELY: BAR2 is range-checked and every
#  poll is bounded, so a surprise can cost the NIC but never the boot.
#  TX: one TX descriptor, kick via TPPoll (RX ring: see npoll_8168).
rtl8168_setup:
    lea 0x18(%ebp), %eax         # BAR2 = MMIO register space (64-bit BAR)
    call pci_read
    and $0xfffffff0, %eax
    test %eax, %eax              # unassigned? leave net_present=0, keep scanning
    jz r8168_bail
    cmp $0x2000000, %eax         # implausibly low (overlaps our RAM)? bail
    jb r8168_bail
    mov %eax, r8168_mmio
    lea 0x1c(%ebp), %eax         # BAR2 high dword - must be 0 (under 4 GB)
    call pci_read
    test %eax, %eax
    jnz r8168_bail
    lea 0x04(%ebp), %eax         # enable memory space + bus master
    call pci_read
    or $0x06, %eax
    mov %eax, %esi
    mov %ebp, %eax
    or $0x04, %eax
    mov $0xcf8, %dx
    out %eax, %dx
    mov $0xcfc, %dx
    mov %esi, %eax
    out %eax, %dx
    mov r8168_mmio, %edx         # map the MMIO BAR as a 4 MB uncached page
    mov %edx, %ecx               # (it lives high, above our identity map)
    shr $22, %ecx
    and $0xffc00000, %edx
    or $0x9b, %edx               # present|rw|PS|PWT|PCD
    mov %edx, PAGE_DIR(,%ecx,4)
    mov %cr4, %eax
    or $0x10, %eax               # PSE
    mov %eax, %cr4
    mov $PAGE_DIR, %eax
    mov %eax, %cr3               # flush TLB
    mov r8168_mmio, %ebx         # EBX = MMIO base
    movb $0x10, 0x37(%ebx)       # CR: software reset, poll bit 4 (bounded)
    mov $0x100000, %ecx
r8168_rst:
    movzbl 0x37(%ebx), %eax
    test $0x10, %eax
    jz r8168_rdy
    loop r8168_rst
r8168_rdy:
    movb $0xc0, 0x50(%ebx)       # 9346CR: unlock config registers
    mov 0x00(%ebx), %eax         # MAC from IDR0-5
    mov %eax, nic_mac
    mov 0x04(%ebx), %eax
    mov %ax, nic_mac+4
    mov $R8168_TXRING, %edi      # zero TX + RX descriptor rings
    xor %eax, %eax
    mov $128, %ecx
    rep stosl
    movl $R8168_TXRING, 0x20(%ebx)  # TNPDS: TX descriptor ring address
    movl $0, 0x24(%ebx)
    # --- RX descriptor ring (4 entries) for the return channel ---
    push %ebx
    mov $R8168_RXRING, %edi
    mov $R8168_RXBUF, %esi          # 4 buffers of 2 KB
    mov $4, %ecx
r8168_rxd:
    mov %esi, 8(%edi)               # buffer address low
    movl $0, 12(%edi)               # buffer address high
    movl $0, 4(%edi)                # vlan
    mov $0x80000800, %eax           # OWN | buffer size 2048
    cmp $1, %ecx                    # last descriptor gets EOR
    jne r8168_rxd_n
    or $0x40000000, %eax
r8168_rxd_n:
    mov %eax, (%edi)
    add $0x800, %esi
    add $16, %edi
    dec %ecx
    jnz r8168_rxd
    movl $0, r8168_rxidx
    pop %ebx
    movl $R8168_RXRING, 0xe4(%ebx)  # RDSAR: RX descriptor ring
    movl $0, 0xe8(%ebx)
    movl $0x03000700, 0x40(%ebx)    # TCR: standard IFG + max DMA burst
    movl $0x0000e70f, 0x44(%ebx)    # RCR: MXDMA=7 (unlimited) + RXFTH=7 (no
                                    #   threshold) + accept phys/mcast/bcast/
                                    #   promisc. 0x700f gave a 16-byte
                                    #   DMA burst -> RX never filled (test PC inbox).
    movw $0x1800, 0xda(%ebx)        # RMS: max RX packet size (6 KB)
    movb $0x3b, 0xec(%ebx)          # MTPS: max TX packet size
    movb $0x0c, 0x37(%ebx)          # CR: TE + RE (transmit AND receive)
    movb $0x00, 0x50(%ebx)          # 9346CR: lock config registers again
    movb $3, net_present            # 3 = RTL8168
    popal
    ret
r8168_bail:
    popal
    ret

# RTL8168 transmit: fill descriptor 0, kick TPPoll, poll OWN clear.
rtl8168_send:
    pushal
    mov %eax, %esi               # copy frame into the TX buffer (DMA src)
    mov $R8168_TXBUF, %edi
    mov %ecx, %ebp               # EBP = length
    push %ecx
    rep movsb
    pop %ecx
    mov r8168_mmio, %ebx
    mov $R8168_TXRING, %edi      # descriptor 0
    movl $R8168_TXBUF, 8(%edi)   # buffer address low
    movl $0, 12(%edi)            # buffer address high
    movl $0, 4(%edi)             # vlan
    mov %ebp, %eax               # flags = OWN|EOR|FS|LS | length
    and $0xffff, %eax
    or $0xf0000000, %eax         # 0x80000000 OWN | 0x40000000 EOR
    mov %eax, (%edi)             # | 0x20000000 FS | 0x10000000 LS
    movb $0x40, 0x38(%ebx)       # TPPoll: NPQ - kick the normal TX queue
    mov $0x100000, %ecx          # poll OWN clear (NIC done), bounded
r8168_w:
    mov (%edi), %eax
    test $0x80000000, %eax
    jz r8168_done
    loop r8168_w
r8168_done:
    popal
    ret

# net_udp_bcast: ESI = payload, ECX = length. Builds Eth/IP/UDP broadcast
#  to 255.255.255.255:4711 at NIC_PKT and sends it.
net_udp_bcast:
    pushal
    cmpb $0, net_present
    je nub_ret
    mov %esi, %ebx               # EBX = payload, EBP = length
    mov %ecx, %ebp
    mov $NIC_PKT, %edi
    mov $6, %ecx                 # Ethernet dst = broadcast
    mov $0xff, %al
    rep stosb
    mov $nic_mac, %esi           # Ethernet src = our MAC
    mov $6, %ecx
    rep movsb
    movw $0x0008, (%edi)         # ethertype 0x0800 (IPv4)
    add $2, %edi
    movb $0x45, (%edi)           # IPv4: version 4, IHL 5
    movb $0, 1(%edi)             # DSCP/ECN
    lea 28(%ebp), %eax           # total length = 20 IP + 8 UDP + payload
    push %edi
    add $2, %edi
    call put16be
    pop %edi
    movl $0, 4(%edi)             # id + flags/frag = 0
    movb $64, 8(%edi)            # TTL
    movb $17, 9(%edi)            # protocol = UDP
    movw $0, 10(%edi)            # header checksum (filled below)
    movl $0, 12(%edi)            # src IP 0.0.0.0 (we have none)
    movl $0xffffffff, 16(%edi)   # dst IP 255.255.255.255
    mov %edi, %esi               # IP checksum over the 20-byte header
    xor %eax, %eax
    mov $10, %ecx
nub_ck:
    movzwl (%esi), %edx
    add %edx, %eax
    add $2, %esi
    loop nub_ck
    mov %eax, %edx               # fold carries
    shr $16, %edx
    and $0xffff, %eax
    add %edx, %eax
    mov %eax, %edx
    shr $16, %edx
    add %edx, %eax
    not %eax
    mov %ax, 10(%edi)
    add $20, %edi                # UDP header
    movw $0x6712, (%edi)         # src port 4711
    movw $0x6712, 2(%edi)        # dst port 4711
    lea 8(%ebp), %eax            # UDP length = 8 + payload
    push %edi
    add $4, %edi
    call put16be
    pop %edi
    movw $0, 6(%edi)             # UDP checksum 0 (optional on IPv4)
    add $8, %edi
    mov %ebx, %esi               # copy the payload
    mov %ebp, %ecx
    rep movsb
    lea 42(%ebp), %ecx           # total frame = 14 + 20 + 8 + payload
    mov $NIC_PKT, %eax
    call net_send
nub_ret:
    popal
    ret

# --- network receive: the return channel. Polled
#   ~1x/sec from the timer. For now RX is implemented for the RTL8139
#   (QEMU-testable); the RTL8168 RX path is groundwork for the test PC.
#   A UDP datagram to port 4713 carrying "AGENTOS-REBOOT" reboots the
#   machine - so the dev box can reboot the netbooted PC remotely and
#   PXE pulls the latest build. Any other payload lands in the inbox.
net_poll:
    mov ticks, %eax               # a userspace net program owns the RX ring for
    sub net_last_syscall, %eax     #   ~30 s after each net syscall - back off so
    cmp $540, %eax                 #   we don't steal its TCP frames (net_poll runs
    jb np_yield                    #   in the timer ISR; SYS_NET_RX drains instead)
    cmpb $1, net_present          # dispatch on the NIC the kernel found
    je npoll_8139
    cmpb $3, net_present
    je npoll_8168
np_yield:
    ret
npoll_8139:
    pushal
    mov nic_io, %ebx
    mov $8, %ebp                  # HARD bound: at most 8 packets per poll -
npoll_loop:                       # this runs in the timer ISR, it must
    dec %ebp                      # NEVER loop forever (a bug would hang all)
    js npoll_done
    lea 0x37(%ebx), %edx          # CR: bit 0 = BUFE (RX buffer empty)
    in %dx, %al
    test $1, %al
    jnz npoll_done                # empty -> nothing more
    mov rtl_rxoff, %esi           # our read offset into the 8K ring
    lea NIC_RXBUF(%esi), %edi     # EDI -> packet header in the ring
    movzwl 2(%edi), %ecx          # length (frame + 4 CRC)
    cmp $20, %ecx                 # sane?
    jb npoll_skip
    cmp $1600, %ecx
    ja npoll_skip
    testb $1, (%edi)              # rx status bit0 = ROK?
    jz npoll_skip
    lea 4(%edi), %esi             # ESI -> Ethernet frame
    lea -4(%ecx), %eax            # frame length without CRC (info only)
    call net_handle
npoll_skip:
    mov rtl_rxoff, %esi           # advance: (off + len + 4 + 3) & ~3
    add %ecx, %esi
    add $7, %esi
    and $0xfffffffc, %esi
    and $0x1fff, %esi             # wrap in the 8K ring
    mov %esi, rtl_rxoff
    lea -16(%esi), %eax           # CAPR is the read pointer minus 16
    lea 0x38(%ebx), %edx
    out %ax, %dx
    jmp npoll_loop
npoll_done:
    popal
    ret

# net_rx_one: pop ONE Ethernet frame from the RTL8139 RX ring into [EDI].
#   Returns EAX = frame length (CRC stripped), or 0 if the ring is empty / the
#   frame was bad. Drives userspace RX (SYS_NET_RX); shares rtl_rxoff/CAPR with
#   net_poll, which yields while a net program runs. Dispatches on the NIC:
net_rx_one:
    pushal
    mov %edi, nro_dst
    cmpb $4, net_present          # virtio-net - split virtqueue
    je nro_virtio
    cmpb $3, net_present          # RTL8168 (the test PC) - descriptor ring
    je nro_8168
    cmpb $1, net_present          # RTL8139 (QEMU) - linear ring
    jne nro_empty
    mov nic_io, %ebx
    lea 0x37(%ebx), %edx          # CR: BUFE = ring empty?
    in %dx, %al
    test $1, %al
    jnz nro_empty
    mov rtl_rxoff, %esi
    add $NIC_RXBUF, %esi          # ESI -> packet header
    movzwl 2(%esi), %ecx          # ring length (frame + 4 CRC)
    mov %ecx, nro_rlen
    cmp $20, %ecx
    jb nro_drop
    cmp $1600, %ecx
    ja nro_drop
    testb $1, (%esi)              # rx status bit0 = ROK?
    jz nro_drop
    lea -4(%ecx), %ecx            # frame length without CRC
    mov %ecx, nro_flen
    lea 4(%esi), %esi             # ESI -> Ethernet frame
    mov nro_dst, %edi
    rep movsb                     # copy frame into the user buffer
    jmp nro_adv
nro_drop:
    movl $0, nro_flen
nro_adv:
    mov rtl_rxoff, %esi           # advance: (off + ringlen + 4 + 3) & ~3
    add nro_rlen, %esi
    add $7, %esi
    and $0xfffffffc, %esi
    and $0x1fff, %esi             # wrap in the 8K ring
    mov %esi, rtl_rxoff
    lea -16(%esi), %eax           # CAPR = read pointer - 16
    lea 0x38(%ebx), %edx
    out %ax, %dx
    mov nro_flen, %eax
    mov %eax, nro_retval
    jmp nro_ret
# RTL8168 path (the test PC). Mirrors npoll_8168: ack the ISR (write-1-to-clear,
# the bit that keeps the RX engine alive), pop one filled descriptor, copy its
# buffer to the user, hand the descriptor back. BLIND - QEMU has no 8168, so
# this is test-PC-only and verified only on hardware.
nro_8168:
    mov r8168_mmio, %ebx
    movzwl 0x3e(%ebx), %eax       # ISR ack (keeps the receiver from halting)
    movw %ax, 0x3e(%ebx)
    mov r8168_rxidx, %esi
    mov %esi, %eax
    shl $4, %eax
    add $R8168_RXRING, %eax       # EAX -> current descriptor
    mov (%eax), %ecx              # flags
    test $0x80000000, %ecx        # OWN set? NIC has not filled it -> empty
    jnz nro_empty
    mov %ecx, %edx
    and $0x3fff, %edx             # frame length (including CRC)
    sub $4, %edx                  # strip CRC
    js n68r_drop
    cmp $1600, %edx
    ja n68r_drop
    mov %edx, nro_flen
    mov 8(%eax), %esi             # descriptor buffer address
    mov nro_dst, %edi
    mov %edx, %ecx
    rep movsb                     # copy the frame into the user buffer
    jmp n68r_give
n68r_drop:
    movl $0, nro_flen
n68r_give:
    mov r8168_rxidx, %esi         # give the descriptor back to the NIC
    mov %esi, %eax
    shl $4, %eax
    add $R8168_RXRING, %eax
    mov (%eax), %ecx
    and $0x40000000, %ecx         # keep EOR
    or $0x80000800, %ecx          # OWN | size 2048
    mov %ecx, (%eax)
    inc %esi                      # advance to the next of the 4 descriptors
    and $3, %esi
    mov %esi, r8168_rxidx
    mov nro_flen, %eax
    mov %eax, nro_retval
    jmp nro_ret
# virtio-net RX: if the RX used ring advanced, copy the frame (past the
# 10-byte virtio_net_hdr) to the user, re-arm the descriptor on avail, notify.
nro_virtio:
    movzwl VNET_RXVQ+0x2002, %eax    # RX used.idx
    mov vnet_rx_used, %edx
    and $0xffff, %edx
    cmp %ax, %dx
    je nro_empty                      # nothing new
    mov vnet_rx_used, %ecx            # used.ring[used % 256] = { id(4), len(4) }
    and $255, %ecx
    shl $3, %ecx
    lea VNET_RXVQ+0x2004(%ecx), %esi
    mov (%esi), %ebx                  # EBX = descriptor id
    mov 4(%esi), %ecx                 # ECX = len (incl 10-byte hdr)
    sub $10, %ecx
    js nro_vdrop
    cmp $1600, %ecx
    ja nro_vdrop
    mov %ecx, nro_flen
    mov %ebx, %eax
    shl $11, %eax                     # id * 2048
    add $VNET_RXBUF, %eax
    add $10, %eax                     # skip the virtio_net_hdr
    mov %eax, %esi
    mov nro_dst, %edi
    rep movsb
    jmp nro_vgive
nro_vdrop:
    movl $0, nro_flen
nro_vgive:
    mov vnet_rx_avail, %eax           # re-arm descriptor id on avail
    mov %eax, %ecx
    and $255, %ecx
    mov %bx, VNET_RXVQ+0x1004(,%ecx,2)
    inc %eax
    mov %eax, vnet_rx_avail
    movw %ax, VNET_RXVQ+0x1002        # avail.idx
    incl vnet_rx_used
    mov vnet_io, %ebx                 # notify queue 0
    lea 0x10(%ebx), %edx
    xor %ax, %ax ; out %ax, %dx
    mov nro_flen, %eax
    mov %eax, nro_retval
    jmp nro_ret
nro_empty:
    movl $0, nro_retval
nro_ret:
    popal
    mov nro_retval, %eax
    ret

# RTL8168 RX poll (blind - QEMU has no 8168): walk the RX
#   descriptor ring; for each descriptor the NIC has filled (OWN clear)
#   hand the frame to net_handle, then give the descriptor back. Same
#   HARD 8-packet bound so it can never hang the timer ISR.
npoll_8168:
    pushal
    mov r8168_mmio, %ebx
    movzwl 0x3e(%ebx), %eax       # read ISR, then acknowledge every event by
    movw %ax, 0x3e(%ebx)          #   writing it back (write-1-to-clear). The
                                  #   8168 RX engine HALTS on FIFO overflow /
                                  #   descriptor-unavailable and stays halted
                                  #   until those bits are cleared - this single
                                  #   write is what keeps the receiver alive
                                  #   (proven on the test PC via nicdbg: without it RX
                                  #   dies after the ring fills once; with it the
                                  #   NIC keeps filling descriptors). Do NOT
                                  #   rebuild the ring on RDU/FOVW here - that
                                  #   clobbers a frame the NIC just DMA'd (OWN=0)
                                  #   back to OWN=1 before we ever drain it, which
                                  #   is exactly what killed RX before.
    mov $8, %ebp
    mov r8168_rxidx, %esi         # current RX descriptor index 0-3
n68_loop:
    dec %ebp
    js n68_done
    mov %esi, %eax
    shl $4, %eax
    add $R8168_RXRING, %eax       # EAX -> descriptor
    testl $0x80000000, (%eax)     # OWN still set? NIC has not filled it
    jnz n68_done
    incl rx_seen                  # a frame was delivered to us (diag counter)
    push %eax                     # the frame is in the descriptor's buffer
    push %esi
    mov 8(%eax), %esi
    call net_handle
    pop %esi
    pop %eax
    mov (%eax), %ecx              # give the descriptor back to the NIC
    and $0x40000000, %ecx         # keep EOR
    or $0x80000800, %ecx          # OWN | size 2048
    mov %ecx, (%eax)
    inc %esi                      # next of the 4 descriptors
    and $3, %esi
    mov %esi, r8168_rxidx
    jmp n68_loop
n68_done:
    popal
    ret

# net_handle: ESI -> Ethernet frame. If it is a UDP datagram to port
#   4713, look at the payload. Two things can arrive here:
#
#   * LLM-bridge traffic - part of the product, always compiled in:
#       "AGENTOS-WISH-ACK"  the proxy host confirms a 'netwish' broadcast
#                           (stops the retry loop); anything unrecognised
#                           is plain text for the 'inbox' command (bounded
#                           copy, display only, nothing is executed).
#     The LLM features themselves (wish, llm, llmscript, offload, autopilot,
#     askd, proxy discovery) do NOT go through this port at all: they use
#     the ring-3 TCP stack (user/net.c) talking TO the proxy. Only the
#     'netwish' ACK comes back this way.
#
#   * REMOTE CONTROL - a developer convenience for a headless bare-metal
#     test PC on a trusted lab LAN. It is UNAUTHENTICATED: any host that
#     can send a UDP datagram to the machine can run shell commands,
#     reboot it, launch programs or pull its logs. Covered requests:
#       AGENTOS-REBOOT, AGENTOS-ABORT, MISSION <text>, STATUS, RESULTS,
#       DMESG, RUNPROG, SELFTEST, EHCITEST, EXEC <shell line>
#     plus the shell-loop/idle-loop staging that acts on them and the
#     USB keyboard diagnostic broadcasts. All of this is compiled in ONLY
#     when the kernel is assembled with --defsym REMOTE_CTL=1
#     (make REMOTE_CTL=1, or the agentos32-dev.img target the remote test
#     suites use). The default image ignores every one of these requests
#     - they land in the inbox as text, nothing acts on them.
net_handle:
    cmpw $0x0008, 12(%esi)        # ethertype 0x0800 (IPv4)?
    jne nh_ret
    movzbl 14(%esi), %eax         # IP IHL (low nibble) * 4
    mov %eax, %ecx
    and $0xf, %ecx
    cmp $5, %ecx                  # IHL < 5 is a malformed IP header -> drop.
    jb nh_ret                     #   Untrusted input: any LAN host can send this.
    shl $2, %ecx
    cmpb $17, 23(%esi)            # IP protocol == 17 (UDP)? (offset 14+9)
    jne nh_ret
    lea 14(%esi,%ecx), %edi       # EDI -> UDP header
    cmpw $0x6912, 2(%edi)         # UDP dst port == 4713 (0x1269)?
    jne nh_ret
    incl nh_hits                  # a :4713 datagram actually reached us (diag)
    movzwl 4(%edi), %eax          # UDP length (big-endian) -> payload len
    xchg %al, %ah
    sub $8, %eax                  # payload = udp_len - 8 (header)
    js nh_ret                     # udp_len < 8 -> underflow, drop (no bogus len)
    cmp $1500, %eax               # implausibly large -> drop
    ja nh_ret
    mov %eax, nh_paylen
    lea 8(%edi), %esi             # ESI -> UDP payload
    mov $nh_wishack_str, %edi     # "AGENTOS-WISH-ACK"? (dev box confirms a wish)
    mov $16, %ecx
    push %esi
    repe cmpsb
    pop %esi
    jne nh_chk_reboot
    movb $1, wish_acked           # netwish's retry loop is waiting on this
    ret
.ifdef REMOTE_CTL                 # ---- remote control (see the block above) ----
nh_chk_reboot:
    mov $nh_reboot_str, %edi      # "AGENTOS-REBOOT"?
    mov $14, %ecx
    push %esi
    repe cmpsb
    jne nh_chk_abort
    pop %esi                      # balance the push
    mov $nh_tag_reboot, %esi      # ACK first so the dev box knows it landed,
    call nh_report                #   then reboot (TX poll flushes it first)
    jmp do_reboot                 # never returns
nh_chk_abort:
    pop %esi                      # balance nh_chk_reboot's push
    push %esi
    mov $nh_abort_str, %edi       # "AGENTOS-ABORT"? -> break out of a wedged chain
    mov $13, %ecx                 #   / 'wait' / autopilot WITHOUT a reboot (the
    repe cmpsb                    #   thing that needed a power-cycle in the field)
    jne nh_chk_status             # no-match: leave the push for nh_chk_status to pop
    pop %esi                      # match: balance our push
    movb $1, abort_req            # the shell loop + do_wait check this and bail
    ret
nh_chk_status:
    pop %esi                      # ESI -> payload (restore)
    cmpl $8, nh_paylen            # "MISSION <text>" -> update mission + STATUS
    jb nh_chk_status_plain
    push %esi
    mov $nh_mission_str, %edi
    mov $8, %ecx
    repe cmpsb
    pop %esi
    jne nh_chk_status_plain
    add $8, %esi
    mov nh_paylen, %ecx
    sub $8, %ecx
    call nh_set_mission
    mov $nh_tag_stat, %esi
    call nh_report
    ret
nh_chk_status_plain:
    push %esi
    mov $nh_status_str, %edi      # "STATUS"? -> reply with telemetry
    mov $6, %ecx
    repe cmpsb
    pop %esi
    jne nh_chk_results
    mov $nh_tag_stat, %esi
    call nh_report
    ret
nh_chk_results:
    push %esi
    mov $nh_results_str, %edi     # "RESULTS"? -> reply with task results
    mov $7, %ecx
    repe cmpsb
    pop %esi
    jne nh_chk_dmesg
    call nh_results
    ret
nh_chk_dmesg:
    push %esi
    mov $nh_dmesg_str, %edi       # "DMESG"? -> reply with the recent kernel log
    mov $5, %ecx
    repe cmpsb
    pop %esi
    jne nh_chk_run
    call nh_dmesg
    ret
nh_chk_run:
    cmpl $7, nh_paylen            # "RUNPROG" (7 bytes) -> launch the ring-3 program.
    jb nh_chk_selftest            #   Checked BEFORE the >=8 / >=10 guards below,
    push %esi                     #   which would otherwise route a 7-byte payload
    mov $nh_run_str, %edi         #   straight to the inbox and never reach here.
    mov $7, %ecx
    repe cmpsb
    pop %esi
    jne nh_chk_selftest
    movb $1, run_req              # the shell idle loop picks this up (heavy = not ISR)
    ret
nh_chk_selftest:
    cmpl $8, nh_paylen            # "SELFTEST" -> run CPU+RAM tests, log to dmesg
    jb nh_chk_exec
    push %esi
    mov $nh_selftest_str, %edi
    mov $8, %ecx
    repe cmpsb
    pop %esi
    jne nh_chk_ehci
    movb $1, selftest_req         # the shell idle loop picks this up (heavy = not ISR)
    ret
nh_chk_ehci:
    cmpl $10, nh_paylen           # "EHCITEST" + ctrl byte + port byte -> remote USB
    jb nh_chk_exec                #   enumeration (so we drive it without the keyboard)
    push %esi
    mov $nh_ehci_str, %edi
    mov $8, %ecx
    repe cmpsb
    pop %esi
    jne nh_chk_exec
    movzbl 8(%esi), %eax          # payload[8] = EHCI controller index
    mov %eax, ehci_skip
    movzbl 9(%esi), %eax          # payload[9] = downstream hub port (0 = none)
    mov %eax, ehci_dport
    movb $1, ehcitest_req
    ret
nh_chk_exec:
    cmpl $6, nh_paylen            # "EXEC <cmd>": run any shell line over the wire
    jb nh_inbox                   #   and ship the console output back (so the
    push %esi                     #   LLM session can drive the test PC's tests itself)
    mov $nh_exec_str, %edi        # "EXEC "
    mov $5, %ecx
    repe cmpsb
    pop %esi
    jne nh_inbox
    mov nh_paylen, %ecx           # copy the command text, bounded
    sub $5, %ecx
    cmp $200, %ecx
    jbe nhx_cp
    mov $200, %ecx
nhx_cp:
    add $5, %esi                  # past "EXEC "
    mov $EXEC_CMD, %edi
    rep movsb
    movb $0, (%edi)
    movb $1, exec_req             # the shell loop stages it like typed input
    ret
nh_set_mission:                    # ESI=text, ECX=len; preserves no GPRs
    push %edi
    cmp $47, %ecx
    jbe nhm_len
    mov $47, %ecx
nhm_len:
    mov $atp_mission, %edi
    push %esi
    push %ecx
    mov $48, %ecx
    xor %eax, %eax
    rep stosb
    pop %ecx
    pop %esi
    mov $atp_mission, %edi
nhm_cp:
    test %ecx, %ecx
    jz nhm_done
    movzbl (%esi), %eax
    cmp $0x20, %al
    jb nhm_space
    cmp $0x7f, %al
    jb nhm_store
nhm_space:
    mov $0x20, %al
nhm_store:
    mov %al, (%edi)
    inc %esi
    inc %edi
    dec %ecx
    jmp nhm_cp
nhm_done:
    pop %edi
    ret
.else
nh_chk_reboot:                    # default build: not a wish ACK -> just inbox text
.endif                            # ---- end remote control ----

nh_inbox:
    mov nh_paylen, %ecx           # bound the copy by the real payload length
    cmp $200, %ecx
    jbe nh_cp
    mov $200, %ecx
nh_cp:
    mov $inbox_buf, %edi
nh_cpl:
    test %ecx, %ecx
    jz nh_cpd
    movzbl (%esi), %eax
    cmp $0x20, %al                # also stop at a control char / NUL
    jb nh_cpd
    mov %al, (%edi)
    inc %esi
    inc %edi
    dec %ecx
    jmp nh_cpl
nh_cpd:
    movb $0, (%edi)
    movb $1, inbox_full           # flag: there is a new message
    ret
nh_ret:                           # early exits (before the push) land here
    ret

# nh_report: ESI = tag asciz. Broadcast the return-channel reply
#   "AgentOS/32 v<ver> <tag> up=<sec>s rx=<hex> hit=<hex> in=<hex>" to :4711,
#   so the dev box gets state back over the wire (no photographing the
#   screen). Called from net_handle (timer-ISR context) - net_udp_bcast and
#   rtl8168_send are both bounded, so this is safe there, like do_reboot.
nh_report:
    mov $REPLY_SCRATCH, %edi            # build the payload in the netwish scratch
    mov %edi, nh_rep_buf
    push %esi                     # save the tag
    mov $nh_rep_pfx, %esi         # "AgentOS/32 v<ver> "
    call bputs
    pop %esi                      # tag (e.g. "STAT" / "ACK-REBOOT")
    call bputs
    mov $nh_rep_up, %esi          # " up="
    call bputs
    mov ticks, %eax               # uptime seconds = ticks / 18
    xor %edx, %edx
    mov $18, %ecx
    div %ecx
    call bdec32
    mov $nh_rep_rx, %esi          # "s rx="
    call bputs
    mov rx_seen, %eax
    call bhex32
    mov $nh_rep_hit, %esi         # " hit="
    call bputs
    mov nh_hits, %eax
    call bhex32
    mov $nh_rep_in, %esi          # " in="
    call bputs
    movzbl inbox_full, %eax
    call bhex8
    mov $nh_rep_ms, %esi          # " ms=" (mouse present)
    call bputs
    movzbl mouse_present, %eax
    call bhex8
    mov $nh_rep_irq, %esi         # " pkt=" (complete mouse packets)
    call bputs
    mov mouse_pkts, %eax
    call bhex8
    mov $nh_rep_pa, %esi          # " a=" (8042 aux-flagged bytes seen by poll)
    call bputs
    mov poll_aux, %eax
    call bhex8
    mov $nh_rep_pk, %esi          # " k=" (8042 non-aux bytes seen by poll)
    call bputs
    mov poll_kbd, %eax
    call bhex8
    mov $nh_rep_atp, %esi         # " atp=" autopilot round count
    call bputs
    mov atp_round, %eax
    call bdec32
    mov $nh_rep_res, %esi         # " res=" framebuffer WxH (diagnose the real res)
    call bputs
    mov fb_w, %eax
    call bdec32
    movb $0x78, (%edi)            # 'x'
    inc %edi
    mov fb_h, %eax
    call bdec32
    mov $nh_rep_mis, %esi         # " mis=" the autopilot's current mission.
    call bputs                    #   LAST field, since the text may contain spaces
    mov $atp_mission, %esi
    call bputs
    mov nh_rep_buf, %esi          # ESI = payload, ECX = length
    mov %edi, %ecx
    sub %esi, %ecx
    call net_udp_bcast            # broadcast it to 255.255.255.255:4711
    ret

# nh_results: pull query. On a "RESULTS" datagram, broadcast every
#   finished/errored task's result to :4711 as
#   "AgentOS/32 v<ver> RSLT t<i>=<dec> ...". EBP holds the task pointer
#   (npoll_8168 keeps its packet counter in EBP across net_handle, so we
#   must preserve it). Decimal; negative results get a leading '-'.
nh_results:
    push %ebp
    mov $REPLY_SCRATCH, %edi
    mov %edi, nh_rep_buf
    mov $nh_rep_pfx, %esi
    call bputs
    mov $nh_rslt_tag, %esi        # "RSLT"
    call bputs
    xor %ebx, %ebx
nr_loop:
    mov %ebx, %eax
    shl $4, %eax
    lea tasks_tbl(%eax), %ebp     # EBP -> task entry
    cmpb $0, (%ebp)               # used?
    je nr_next
    movzbl 2(%ebp), %eax          # status: 2 done, 3 ERROR
    cmp $2, %eax
    je nr_done
    cmp $3, %eax
    jne nr_next
    mov $nh_rslt_sp, %esi         # " t"
    call bputs
    mov %ebx, %eax
    call bdec32
    mov $nh_rslt_err, %esi        # "=ERR"
    call bputs
    jmp nr_next
nr_done:
    mov $nh_rslt_sp, %esi         # " t"
    call bputs
    mov %ebx, %eax
    call bdec32
    mov $nh_rslt_eq, %esi         # "="
    call bputs
    mov 12(%ebp), %eax            # result (signed long)
    test %eax, %eax
    jns nr_pos
    push %eax
    mov $nh_rslt_neg, %esi        # "-"
    call bputs
    pop %eax
    neg %eax
nr_pos:
    call bdec32
nr_next:
    inc %ebx
    cmp $8, %ebx
    jb nr_loop
    mov nh_rep_buf, %esi
    mov %edi, %ecx
    sub %esi, %ecx
    call net_udp_bcast
    pop %ebp
    ret

# nh_pushdone: auto-push. Called from sys_finish - the moment an agent
#   finishes, broadcast its result so the dev box gets it without polling:
#   "AgentOS/32 v<ver> DONE a<slot> <type>=<dec>". net up only.
nh_pushdone:
    cmpb $0, net_present
    je nhd_ret
    push %ebp
    mov $REPLY_SCRATCH, %edi
    mov %edi, nh_rep_buf
    mov $nh_rep_pfx, %esi
    call bputs
    mov $nh_done_tag, %esi        # "DONE a"
    call bputs
    call my_core ; movzbl cur_thread(%eax), %eax
    dec %eax
    call bdec32                   # agent slot
    mov notify_task, %ebp         # EBP -> the finished task
    mov $nh_rslt_sp2, %esi        # " "
    call bputs
    movzbl 1(%ebp), %eax          # task type -> name
    mov type_names(,%eax,4), %esi
    call bputs
    mov $nh_rslt_eq, %esi         # "="
    call bputs
    mov 12(%ebp), %eax            # result
    test %eax, %eax
    jns nhd_pos
    push %eax
    mov $nh_rslt_neg, %esi
    call bputs
    pop %eax
    neg %eax
nhd_pos:
    call bdec32
    mov nh_rep_buf, %esi
    mov %edi, %ecx
    sub %esi, %ecx
    call net_udp_bcast
    pop %ebp
nhd_ret:
    ret

# nh_dmesg: On a "DMESG" datagram, broadcast the most recent ~200 bytes
#   of the kernel log ring (at LOG_BUF) to :4711 - remote `dmesg`, no
#   screen needed. Capped to the netwish scratch (REPLY_SCRATCH, <256 B before
#   NIC_PKT); the full log stays available on the serial/screen `dmesg`.
nh_dmesg:
    push %ebp
    mov $REPLY_SCRATCH, %edi
    mov %edi, nh_rep_buf
    mov $nh_rep_pfx, %esi          # "AgentOS/32 v<ver> "
    call bputs
    mov $nh_dmsg_tag, %esi         # "DMSG\r\n"
    call bputs
    mov log_pos, %ecx              # total bytes logged
    cmpb $0, log_wrapped
    je ndm_tot
    mov $LOG_SIZE, %ecx
ndm_tot:
    mov $200, %eax                 # send_len = min(total, 200)
    cmp %eax, %ecx
    jae ndm_cap
    mov %ecx, %eax
ndm_cap:
    mov log_pos, %ebx              # start = (log_pos - send_len) mod LOG_SIZE
    sub %eax, %ebx
    jns ndm_start
    add $LOG_SIZE, %ebx
ndm_start:
    mov %eax, %ebp                 # EBP = bytes left to copy
ndm_cp:
    test %ebp, %ebp
    jz ndm_send
    movzbl LOG_BUF(%ebx), %eax
    mov %al, (%edi)
    inc %edi
    inc %ebx
    cmp $LOG_SIZE, %ebx
    jb ndm_cp2
    xor %ebx, %ebx
ndm_cp2:
    dec %ebp
    jmp ndm_cp
ndm_send:
    mov nh_rep_buf, %esi
    mov %edi, %ecx
    sub %esi, %ecx
    call net_udp_bcast
    pop %ebp
    ret

# =====================================================================
#  kernel log / dmesg. A byte ring in free RAM (the binary budget is
#  tight, so not in the image). log_str appends an asciz line; dmesg dumps
#  it oldest-first. Atomic (cli) - called from ISRs too. Records the events
#  that matter for blind hardware debugging: boot, NIC, watchdog kills.
# =====================================================================
.equ LOG_BUF, 0x102000         # dmesg ring - moved into the 1 MB region too
.equ LOG_SIZE, 4096
.equ PEND_BUF, 0x103000        # shell ';'-chaining stage buffer (free 1 MB region)
log_str:                          # ESI -> asciz line to append
    pushfl
    cli
    push %eax
    push %ebx
    push %esi
    mov log_pos, %ebx
ls_l:
    lodsb
    test %al, %al
    jz ls_d
    mov %al, LOG_BUF(%ebx)
    inc %ebx
    cmp $LOG_SIZE, %ebx
    jb ls_l
    xor %ebx, %ebx               # wrap: overwrite the oldest
    movb $1, log_wrapped
    jmp ls_l
ls_d:
    mov %ebx, log_pos
    pop %esi
    pop %ebx
    pop %eax
    popfl
    ret

log_boot:                         # boot banner + NIC line into the log
    mov $logm_boot, %esi          # "AgentOS/32 v<ver>: boot\n"
    call log_str
    cmpb $0, net_present
    je lb_ret
    mov $logm_net, %esi           # "net: NIC up\n"
    call log_str
lb_ret:
    ret

# log_hwinfo: at boot, write the CPU + RAM detection into the dmesg ring, so
#   the dev box reads the real hardware off the test PC over the wire (net-dmesg.sh)
#   on every boot - self-debugging the hardware detection, no screen needed.
#   Builds each line in the netwish scratch (free at boot) then log_str's it.
log_hwinfo:
    mov $REPLY_SCRATCH, %edi
    mov $logp_cpu, %esi           # "cpu: "
    call bputs
    xor %eax, %eax                # leaf 0 -> vendor string (EBX,EDX,ECX)
    cpuid
    mov %ebx, (%edi)
    mov %edx, 4(%edi)
    mov %ecx, 8(%edi)
    add $12, %edi
    mov $logp_cores, %esi         # " cores "
    call bputs
    mov $1, %eax                  # leaf 1 -> cores (EBX 16:23), features (EDX/ECX)
    cpuid
    mov %edx, feat_edx
    mov %ecx, feat_ecx
    shr $16, %ebx
    movzbl %bl, %eax
    call bdec32
    mov $logp_feat, %esi          # " feat "
    call bputs
    mov feat_edx, %eax
    call bhex32
    mov $logp_slash, %esi         # "/"
    call bputs
    mov feat_ecx, %eax
    call bhex32
    mov $logp_crlf, %esi          # "\r\n"
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    mov $REPLY_SCRATCH, %edi       # second line: RAM
    mov $logp_ram, %esi           # "ram: "
    call bputs
    mov (E820_TOTAL), %eax
    shr $20, %eax                 # bytes -> MB
    call bdec32
    mov $logp_mb, %esi            # " MB (E820)\r\n"
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    mov $REPLY_SCRATCH, %edi       # third line: first PCI storage controller -
    mov $logp_pcis, %esi           # "stor: " vendor:device + subclass, so the
    call bputs                     # dev box reads the test PC's disk controller type
    xor %ebx, %ebx                 # (IDE/SATA/AHCI/NVMe) over the wire
lh_pscan:
    mov %ebx, %ebp
    shl $8, %ebp
    or $0x80000000, %ebp
    mov %ebp, %eax
    call pci_read                  # device:vendor
    cmp $0xffffffff, %eax
    je lh_pnext
    test %eax, %eax
    jz lh_pnext
    mov %eax, lp_vd
    lea 0x08(%ebp), %eax           # class/subclass/prog-if/rev
    call pci_read
    mov %eax, lp_class
    shr $24, %eax                  # class byte
    cmp $1, %al                    # storage controller?
    jne lh_pnext
    mov lp_vd, %eax                # vendor
    call bhex16
    mov $logp_colon, %esi
    call bputs
    mov lp_vd, %eax                # device
    shr $16, %eax
    call bhex16
    mov $logp_sp1, %esi
    call bputs
    mov lp_class, %eax             # subclass -> name (IDE/SATA/AHCI/...)
    shr $16, %eax
    mov %al, %dl
    call pci_storsub
    call bputs
    jmp lh_pdone
lh_pnext:
    inc %ebx
    cmp $0x4000, %ebx
    jb lh_pscan
    mov $logp_none, %esi           # no storage controller found
    call bputs
lh_pdone:
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    ret

# run_selftest: triggered by a remote SELFTEST (flag set in net_handle, run
#   here from the shell idle loop - NOT the ISR, so the heavy loops are fine;
#   the timer still preempts so STATUS stays answerable). Runs a CPU bench +
#   a RAM test and logs both to dmesg, so the dev box reads the results over
#   the wire (net-dmesg.sh). Closes the self-debug loop for the *tests* too.
do_selftest:                      # queue the self-test; the idle loop runs it
    movb $1, selftest_req
    mov $msg_selftest, %esi       # "self-test queued -> results in dmesg\r\n"
    call puts
    jmp shell
run_selftest:
    pushal
    movb $0, selftest_req
    mov ticks, %eax               # CPU bench: run 50M chunks until >= 4 ticks pass,
st_align:                         #   so MHz is reliable on ANY speed CPU and the
    mov ticks, %ebp               #   32-bit cycle delta can't overflow (4 ticks
    cmp %eax, %ebp                #   ~0.22s ~ <1B cycles at 4 GHz). Align to a tick
    je st_align                   #   edge first.
    rdtsc
    mov %eax, %esi                # cycle start
    xor %ebx, %ebx                # checksum
st_chunk:
    mov $50000000, %ecx
st_cpu:
    mov %ecx, %eax
    imul $2654435761, %eax, %eax
    add %eax, %ebx
    dec %ecx
    jnz st_cpu
    mov ticks, %eax
    sub %ebp, %eax
    cmp $4, %eax
    jb st_chunk
    rdtsc
    sub %esi, %eax
    mov %eax, ct_cycles
    mov ticks, %eax
    sub %ebp, %eax
    mov %eax, ct_ticksd
    mov $REPLY_SCRATCH, %edi      # "cpu-bench: <cycles> cyc ~<MHz> MHz"
    mov $logp_cpb, %esi
    call bputs
    mov ct_cycles, %eax
    call bdec32
    mov $logp_cyc, %esi
    call bputs
    mov ct_ticksd, %ecx
    test %ecx, %ecx
    jz st_nomhz
    mov ct_cycles, %eax          # MHz = cycles * 18 / ticks / 1e6
    mov $18, %ecx
    mul %ecx
    mov ct_ticksd, %ecx
    div %ecx
    xor %edx, %edx
    mov $1000000, %ecx
    div %ecx
    call bdec32
st_nomhz:
    mov $logp_mhz, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    mov $16, %eax                 # RAM test: 16 MB (quick health check), capped
    mov (E820_TOTAL), %ecx
    test %ecx, %ecx
    jz st_rmset
    shr $20, %ecx
    sub $4, %ecx
    cmp %ecx, %eax
    jbe st_rmset
    mov %ecx, %eax
st_rmset:
    mov %eax, rt_mb
    call rt_maphigh
    xor %edi, %edi                # error count (rt_pattern accumulates into EDI)
    mov $0xaa55aa55, %eax
    call rt_pattern
    mov $0x55aa55aa, %eax
    call rt_pattern
    call rt_addrtest
    call rt_movinv                # moving inversions in the remote self-test too
    mov %edi, %ebp                # EBP = errors
    mov $REPLY_SCRATCH, %edi      # "ram-test: <mb> MB errors <e>"
    mov $logp_rmt, %esi
    call bputs
    mov rt_mb, %eax
    call bdec32
    mov $logp_rme, %esi
    call bputs
    mov %ebp, %eax
    call bdec32
    mov $logp_crlf, %esi
    call bputs
    movb $0, (%edi)
    mov $REPLY_SCRATCH, %esi
    call log_str
    popal
    ret

do_dmesg:                         # dump the ring oldest-first
    cmpb $0, log_wrapped
    je dm_lin
    mov log_pos, %ebx             # wrapped: from log_pos to end, then 0..log_pos
dm_w1:
    cmp $LOG_SIZE, %ebx
    jae dm_w2
    movzbl LOG_BUF(%ebx), %eax
    push %ebx
    call putc
    pop %ebx
    inc %ebx
    jmp dm_w1
dm_w2:
    xor %ebx, %ebx
dm_lin:
    mov log_pos, %ecx
    xor %ebx, %ebx
    cmpb $0, log_wrapped
    je dm_l
    mov log_pos, %ecx             # (already from 0 here for the tail)
dm_l:
    cmp %ecx, %ebx
    jae dm_done
    movzbl LOG_BUF(%ebx), %eax
    push %ebx
    push %ecx
    call putc
    pop %ecx
    pop %ebx
    inc %ebx
    jmp dm_l
dm_done:
    jmp shell

serial_putc:                     # AL -> COM1 and COM2 (server SOL is COM2);
    push %eax                    #   an absent UART (LSR 0xFF) is skipped
    push %ecx
    push %edx
    mov %al, %ah
    mov $0x3fd, %dx
    call ser_tx
    mov $0x2fd, %dx
    call ser_tx
    pop %edx
    pop %ecx
    pop %eax
    ret
ser_tx:                          # DX = LSR port, AH = byte; bounded wait
    mov $0x10000, %ecx
spw:
    in %dx, %al
    cmp $0xff, %al
    je sp_done
    test $0x20, %al
    jnz sp_send
    loop spw
    jmp sp_done
sp_send:
    sub $5, %dx
    mov %ah, %al
    out %al, %dx
    add $5, %dx
sp_done:
    ret

# hw_com2_init: COM2 115200 8N1, FIFO, no IRQ (output-only debug/SOL mirror)
hw_com2_init:
    push %eax
    push %edx
    mov $0x2f9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x2fb, %dx
    mov $0x80, %al
    out %al, %dx
    mov $0x2f8, %dx
    mov $1, %al
    out %al, %dx
    mov $0x2f9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x2fb, %dx
    mov $3, %al
    out %al, %dx
    mov $0x2fa, %dx
    mov $0xc7, %al
    out %al, %dx
    mov $0x2fc, %dx
    mov $3, %al
    out %al, %dx
    pop %edx
    pop %eax
    ret

# hw_mark: AL = marker byte -> COM2 only (COM1 stays byte-exact for the
#   QEMU gate); plus a colour stripe in the firmware framebuffer while
#   paging is off (the physical address is valid then).
hw_mark:
    pushal
    mov %al, %ah
    mov $0x2fd, %dx
    call ser_tx
    movzbl %ah, %ebp             # keep the marker byte
    mov %cr0, %eax
    test $0x80000000, %eax
    jnz hwm_done
    cmpl $0x49464555, UEFI_INFO
    jne hwm_done
    mov UEFI_INFO+8, %edi
    test %edi, %edi
    jz hwm_done
    cmpl $0, UEFI_INFO+0xc
    jne hwm_done
    cmp $0x61, %ebp              # only the stage letters a..z paint
    jb hwm_done
    movzbl hw_bar_n, %eax
    incb hw_bar_n
    cmp $20, %eax
    jae hwm_done
    mov %eax, %ebx
    and $7, %ebx
    mov hw_cols(,%ebx,4), %ebx
    add $4, %eax                 # the loader paints stripes 0-2
    imul $20, %eax, %eax
    add $8, %eax
    mull UEFI_INFO+0x18          # * pixels per scanline
    lea (%edi,%eax,4), %edi
    mov $16, %edx
hwm_row:
    push %edi
    mov UEFI_INFO+0x10, %ecx
    mov %ebx, %eax
    rep stosl
    pop %edi
    mov UEFI_INFO+0x18, %eax
    lea (%edi,%eax,4), %edi
    dec %edx
    jnz hwm_row
hwm_done:
    popal
    ret
hw_puts:                         # ESI = asciz -> COM2
    push %eax
hwp_l:
    lodsb
    test %al, %al
    jz hwp_d
    pushal
    mov %al, %ah
    mov $0x2fd, %dx
    call ser_tx
    popal
    jmp hwp_l
hwp_d:
    pop %eax
    ret
hw_hex:                          # EAX -> 8 hex digits + ' ' on COM2
    pushal
    mov %eax, %edx
    mov $8, %ecx
hwh_l:
    rol $4, %edx
    mov %dl, %al
    and $15, %al
    add $0x30, %al
    cmp $0x39, %al
    jbe hwh_d
    add $7, %al
hwh_d:
    push %ecx
    push %edx
    mov %al, %ah
    mov $0x2fd, %dx
    call ser_tx
    pop %edx
    pop %ecx
    loop hwh_l
    mov $0x20, %ah
    mov $0x2fd, %dx
    call ser_tx
    popal
    ret
hw_cols:
    .long 0xff0000, 0xff8000, 0xffff00, 0x00ff00, 0x00ffff, 0x0000ff, 0xff00ff, 0xffffff
hw_bar_n:  .byte 0
hwm_hello: .asciz "\r\nAF kernel cr0/cr4/ram: "
    .balign 4

# serial_cp437: AL = a CP437 code >= 0x80 -> its UTF-8 sequence on COM1
#   (the glyphs the framebuffer font knows; anything else is sent raw).
serial_cp437:
    push %eax
    push %esi
    movzbl %al, %esi
    movzbl font_cp437_map-0x80(%esi), %esi
    test %esi, %esi
    jz sc8_raw
    lea font_extra_utf8-4(,%esi,4), %esi
sc8_l:
    lodsb
    test %al, %al
    jz sc8_d
    call serial_putc
    jmp sc8_l
sc8_raw:
    pop %esi
    pop %eax
    jmp serial_putc
sc8_d:
    pop %esi
    pop %eax
    ret

com1_isr:
    pushal
sr_next:
    mov $0x3fd, %dx
    in %dx, %al
    cmp $0xff, %al
    je sr_done
    test $0x01, %al
    jz sr_done
    mov $0x3f8, %dx
    in %dx, %al
    cmpb $1, esc_state
    je sr_esc1
    cmpb $2, esc_state
    je sr_esc2
    cmpb $3, esc_state
    je sr_esc3
    cmp $0x1b, %al
    je sr_esc_start
    cmp $3, %al                  # Ctrl+C: serial chain/autopilot abort (a lone
    je sr_ctlc                   #   ESC is eaten by the ESC-[ sequence decoder)
    cmp $13, %al
    je sr_enter
    cmp $10, %al
    je sr_enter
    cmp $0x7f, %al
    je sr_bs
    cmp $8, %al
    je sr_bs
    cmp $0x20, %al
    jb sr_ctl
    cmp $0x7e, %al
    ja sr_next
    xor %ah, %ah
    call push_key
    jmp sr_next
sr_ctl:
    cmpb $0, fg_prog             # control bytes (^S, ^Q, Tab, ...) reach a
    je sr_next                   #   foreground ring-3 program only; the shell
    xor %ah, %ah                 #   line editor keeps ignoring them
    call push_key
    jmp sr_next
sr_enter:
    mov $0x000d, %ax
    call push_key
    jmp sr_next
sr_ctlc:
    mov $0x0003, %ax
    call push_key
    jmp sr_next
sr_bs:
    mov $0x0008, %ax
    call push_key
    jmp sr_next
sr_esc_start:
    movb $1, esc_state
    jmp sr_next
sr_esc1:
    movb $0, esc_state
    cmp $0x1b, %al               # ESC ESC: a lone Escape for a foreground
    je sr_esc_lone               #   ring-3 program (a single ESC is eaten here)
    cmp $0x5b, %al
    jne sr_next
    movb $2, esc_state
    jmp sr_next
sr_esc_lone:
    cmpb $0, fg_prog
    je sr_next
    mov $0x001b, %ax
    call push_key
    jmp sr_next
# ESC [ A/B/C/D/H/F -> the PS/2 scancodes of up/down/right/left/home/end;
#   ESC [ 1..6 ~ -> home/del/end/pgup/pgdn (vt100/xterm). Pushed scancode-
#   only (AL=0): readline keeps using 0x48 for history, ring-3 programs get
#   0x80|scancode out of the key ring (see pk_ring).
sr_esc2:
    movb $0, esc_state
    mov $0x48, %ah
    cmp $0x41, %al               # 'A' up
    je sr_esc_push
    mov $0x50, %ah
    cmp $0x42, %al               # 'B' down
    je sr_esc_push
    mov $0x4d, %ah
    cmp $0x43, %al               # 'C' right
    je sr_esc_push
    mov $0x4b, %ah
    cmp $0x44, %al               # 'D' left
    je sr_esc_push
    mov $0x47, %ah
    cmp $0x48, %al               # 'H' home
    je sr_esc_push
    mov $0x4f, %ah
    cmp $0x46, %al               # 'F' end
    je sr_esc_push
    cmp $0x31, %al               # '1'..'6': remember the digit, wait for '~'
    jb sr_next
    cmp $0x36, %al
    ja sr_next
    mov %al, esc_digit
    movb $3, esc_state
    jmp sr_next
sr_esc_push:
    xor %al, %al
    call push_key
    jmp sr_next
sr_esc3:
    movb $0, esc_state
    cmp $0x7e, %al               # '~' closes the sequence
    jne sr_next
    mov esc_digit, %al
    mov $0x47, %ah
    cmp $0x31, %al               # '1' home
    je sr_esc_push
    mov $0x53, %ah
    cmp $0x33, %al               # '3' delete
    je sr_esc_push
    mov $0x4f, %ah
    cmp $0x34, %al               # '4' end
    je sr_esc_push
    mov $0x49, %ah
    cmp $0x35, %al               # '5' page up
    je sr_esc_push
    mov $0x51, %ah
    cmp $0x36, %al               # '6' page down
    je sr_esc_push
    jmp sr_next
sr_done:
    mov $0x20, %al
    out %al, $0x20
    popal
    iret

# =====================================================================
#  ATA DISK DRIVER (PIO, LBA28, primary master)
# =====================================================================
ata_init:
    push %eax
    push %edx
    mov $0x3f6, %dx
    mov $0x02, %al               # nIEN: no disk IRQs, we poll
    out %al, %dx
    pop %edx
    pop %eax
    ret

# ata_wait_flush: ata_wait_rdy with ~64x the patience. FLUSH CACHE is the
#   one command whose BSY time is the HOST's: under QEMU it is an fdatasync
#   of the image file, which on a loaded box outlasts 64K status reads and
#   turned a successful slot write into -1 (llmscript/askd "REFUSED").
ata_wait_flush:
    push %eax
    push %ecx
    push %edx
    mov $0x1f7, %dx
    mov $0x400000, %ecx
    jmp aw_loop
ata_wait_rdy:
    push %eax
    push %ecx
    push %edx
    mov $0x1f7, %dx
    mov $0x10000, %ecx
aw_loop:
    in %dx, %al
    cmp $0xff, %al
    je aw_fail
    test $0x80, %al
    jz aw_ok
    loop aw_loop
aw_fail:
    pop %edx
    pop %ecx
    pop %eax
    stc
    ret
aw_ok:
    pop %edx
    pop %ecx
    pop %eax
    clc
    ret

ata_wait_drq:
    push %eax
    push %ecx
    push %edx
    mov $0x1f7, %dx
    mov $0x10000, %ecx
ad_loop:
    in %dx, %al
    test $0x01, %al
    jnz ad_fail
    test $0x08, %al
    jnz ad_ok
    loop ad_loop
ad_fail:
    pop %edx
    pop %ecx
    pop %eax
    stc
    ret
ad_ok:
    pop %edx
    pop %ecx
    pop %eax
    clc
    ret

# ata_setup: AX = LBA (16 bits are enough for us), BL = ATA command
ata_setup:
    push %eax
    push %edx
    call ata_wait_rdy
    jc as_out
    push %eax
    mov $0x1f2, %dx
    mov $1, %al
    out %al, %dx
    pop %eax
    mov $0x1f3, %dx
    out %al, %dx
    mov $0x1f4, %dx
    mov %ah, %al
    out %al, %dx
    mov $0x1f5, %dx
    xor %al, %al
    out %al, %dx
    mov $0x1f6, %dx
    mov $0xe0, %al
    out %al, %dx
    mov $0x1f7, %dx
    mov %bl, %al
    out %al, %dx
    clc
as_out:
    pop %edx
    pop %eax
    ret

# ram_slot_addr: EAX = LBA -> CF=0 and EDX = SLOT_RAM address when the LBA is
#   an AgentFS/wish/tasks slot (257-273), CF=1 otherwise. Preserves EAX.
#   on a diskless / foreign-disk box diskon arms RAM-backed slots (fs_ram)
#   instead of refusing, so llmscript/script/autopilot work with no medium and
#   the foreign disk is never written. ata_read/ata_write reroute slot LBAs to
#   this RAM region; everything else (boot reads, marker) still hits the disk.
ram_slot_addr:
    push %eax
    sub $257, %eax
    jc rsa_no                    # LBA < 257
    cmp $16, %eax
    ja rsa_no                    # LBA > 273 (17 slots: 257..273)
    shl $9, %eax                 # *512
    lea SLOT_RAM(%eax), %edx
    pop %eax
    clc
    ret
rsa_no:
    pop %eax
    stc
    ret

# ata_read: AX = LBA, EDI = destination buffer (512 bytes). CF=1 on error.
ata_read:
    cmpb $0, fs_ram
    je ar_phys
    push %edx
    call ram_slot_addr
    jnc ar_ram
    pop %edx
    jmp ar_phys
ar_ram:
    push %ecx
    push %esi
    push %edi
    mov %edx, %esi               # RAM slot -> caller's EDI buffer
    mov $128, %ecx
    rep movsl
    pop %edi
    pop %esi
    pop %ecx
    pop %edx
    clc
    ret
ar_phys:
    push %eax
    push %ebx
    push %ecx
    push %edx
    push %edi
    mov $0x20, %bl
    call ata_setup
    jc ar_out
    call ata_wait_drq
    jc ar_out
    mov $0x1f0, %dx
    mov $256, %ecx
    rep insw
    clc
ar_out:
    pop %edi
    pop %edx
    pop %ecx
    pop %ebx
    pop %eax
    ret

# smart_cmd: issue a SMART command, feature in BL, no data phase. Loads
#   the SMART signature LBA (mid 0x4F, hi 0xC2) and command 0xB0 to the
#   primary master. CF=1 if the controller never went ready.
smart_cmd:
    push %eax
    push %edx
    call ata_wait_rdy
    jc smc_out
    mov $0x1f1, %dx              # feature = BL
    mov %bl, %al
    out %al, %dx
    mov $0x1f2, %dx              # sector count = 1
    mov $1, %al
    out %al, %dx
    mov $0x1f3, %dx              # LBA low = 0
    xor %al, %al
    out %al, %dx
    mov $0x1f4, %dx              # LBA mid = 0x4F (SMART magic)
    mov $0x4f, %al
    out %al, %dx
    mov $0x1f5, %dx              # LBA hi = 0xC2
    mov $0xc2, %al
    out %al, %dx
    mov $0x1f6, %dx              # primary master, LBA
    mov $0xe0, %al
    out %al, %dx
    mov $0x1f7, %dx              # command = 0xB0 (SMART)
    mov $0xb0, %al
    out %al, %dx
    clc
smc_out:
    pop %edx
    pop %eax
    ret

# --- smart: drive health + key SMART attributes (temp, hours, sectors)
do_smart:
    mov $0xd8, %bl               # SMART ENABLE OPERATIONS
    call smart_cmd
    call ata_wait_rdy
    mov $0xda, %bl               # SMART RETURN STATUS (health)
    call smart_cmd
    jc sm_nodrv
    call ata_wait_rdy
    jc sm_nodrv
    mov $0x0b, %al               # cyan label
    mov $msg_sm_health, %esi
    call putsc
    mov $0x1f4, %dx              # LBA mid 0xF4 + hi 0x2C => threshold exceeded
    in %dx, %al
    cmp $0xf4, %al
    je sm_fail
    mov $0x0a, %al               # green
    mov $msg_sm_ok, %esi
    call putsc
    jmp sm_data
sm_fail:
    mov $0x0c, %al               # red
    mov $msg_sm_fail, %esi
    call putsc
sm_data:
    mov $0xd0, %bl               # SMART READ DATA -> 512 bytes
    call smart_cmd
    jc sm_done
    call ata_wait_drq
    jc sm_done
    mov $fs_buf, %edi
    mov $0x1f0, %dx
    mov $256, %ecx
    rep insw
    mov $fs_buf+2, %ebp          # EBP = attribute record, EDI = count
    mov $30, %edi                # (print helpers preserve EBP/EDI)
sm_attr:
    movzbl 0(%ebp), %eax         # attribute id (0 = unused slot)
    test %eax, %eax
    jz sm_next
    cmp $194, %eax               # 0xC2 = temperature (Celsius)
    je sm_temp
    cmp $9, %eax                 # power-on hours
    je sm_hours
    cmp $5, %eax                 # reallocated sectors
    je sm_realloc
    cmp $197, %eax               # current pending sectors
    je sm_pending
    jmp sm_next
sm_temp:
    mov $0x0b, %al
    mov $msg_sm_temp, %esi
    call putsc
    movzbl 5(%ebp), %eax         # raw[0] = degrees C
    call print_dec32
    mov $msg_sm_c, %esi
    call puts
    jmp sm_next
sm_hours:
    mov $0x0b, %al
    mov $msg_sm_hours, %esi
    call putsc
    mov 5(%ebp), %eax            # raw dword = hours
    call print_dec32
    mov $msg_done4, %esi
    call puts
    jmp sm_next
sm_realloc:
    mov $0x0b, %al
    mov $msg_sm_realloc, %esi
    call putsc
    movzwl 5(%ebp), %eax
    call print_dec32
    mov $msg_done4, %esi
    call puts
    jmp sm_next
sm_pending:
    mov $0x0b, %al
    mov $msg_sm_pending, %esi
    call putsc
    movzwl 5(%ebp), %eax
    call print_dec32
    mov $msg_done4, %esi
    call puts
sm_next:
    add $12, %ebp
    dec %edi
    jnz sm_attr
sm_done:
    jmp shell
sm_nodrv:
    mov $msg_sm_none, %esi
    call puts
    jmp shell

# --- temp: CPU temperature via the Intel digital thermal sensor (MSR).
#   Guarded by vendor + CPUID.06H so rdmsr never #GPs on a CPU without
#   it (then it just says 'not available'). Fan tach is Super-I/O and
#   board-specific - out of scope here.
do_temp:
    xor %eax, %eax               # vendor == GenuineIntel?
    cpuid
    cmp $0x756e6547, %ebx        # "Genu"
    jne temp_na
    cmp $0x49656e69, %edx        # "ineI"
    jne temp_na
    cmp $0x6c65746e, %ecx        # "ntel"
    jne temp_na
    mov $6, %eax                 # digital thermal sensor present?
    cpuid
    test $1, %eax                # CPUID.06H:EAX bit 0
    jz temp_na
    mov $0x1a2, %ecx             # MSR_TEMPERATURE_TARGET: TjMax bits 23:16
    rdmsr
    shr $16, %eax
    and $0xff, %eax
    test %eax, %eax
    jnz temp_tj
    mov $100, %eax               # default TjMax if the MSR reads 0
temp_tj:
    mov %eax, temp_tjmax
    mov $0x19c, %ecx             # IA32_THERM_STATUS: readout bits 22:16
    rdmsr
    shr $16, %eax
    and $0x7f, %eax              # degrees BELOW TjMax
    mov temp_tjmax, %edx
    sub %eax, %edx               # actual temp = TjMax - readout
    mov $0x0b, %al
    mov $msg_temp1, %esi
    call putsc
    mov %edx, %eax
    call print_dec32
    mov $msg_temp_c, %esi
    call puts
    jmp shell
temp_na:
    mov $msg_temp_na, %esi
    call puts
    jmp shell

# --- inbox: show the last message received over the network return
#   channel (UDP to port 4713). 'netwish' on the dev box sends TO the
#   dev box; this shows what came back the other way.
do_inbox:
    cmpb $0, inbox_full
    je inbox_empty
    mov $0x0b, %al
    mov $msg_inbox1, %esi         # "inbox: "
    call putsc
    mov $inbox_buf, %esi
    call puts
    call crlf
    movb $0, inbox_full           # mark as read
    jmp shell
inbox_empty:
    mov $msg_inbox0, %esi
    call puts
    jmp shell

# --- nicdbg: RTL8168 self-diagnosis. Dumps the live RX state both to the
#   SCREEN (photograph it - the dependable path, since this NIC's TX turns
#   out to be unreliable across boots) AND as an ASCII UDP broadcast to
#   :4711 (caught by tcpdump on the dev box when TX happens to work).
#   Fields (hex): "DBG CR ISR RCR PHY i D0 D1 D2 D3"
#   CR(0x37) TE|RE, ISR(0x3E) RxOK/RDU/FOVW, RCR(0x44), PHYstatus(0x6C)
#   link/speed, r8168_rxidx, and the 4 RX descriptors' dword0 (OWN bit:
#   set = NIC still owns it / nothing received; clear = a frame landed).
do_nicdbg:
    cmpb $3, net_present
    jne nd_no
    mov $0x0a, %al                # --- screen readout (TX-independent) ---
    mov $nd_l_cr, %esi            # "DBG CR="
    call putsc
    mov r8168_mmio, %ebx
    movzbl 0x37(%ebx), %eax
    call phex8
    mov $nd_l_isr, %esi           # " ISR="
    call puts
    mov r8168_mmio, %ebx
    movzwl 0x3e(%ebx), %eax
    call phex16
    mov $nd_l_rcr, %esi           # " RCR="
    call puts
    mov r8168_mmio, %ebx
    mov 0x44(%ebx), %eax
    call phex32
    mov $nd_l_phy, %esi           # " PHY="
    call puts
    mov r8168_mmio, %ebx
    movzbl 0x6c(%ebx), %eax
    call phex8
    mov $nd_l_i, %esi             # " i="
    call puts
    mov r8168_rxidx, %eax
    call phex8
    mov $nd_l_rxd, %esi           # "\r\nrxd"
    call puts
    xor %ebp, %ebp
nd_sloop:
    mov $nd_l_sp, %esi            # " "
    call puts
    mov %ebp, %eax
    shl $4, %eax
    add $R8168_RXRING, %eax
    mov (%eax), %eax
    call phex32
    inc %ebp
    cmp $4, %ebp
    jb nd_sloop
    mov $nd_l_rx, %esi            # "  rx="  frames net_poll drained
    call puts
    mov rx_seen, %eax
    call phex32
    mov $nd_l_hit, %esi           # " hit="  datagrams matching :4713
    call puts
    mov nh_hits, %eax
    call phex32
    call crlf
    mov $REPLY_SCRATCH, %edi            # --- and broadcast the same (when TX works) ---
    push %edi
    mov $nd_pfx, %esi             # "DBG "
    call bputs
    mov r8168_mmio, %ebx
    movzbl 0x37(%ebx), %eax       # CR  (TE|RE|RST)
    call bhex8
    call bsp
    mov r8168_mmio, %ebx
    movzwl 0x3e(%ebx), %eax       # ISR (RxOK bit0, RDU bit4, FOVW bit6)
    call bhex16
    call bsp
    mov r8168_mmio, %ebx
    mov 0x44(%ebx), %eax          # RCR
    call bhex32
    call bsp
    mov r8168_mmio, %ebx
    movzbl 0x6c(%ebx), %eax       # PHYstatus (LinkSts bit1, speed bits)
    call bhex8
    call bsp
    mov r8168_rxidx, %eax         # current RX descriptor index
    call bhex8
    xor %ebp, %ebp                # append the 4 RX descriptors' dword0
nd_dloop:
    call bsp
    mov %ebp, %eax
    shl $4, %eax
    add $R8168_RXRING, %eax
    mov (%eax), %eax
    call bhex32
    inc %ebp
    cmp $4, %ebp
    jb nd_dloop
    pop %esi                      # ESI = payload, ECX = its length
    mov %edi, %ecx
    sub %esi, %ecx
    call net_udp_bcast            # broadcast it to 255.255.255.255:4711
    jmp shell
nd_no:
    mov $msg_nd_no, %esi          # "nicdbg: no RTL8168\r\n"
    call puts
    jmp shell

# --- disktest: read 4000 sectors (2 MB) from the primary master,
#   count read errors and time it (RDTSC + ticks) for a MB/s figure.
do_disktest:
    mov $0x0e, %al
    mov $msg_dt1, %esi
    call putsc
    xor %ebp, %ebp               # EBP = read error count
    mov ticks, %eax
    mov %eax, ct_ticks0
    xor %ebx, %ebx               # EBX = LBA
dt_loop:
    mov %ebx, %eax
    mov $fs_buf, %edi
    call ata_read
    jnc dt_ok
    inc %ebp
dt_ok:
    inc %ebx
    test $0x1ff, %ebx            # update the bar every 512 sectors (256 KB)
    jnz dt_more
    mov %ebx, %eax               # percent = LBA * 100 / 4000 = LBA / 40
    xor %edx, %edx
    mov $40, %ecx
    div %ecx
    call draw_bar
dt_more:
    cmp $4000, %ebx
    jb dt_loop
    mov ticks, %eax              # elapsed ticks -> seconds*10 for KB/s
    sub ct_ticks0, %eax
    mov %eax, ct_ticksd
    mov $msg_dt2, %esi           # "\r\n  2 MB read, errors: "
    call puts
    mov %ebp, %eax
    call print_dec32
    mov $msg_dt3, %esi           # ", "
    call puts
    mov ct_ticksd, %ecx          # KB/s = 2048 KB * 18 / ticks
    test %ecx, %ecx
    jz dt_fast
    mov $2048, %eax
    mov $18, %edx
    imul %edx, %eax              # 2048*18 (fits)
    xor %edx, %edx
    div %ecx                     # EAX = KB/s
    call print_dec32
    mov $msg_dt_kbs, %esi        # " KB/s\r\n"
    call puts
    jmp shell
dt_fast:
    mov $msg_dt_fast, %esi       # "<1 tick (very fast)\r\n"
    call puts
    jmp shell

# ata_write: AX = LBA, ESI = source buffer (512 bytes). CF=1 on error.
ata_write:
    cmpb $0, fs_ram
    je aw_phys
    push %edx
    call ram_slot_addr
    jnc aw_ram
    pop %edx
    jmp aw_phys
aw_ram:
    push %ecx
    push %esi
    push %edi
    mov %edx, %edi               # caller's ESI buffer -> RAM slot
    mov $128, %ecx
    rep movsl
    pop %edi
    pop %esi
    pop %ecx
    pop %edx
    clc
    ret
aw_phys:
    push %eax
    push %ebx
    push %ecx
    push %edx
    push %esi
    mov $0x30, %bl
    call ata_setup
    jc awr_out
    call ata_wait_drq
    jc awr_out
    mov $0x1f0, %dx
    mov $256, %ecx
    rep outsw
    call ata_wait_rdy
    jc awr_out
    mov $0x1f7, %dx
    mov $0xe7, %al               # FLUSH CACHE
    out %al, %dx
    call ata_wait_flush
awr_out:
    pop %esi
    pop %edx
    pop %ecx
    pop %ebx
    pop %eax
    ret

# =====================================================================
#  FRAMEBUFFER CONSOLE: under UEFI there is no VGA text
#  RAM - the stage-0 stub leaves the GOP framebuffer in the boot-info
#  block at UEFI_INFO and we render the SAME 80x25 grid ourselves with
#  an 8x16 font (extracted once from a PSF console font, pure data).
#  putc stays the only interface: every VGA cell write is mirrored
#  per cell, scroll/cls move pixels - never read 0xB8000 back, the
#  legacy window is not readable under UEFI. Pixel format BGRx; the
#  16 VGA colors come from vga_pal. snake goes through sn_wrcell/
#  sn_rdcell (shadow at SNAKE_SHADOW) and plays on all boot paths.
# =====================================================================
fb_init:                         # adopt the framebuffer info (UEFI GOP stub
                                 #   OR the BIOS/PXE VBE setup in stage2_go)
    cmpl $0x49464555, UEFI_INFO    # magic "UEFI" - present on either path
    jne fbi_ret
    mov UEFI_INFO+8, %eax            # framebuffer base (low half)
    test %eax, %eax
    jz fbi_ret
    cmpl $0, UEFI_INFO+0xc             # above 4 GB? then serial-only
    jne fbi_ret
    cmpl $640, UEFI_INFO+0x10           # hres too small for 80x8 px?
    jb fbi_ret
    cmpl $400, UEFI_INFO+0x14           # vres too small for 25x16 px?
    jb fbi_ret
    mov %eax, fb_base
    mov UEFI_INFO+0x10, %eax            # horizontal resolution
    mov %eax, fb_w
    mov UEFI_INFO+0x14, %eax            # vertical resolution
    mov %eax, fb_h
    mov UEFI_INFO+0x18, %eax            # pixels per scanline
    mov %eax, fb_ppsl
    sub $8, %eax                 # byte skip from glyph end to next
    shl $2, %eax                 # glyph row start
    mov %eax, fb_rowskip
    mov fb_ppsl, %eax            # 2x font: cell is 16 px wide
    sub $16, %eax
    shl $2, %eax
    mov %eax, fb_rowskip2
    # font scale = clamp(vres / 450, 1, 4): the console glyphs scale with the
    #   resolution so the terminal fills the screen on any monitor (1080->2x,
    #   1440->3x, 2160->4x). cellW = 8*scale, cellH = 16*scale.
    mov fb_h, %eax
    xor %edx, %edx
    mov $450, %ecx
    div %ecx                     # eax = vres / 450
    test %eax, %eax
    jnz fbs_lo
    mov $1, %eax
fbs_lo:
    cmp $4, %eax
    jbe fbs_hi
    mov $4, %eax
fbs_hi:
    mov %eax, fb_scale
    mov %eax, %ecx               # scaled cell row-skip = (ppsl - 8*scale) * 4
    shl $3, %ecx                 # 8 * scale
    mov fb_ppsl, %eax
    sub %ecx, %eax
    shl $2, %eax
    mov %eax, fb_rowskip_s
    # The framebuffer lives far above our identity-mapped 0-32 MB
    # (QEMU: ~0xFD000000) - unmapped pixel writes #PF-recursed into
    # the next \r flood. Map it here with 4 MB pages: CR4.PSE on,
    # PDEs with the PS bit, supervisor-only (agents keep hands off).
    pushal
    mov %cr4, %eax
    or $0x10, %eax               # PSE
    mov %eax, %cr4
    mov fb_ppsl, %eax            # size = ppsl * vres * 4 bytes
    mov UEFI_INFO+0x14, %ecx            # vertical resolution
    imul %ecx, %eax
    shl $2, %eax
    mov fb_base, %edx
    lea (%edx,%eax), %ebp        # EBP = end address
    add $0x800000, %ebp          # +8 MB margin: GUI elements (e.g. the logo) may
                                 #   paint just past vres; map a bit beyond so an
                                 #   off-screen write can never #PF -> triple fault
    and $0xffc00000, %edx        # EDX = first 4 MB boundary
fbm_loop:
    mov %edx, %ecx
    shr $22, %ecx                # PDE index
    mov %edx, %esi
    or $0x87, %esi               # present | writable | USER | 4 MB page
                                 #   (U=1: ring-3 C programs blit the framebuffer)
    mov %esi, PAGE_DIR(,%ecx,4)
    add $0x400000, %edx
    cmp %ebp, %edx
    jb fbm_loop
    mov $PAGE_DIR, %eax
    mov %eax, %cr3               # flush the TLB
    popal
    movb $1, fb_active
    pushal                       # blank the WHOLE screen once: the
    mov fb_ppsl, %ecx            # firmware logo lives outside our
    mov UEFI_INFO+0x14, %eax            # 80x25 grid and would linger forever
    imul %eax, %ecx
    mov fb_base, %edi
    xor %eax, %eax
    rep stosl
    popal
fbi_ret:
    ret

# fb_glyph: EAX = character code (0..255) -> ESI = its 16 bitmap bytes.
#   ASCII 32..126 from font8x16, the CP437 block/shade/box extras from
#   font_extra (via font_cp437_map); everything else draws as a space.
fb_glyph:
    cmp $0x80, %eax
    jae fgl_hi
    sub $0x20, %eax
    cmp $95, %eax
    jb fgl_lo
    xor %eax, %eax
fgl_lo:
    shl $4, %eax
    lea font8x16(%eax), %esi
    ret
fgl_hi:
    movzbl font_cp437_map-0x80(%eax), %eax
    test %eax, %eax
    jz fgl_lo                    # unmapped -> glyph 0 (space)
    dec %eax
    shl $4, %eax
    lea font_extra(%eax), %esi
    ret

# fb_cell_edi: render one cell. AL=char, AH=attr, EDI=VGA cell address.
#   Keeps everything (pushal) - safe to sprinkle after any stosw/mov.
fb_cell_edi:
    cmpb $0, fb_active
    je fbc_ret
    cmpb $0, compositor_active    # a ring-3 compositor owns the FB? don't mirror
    jne fbc_ret
    pushal
    pushfl                       # the cell temps + the terminal-bg painter below
    cli                          #   are shared with the status-line ISR writer
    mov %ax, %bx                 # BL=char, BH=attr
    sub $0xb8000, %edi
    shr $1, %edi                 # EDI = cell index 0..1999
    mov %edi, %eax
    xor %edx, %edx
    mov $80, %ecx
    div %ecx                     # EAX=row, EDX=col
    mov fb_scale, %ecx           # cell = (8*scale) x (16*scale) px
    imul $16, %ecx
    imul %ecx, %eax              # row * (16*scale)
    mov %eax, %ebp
    add con_oy, %ebp
    mov %ebp, fbc_cy             # cell y on screen (desktop bg painter)
    imul fb_ppsl, %eax
    mov fb_scale, %ecx
    imul $8, %ecx
    imul %ecx, %edx              # col * (8*scale)
    mov %edx, %ebp
    add con_ox, %ebp
    mov %ebp, fbc_cx             # cell x on screen
    add %edx, %eax
    add con_off, %eax            # + console-window offset (0 in plain text mode)
    shl $2, %eax                 # 4 bytes per pixel
    add fb_base, %eax
    mov %eax, %edi               # EDI = first pixel of the cell
    movzbl %bl, %eax             # glyph: ASCII 32..126 + the CP437 extras
    call fb_glyph                # ESI = 16 bitmap bytes
    movzbl %bh, %eax             # colors from the VGA attribute
    mov %eax, %ecx
    and $0x0f, %eax
    shr $4, %ecx
    and $7, %ecx
    cmpb $0, desk_active         # desktop: brand-tuned console palette (WP3).
    je fbc_vga                   #   Plain console + games keep the VGA colours.
    mov desk_pal(,%eax,4), %edx  # EDX = foreground
    mov desk_bgpal(,%ecx,4), %ebp # EBP = background, -1 = TRANSPARENT (bg 0):
    cmp $-1, %ebp                #   the terminal background (CONBG + faint fir)
    jne fbc_bg                   #   goes under the glyph, nothing else
    cmpb $0, cell_tr             # con_repaint_rect painted it for the whole
    jne fbc_bg                   #   rect already - glyph only
    push %esi                    # keep glyph, fg and BL (char) across the call
    push %edx
    push %ebx
    mov fbc_cx, %eax
    mov fbc_cy, %ebx
    mov fb_scale, %ecx
    shl $3, %ecx                 # 8s x 16s cell
    lea (%ecx,%ecx), %edx
    call con_bg_fill_rect        # (skips the fir walk outside the fir rect)
    pop %ebx
    pop %edx
    pop %esi
    jmp fbc_bg
fbc_vga:
    mov vga_pal(,%eax,4), %edx   # EDX = foreground
    mov vga_pal(,%ecx,4), %ebp   # EBP = background
    cmpb $0, cell_tr             # con_repaint_rect: glyph only, background already
    je fbc_bg                    #   painted by con_bg_fill_rect
    mov $-1, %ebp
fbc_bg:
    mov fb_scale, %eax           # the console blits at the console scale
    mov %eax, gb_scale
    mov fb_rowskip_s, %eax
    mov %eax, gb_rowskip
    cmpl $2, fb_scale            # scale 2 (e.g. the test PC 1080p): smooth glyph edges
    jne fbc_near                 #   with Scale2x/EPX. Sprites call fbc_blit directly,
    cmp $0x80, %bl               #   so they keep their chunky retro look - and so do
    jae fbc_near                 #   the CP437 blocks/shades (EPX would notch them).
    call fbc_blit_epx
    jmp fbc_done
fbc_near:
    call fbc_blit
fbc_done:
    popfl
    popal
fbc_ret:
    ret

# ---------------------------------------------------------------------------
# glyph_blit: the ONE scaled glyph blitter for UI text and console cells.
#   In:  EDI = address of the cell's first pixel (fb_base + (y*ppsl + x)*4)
#        ESI = 16 glyph bytes (8x16, MSB = left pixel; fb_glyph gives them)
#        EDX = foreground 0x00RRGGBB
#        EBP = background 0x00RRGGBB, or 0xFFFFFFFF = TRANSPARENT (bg pixels
#              are skipped, whatever is on screen stays)
#        gb_scale (.long, 1..4) = pixel scale -> cell is 8*s x 16*s px
#        gb_epx   (.byte) 1 = at gb_scale==2 round the stair-steps with
#              Scale2x/EPX (crisp 2x UI text), 0 = nearest (blocks/sprites)
#   Preserves all registers. No clipping: the caller keeps the cell on screen.
glyph_blit:
    pushal
    mov gb_scale, %eax           # row skip = (ppsl - 8*scale) * 4 bytes
    shl $3, %eax
    mov fb_ppsl, %ecx
    sub %eax, %ecx
    shl $2, %ecx
    mov %ecx, gb_rowskip
    cmpl $2, gb_scale
    jne gbl_near
    cmpb $0, gb_epx
    je gbl_near
    call fbc_blit_epx
    popal
    ret
gbl_near:
    call fbc_blit
    popal
    ret

# fbc_blit: nearest-neighbour core. EDI=first pixel, ESI=bitmap, EDX=fg,
#   EBP=bg (-1 = transparent), gb_scale/gb_rowskip set. Clobbers EAX..EDI
#   (callers run it inside their own pushal).
fbc_blit:
    mov $16, %ecx
fbc_row:
    push %ecx
    lodsb
    mov %al, %bl                 # BL = bitmap row, MSB = left pixel
    mov gb_scale, %ecx           # repeat each source row 'scale' screen scanlines
fbc_vdup:
    push %ecx
    push %ebx                    # BL is consumed by the shift - keep it per copy
    mov $8, %ecx
fbc_px:
    shl $1, %bl
    jc fbc_fg
    cmp $-1, %ebp                # transparent background: leave the pixels alone
    je fbc_skip
    mov %ebp, %eax
    jmp fbc_w
fbc_fg:
    mov %edx, %eax
fbc_w:
    push %ecx                    # each source pixel -> 'scale' screen pixels wide
    mov gb_scale, %ecx
    rep stosl
    pop %ecx
    loop fbc_px
    jmp fbc_eol
fbc_skip:
    mov gb_scale, %eax
    lea (%edi,%eax,4), %edi
    loop fbc_px
fbc_eol:
    pop %ebx
    add gb_rowskip, %edi         # next scanline (cell is 8*scale px wide)
    pop %ecx
    loop fbc_vdup
    pop %ecx
    loop fbc_row
    ret

# EPX_PUT: AL = chosen source bit -> emit one screen pixel (fg / bg / skip).
.macro EPX_PUT
    test %al, %al
    jz 1f
    mov %edx, %eax
    stosl
    jmp 2f
1:  cmp $-1, %ebp
    je 3f
    mov %ebp, %eax
    stosl
    jmp 2f
3:  add $4, %edi
2:
.endm

# fbc_blit_epx: Scale2x/EPX core for gb_scale==2. Renders the 8x16 font
#   into a 16x32 cell, but instead of doubling each pixel into a 2x2 block it
#   uses the neighbour pixels to round diagonal staircases - crisp text on the
#   test PC's 1080p (scale 2) console and for the desktop's 2x UI text.
#   EDI=first pixel, ESI=16 font bytes, EDX=fg, EBP=bg (-1 = transparent),
#   gb_rowskip = (ppsl-16)*4. Clobbers EAX..EDI (inside the caller's pushal).
fbc_blit_epx:
    push %edi                    # copy the 16 glyph rows into epx_buf+1, with a
    mov $epx_buf+1, %edi         #   zero guard row above (epx_buf) and below
    mov $16, %ecx                #   (epx_buf+17) so vertical neighbours of the
febx_cp:                         #   top/bottom rows read as background.
    movsb
    loop febx_cp
    pop %edi
    movb $0, epx_buf
    movb $0, epx_buf+17
    movl $0, epx_py
febx_y:
    mov epx_py, %ebx             # load the 3 relevant rows (above/cur/below)
    movzbl epx_buf(%ebx), %eax  ; mov %al, epx_a
    movzbl epx_buf+1(%ebx), %eax; mov %al, epx_e
    movzbl epx_buf+2(%ebx), %eax; mov %al, epx_d
    movl $0, epx_px              # --- top output scanline: E0,E1 per src px ---
febx_top:
    call epx_extract
    mov epx_P, %al               # E0 = (C==A && C!=D && A!=B) ? A : P
    movb epx_Cv, %bl ; cmpb epx_Av, %bl ; jne e0w
    movb epx_Cv, %bl ; cmpb epx_Dv, %bl ; je  e0w
    movb epx_Av, %bl ; cmpb epx_Bv, %bl ; je  e0w
    mov epx_Av, %al
e0w:
    EPX_PUT
    mov epx_P, %al               # E1 = (A==B && A!=C && B!=D) ? B : P
    movb epx_Av, %bl ; cmpb epx_Bv, %bl ; jne e1w
    movb epx_Av, %bl ; cmpb epx_Cv, %bl ; je  e1w
    movb epx_Bv, %bl ; cmpb epx_Dv, %bl ; je  e1w
    mov epx_Bv, %al
e1w:
    EPX_PUT
    incl epx_px ; cmpl $8, epx_px ; jb febx_top
    add gb_rowskip, %edi         # to the start of the bottom scanline
    movl $0, epx_px              # --- bottom output scanline: E2,E3 per src px ---
febx_bot:
    call epx_extract
    mov epx_P, %al               # E2 = (D==C && D!=B && C!=A) ? C : P
    movb epx_Dv, %bl ; cmpb epx_Cv, %bl ; jne e2w
    movb epx_Dv, %bl ; cmpb epx_Bv, %bl ; je  e2w
    movb epx_Cv, %bl ; cmpb epx_Av, %bl ; je  e2w
    mov epx_Cv, %al
e2w:
    EPX_PUT
    mov epx_P, %al               # E3 = (B==D && B!=A && D!=C) ? B : P
    movb epx_Bv, %bl ; cmpb epx_Dv, %bl ; jne e3w
    movb epx_Bv, %bl ; cmpb epx_Av, %bl ; je  e3w
    movb epx_Dv, %bl ; cmpb epx_Cv, %bl ; je  e3w
    mov epx_Bv, %al
e3w:
    EPX_PUT
    incl epx_px ; cmpl $8, epx_px ; jb febx_bot
    add gb_rowskip, %edi
    incl epx_py ; cmpl $16, epx_py ; jb febx_y
    ret

# epx_extract: ECX/EAX/EBX scratch. Reads epx_px + epx_a/e/d (3 row bytes),
#   writes the five neighbour bits as 0/1: P(self) Av(up) Dv(down) Bv(right)
#   Cv(left). Pixels are MSB-first (bit 7 = column 0). EDI/EDX/EBP/ESI kept.
epx_extract:
    mov epx_px, %ecx
    mov $7, %ebx
    sub %ecx, %ebx               # BL = 7-px = base shift for column px
    mov %bl, %cl
    movzbl epx_e, %eax ; shr %cl, %eax ; and $1, %eax ; mov %al, epx_P
    movzbl epx_a, %eax ; shr %cl, %eax ; and $1, %eax ; mov %al, epx_Av
    movzbl epx_d, %eax ; shr %cl, %eax ; and $1, %eax ; mov %al, epx_Dv
    cmpl $7, epx_px              # B = right neighbour (col px+1), 0 at the edge
    je epxb0
    mov %bl, %cl ; dec %cl       # shift = 6-px
    movzbl epx_e, %eax ; shr %cl, %eax ; and $1, %eax ; jmp epxbs
epxb0:
    xor %eax, %eax
epxbs:
    mov %al, epx_Bv
    cmpl $0, epx_px              # C = left neighbour (col px-1), 0 at the edge
    je epxc0
    mov %bl, %cl ; inc %cl       # shift = 8-px
    movzbl epx_e, %eax ; shr %cl, %eax ; and $1, %eax ; jmp epxcs
epxc0:
    xor %eax, %eax
epxcs:
    mov %al, epx_Cv
    ret

# game_tile_edi: like fb_cell_edi (EDI=VGA cell addr, AX=attr<<8|char) but
#   renders the snake/invaders cells as little graphical SPRITES instead
#   of text glyphs - so the games look like games, not ASCII. Each sprite
#   is an 8x16 bitmap (like a font glyph) drawn scaled with its own colour
#   on black, reusing fb_cell_edi's blit core (fbc_blit). Non-game chars
#   (score text, messages) fall through to the normal glyph path.
#   Active only while game_gfx is set (snake/invaders gameplay).
game_tile_edi:
    cmpb $0, fb_active
    je gte_ret
    # Dispatch on the char (AL) into memory temps BEFORE pushal, so NO
    # caller register is touched (the gts_* arms only write memory). A
    # register-based version corrupted callers - inv_paint loops on EBX.
    cmp $0x4F, %al ; je gts_snake     # 'O' snake segment
    cmp $0x2a, %al ; je gts_food      # '*' food
    cmp $0x23, %al ; je gts_wall      # '#' wall
    cmp $0x57, %al ; je gts_alien     # 'W' invader
    cmp $0x5e, %al ; je gts_ship      # '^' player ship
    cmp $0x59, %al ; je gts_shipP     # 'Y' powered-up ship (spread active)
    cmp $0x7c, %al ; je gts_bull      # '|' player bullet
    cmp $0x76, %al ; je gts_bomb      # 'v' alien bomb
    cmp $0x55, %al ; je gts_ufo       # 'U' UFO / mothership
    cmp $0x40, %al ; je gts_bunk      # '@' bunker block
    cmp $0x26, %al ; je gts_pwr       # '&' power-up
    jmp fb_cell_edi                   # not a sprite -> render the glyph (clean tail call)
gts_snake: movl $gt_snake,gt_spr; jmp gte_go
gts_food:  movl $gt_food, gt_spr; jmp gte_go
gts_wall:  movl $gt_wall, gt_spr; jmp gte_go
gts_alien: movl $gt_alien,gt_spr; jmp gte_go
gts_ship:  movl $gt_ship, gt_spr; jmp gte_go
gts_shipP: movl $gt_shipP,gt_spr; jmp gte_go
gts_bull:  movl $gt_bull, gt_spr; jmp gte_go
gts_bomb:  movl $gt_bomb, gt_spr; jmp gte_go
gts_ufo:   movl $gt_ufo,  gt_spr; jmp gte_go
gts_bunk:  movl $gt_bunk, gt_spr; jmp gte_go
gts_pwr:   movl $gt_pwr,  gt_spr; jmp gte_go
gte_go:
    mov %ah, gt_attr                  # save the attr (memory write, no reg clobber)
    pushal                            # now safe to clobber - all caller regs saved
    sub $0xb8000, %edi                # ---- cell -> first pixel (as fb_cell_edi) --
    shr $1, %edi
    mov %edi, %eax
    xor %edx, %edx
    mov $80, %ecx
    div %ecx                          # EAX=row, EDX=col
    mov fb_scale, %ecx
    imul $16, %ecx
    imul %ecx, %eax
    imul fb_ppsl, %eax
    mov fb_scale, %ecx
    imul $8, %ecx
    imul %ecx, %edx
    add %edx, %eax
    add con_off, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, %edi                    # EDI = first pixel
    movzbl gt_attr, %ecx              # sprite colour from the VGA attr (like a glyph)
    mov %ecx, %eax
    and $0x0f, %eax
    mov vga_pal(,%eax,4), %edx        # EDX = fg
    shr $4, %ecx
    and $7, %ecx
    mov vga_pal(,%ecx,4), %ebp        # EBP = bg
    mov gt_spr, %esi                  # sprite bitmap
    mov fb_scale, %eax                # console scale, nearest (chunky sprites)
    mov %eax, gb_scale
    mov fb_rowskip_s, %eax
    mov %eax, gb_rowskip
    call fbc_blit                     # ESI=sprite, EDX=fg, EBP=bg, EDI=pixel
    popal
gte_ret:
    ret

# 8x16 game sprites (MSB = leftmost pixel), coloured by the VGA attr:
gt_snake: .byte 0x00,0x3C,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x7E,0x3C,0x00
gt_food:  .byte 0x00,0x10,0x18,0x3C,0x7E,0xFF,0xFF,0xFF,0xFF,0xFF,0x7E,0x3C,0x00,0x00,0x00,0x00
gt_wall:  .byte 0xFF,0xEE,0xEE,0xFF,0xBB,0xBB,0xFF,0xEE,0xEE,0xFF,0xBB,0xBB,0xFF,0xEE,0xEE,0xFF
gt_alien: .byte 0x00,0x00,0x42,0x24,0x3C,0x7E,0xDB,0xFF,0xFF,0x66,0x24,0x42,0x81,0x00,0x00,0x00
gt_ship:  .byte 0x00,0x00,0x18,0x18,0x3C,0x3C,0x7E,0x7E,0xFF,0xFF,0xFF,0xDB,0xDB,0x99,0x00,0x00
gt_shipP: .byte 0x00,0x18,0x18,0x3C,0x3C,0x7E,0xFF,0xFF,0xFF,0xE7,0xE7,0xC3,0xC3,0x81,0x00,0x00
gt_bull:  .byte 0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18
gt_bomb:  .byte 0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08
gt_ufo:   .byte 0x00,0x00,0x00,0x00,0x3C,0x7E,0xDB,0xFF,0xFF,0x7E,0x3C,0x18,0x00,0x00,0x00,0x00
gt_bunk:  .byte 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
gt_pwr:   .byte 0x00,0x00,0x3C,0x42,0x99,0xA5,0xA5,0xA5,0xA5,0xA5,0x99,0x42,0x3C,0x00,0x00,0x00
.balign 4
gt_spr:   .long 0                # game_tile_edi scratch: selected sprite
gt_attr:  .byte 0                # ... and the cell's VGA attr (for the colour)
.balign 4

fb_scroll:                       # text rows 1..24 up one row, blank row 24 -
    cmpb $0, fb_active           # operates on the 640-wide console sub-rect at
    je fbs_ret                   # con_off (works windowed OR full-screen)
    cmpb $0, compositor_active    # compositor owns the FB - don't shift its pixels
    jne fbs_ret                   #   (it re-renders the scrolled shadow itself)
    call cursor_hide             # lift the cursor before moving pixels
    pushal
    mov fb_base, %ebp            # EBP = framebuffer base
    mov fb_ppsl, %esi            # ESI = stride (pixels per scanline)
    mov fb_scale, %ebx           # EBX = rowH = 16*scale (scanlines per text row)
    imul $16, %ebx
    mov con_off, %edi            # EDI = dst pixel index = console row 1
    mov %esi, %eax
    imul %ebx, %eax              # rowH*stride
    add %eax, %edi
    mov %ebx, %edx               # 23 text rows x rowH scanlines
    imul $23, %edx
fbs_l:
    push %esi
    push %edi
    mov %edi, %eax               # src index = dst + rowH*stride
    mov %esi, %ecx
    imul %ebx, %ecx
    add %ecx, %eax
    lea (%ebp,%eax,4), %esi      # SRC address
    lea (%ebp,%edi,4), %edi      # DST address
    mov fb_scale, %ecx           # conW = 80 cells x (8*scale) = 640*scale px
    imul $640, %ecx
    rep movsl
    pop %edi
    pop %esi
    add %esi, %edi               # next scanline
    dec %edx
    jnz fbs_l
    mov %ebx, %edx               # blank console row 24 (rowH scanlines) with the
    imul $24, %ebx               #   terminal background (CONBG + fir on the desktop)
    add con_oy, %ebx
    mov con_ox, %eax
    mov con_w, %ecx
    call con_bg_fill_rect
    cmpb $0, desk_active         # the fir silhouette must not scroll with the text:
    je fbs_nofir                 #   repaint its rect (background + glyphs on top)
    cmpl $0, term_fir_img
    je fbs_nofir
    mov fir_term_x, %eax         #   plus the text row above it, where the memcpy
    mov fir_term_y, %ebx         #   just parked a copy of the fir's top rows
    mov fb_scale, %ecx
    shl $4, %ecx
    sub %ecx, %ebx
    mov fir_term_h, %edx
    add %ecx, %edx
    mov fir_term_w, %ecx
    call con_repaint_rect
fbs_nofir:
    popal
fbs_ret:
    ret

fb_clear:                        # blank console rows 1..24 (cls keeps row 0)
    cmpb $0, fb_active
    je fbcl_ret
    cmpb $0, compositor_active    # compositor owns the FB - it clears via the shadow
    jne fbcl_ret
    call cursor_hide
    movl $-1, caret_pos          # the client area is repainted (cls re-draws the caret)
    pushal
    mov fb_base, %ebp
    mov fb_ppsl, %esi
    mov fb_scale, %ebx           # rowH = 16*scale
    imul $16, %ebx
    mov %ebx, %edx               # rows 1..24 = 24 x rowH scanlines, painted with
    imul $24, %edx               #   the terminal background (CONBG + fir on the desktop)
    add con_oy, %ebx             # start at console row 1
    mov con_ox, %eax
    mov con_w, %ecx
    call con_bg_fill_rect
    popal
fbcl_ret:
    ret

# =====================================================================
#  GRAPHICAL DESKTOP (concept C "Workspace", desktop-design/SPEC.md) - drawn
#  over the linear framebuffer when the mode fits (desk_layout): wallpaper
#  gradient + fir silhouette, a top bar (brand, menu titles, status pills,
#  clock, power), the terminal window holding the 80x25 console (offset via
#  con_off) with the wish field under it, and the agents panel on the right.
#  Falls back to the plain top-left console otherwise.
# =====================================================================
# gfx_fillrect: EAX=x, EBX=y, ECX=w, EDX=h, ESI=color (0x00RRGGBB / BGRx).
gfx_fillrect:
    pushal
gfr_row:
    test %edx, %edx
    jz gfr_done
    push %eax
    push %ecx
    mov %ebx, %edi
    imul fb_ppsl, %edi
    add %eax, %edi
    shl $2, %edi
    add fb_base, %edi
    mov %esi, %eax
    rep stosl
    pop %ecx
    pop %eax
    inc %ebx
    dec %edx
    jmp gfr_row
gfr_done:
    popal
    ret

# gfx_putpixel: EAX=x, EBX=y, ESI=color (0x00RRGGBB). Clipped to the screen.
gfx_putpixel:
    pushal
    test %eax, %eax
    js gpp_ret
    cmp fb_w, %eax
    jge gpp_ret
    test %ebx, %ebx
    js gpp_ret
    cmp fb_h, %ebx
    jge gpp_ret
    mov %ebx, %edi
    imul fb_ppsl, %edi
    add %eax, %edi
    shl $2, %edi
    add fb_base, %edi
    mov %esi, %eax
    stosl
gpp_ret:
    popal
    ret

# gfx_drawline: Bresenham from (gln_x0,gln_y0) to (gln_x1,gln_y1) in gln_col.
gfx_drawline:
    pushal
    mov gln_x0, %eax ; mov %eax, gln_cx        # cx = x0
    mov gln_y0, %eax ; mov %eax, gln_cy        # cy = y0
    mov gln_x1, %eax ; sub gln_x0, %eax        # dx = |x1-x0|, sx = sign
    jge gl_dxp
    neg %eax ; movl $-1, gln_sx ; jmp gl_dxs
gl_dxp:
    movl $1, gln_sx
gl_dxs:
    mov %eax, gln_dx
    mov gln_y1, %eax ; sub gln_y0, %eax        # dy = -|y1-y0|, sy = sign
    jge gl_dyp
    neg %eax ; movl $-1, gln_sy ; jmp gl_dys
gl_dyp:
    movl $1, gln_sy
gl_dys:
    neg %eax ; mov %eax, gln_dy
    mov gln_dx, %eax ; add gln_dy, %eax ; mov %eax, gln_err   # err = dx+dy
gl_loop:
    mov gln_cx, %eax
    mov gln_cy, %ebx
    mov gln_col, %esi
    call gfx_putpixel
    mov gln_cx, %eax ; cmp gln_x1, %eax ; jne gl_step
    mov gln_cy, %eax ; cmp gln_y1, %eax ; jne gl_step
    jmp gl_done
gl_step:
    mov gln_err, %eax ; add %eax, %eax ; mov %eax, %ecx       # e2 = 2*err
    cmp gln_dy, %ecx ; jl gl_skipx                            # e2 >= dy: x step
    mov gln_dy, %eax ; add %eax, gln_err
    mov gln_sx, %eax ; add %eax, gln_cx
gl_skipx:
    cmp gln_dx, %ecx ; jg gl_skipy                            # e2 <= dx: y step
    mov gln_dx, %eax ; add %eax, gln_err
    mov gln_sy, %eax ; add %eax, gln_cy
gl_skipy:
    jmp gl_loop
gl_done:
    popal
    ret

# gfx_circle: midpoint circle, centre (gcr_cx,gcr_cy) radius gcr_r in gln_col.
gfx_circle:
    pushal
    mov gcr_r, %eax ; mov %eax, gci_x          # x = r
    movl $0, gci_y                             # y = 0
    movl $0, gci_err
gci_loop:
    mov gci_x, %eax ; cmp gci_y, %eax ; jl gci_done   # while x >= y
    call gci_plot8
    incl gci_y
    cmpl $0, gci_err
    jg gci_dec
    mov gci_y, %eax ; lea 1(%eax,%eax,1), %eax        # err += 2*y+1
    add %eax, gci_err
    jmp gci_loop
gci_dec:
    decl gci_x
    mov gci_y, %eax ; sub gci_x, %eax ; lea 1(%eax,%eax,1), %eax  # err += 2*(y-x)+1
    add %eax, gci_err
    jmp gci_loop
gci_done:
    popal
    ret
# gci_plot8: plot the 8 symmetric points of (gci_x,gci_y) about (gcr_cx,gcr_cy).
gci_plot8:
    pushal
    mov gci_x, %ebp ; mov gci_y, %edx          # EBP=x EDX=y (kept across putpixel)
    mov gcr_cx,%eax ;add %ebp,%eax ;mov gcr_cy,%ebx ;add %edx,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    mov gcr_cx,%eax ;sub %ebp,%eax ;mov gcr_cy,%ebx ;add %edx,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    mov gcr_cx,%eax ;add %ebp,%eax ;mov gcr_cy,%ebx ;sub %edx,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    mov gcr_cx,%eax ;sub %ebp,%eax ;mov gcr_cy,%ebx ;sub %edx,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    mov gcr_cx,%eax ;add %edx,%eax ;mov gcr_cy,%ebx ;add %ebp,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    mov gcr_cx,%eax ;sub %edx,%eax ;mov gcr_cy,%ebx ;add %ebp,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    mov gcr_cx,%eax ;add %edx,%eax ;mov gcr_cy,%ebx ;sub %ebp,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    mov gcr_cx,%eax ;sub %edx,%eax ;mov gcr_cy,%ebx ;sub %ebp,%ebx ;mov gln_col,%esi ;call gfx_putpixel
    popal
    ret

# =====================================================================
#  UI TEXT  (gfx_char / gfx_puts / gfx_line) - 8x16 glyphs at 1x or 2x
#   State (memory): gtx_x, gtx_y   pen position (pixels)
#                   gtx_fg, gtx_bg colours 0x00RRGGBB
#                   gtx_tr   1 = transparent background (only glyph pixels
#                            are written - text on gradients/photos)
#                   gtx_scale 1 | 2 (2 = 16x32 via Scale2x/EPX)
#                   gtx_adv  horizontal advance per char, 0 = 8*gtx_scale
#                            (10 = the spaced-out small-caps headers)
#   ui_puts below sets all of them from registers in one call.
# =====================================================================
# gfx_char: AL=char, drawn at (gtx_x,gtx_y). Advances nothing. Preserves all.
gfx_char:
    pushal
    movzbl %al, %eax
    call fb_glyph                # ESI = 16 glyph bytes
    mov gtx_y, %eax
    imul fb_ppsl, %eax
    add gtx_x, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, %edi               # EDI = first pixel
    mov gtx_fg, %edx
    mov gtx_bg, %ebp
    cmpb $0, gtx_tr
    je gch_op
    mov $-1, %ebp                # transparent
gch_op:
    mov gtx_scale, %eax
    mov %eax, gb_scale
    movb $1, gb_epx
    call glyph_blit
    popal
    ret

# gfx_puts: draw the asciz string at ESI from (gtx_x,gtx_y), advancing gtx_x
#   by gtx_adv (or 8*gtx_scale) per character. Preserves all registers.
gfx_puts:
    pushal
gps_l:
    movzbl (%esi), %eax
    test %al, %al
    jz gps_d
    push %esi
    call gfx_char
    mov gtx_adv, %eax
    test %eax, %eax
    jnz gps_adv
    mov gtx_scale, %eax
    shl $3, %eax
gps_adv:
    add %eax, gtx_x
    pop %esi
    inc %esi
    jmp gps_l
gps_d:
    popal
    ret

# gfx_line: ESI=label asciz, EAX=number -> "<label><dec>" at (gtx_x,gtx_y).
gfx_line:
    pushal
    mov %eax, %ebp
    mov $gtx_buf, %edi
    call bputs                   # copy label
    mov %ebp, %eax
    call bdec32                  # append the number
    movb $0, (%edi)
    mov $gtx_buf, %esi
    call gfx_puts
    popal
    ret

# ui_puts: one-call text. ESI=asciz, EAX=x, EBX=y, ECX=fg, EDX=scale (1|2),
#   EBP=bg colour or -1 (transparent). Advance = 8*scale (gtx_adv reset to 0).
#   Leaves gtx_x after the text (callers that chain text read it). Preserves all.
ui_puts:
    pushal
    mov %eax, gtx_x
    mov %ebx, gtx_y
    mov %ecx, gtx_fg
    mov %edx, gtx_scale
    movl $0, gtx_adv
    movb $0, gtx_tr
    cmp $-1, %ebp
    jne uip_op
    movb $1, gtx_tr
uip_op:
    mov %ebp, gtx_bg
    call gfx_puts
    popal
    ret

# =====================================================================
#  DESKTOP PRIMITIVES (WP1). Register ABI like gfx_fillrect:
#     EAX=x  EBX=y  ECX=w  EDX=h  ESI=colour (0x00RRGGBB)  - all pushal-safe,
#   every routine preserves every register; extra inputs are noted per routine.
#   Colours are written as-is (the framebuffer is BGRx = a .long 0x00RRGGBB).
# =====================================================================

# grd_lerp: EAX=i, ECX=n -> EAX = grd_c0 + (grd_c1-grd_c0)*i/n per channel
#   (n==0 -> grd_c0). Preserves everything else.
grd_lerp:
    push %ebx
    push %ecx
    push %edx
    push %esi
    push %edi
    push %ebp
    mov %eax, %esi               # i
    mov %ecx, %edi               # n
    xor %ebp, %ebp               # result
    mov $16, %ecx                # channel shift 16 / 8 / 0
grl_ch:
    mov grd_c1, %eax
    shr %cl, %eax
    and $255, %eax
    mov %eax, %ebx               # c1
    mov grd_c0, %eax
    shr %cl, %eax
    and $255, %eax               # c0
    sub %eax, %ebx               # d = c1 - c0 (signed)
    push %eax
    mov %ebx, %eax
    imul %esi, %eax              # d * i
    test %edi, %edi
    jz grl_zero
    cdq
    idiv %edi                    # d*i/n
    jmp grl_add
grl_zero:
    xor %eax, %eax
grl_add:
    pop %ebx
    add %ebx, %eax               # c0 + d*i/n
    jns grl_lo
    xor %eax, %eax
grl_lo:
    cmp $255, %eax
    jbe grl_ok
    mov $255, %eax
grl_ok:
    shl %cl, %eax
    or %eax, %ebp
    sub $8, %cl
    jns grl_ch
    mov %ebp, %eax
    pop %ebp
    pop %edi
    pop %esi
    pop %edx
    pop %ecx
    pop %ebx
    ret

# gfx_vgrad: EAX=x EBX=y ECX=w EDX=h, colour per ROW from grd_c0 (row 0) to
#   grd_c1 (row h-1), integer lerp. (ESI unused.)
gfx_vgrad:
    pushal
    mov %eax, vg_x
    mov %ebx, vg_y
    mov %ecx, vg_w
    mov %edx, vg_h
    xor %ebp, %ebp               # i
vg_l:
    cmp vg_h, %ebp
    jae vg_d
    mov %ebp, %eax
    mov vg_h, %ecx
    dec %ecx
    call grd_lerp
    mov %eax, %esi
    mov vg_x, %eax
    mov vg_y, %ebx
    add %ebp, %ebx
    mov vg_w, %ecx
    mov $1, %edx
    call gfx_fillrect
    inc %ebp
    jmp vg_l
vg_d:
    popal
    ret

# gfx_hgrad: EAX=x EBX=y ECX=w EDX=h, colour per COLUMN from grd_c0 (x) to
#   grd_c1 (x+w-1). (Aurora line, focus underline.)
gfx_hgrad:
    pushal
    mov %eax, vg_x
    mov %ebx, vg_y
    mov %ecx, vg_w
    mov %edx, vg_h
    xor %ebp, %ebp               # i
hg_l:
    cmp vg_w, %ebp
    jae hg_d
    mov %ebp, %eax
    mov vg_w, %ecx
    dec %ecx
    call grd_lerp
    mov %eax, %esi
    mov vg_x, %eax
    add %ebp, %eax
    mov vg_y, %ebx
    mov $1, %ecx
    mov vg_h, %edx
    call gfx_fillrect
    inc %ebp
    jmp hg_l
hg_d:
    popal
    ret

# bg_at: EBX=y -> EAX = wallpaper colour of that row (BG_TOP at row 0 ->
#   BG_BOT at row fb_h-1), analytic - no framebuffer read-back. Use it to
#   "erase" chrome drawn on the wallpaper. Preserves grd_c0/c1 and all regs.
bg_at:
    push %ecx
    push grd_c0
    push grd_c1
    movl $C_BG_TOP, grd_c0
    movl $C_BG_BOT, grd_c1
    mov %ebx, %eax
    mov fb_h, %ecx
    dec %ecx
    call grd_lerp
    pop grd_c1
    pop grd_c0
    pop %ecx
    ret

# gfx_shadow: EAX=x EBX=y ECX=w EDX=h = the panel rect, ESI = grow (0 | 2).
#   Draws the analytic drop shadow of a panel ON THE WALLPAPER - call it
#   BEFORE the panel: two full offset layers, (+4,+6) at bg_at(y)-(3,5,4) and
#   (+2,+3) at bg_at(y)-(6,9,8), each grown by ESI px on every side. Rows
#   outside the screen are skipped, the right edge is clipped to fb_w.
gfx_shadow:
    pushal
    mov %eax, sh_x
    mov %ebx, sh_y
    mov %ecx, sh_w
    mov %edx, sh_h
    mov %esi, sh_g
    movl $0x030504, sh_d         # layer 1: offset (4,6)
    mov $4, %eax
    mov $6, %ebx
    call sh_layer
    movl $0x060908, sh_d         # layer 2: offset (2,3)
    mov $2, %eax
    mov $3, %ebx
    call sh_layer
    popal
    ret
sh_layer:                        # EAX=ox EBX=oy
    pushal
    mov sh_x, %ecx
    add %eax, %ecx
    sub sh_g, %ecx
    mov %ecx, sh_lx              # layer x = x + ox - grow
    mov sh_w, %ecx
    add sh_g, %ecx
    add sh_g, %ecx               # layer w = w + 2*grow
    mov sh_lx, %eax
    add %ecx, %eax
    sub fb_w, %eax
    jle shl_wok
    sub %eax, %ecx               # clip to the right edge
shl_wok:
    mov %ecx, sh_lw
    mov sh_y, %ebp
    add %ebx, %ebp
    sub sh_g, %ebp               # first row = y + oy - grow
    mov sh_h, %edi
    add sh_g, %edi
    add sh_g, %edi               # rows = h + 2*grow
shl_row:
    test %edi, %edi
    jz shl_done
    mov %ebp, %ebx
    test %ebx, %ebx
    js shl_next
    cmp fb_h, %ebx
    jae shl_next
    call bg_at                   # EAX = wallpaper colour of this row
    sub sh_d, %eax               # darken (channels never underflow: BG_TOP >= delta)
    mov %eax, %esi
    mov sh_lx, %eax
    mov sh_lw, %ecx
    mov $1, %edx
    call gfx_fillrect
shl_next:
    inc %ebp
    dec %edi
    jmp shl_row
shl_done:
    popal
    ret

# gfx_rrect: filled rounded rectangle. EAX=x EBX=y ECX=w EDX=h ESI=colour,
#   EBP = corner radius r (0..24; clamped to w/2, h/2). Corners come from the
#   inset tables rr_tab (row i < r is inset rr_ins_r[i] on both sides, the
#   last r rows mirrored) - no sqrt at run time.
gfx_rrect:
    pushal
    mov %eax, rr_x
    mov %ebx, rr_y
    mov %ecx, rr_w
    mov %edx, rr_h
    mov %esi, rr_col
    mov %ebp, %eax               # clamp r
    cmp $24, %eax
    jbe rrc_1
    mov $24, %eax
rrc_1:
    mov rr_h, %ecx
    shr $1, %ecx
    cmp %ecx, %eax
    jbe rrc_2
    mov %ecx, %eax
rrc_2:
    mov rr_w, %ecx
    shr $1, %ecx
    cmp %ecx, %eax
    jbe rrc_3
    mov %ecx, %eax
rrc_3:
    mov %eax, rr_r
    test %eax, %eax
    jnz rr_round
    mov rr_x, %eax               # r == 0: plain rectangle
    mov rr_y, %ebx
    mov rr_w, %ecx
    mov rr_h, %edx
    mov rr_col, %esi
    call gfx_fillrect
    jmp rr_done
rr_round:
    movzwl rr_off-2(%eax,%eax), %ecx  # inset table for radius r
    lea rr_tab(%ecx), %ebp       # EBP = &ins[0]
    xor %edi, %edi               # i = 0 .. r-1: top rows + mirrored bottom rows
rr_corner:
    cmp rr_r, %edi
    jae rr_mid
    movzbl (%ebp,%edi), %eax     # o = ins[i]
    mov rr_x, %ecx
    add %eax, %ecx               # x + o
    mov rr_w, %edx
    sub %eax, %edx
    sub %eax, %edx               # w - 2o
    jle rr_cnext
    push %ecx
    push %edx
    mov %ecx, %eax
    mov rr_y, %ebx
    add %edi, %ebx               # top row y+i
    mov %edx, %ecx
    mov $1, %edx
    mov rr_col, %esi
    call gfx_fillrect
    mov rr_y, %ebx
    add rr_h, %ebx
    dec %ebx
    sub %edi, %ebx               # bottom row y+h-1-i
    call gfx_fillrect
    pop %edx
    pop %ecx
rr_cnext:
    inc %edi
    jmp rr_corner
rr_mid:
    mov rr_h, %edx               # middle: y+r .. y+h-r-1 as one rect
    sub rr_r, %edx
    sub rr_r, %edx
    jle rr_done
    mov rr_x, %eax
    mov rr_y, %ebx
    add rr_r, %ebx
    mov rr_w, %ecx
    mov rr_col, %esi
    call gfx_fillrect
rr_done:
    popal
    ret

# gfx_rrect_b: bordered rounded rectangle = gfx_rrect(r, EDI=border colour)
#   + gfx_rrect(x+1,y+1,w-2,h-2, r-1, ESI=fill colour). EBP = r.
gfx_rrect_b:
    pushal
    push %esi
    mov %edi, %esi
    call gfx_rrect               # border
    pop %esi
    inc %eax
    inc %ebx
    sub $2, %ecx
    sub $2, %edx
    test %ebp, %ebp
    jz rrb_fill
    dec %ebp
rrb_fill:
    call gfx_rrect               # fill
    popal
    ret

# gfx_mask: 1-bit icon. EAX=x EBX=y ESI=colour, EDI = rows (.word per row,
#   MSB = left pixel), ECX = width in bits (<=16), EDX = height in rows,
#   EBP = pixel scale (1..3). Set bits become scale x scale blocks, clear
#   bits are transparent.
# gfx_mask12: the same for the 12x12 icon tables (icon_*): ECX/EDX = 12.
gfx_mask12:
    pushal
    mov $12, %ecx
    mov $12, %edx
    call gfx_mask
    popal
    ret
gfx_mask:
    pushal
    mov %eax, mk_x
    mov %ebx, mk_y
    mov %ecx, mk_w
    mov %edx, mk_h
    mov %esi, mk_col
    mov %ebp, mk_s
    xor %ebx, %ebx               # row
mk_row:
    cmp mk_h, %ebx
    jae mk_done
    movzwl (%edi,%ebx,2), %edx   # row bits
    xor %ecx, %ecx               # col
mk_cl:
    cmp mk_w, %ecx
    jae mk_rnext
    shl $1, %dx
    jnc mk_cnext
    push %ebx
    push %ecx
    push %edx
    mov mk_s, %eax
    imul %eax, %ecx
    add mk_x, %ecx
    imul %eax, %ebx
    add mk_y, %ebx
    mov %ecx, %eax               # EAX = x + col*s, EBX = y + row*s
    mov mk_s, %ecx
    mov mk_s, %edx
    mov mk_col, %esi
    call gfx_fillrect
    pop %edx
    pop %ecx
    pop %ebx
mk_cnext:
    inc %ecx
    jmp mk_cl
mk_rnext:
    inc %ebx
    jmp mk_row
mk_done:
    popal
    ret

# gfx_clip_set: EAX=x EBX=y ECX=w EDX=h -> the clip rectangle draw_rle honours
#   (clip_x0/y0 inclusive, clip_x1/y1 exclusive). gfx_clip_reset: whole screen.
#   desk_layout resets it; con_bg_fill_rect saves/sets/restores it itself.
gfx_clip_set:
    mov %eax, clip_x0
    mov %ebx, clip_y0
    push %eax
    add %ecx, %eax
    mov %eax, clip_x1
    mov %ebx, %eax
    add %edx, %eax
    mov %eax, clip_y1
    pop %eax
    ret
gfx_clip_reset:
    push %eax
    xor %eax, %eax
    mov %eax, clip_x0
    mov %eax, clip_y0
    mov fb_w, %eax
    mov %eax, clip_x1
    mov fb_h, %eax
    mov %eax, clip_y1
    pop %eax
    ret

# draw_rle: blit an RLE v2 image (format: logo/mkgui.py) to the framebuffer.
#   ESI = image, EAX = x, EBX = y (screen px; may lie partly OFF screen - the
#   blit is clipped to the clip rect, default the whole screen).
#   Palette index 0 = TRANSPARENT (skipped). rle_pal_ovr != 0 -> use that
#   .long palette instead of the image's own (recolour the same silhouette).
#   Rows are indexed (rowoff table), so a clipped blit only decodes the rows
#   it touches and stops a row once past the clip's right edge.
draw_rle:
    pushal
    mov %eax, rle_x
    mov %ebx, rle_y
    mov (%esi), %ecx
    mov %ecx, rle_w
    mov 4(%esi), %ecx
    mov %ecx, rle_h
    mov 8(%esi), %ecx            # ncolors
    lea 12(%esi), %edx
    cmpl $0, rle_pal_ovr
    je drl_pal
    mov rle_pal_ovr, %edx
drl_pal:
    mov %edx, rle_pal
    lea 12(%esi,%ecx,4), %edx    # row offset table (.word per row)
    mov %edx, rle_rows
    mov rle_h, %ecx
    lea (%edx,%ecx,2), %edx      # run data
    mov %edx, rle_run
    mov clip_y0, %eax            # visible rows r0 .. r1-1 (image coordinates)
    sub rle_y, %eax
    jns drl_r0
    xor %eax, %eax
drl_r0:
    mov %eax, rle_r0
    mov clip_y1, %eax
    sub rle_y, %eax
    cmp rle_h, %eax
    jle drl_r1
    mov rle_h, %eax
drl_r1:
    mov %eax, rle_r1
    cmp rle_r0, %eax
    jle drl_done
    mov clip_x0, %eax            # visible columns c0 .. c1-1
    sub rle_x, %eax
    jns drl_c0
    xor %eax, %eax
drl_c0:
    mov %eax, rle_c0
    mov clip_x1, %eax
    sub rle_x, %eax
    cmp rle_w, %eax
    jle drl_c1
    mov rle_w, %eax
drl_c1:
    mov %eax, rle_c1
    cmp rle_c0, %eax
    jle drl_done
    mov rle_r0, %edx             # EDX = row
drl_row:
    cmp rle_r1, %edx
    jge drl_done
    mov rle_y, %eax
    add %edx, %eax
    imul fb_ppsl, %eax
    add rle_x, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, rle_row            # address of (x, y+row)
    mov rle_rows, %ebx
    movzwl (%ebx,%edx,2), %esi
    add rle_run, %esi            # ESI = this row's first run
    xor %ebp, %ebp               # EBP = column
drl_run:
    movzbl (%esi), %eax          # bits 0-5 colour, 6-7 run - 1 (3: next byte + 4)
    inc %esi
    mov %eax, %ecx
    shr $6, %ecx
    and $63, %eax
    cmp $3, %ecx
    jb drl_short
    movzbl (%esi), %ecx
    inc %esi
    add $4, %ecx
    jmp drl_have
drl_short:
    inc %ecx
drl_have:                        # EAX = index, ECX = run length
    test %eax, %eax
    jz drl_adv                   # transparent
    mov %ebp, %ebx               # a = max(col, c0)
    cmp rle_c0, %ebx
    jge drl_a
    mov rle_c0, %ebx
drl_a:
    lea (%ebp,%ecx), %edi        # b = min(col+n, c1)
    cmp rle_c1, %edi
    jle drl_b
    mov rle_c1, %edi
drl_b:
    sub %ebx, %edi               # pixels to write
    jle drl_adv
    push %ecx
    mov %edi, %ecx
    mov rle_pal, %edi
    mov (%edi,%eax,4), %eax      # colour
    mov rle_row, %edi
    lea (%edi,%ebx,4), %edi
    rep stosl
    pop %ecx
drl_adv:
    add %ecx, %ebp
    cmp rle_c1, %ebp
    jge drl_rnext                # past the clip: rest of the row is invisible
    cmp rle_w, %ebp
    jb drl_run
drl_rnext:
    inc %edx
    jmp drl_row
drl_done:
    popal
    ret

# con_bg_fill_rect: paint the TERMINAL BACKGROUND into the screen rect
#   EAX=x EBX=y ECX=w EDX=h (pixels, absolute): the flat term_bg_col (CONBG
#   on the desktop, black on the plain console) plus, when the desktop is
#   active, the faint fir silhouette (term_fir_img at fir_term_x/y, tones
#   term_fir_pal) wherever the rect overlaps it. This is what fb_clear,
#   fb_scroll and the console cell painter must use instead of a flat fill
#   (WP3): fill the cell rect with it, then blit the glyph with a
#   TRANSPARENT background (glyph_blit EBP=-1). Cheap: rows outside the fir
#   cost one compare, inside it one RLE row walk. Preserves all registers
#   and the global clip rect.
con_bg_fill_rect:
    pushal
    mov term_bg_col, %esi
    call gfx_fillrect
    cmpb $0, desk_active
    je cbf_done
    cmpl $0, term_fir_img
    je cbf_done
    mov fir_term_x, %edi         # rect entirely outside the fir rect? then the
    add fir_term_w, %edi         #   flat fill was all (per-cell painter, WP3)
    cmp %edi, %eax
    jge cbf_done
    lea (%eax,%ecx), %edi
    cmp fir_term_x, %edi
    jle cbf_done
    mov fir_term_y, %edi
    add fir_term_h, %edi
    cmp %edi, %ebx
    jge cbf_done
    lea (%ebx,%edx), %edi
    cmp fir_term_y, %edi
    jle cbf_done
    push clip_x0
    push clip_y0
    push clip_x1
    push clip_y1
    call gfx_clip_set
    movl $term_fir_pal, rle_pal_ovr
    mov term_fir_img, %esi
    mov fir_term_x, %eax
    mov fir_term_y, %ebx
    call draw_rle
    movl $0, rle_pal_ovr
    pop clip_y1
    pop clip_x1
    pop clip_y0
    pop clip_x0
cbf_done:
    popal
    ret

# con_repaint_rows: EAX = first console row, EBX = last row (inclusive,
#   0..24): redraw those rows' cells from CONSOLE_SHADOW via fb_cell_edi
#   (restores the console under a closed menu/popover). Hides the cursor
#   first. Compositor-gated like every kernel draw path.
con_repaint_rows:
    cmpb $0, fb_active
    je crr_ret
    cmpb $0, compositor_active
    jne crr_ret
    pushal
    mov %eax, %ebp               # row
    call cursor_hide
crr_row:
    cmp %ebx, %ebp
    ja crr_done
    mov %ebp, %edi
    imul $160, %edi              # cell offset of column 0
    mov $80, %ecx
crr_cell:
    mov CONSOLE_SHADOW(%edi), %ax
    push %edi
    add $0xb8000, %edi
    call fb_cell_edi
    pop %edi
    add $2, %edi
    loop crr_cell
    inc %ebp
    jmp crr_row
crr_done:
    call con_caret_show          # the caret cell may have been repainted
    popal
crr_ret:
    ret

# con_repaint_rect: EAX=x EBX=y ECX=w EDX=h (screen px) -> repaint that part
#   of the console: terminal background (con_bg_fill_rect) first, then the
#   glyphs of every cell the rect touches from CONSOLE_SHADOW with a
#   TRANSPARENT background (cell_tr), so the fir silhouette shows through the
#   text. fb_scroll uses it for the fir rect; menus/popovers can use it to
#   restore the console underneath them. Runs with interrupts off (the status
#   line writer must not see cell_tr). Hides the cursor. Compositor-gated.
con_repaint_rect:
    cmpb $0, fb_active
    je crt_ret
    cmpb $0, compositor_active
    jne crt_ret
    pushal
    pushfl
    cli
    mov %eax, crt_x
    mov %ebx, crt_y
    mov %ecx, crt_w
    mov %edx, crt_h
    call cursor_hide
    call con_bg_fill_rect
    mov fb_scale, %ecx
    shl $3, %ecx                 # cell width 8s
    mov crt_x, %eax
    sub con_ox, %eax
    js crt_c0z
    xor %edx, %edx
    div %ecx
    jmp crt_c0
crt_c0z:
    xor %eax, %eax
crt_c0:
    mov %eax, crt_c0v            # first column
    mov crt_x, %eax
    add crt_w, %eax
    dec %eax
    sub con_ox, %eax
    js crt_done
    xor %edx, %edx
    div %ecx
    cmp $79, %eax
    jbe crt_c1
    mov $79, %eax
crt_c1:
    mov %eax, crt_c1v            # last column
    shl $1, %ecx                 # cell height 16s
    mov crt_y, %eax
    sub con_oy, %eax
    js crt_r0z
    xor %edx, %edx
    div %ecx
    jmp crt_r0
crt_r0z:
    xor %eax, %eax
crt_r0:
    mov %eax, %ebp               # EBP = row
    mov crt_y, %eax
    add crt_h, %eax
    dec %eax
    sub con_oy, %eax
    js crt_done
    xor %edx, %edx
    div %ecx
    cmp $24, %eax
    jbe crt_r1
    mov $24, %eax
crt_r1:
    mov %eax, crt_r1v            # last row
    movb $1, cell_tr
crt_row:
    cmp crt_r1v, %ebp
    ja crt_fin
    mov %ebp, %edi
    imul $80, %edi
    add crt_c0v, %edi
    shl $1, %edi                 # cell offset
    mov crt_c1v, %ecx
    sub crt_c0v, %ecx
    inc %ecx
crt_cell:
    mov CONSOLE_SHADOW(%edi), %ax
    push %edi
    add $0xb8000, %edi
    call fb_cell_edi
    pop %edi
    add $2, %edi
    loop crt_cell
    inc %ebp
    jmp crt_row
crt_fin:
    movb $0, cell_tr
    call con_caret_show          # the caret cell may have been repainted
crt_done:
    popfl
    popal
crt_ret:
    ret

# hit_rect: ECX=x EDX=y ESI=w EDI=h -> EAX = 1 if (click_x, click_y) lies in
#   the rect, else 0. Other registers preserved.
hit_rect:
    mov click_x, %eax
    sub %ecx, %eax
    js hr_no
    cmp %esi, %eax
    jae hr_no
    mov click_y, %eax
    sub %edx, %eax
    js hr_no
    cmp %edi, %eax
    jae hr_no
    mov $1, %eax
    ret
hr_no:
    xor %eax, %eax
    ret

# =====================================================================
#  DESKTOP LAYOUT (concept C "Workspace"): every coordinate is computed ONCE
#  here from fb_w/fb_h/fb_scale into the named .long variables below; the
#  drawing code AND the hit tests read those - no literals anywhere else.
#    s = fb_scale (console 640s x 400s px)    u = ui_s = min(s, 2) (UI scale)
#    MARGIN=10u  TOP_H=24u  TITLE_H=20u  PAD=6u  CHIP_H=18u  WISH_H=30u
#    term  = (2M, TOP_H+2M, 640s+2PAD+2, TITLE_H+2PAD+400s+1)
#    wish  = (term_x, term_y+term_h+M, term_w, 30u)
#    panel = (term_x+term_w+2M, term_y, fb_w-panel_x-2M, term_h+M+30u)
#  Fits when panel_w >= 140u and panel_y+panel_h+M <= fb_h (1024x768,
#  1280x800, 1366x768, 1920x1080, 2560x1600 fit; 1600x900 does not ->
#  plain full-screen console, desk_active stays 0).
# =====================================================================
desk_layout:
    pushal
    movl $0, desk_fit
    mov fb_scale, %esi
    cmp $2, %esi
    jbe dl_u
    mov $2, %esi
dl_u:
    mov %esi, ui_s               # ESI = u for the whole routine
    mov fb_scale, %eax
    imul $640, %eax
    mov %eax, con_w
    mov fb_scale, %eax
    imul $400, %eax
    mov %eax, con_h
    imul $10, %esi, %eax
    mov %eax, dk_margin
    imul $24, %esi, %eax
    mov %eax, top_h
    imul $20, %esi, %eax
    mov %eax, title_h
    imul $6, %esi, %ebp          # EBP = PAD
    # --- terminal window + console client rect
    mov con_w, %eax
    lea 2(%eax,%ebp,2), %eax
    mov %eax, term_w
    mov con_h, %eax
    lea 1(%eax,%ebp,2), %eax
    add title_h, %eax
    mov %eax, term_h
    mov dk_margin, %eax
    add %eax, %eax
    mov %eax, term_x
    add top_h, %eax
    mov %eax, term_y
    mov term_x, %eax
    lea 1(%eax,%ebp), %eax
    mov %eax, con_ox
    mov term_y, %eax
    add title_h, %eax
    add %ebp, %eax
    mov %eax, con_oy
    # --- wish field under the terminal
    mov term_x, %eax
    mov %eax, wish_x
    mov term_w, %eax
    mov %eax, wish_w
    mov term_y, %eax
    add term_h, %eax
    add dk_margin, %eax
    mov %eax, wish_y
    imul $30, %esi, %eax
    mov %eax, wish_h
    # --- agents panel on the right
    mov term_x, %eax
    add term_w, %eax
    add dk_margin, %eax
    add dk_margin, %eax
    mov %eax, panel_x
    mov term_y, %eax
    mov %eax, panel_y
    mov fb_w, %eax
    sub panel_x, %eax
    sub dk_margin, %eax
    sub dk_margin, %eax
    mov %eax, panel_w
    mov term_h, %eax
    add dk_margin, %eax
    add wish_h, %eax
    mov %eax, panel_h
    imul $12, %esi, %eax
    add panel_x, %eax
    mov %eax, card_x
    imul $24, %esi, %eax
    neg %eax
    add panel_w, %eax
    mov %eax, card_w
    imul $52, %esi, %eax
    add panel_y, %eax
    mov %eax, card_y
    mov panel_y, %eax
    add panel_h, %eax
    sub card_y, %eax
    imul $12, %esi, %ecx
    sub %ecx, %eax
    mov %eax, card_h
    # --- fit test
    imul $140, %esi, %eax
    cmp %eax, panel_w
    jl dl_nofit
    mov panel_y, %eax
    add panel_h, %eax
    add dk_margin, %eax
    cmp fb_h, %eax
    ja dl_nofit
    movl $1, desk_fit
dl_nofit:
    # --- title-bar chips (help / clear), right-aligned in the title bar
    imul $18, %esi, %eax
    mov %eax, chip_h
    mov term_y, %eax
    lea 1(%eax,%esi), %eax
    mov %eax, chip_y
    imul $56, %esi, %eax
    mov %eax, chip_clear_w
    mov term_x, %ecx
    add term_w, %ecx
    sub %eax, %ecx
    imul $8, %esi, %eax
    sub %eax, %ecx
    mov %ecx, chip_clear_x
    imul $48, %esi, %eax
    mov %eax, chip_help_w
    sub %eax, %ecx
    imul $6, %esi, %eax
    sub %eax, %ecx
    mov %ecx, chip_help_x
    # --- top bar: brand, menu titles, pills, clock, power
    movl $brand_u1, brand_img
    movl $fir_u1, fir_img
    cmp $2, %esi
    jb dl_u1
    movl $brand_u2, brand_img
    movl $fir_u2, fir_img
dl_u1:
    mov dk_margin, %eax
    mov %eax, brand_x
    lea (%esi,%esi), %eax
    mov %eax, brand_y
    mov brand_img, %ebx
    mov (%ebx), %eax
    mov %eax, brand_w
    add brand_x, %eax
    imul $28, %esi, %ecx
    add %ecx, %eax               # EAX = first menu title x
    mov %esi, menu_y
    imul $20, %esi, %ecx
    mov %ecx, menu_h
    xor %edi, %edi
dl_menu:
    mov %eax, menu_x(,%edi,4)
    movzbl menu_len(%edi), %ecx
    shl $3, %ecx
    add $16, %ecx
    imul %esi, %ecx              # w = (len*8 + 16) * u
    mov %ecx, menu_w(,%edi,4)
    add %ecx, %eax
    lea (,%esi,4), %ecx          # gap 4u
    add %ecx, %eax
    inc %edi
    cmp $MENU_N, %edi
    jb dl_menu
    imul $18, %esi, %eax
    mov %eax, pwr_s
    mov %eax, pill_h
    mov fb_w, %ecx
    sub dk_margin, %ecx
    sub %eax, %ecx
    mov %ecx, pwr_x
    lea (%esi,%esi), %eax
    mov %eax, pwr_y
    mov %eax, pill_y
    lea (%eax,%esi), %eax
    mov %eax, clock_y
    mov %eax, pill_ty
    imul $76, %esi, %eax
    sub %eax, %ecx
    mov %ecx, clock_x            # clock = 8 chars 2x left of the power button
    imul $64, %esi, %eax
    mov %eax, pill_up_w
    imul $16, %esi, %edx
    sub %edx, %ecx
    sub %eax, %ecx
    mov %ecx, pill_up_x
    imul $32, %esi, %eax
    add %ecx, %eax
    mov %eax, pill_up_vx
    imul $88, %esi, %eax
    mov %eax, pill_th_w
    imul $8, %esi, %edx
    sub %edx, %ecx
    sub %eax, %ecx
    mov %ecx, pill_th_x
    imul $72, %esi, %eax
    add %ecx, %eax
    mov %eax, pill_th_vx
    imul $96, %esi, %eax
    mov %eax, pill_ag_w
    sub %edx, %ecx
    sub %eax, %ecx
    mov %ecx, pill_ag_x
    imul $80, %esi, %eax
    add %ecx, %eax
    mov %eax, pill_ag_vx
    # --- the fir silhouette: on the wallpaper (bottom right) and inside the
    #     terminal (bottom right of the console, recoloured via term_fir_pal)
    mov fir_img, %ebx
    mov (%ebx), %ecx             # w
    mov 4(%ebx), %edx            # h
    mov %ecx, fir_term_w
    mov %edx, fir_term_h
    mov %ebx, term_fir_img
    mov %ecx, %eax
    imul $5, %eax
    push %edx
    xor %edx, %edx
    push %ecx
    mov $6, %ecx
    div %ecx                     # w*5/6
    pop %ecx
    pop %edx
    neg %eax
    add fb_w, %eax
    mov %eax, fir_wall_x
    mov fb_h, %eax
    sub %edx, %eax
    sub dk_margin, %eax
    sub dk_margin, %eax
    mov %eax, fir_wall_y
    mov con_ox, %eax
    add con_w, %eax
    sub %ecx, %eax
    imul $16, %esi, %ebx
    sub %ebx, %eax
    mov %eax, fir_term_x
    mov con_oy, %eax
    add con_h, %eax
    sub %edx, %eax
    imul $8, %esi, %ebx
    sub %ebx, %eax
    mov %eax, fir_term_y
    call gfx_clip_reset
    popal
    ret

# =====================================================================
#  desktop_init: lay out and paint the desktop (boot, and again from
#   screen_repaint after a game). Order: wallpaper + silhouette, top bar,
#   terminal frame (WP3 owns its final look), wish field (WP3), agents
#   panel (WP4). Re-entrant. If the mode is too small nothing is drawn and
#   the console stays full-screen at (0,0).
# =====================================================================
desktop_init:
    cmpb $0, fb_active
    je dsi_ret
    call desk_layout
    cmpl $0, desk_fit
    jne dsi_fit
    movb $0, desk_active         # too small: plain console, black background
    movl $0, con_ox
    movl $0, con_oy
    movl $0, con_off
    movl $0, term_bg_col
    jmp dsi_ret
dsi_fit:
    pushal
    call cursor_hide
    mov con_oy, %eax             # place the console inside the terminal window
    imul fb_ppsl, %eax
    add con_ox, %eax
    mov %eax, con_off
    movl $C_CONBG, term_bg_col
    movb $1, desk_active
    call draw_backdrop
    call draw_topbar
    call draw_terminal_frame     # WP3
    call draw_wish               # WP3
    call draw_agents_panel       # WP4
    popal
dsi_ret:
    ret

# draw_backdrop: wallpaper gradient + the fir silhouette (bottom right).
draw_backdrop:
    pushal
    movl $C_BG_TOP, grd_c0
    movl $C_BG_BOT, grd_c1
    xor %eax, %eax
    xor %ebx, %ebx
    mov fb_w, %ecx
    mov fb_h, %edx
    call gfx_vgrad
    call gfx_clip_reset
    mov fir_img, %esi
    mov fir_wall_x, %eax
    mov fir_wall_y, %ebx
    call draw_rle
    popal
    ret

# draw_topbar: flat SURFACE2 bar, aurora line, brand, the five menu titles
#   (text only - WP2 adds the dropdowns in menu_handle_click), the three
#   status pills, the clock and the power button; then desk_refresh fills in
#   the live values.
draw_topbar:
    pushal
    mov ui_s, %esi
    xor %eax, %eax
    xor %ebx, %ebx
    mov fb_w, %ecx
    mov top_h, %edx
    push %esi
    mov $C_SURFACE2, %esi
    call gfx_fillrect
    mov top_h, %ebx
    dec %ebx
    mov $1, %edx
    mov $C_BORDER, %esi
    call gfx_fillrect            # bottom border line
    pop %esi
    lea (%esi,%esi), %edx        # aurora: 2u px, left half ACCENT -> BORDER
    mov top_h, %ebx
    sub %edx, %ebx
    dec %ebx
    mov fb_w, %ecx
    shr $1, %ecx
    movl $C_ACCENT, grd_c0
    movl $C_BORDER, grd_c1
    call gfx_hgrad
    mov %ecx, %eax               # right half flat BORDER
    mov fb_w, %ecx
    sub %eax, %ecx
    push %esi
    mov $C_BORDER, %esi
    call gfx_fillrect
    pop %esi
    call gfx_clip_reset
    push %esi
    mov brand_img, %esi          # fir mark + wordmark (pre-blended on SURFACE2)
    mov brand_x, %eax
    mov brand_y, %ebx
    call draw_rle
    pop %esi
    xor %edi, %edi               # menu titles
dtb_menu:
    mov menu_x(,%edi,4), %eax
    imul $8, %esi, %ebx
    add %ebx, %eax
    mov menu_y, %ebx
    lea (%ebx,%esi,2), %ebx
    mov $C_TEXT2, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    push %esi
    mov menu_lbl(,%edi,4), %esi
    call ui_puts
    pop %esi
    inc %edi
    cmp $MENU_N, %edi
    jb dtb_menu
    mov pill_ag_x, %eax          # pill chrome + labels
    mov pill_ag_w, %ecx
    mov $lbl_agents, %edi
    call dtb_pill
    mov pill_th_x, %eax
    mov pill_th_w, %ecx
    mov $lbl_threads, %edi
    call dtb_pill
    mov pill_up_x, %eax
    mov pill_up_w, %ecx
    mov $lbl_up, %edi
    call dtb_pill
    mov pwr_x, %eax              # power button
    mov pwr_y, %ebx
    mov pwr_s, %ecx
    mov pwr_s, %edx
    push %esi
    mov $C_SURFACE3, %esi
    mov $C_BORDER, %edi
    mov ui_s, %ebp
    shl $2, %ebp                 # r = 4u
    call gfx_rrect_b
    pop %esi
    imul $5, %esi, %ebx
    add %ebx, %eax
    add pwr_y, %ebx
    mov $icon_power, %edi
    mov $8, %ecx
    mov $8, %edx
    mov %esi, %ebp
    push %esi
    mov $C_TEXT2, %esi
    call gfx_mask
    pop %esi
    call desk_refresh            # live values + clock
    popal
    ret
dtb_pill:                        # EAX=x ECX=w EDI=label (ESI=u): chrome + label
    pushal
    mov pill_y, %ebx
    mov pill_h, %edx
    push %edi
    push %eax
    mov $C_SURFACE3, %esi
    mov $C_BORDER, %edi
    mov ui_s, %ebp
    shl $2, %ebp
    call gfx_rrect_b
    pop %eax
    pop %edi
    mov ui_s, %esi
    shl $3, %esi
    add %esi, %eax               # text x = x + 8u
    cmp $lbl_agents, %edi
    jne dtp_lbl
    add %esi, %eax               # AGENTS: room for the dot (16u)
    add %esi, %eax
dtp_lbl:
    mov pill_ty, %ebx
    mov $C_TEXT2, %ecx
    mov ui_s, %edx
    mov $-1, %ebp
    mov %edi, %esi
    call ui_puts
    popal
    ret

# desk_refresh: the live top-bar values - AGENTS dot + count, THREADS count,
#   UP time, clock. Opaque text on the flat pill/bar colour, so no clearing.
#   Called from draw_topbar and desktop_tick (~1/s).
desk_refresh:
    pushal
    xor %ebp, %ebp               # live agents
    xor %ebx, %ebx
dr_ac:
    mov %ebx, %eax
    shl $3, %eax
    cmpb $0, agents_tbl(%eax)
    je dr_acn
    inc %ebp
dr_acn:
    inc %ebx
    cmp $8, %ebx
    jb dr_ac
    mov $C_OK, %esi              # dot: OK when agents > 0, else MUTED
    test %ebp, %ebp
    jnz dr_dot
    mov $C_MUTED, %esi
dr_dot:
    push %ebp
    mov ui_s, %ecx
    mov pill_ag_x, %eax
    imul $9, %ecx, %edx
    add %edx, %eax               # dot centre x = x + 12u, y = ty + 8u -> rect 6u
    mov pill_ty, %ebx
    imul $5, %ecx, %edx
    add %edx, %ebx
    imul $6, %ecx, %ecx
    mov %ecx, %edx
    mov ui_s, %ebp
    lea (%ebp,%ebp,2), %ebp      # r = 3u
    call gfx_rrect
    pop %ebp
    mov %ebp, %eax
    mov pill_ag_vx, %ebx
    call dr_digit
    xor %ecx, %ecx               # runnable threads (incl. shell)
    xor %ebx, %ebx
dr_thr:
    cmpb $1, tcb_state(%ebx)
    jne dr_th2
    inc %ecx
dr_th2:
    inc %ebx
    cmp $9, %ebx
    jb dr_thr
    mov %ecx, %eax
    mov pill_th_vx, %ebx
    call dr_digit
    mov ticks, %eax              # uptime: <100 "NNs", <6000 s "NNm", else "NNh"
    xor %edx, %edx
    mov $18, %ecx
    div %ecx
    mov $0x73, %bl               # 's'
    cmp $100, %eax
    jb dr_up
    xor %edx, %edx
    mov $60, %ecx
    div %ecx
    mov $0x6d, %bl               # 'm'
    cmp $100, %eax
    jb dr_up
    xor %edx, %edx
    div %ecx
    mov $0x68, %bl               # 'h'
dr_up:
    mov $gtx_buf, %edi
    call bdec32
    mov %bl, (%edi)
    inc %edi
    movb $0x20, (%edi)           # pad to 3 columns ("7s ")
    movb $0, 1(%edi)
    mov $gtx_buf, %esi
    mov pill_up_vx, %eax
    mov pill_ty, %ebx
    mov $C_TEXT, %ecx
    mov ui_s, %edx
    mov $C_SURFACE3, %ebp
    call ui_puts
    call draw_clock
    popal
    ret
dr_digit:                        # EAX = value (clamped to 9), EBX = text x
    pushal
    cmp $9, %eax
    jbe dr_d9
    mov $9, %eax
dr_d9:
    add $0x30, %al
    mov %al, gtx_buf
    movb $0, gtx_buf+1
    mov %ebx, %eax
    mov $gtx_buf, %esi
    mov pill_ty, %ebx
    mov $C_TEXT, %ecx
    mov ui_s, %edx
    mov $C_SURFACE3, %ebp
    call ui_puts
    popal
    ret

# =====================================================================
#  STUBS the other work packages fill in. Minimal versions here keep the
#  desktop usable: WP3 = draw_terminal_frame + draw_wish/wish_render/
#  wish_edit + console colours, WP2 = menu_handle_click (dropdowns, hover,
#  power/chip actions), WP4 = draw_agents_panel (cards, tick refresh).
# =====================================================================
# draw_terminal_frame (WP3 owns): shadow, bordered rounded window, title bar
#   with the fir mark, "Terminal 80x25 . ring 3", help/clear chips, and the
#   console client background (con_bg_fill_rect = CONBG + faint fir).
draw_terminal_frame:
    pushal
    pushfl                       # the ISR's desk_refresh shares the gtx_* pen
    cli
    movl $-1, caret_pos          # the client area is repainted; cls re-draws the caret
    mov ui_s, %esi
    mov term_x, %eax
    mov term_y, %ebx
    mov term_w, %ecx
    mov term_h, %edx
    mov $2, %esi
    call gfx_shadow
    mov $C_CONBG, %esi
    mov $C_BORDER2, %edi
    mov ui_s, %ebp
    shl $3, %ebp                 # R_MD = 8u
    call gfx_rrect_b
    inc %eax                     # title bar: rrect (r-1) + squared lower half
    inc %ebx
    sub $2, %ecx
    mov title_h, %edx
    mov $C_SURFACE2, %esi
    dec %ebp
    call gfx_rrect
    mov title_h, %edx
    shr $1, %edx
    add %edx, %ebx
    dec %ebx
    inc %edx
    call gfx_fillrect
    mov term_x, %eax             # 1 px highlight along the top edge (between the
    lea 1(%eax,%ebp), %eax       #   corners) - the lit rim of the window
    mov term_y, %ebx
    inc %ebx
    mov term_w, %ecx
    sub %ebp, %ecx
    sub %ebp, %ecx
    sub $2, %ecx
    mov $1, %edx
    mov $C_SURFACE3, %esi
    call gfx_fillrect
    mov term_x, %eax             # title/client separator
    inc %eax
    mov term_y, %ebx
    add title_h, %ebx
    mov term_w, %ecx
    sub $2, %ecx
    mov $1, %edx
    mov $C_BORDER, %esi
    call gfx_fillrect
    movl $C_ACCENT_DEEP, grd_c0  # ... with a short teal fade at its left end
    movl $C_BORDER, grd_c1       #   (echoes the top bar's aurora line)
    mov term_w, %ecx
    shr $2, %ecx
    call gfx_hgrad
    mov ui_s, %esi
    imul $14, %esi, %eax         # 12x12 fir mark (accent) left of the title
    add term_x, %eax
    mov term_y, %ebx
    lea 1(%ebx,%esi,4), %ebx     # y = term_y + 1 + (TITLE_H - 12u)/2
    mov %esi, %ebp
    mov $icon_fir, %edi
    mov $C_ACCENT, %esi
    call gfx_mask12
    mov ui_s, %esi
    imul $34, %esi, %eax         # title text at term_x + 14u + 12u + 8u
    add term_x, %eax
    mov term_y, %ebx
    lea 1(%ebx,%esi,2), %ebx
    mov $C_TEXT, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    mov $dsk_term, %esi
    call ui_puts
    mov ui_s, %esi
    mov gtx_x, %eax
    lea (%eax,%esi,8), %eax
    mov $C_MUTED, %ecx
    mov $dsk_term2, %esi         # "80x25"
    call ui_puts
    mov ui_s, %esi
    mov gtx_x, %eax              # separator dot 2u x 2u, one char cell wide
    lea -1(%eax,%esi,8), %eax
    sub %esi, %eax
    mov gtx_y, %ebx
    lea (%ebx,%esi,8), %ebx
    sub %esi, %ebx
    lea (%esi,%esi), %ecx
    mov %ecx, %edx
    mov $C_MUTED, %esi
    call gfx_fillrect
    mov ui_s, %esi
    mov gtx_x, %eax
    lea (%eax,%esi,8), %eax
    lea (%eax,%esi,8), %eax
    mov term_y, %ebx
    lea 1(%ebx,%esi,2), %ebx
    mov $C_MUTED, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    mov $dsk_term3, %esi         # "ring 3"
    call ui_puts
    call draw_term_chips         # help / clear (state bytes chip_help_st/clear_st)
    mov con_ox, %eax             # console client background (+ faint fir)
    mov con_oy, %ebx
    mov con_w, %ecx
    mov con_h, %edx
    call con_bg_fill_rect
    popfl
    popal
    ret

# draw_term_chips: both title-bar chips in their current state. WP2's hover
#   code sets chip_help_st / chip_clear_st (0 normal, 1 hover, 2 pressed) and
#   calls this (cursor_hide first) - or term_chip_draw for a single chip.
draw_term_chips:
    pushal
    mov chip_help_x, %eax
    mov chip_help_w, %ecx
    mov $lbl_help, %edi
    movzbl chip_help_st, %esi
    call term_chip_draw
    mov chip_clear_x, %eax
    mov chip_clear_w, %ecx
    mov $lbl_clear, %edi
    movzbl chip_clear_st, %esi
    call term_chip_draw
    popal
    ret

# term_chip_draw: EAX=x ECX=w EDI=label ESI=state (0|1|2) -> chip at chip_y
#   with the SPEC 4.5 colours (chip_cols). Preserves all registers.
term_chip_draw:
    pushal
    cmp $2, %esi
    jbe tcd_st
    xor %esi, %esi
tcd_st:
    imul $12, %esi, %ebx         # EBX -> {fill, border, text}
    push %edi
    push %eax
    mov chip_cols(%ebx), %esi
    mov chip_cols+4(%ebx), %edi
    push %ebx
    mov chip_y, %ebx
    mov chip_h, %edx
    mov ui_s, %ebp
    shl $2, %ebp                 # R_SM
    call gfx_rrect_b
    pop %ebx
    mov chip_cols+8(%ebx), %ecx
    pop %eax
    pop %esi
    mov ui_s, %edx
    lea (%eax,%edx,8), %eax      # text at x + 8u, y + u
    mov chip_y, %ebx
    add %edx, %ebx
    mov $-1, %ebp
    call ui_puts
    popal
    ret

# =====================================================================
#  CONSOLE CARET (WP3): on the desktop the text cursor is an ACCENT block
#   over the cell at (cur_x, cur_y) with the cell's glyph cut out in CONBG.
#   caret_pos = cell index of the painted block, -1 = none. move_cursor calls
#   con_caret_move; scroll_up / fb_clear / the frame painter lift or forget
#   it before pixels move; con_repaint_rows/rect re-show it. Gated like
#   every kernel draw path (and off while a ring-3 program owns the screen).
# =====================================================================
con_caret_move:
    cmpb $0, fb_active
    je ccm_ret
    cmpb $0, desk_active
    je ccm_ret
    cmpb $0, compositor_active
    jne ccm_ret
    cmpb $0, fg_prog
    jne ccm_ret
    cmpb $25, cur_y              # mid-scroll (row 25): nothing to paint yet
    jae ccm_ret
    pushal
    pushfl
    cli
    movzbl cur_y, %eax
    imul $80, %eax
    movzbl cur_x, %ebx
    add %ebx, %eax
    cmp caret_pos, %eax
    je ccm_done
    mov %eax, %ebx
    call con_caret_hide
    mov %ebx, caret_pos
    call con_caret_paint
ccm_done:
    popfl
    popal
ccm_ret:
    ret

# con_caret_hide: repaint the caret cell from CONSOLE_SHADOW, forget it.
con_caret_hide:
    cmpl $-1, caret_pos
    je cch_ret
    cmpb $0, fb_active
    je cch_ret
    cmpb $0, compositor_active
    jne cch_ret
    pushal
    mov caret_pos, %edi
    movl $-1, caret_pos
    shl $1, %edi
    mov CONSOLE_SHADOW(%edi), %ax
    add $0xb8000, %edi
    call fb_cell_edi
    popal
cch_ret:
    ret

# con_caret_show: (after a shadow repaint) paint the caret again at the cursor.
con_caret_show:
    movl $-1, caret_pos
    call con_caret_move
    ret

# con_caret_paint: EBX = cell index -> ACCENT block + inverted glyph.
con_caret_paint:
    pushal
    mov %ebx, %eax
    xor %edx, %edx
    mov $80, %ecx
    div %ecx                     # EAX=row, EDX=col
    mov fb_scale, %ecx
    shl $3, %ecx                 # ECX = 8s
    imul %ecx, %edx
    add con_ox, %edx             # EDX = x
    lea (%ecx,%ecx), %ebp        # EBP = 16s
    imul %ebp, %eax
    add con_oy, %eax             # EAX = y
    push %eax
    push %edx
    mov %eax, %ebx
    mov %edx, %eax
    mov %ebp, %edx
    mov $C_ACCENT, %esi
    call gfx_fillrect            # the block
    pop %edx
    pop %eax
    imul fb_ppsl, %eax
    add %edx, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, %edi               # EDI = first pixel
    mov caret_pos, %eax
    movzbl CONSOLE_SHADOW(,%eax,2), %eax   # the char under the caret
    mov %eax, %ecx
    call fb_glyph                # ESI = glyph
    mov fb_scale, %eax
    mov %eax, gb_scale
    movb $1, gb_epx
    cmp $0x80, %ecx              # CP437 blocks stay nearest (as in fb_cell_edi)
    jb ccp_blit
    movb $0, gb_epx
ccp_blit:
    mov $C_CONBG, %edx           # glyph in the terminal colour, transparent bg
    mov $-1, %ebp
    call glyph_blit
    movb $1, gb_epx
    popal
    ret

# draw_wish (WP3 owns): the wish field under the terminal = wish_render.
draw_wish:
    call wish_render
    ret

# =====================================================================
#  AGENTS PANEL (WP4 owns): live cards from agents_tbl / tasks_tbl.
#   Vertical budget (units of u = ui_s) inside (card_x, card_y, card_w,
#   card_h): agent card 72u (+8u gap), empty-slot card 36u (+8u), "+ N
#   more" line 24u, Spawn button 32u (+12u), RECENT TASKS header 20u +
#   3..5 rows of 20u, footer 40u (+16u incl. separator) at the bottom.
#   panel_layout fits as many cards as the height allows (the rest ->
#   "+ N hidden agents"), max 2 empty slots, and gives spare height to
#   RECENT rows. draw_agents_panel paints everything (desktop_init);
#   panel_refresh (desktop_tick, ~1/s, cursor hidden) repaints only what
#   changed against pn_cache / pn_tcache - bar-only when just the % moved,
#   whole body when a slot appeared/vanished. panel_handle_click: agent
#   card -> `tasks`, Spawn button / empty slot -> inline chooser (math
#   prime count gcd) -> `spawn <type>`, header -> `agents`. pn_busy keeps
#   the timer-path refresh out of a main-thread paint.
# =====================================================================
draw_agents_panel:
    pushal
    movb $1, pn_busy
    movb $0, pn_choose
    mov panel_x, %eax
    mov panel_y, %ebx
    mov panel_w, %ecx
    mov panel_h, %edx
    xor %esi, %esi
    call gfx_shadow
    mov $C_SURFACE, %esi
    mov $C_BORDER, %edi
    mov ui_s, %ebp
    shl $3, %ebp
    call gfx_rrect_b
    call panel_layout
    call pn_header
    call pn_cards
    call pn_recent
    call pn_footer
    call pn_snapshot
    movb $0, pn_busy
    popal
    ret

# panel_refresh: the ~1/s delta repaint (from desktop_tick, cursor hidden).
panel_refresh:
    cmpb $0, pn_busy
    jne pr_ret
    cmpb $0, fg_prog             # a game owns the screen: leave it alone
    jne pr_ret
    pushal
    movb $1, pn_busy
    call gfx_state_save          # we run from the timer path: leave the
    xor %ebx, %ebx               # did a slot appear / vanish?
    xor %ecx, %ecx
pr_u:
    mov agents_tbl(,%ebx,8), %al
    cmp pn_cache(,%ebx,8), %al
    je pr_u1
    inc %ecx
pr_u1:
    inc %ebx
    cmp $8, %ebx
    jb pr_u
    test %ecx, %ecx
    jz pr_cards
    call pn_clear_body           # structure changed: relayout + full body
    call panel_layout
    call pn_hdr_count
    call pn_cards
    call pn_recent
    jmp pr_snap
pr_cards:
    xor %ecx, %ecx               # ECX = visible card index
pr_c:
    cmp pn_ncards, %ecx
    jae pr_tasks
    movzbl pn_slots(%ecx), %ebx
    lea agents_tbl(,%ebx,8), %esi
    lea pn_cache(,%ebx,8), %edi
    push %ecx
    mov $6, %ecx                 # used/type/status/task/done differ?
    repe cmpsb
    pop %ecx
    jne pr_card
    cmpb $1, agents_tbl+2(,%ebx,8)
    jne pr_cn                    # idle + unchanged: nothing to do
    call pn_bar                  # working: bar moves (or sweeps)
    jmp pr_cn
pr_card:
    call pn_card
pr_cn:
    inc %ecx
    jmp pr_c
pr_tasks:
    mov $tasks_tbl, %esi
    mov $pn_tcache, %edi
    mov $128, %ecx
    repe cmpsb
    je pr_snap
    call pn_recent
pr_snap:
    call pn_snapshot
    call pn_uptime
    call gfx_state_restore       #   primitives' pen/scratch as we found it
    movb $0, pn_busy
    popal
pr_ret:
    ret

# gfx_state_save / gfx_state_restore: snapshot the drawing primitives'
#   memory temps (grd_/vg_/sh_/rr_/mk_/clip_/rle_/crt_ block and the
#   gb_/gtx_ pen state) so a paint from the timer ISR cannot corrupt a
#   main-thread paint it interrupted (e.g. desktop_init's text continuing
#   at the ISR's pen position). pushal-safe; ~250 bytes copied.
gfx_state_save:
    pushal
    cld
    mov $grd_c0, %esi
    mov $pn_save, %edi
    mov $(rr_off - grd_c0), %ecx
    rep movsb
    mov $gb_epx, %esi
    mov $(gtx_buf - gb_epx), %ecx
    rep movsb
    popal
    ret
gfx_state_restore:
    pushal
    cld
    mov $pn_save, %esi
    mov $grd_c0, %edi
    mov $(rr_off - grd_c0), %ecx
    rep movsb
    mov $gb_epx, %edi
    mov $(gtx_buf - gb_epx), %ecx
    rep movsb
    popal
    ret

pn_snapshot:                     # remember what is on screen now
    pushal
    cld
    mov $agents_tbl, %esi
    mov $pn_cache, %edi
    mov $48, %ecx                # 64 + 128 bytes, the tables are adjacent
    rep movsl
    popal
    ret

# panel_layout: counts + y positions (no drawing). See the header comment.
panel_layout:
    pushal
    mov ui_s, %esi
    xor %ecx, %ecx
    xor %ebx, %ebx
pl_cnt:
    cmpb $0, agents_tbl(,%ebx,8)
    je pl_c1
    mov %bl, pn_slots(%ecx)      # visible-card index -> slot
    inc %ecx
pl_c1:
    inc %ebx
    cmp $8, %ebx
    jb pl_cnt
    mov %ecx, pn_active
    mov card_h, %eax
    imul $204, %esi, %edx        # fixed: footer 56 + recent 80 + spawn 44 + more 24
    sub %edx, %eax
    mov %eax, %ebp               # EBP = spare height
    imul $80, %esi, %ecx
    xor %edx, %edx
    div %ecx
    cmp pn_active, %eax          # cards = min(active, spare / 80u)
    jbe pl_nc
    mov pn_active, %eax
pl_nc:
    mov %eax, pn_ncards
    imul %ecx, %eax
    sub %eax, %ebp
    mov %ebp, %eax
    imul $44, %esi, %ecx
    xor %edx, %edx
    div %ecx
    cmp $2, %eax                 # empty slots = min(free, 2, spare / 44u)
    jbe pl_ne
    mov $2, %eax
pl_ne:
    mov $8, %edx
    sub pn_active, %edx
    cmp %edx, %eax
    jbe pl_ne2
    mov %edx, %eax
pl_ne2:
    mov %eax, pn_nempty
    imul %ecx, %eax
    sub %eax, %ebp
    mov %ebp, %eax
    imul $20, %esi, %ecx
    xor %edx, %edx
    div %ecx
    cmp $2, %eax                 # recent rows = 3 + min(2, spare / 20u)
    jbe pl_nr
    mov $2, %eax
pl_nr:
    add $3, %eax
    mov %eax, pn_rows
    mov card_y, %eax
    mov pn_ncards, %edx
    imul $80, %esi, %ecx
    imul %ecx, %edx
    add %edx, %eax
    mov %eax, pn_ey              # first empty-slot card
    mov pn_nempty, %edx
    imul $44, %esi, %ecx
    imul %ecx, %edx
    add %edx, %eax
    mov %eax, pn_my              # "+ N more" line
    imul $24, %esi, %ecx
    add %ecx, %eax
    mov %eax, pn_sy              # Spawn button
    mov panel_y, %eax
    add panel_h, %eax
    imul $52, %esi, %ecx
    sub %ecx, %eax
    mov %eax, pn_fy              # footer (fir + two lines)
    imul $36, %esi, %ecx
    sub %ecx, %eax
    mov pn_rows, %edx
    imul $20, %esi, %ecx
    imul %ecx, %edx
    sub %edx, %eax
    mov %eax, pn_ry              # RECENT TASKS header
    popal
    ret

# pn_header: agent glyph, "Agents", "N of 8 slots", chevron, separator.
pn_header:
    pushal
    mov ui_s, %esi
    imul $16, %esi, %eax
    add panel_x, %eax
    imul $16, %esi, %ebx
    add panel_y, %ebx
    mov %esi, %ebp
    mov $icon_agents, %edi
    push %esi
    mov $C_ACCENT, %esi
    call gfx_mask12
    pop %esi
    imul $36, %esi, %eax
    add panel_x, %eax
    imul $14, %esi, %ebx
    add panel_y, %ebx
    mov $C_TEXT, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    push %esi
    mov $lbl_agents_hdr, %esi
    call ui_puts
    pop %esi
    call pn_hdr_count
    mov panel_x, %eax
    add panel_w, %eax
    imul $28, %esi, %ebx
    sub %ebx, %eax
    imul $16, %esi, %ebx
    add panel_y, %ebx
    mov %esi, %ebp
    mov $icon_chev_r, %edi
    mov $C_TEXT2, %esi
    call gfx_mask12
    mov ui_s, %esi
    mov card_x, %eax
    imul $40, %esi, %ebx
    add panel_y, %ebx
    mov card_w, %ecx
    mov $1, %edx
    mov $C_BORDER, %esi
    call gfx_fillrect
    popal
    ret

pn_hdr_count:                    # "N of 8 slots " (opaque, 1x, MUTED)
    pushal
    mov $pn_buf, %edi
    mov pn_active, %eax
    call bdec32
    mov $pn_s_of, %esi
    call bputs
    movb $0, (%edi)
    mov ui_s, %esi
    imul $92, %esi, %eax
    add panel_x, %eax
    imul $22, %esi, %ebx
    add panel_y, %ebx
    sub $8, %ebx
    mov $C_MUTED, %ecx
    mov $1, %edx
    mov $C_SURFACE, %ebp
    mov $pn_buf, %esi
    call ui_puts
    popal
    ret

pn_clear_body:                   # SURFACE over cards .. recent (footer stays)
    pushal
    mov card_x, %eax
    mov card_y, %ebx
    mov card_w, %ecx
    mov pn_fy, %edx
    mov ui_s, %esi
    shl $4, %esi
    sub %esi, %edx
    sub %ebx, %edx
    mov $C_SURFACE, %esi
    call gfx_fillrect
    popal
    ret

# pn_cards: all visible agent cards, empty-slot cards, more line, button.
pn_cards:
    pushal
    xor %ecx, %ecx
pcs_c:
    cmp pn_ncards, %ecx
    jae pcs_e
    movzbl pn_slots(%ecx), %ebx
    call pn_card
    inc %ecx
    jmp pcs_c
pcs_e:
    xor %ecx, %ecx
pcs_el:
    cmp pn_nempty, %ecx
    jae pcs_m
    call pn_empty
    inc %ecx
    jmp pcs_el
pcs_m:
    call pn_more
    call pn_spawn
    popal
    ret

# pn_card: EBX = agent slot, ECX = visible card index. Draws the whole
#   card (then the bar via pn_bar). Colour/label by state: busy WORKING
#   (ACCENT), idle with completed tasks DONE (OK), else IDLE (MUTED).
pn_card:
    pushal
    mov ui_s, %esi
    mov %ebx, pc_slot
    mov %ecx, %eax
    imul $80, %esi, %edx
    imul %edx, %eax
    add card_y, %eax
    mov %eax, pc_y
    lea agents_tbl(,%ebx,8), %edi
    mov $C_ACCENT, %eax
    mov $pn_s_work, %edx
    cmpb $1, 2(%edi)
    je pc_c0
    mov $C_OK, %eax
    mov $pn_s_dn, %edx
    cmpw $0, 4(%edi)
    jne pc_c0
    mov $C_MUTED, %eax
    mov $pn_s_idle, %edx
pc_c0:
    mov %eax, pcd_col
    mov %edx, pc_lbl
    mov card_x, %eax             # card body
    mov pc_y, %ebx
    mov card_w, %ecx
    imul $72, %esi, %edx
    push %esi
    mov $C_SURFACE2, %esi
    mov $C_BORDER, %edi
    mov ui_s, %ebp
    lea (%ebp,%ebp,2), %ebp
    add %ebp, %ebp               # r = 6u
    call gfx_rrect_b
    pop %esi
    inc %eax                     # state strip: x+1, y+6u, 2u x (h-12u)
    imul $6, %esi, %edx
    add %edx, %ebx
    lea (%esi,%esi), %ecx
    imul $60, %esi, %edx
    push %esi
    mov pcd_col, %esi
    call gfx_fillrect
    pop %esi
    mov card_x, %eax             # status dot: 8u disc at (x+16u, y+12u)
    imul $16, %esi, %edx
    add %edx, %eax
    mov pc_y, %ebx
    imul $12, %esi, %edx
    add %edx, %ebx
    lea (,%esi,8), %ecx
    mov %ecx, %edx
    lea (,%esi,4), %ebp
    push %esi
    mov pcd_col, %esi
    call gfx_rrect
    pop %esi
    mov card_x, %eax             # name (scale u, TEXT) at (x+32u, y+8u)
    imul $32, %esi, %edx
    add %edx, %eax
    mov pc_y, %ebx
    lea (,%esi,8), %edx
    add %edx, %ebx
    mov %ebx, pc_ty
    mov $C_TEXT, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    push %esi
    mov pc_slot, %esi
    mov agent_names(,%esi,4), %esi
    call ui_puts
    pop %esi
    mov pc_slot, %edi            # type chip after the name (1x text)
    movzbl agents_tbl+1(,%edi,8), %edi
    mov type_names(,%edi,4), %edi
    mov %edi, pc_typ
    call pn_strlen
    lea 12(,%ecx,8), %ecx
    mov gtx_x, %eax
    imul $10, %esi, %edx
    add %edx, %eax
    mov %eax, pc_cx
    mov pc_ty, %ebx
    lea -10(,%esi,8), %edx       # (16u - 20) / 2
    add %edx, %ebx
    mov %ebx, pc_cy
    mov $20, %edx
    push %esi
    mov $C_SURFACE3, %esi
    mov $C_BORDER2, %edi
    mov $4, %ebp
    call gfx_rrect_b
    pop %esi
    mov pc_cx, %eax
    add $6, %eax
    mov pc_cy, %ebx
    add $2, %ebx
    mov $C_TEXT2, %ecx
    mov $1, %edx
    mov $-1, %ebp
    push %esi
    mov pc_typ, %esi
    call ui_puts
    pop %esi
    mov pc_lbl, %edi             # state label, spaced 1x, right-aligned
    call pn_strlen
    imul $10, %ecx, %ecx
    mov card_x, %eax
    add card_w, %eax
    imul $10, %esi, %edx
    sub %edx, %eax
    sub %ecx, %eax
    mov pc_ty, %ebx
    lea -8(,%esi,8), %edx
    add %edx, %ebx
    mov pcd_col, %ecx
    push %esi
    mov pc_lbl, %esi
    call pn_puts_sp
    pop %esi
    mov $pn_buf, %edi            # meta line "slot N  ring 3  stack 4 KB"
    mov $pn_s_slot, %esi
    call bputs
    mov pc_slot, %eax
    add $0x30, %al
    stosb
    mov $pn_s_meta, %esi
    call bputs
    movb $0, (%edi)
    mov ui_s, %esi
    mov card_x, %eax
    imul $32, %esi, %edx
    add %edx, %eax
    mov pc_y, %ebx
    imul $34, %esi, %edx
    add %edx, %ebx
    mov %ebx, pc_ty
    mov $C_MUTED, %ecx
    mov $1, %edx
    mov $-1, %ebp
    push %esi
    mov $pn_buf, %esi
    call ui_puts
    pop %esi
    mov $pn_buf, %edi            # "N done", right-aligned, 1x TEXT2
    mov pc_slot, %eax
    movzwl agents_tbl+4(,%eax,8), %eax
    call bdec32
    mov $pn_s_done, %esi
    call bputs
    movb $0, (%edi)
    mov ui_s, %esi
    mov $pn_buf, %edi
    call pn_strlen
    shl $3, %ecx
    mov card_x, %eax
    add card_w, %eax
    imul $10, %esi, %edx
    sub %edx, %eax
    sub %ecx, %eax
    mov pc_ty, %ebx
    mov $C_TEXT2, %ecx
    mov $1, %edx
    mov $-1, %ebp
    mov $pn_buf, %esi
    call ui_puts
    popal
    jmp pn_bar

# pn_bar: EBX = slot, ECX = card index. Track (BORDER) + fill: while the
#   agent ramps 0..99 % a determinate ACCENT bar; at 100 % (computing) a
#   quarter-width segment that bounces with ticks; idle: track only.
pn_bar:
    pushal
    mov ui_s, %esi
    mov %ebx, pb_slot
    mov %ecx, %eax
    imul $80, %esi, %edx
    imul %edx, %eax
    add card_y, %eax
    imul $58, %esi, %edx
    add %edx, %eax
    mov %eax, pb_y
    mov card_x, %eax
    imul $32, %esi, %edx
    add %edx, %eax
    mov %eax, pb_x
    mov card_w, %ecx
    imul $42, %esi, %edx
    sub %edx, %ecx
    mov %ecx, pb_w
    mov pb_y, %ebx
    lea (,%esi,4), %edx
    lea (%esi,%esi), %ebp
    push %esi
    mov $C_BORDER, %esi
    call gfx_rrect
    pop %esi
    mov pb_slot, %edi
    cmpb $1, agents_tbl+2(,%edi,8)
    jne pb_done
    movzbl agents_tbl+6(,%edi,8), %eax
    cmp $100, %eax
    jae pb_indet
    imul pb_w, %eax
    xor %edx, %edx
    mov $100, %ecx
    div %ecx
    mov %eax, %ecx
    mov pb_x, %eax
    jmp pb_fill
pb_indet:
    mov pb_w, %ecx
    shr $2, %ecx                 # segment = w/4, travels over span = w - seg
    mov pb_w, %edi
    sub %ecx, %edi
    mov ticks, %eax
    shl $2, %eax
    xor %edx, %edx
    push %ecx
    lea (%edi,%edi), %ecx
    div %ecx
    pop %ecx
    mov %edx, %eax               # 0 .. 2*span: bounce
    cmp %edi, %eax
    jbe pb_pos
    lea (%edi,%edi), %edx
    sub %eax, %edx
    mov %edx, %eax
pb_pos:
    add pb_x, %eax
pb_fill:
    test %ecx, %ecx
    jz pb_done
    mov pb_y, %ebx
    lea (,%esi,4), %edx
    lea (%esi,%esi), %ebp
    mov $C_ACCENT, %esi
    call gfx_rrect
pb_done:
    popal
    ret

pn_empty:                        # ECX = empty-slot index (0 | 1)
    pushal
    mov ui_s, %esi
    mov %ecx, %eax
    imul $44, %esi, %edx
    imul %edx, %eax
    add pn_ey, %eax
    mov %eax, %ebx
    mov %ecx, %ebp
    mov $pn_buf, %edi
    push %esi
    mov $pn_s_empty, %esi
    call bputs
    pop %esi
    lea 0x31(%ebp), %eax
    stosb
    movb $0, (%edi)
    mov card_x, %eax
    mov card_w, %ecx
    imul $36, %esi, %edx
    push %esi
    mov $C_SURFACE, %esi
    mov $C_BORDER, %edi
    mov ui_s, %ebp
    lea (%ebp,%ebp,2), %ebp
    add %ebp, %ebp
    call gfx_rrect_b
    pop %esi
    imul $16, %esi, %edx
    add %edx, %eax
    imul $18, %esi, %edx
    sub $8, %edx
    add %edx, %ebx
    mov $C_MUTED, %ecx
    mov $1, %edx
    mov $-1, %ebp
    mov $pn_buf, %esi
    call ui_puts
    popal
    ret

pn_more:                         # "+ N hidden agents" | "+ N more free slots"
    pushal
    mov ui_s, %esi
    mov card_x, %eax
    mov pn_my, %ebx
    mov card_w, %ecx
    imul $24, %esi, %edx
    push %esi
    mov $C_SURFACE, %esi
    call gfx_fillrect
    pop %esi
    mov $pn_buf, %edi
    movb $0x2b, (%edi)           # "+ "
    movb $0x20, 1(%edi)
    add $2, %edi
    mov pn_active, %eax
    sub pn_ncards, %eax
    mov $pn_s_hidden, %edx
    jnz pm_txt
    mov $8, %eax
    sub pn_active, %eax
    sub pn_nempty, %eax
    mov $pn_s_free, %edx
    jz pmr_done
pm_txt:
    call bdec32
    mov %edx, %esi
    call bputs
    movb $0, (%edi)
    mov ui_s, %esi
    lea (,%esi,4), %eax
    add card_x, %eax
    lea (,%esi,4), %ebx
    add pn_my, %ebx
    mov $C_MUTED, %ecx
    mov $1, %edx
    mov $-1, %ebp
    mov $pn_buf, %esi
    call ui_puts
pmr_done:
    popal
    ret

# pn_spawn: the "Spawn agent" button (ACCENT outline on ACCENT_BG) or,
#   while pn_choose = 1, four type chips in its place.
pn_spawn:
    pushal
    mov ui_s, %esi
    mov card_x, %eax
    mov pn_sy, %ebx
    mov card_w, %ecx
    imul $32, %esi, %edx
    cmpb $0, pn_choose
    jne ps_choose
    push %esi
    mov $C_ACCENT_BG, %esi
    mov $C_ACCENT, %edi
    mov ui_s, %ebp
    lea (%ebp,%ebp,2), %ebp
    add %ebp, %ebp
    call gfx_rrect_b
    pop %esi
    mov card_w, %eax             # label centred, scale u, ACCENT2
    imul $88, %esi, %edx         # 11 chars * 8u
    sub %edx, %eax
    shr $1, %eax
    add card_x, %eax
    lea (,%esi,8), %ebx
    add pn_sy, %ebx
    mov $C_ACCENT2, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    mov $pn_s_spawn, %esi
    call ui_puts
    jmp ps_done
ps_choose:
    push %esi
    mov $C_SURFACE, %esi
    call gfx_fillrect
    pop %esi
    xor %ebx, %ebx
ps_chip:
    push %ebx
    call pn_chip_rect            # -> ECX x, EDX y, ESI w, EDI h
    mov %ecx, %eax
    mov %edx, %ebx
    mov %esi, %ecx
    mov %edi, %edx
    mov %ecx, ps_cw
    mov $C_SURFACE3, %esi
    mov $C_BORDER2, %edi
    mov ui_s, %ebp
    lea (%ebp,%ebp,2), %ebp
    add %ebp, %ebp
    call gfx_rrect_b
    mov (%esp), %ebx
    movzbl pn_choice(%ebx), %edi
    mov type_names(,%edi,4), %edi
    call pn_strlen
    mov ui_s, %esi
    imul %esi, %ecx
    shl $3, %ecx                 # text width
    mov ps_cw, %edx
    sub %ecx, %edx
    shr $1, %edx
    add %edx, %eax
    lea (,%esi,8), %ebx
    add pn_sy, %ebx
    mov $C_TEXT, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    mov %edi, %esi
    call ui_puts
    pop %ebx
    inc %ebx
    cmp $4, %ebx
    jb ps_chip
ps_done:
    popal
    ret

pn_chip_rect:                    # EBX = chip 0..3 -> ECX x, EDX y, ESI w, EDI h
    push %eax
    mov ui_s, %edi
    mov card_w, %eax
    imul $18, %edi, %esi
    sub %esi, %eax
    shr $2, %eax                 # w = (card_w - 18u) / 4
    mov %eax, %esi
    imul $6, %edi, %ecx
    add %eax, %ecx
    imul %ebx, %ecx
    add card_x, %ecx
    mov pn_sy, %edx
    shl $5, %edi                 # h = 32u
    pop %eax
    ret

# pn_recent: "RECENT TASKS" + the newest used tasks (highest index first).
pn_recent:
    pushal
    mov ui_s, %esi
    mov card_x, %eax
    mov pn_ry, %ebx
    mov card_w, %ecx
    mov pn_rows, %edx
    inc %edx
    imul $20, %esi, %edi
    imul %edi, %edx
    push %esi
    mov $C_SURFACE, %esi
    call gfx_fillrect
    pop %esi
    lea (,%esi,4), %eax
    add card_x, %eax
    imul $10, %esi, %ebx
    sub $8, %ebx
    add pn_ry, %ebx
    mov $C_MUTED, %ecx
    push %esi
    mov $pn_s_recent, %esi
    call pn_puts_sp
    pop %esi
    imul $20, %esi, %ebx
    add pn_ry, %ebx              # EBX = row y
    mov pn_rows, %ebp            # rows left
    mov $7, %ecx                 # task index, newest (highest) first
    xor %edx, %edx               # rows drawn
prc_l:
    mov %ecx, %edi
    shl $4, %edi
    add $tasks_tbl, %edi
    cmpb $0, (%edi)
    je prc_n
    call pn_row
    imul $20, %esi, %eax
    add %eax, %ebx
    inc %edx
    dec %ebp
    jz prc_d
prc_n:
    dec %ecx
    jns prc_l
    test %edx, %edx
    jnz prc_d
    lea (,%esi,4), %eax          # nothing yet
    add card_x, %eax
    lea (%esi,%esi), %edx
    add %edx, %ebx
    mov $C_MUTED, %ecx
    mov $1, %edx
    mov $-1, %ebp
    mov $pn_s_none, %esi
    call ui_puts
prc_d:
    popal
    ret

# pn_row: EDI = task entry, EBX = row y. Dot (status colour), "<type>
#   <args>" (TEXT2, truncated to the width), result right-aligned.
pn_row:
    pushal
    mov %edi, %ebp
    mov %ebx, pr_y
    mov $pn_buf2, %edi
    movzbl 2(%ebp), %eax
    cmp $2, %eax
    je prw_done
    cmp $1, %eax
    je prw_run
    mov $C_MUTED, %ecx
    mov $pn_s_wait, %esi
    test %eax, %eax
    jz prw_s
    mov $C_ERR, %ecx
    mov $pn_s_err, %esi
    cmp $3, %eax
    je prw_s
    mov $C_WARN, %ecx
    mov $pn_s_dep, %esi
prw_s:
    call bputs
    jmp prw_r
prw_done:
    mov $C_OK, %ecx
    mov 12(%ebp), %eax
    call bdec32
    jmp prw_r
prw_run:
    mov $C_ACCENT, %ecx
    movzbl 3(%ebp), %eax
    and $7, %eax
    movzbl agents_tbl+6(,%eax,8), %eax
    call bdec32
    movb $0x25, (%edi)
    inc %edi
prw_r:
    movb $0, (%edi)
    mov %ecx, pr_col
    mov $pn_buf, %edi            # command text
    movzbl 1(%ebp), %eax
    mov type_names(,%eax,4), %esi
    call bputs
    mov 1(%ebp), %al
    cmp $7, %al
    je prw_ce                    # fault: no args
    movb $0x20, (%edi)
    inc %edi
    cmp $0, %al
    je prw_math
    cmp $1, %al
    je prw_scan
    cmp $6, %al
    je prw_gcd
    mov 4(%ebp), %eax            # count / prime: n
    call bdec32
    jmp prw_ce
prw_scan:
    movb $0x40, (%edi)
    inc %edi
    mov 4(%ebp), %eax
    call bhex32
    jmp prw_ce
prw_math:
    movzwl 4(%ebp), %eax
    call bdec32
    movb $0x20, (%edi)
    mov 8(%ebp), %al
    mov %al, 1(%edi)
    movb $0x20, 2(%edi)
    add $3, %edi
    jmp prw_b
prw_gcd:
    movzwl 4(%ebp), %eax
    call bdec32
    movb $0x20, (%edi)
    inc %edi
prw_b:
    movzwl 6(%ebp), %eax
    call bdec32
prw_ce:
    movb $0, (%edi)
    mov ui_s, %esi
    mov $pn_buf2, %edi
    call pn_strlen
    mov %ecx, pr_rl              # result length (chars)
    mov card_w, %eax             # max command chars = (w - 32u) / 8u - rl
    mov %esi, %ecx
    shl $5, %ecx
    sub %ecx, %eax
    xor %edx, %edx
    lea (,%esi,8), %ecx
    div %ecx
    sub pr_rl, %eax
    mov $pn_buf, %edi
    call pn_strlen
    cmp %eax, %ecx
    jbe prw_fit
    movb $0, pn_buf(%eax)
prw_fit:
    imul $6, %esi, %eax          # dot
    add card_x, %eax
    imul $7, %esi, %ebx
    add pr_y, %ebx
    imul $6, %esi, %ecx
    mov %ecx, %edx
    lea (%esi,%esi,2), %ebp
    push %esi
    mov pr_col, %esi
    call gfx_rrect
    pop %esi
    imul $20, %esi, %eax         # command
    add card_x, %eax
    lea (%esi,%esi), %ebx
    add pr_y, %ebx
    mov $C_TEXT2, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    push %esi
    mov $pn_buf, %esi
    call ui_puts
    pop %esi
    mov pr_rl, %eax              # result, right-aligned
    imul %esi, %eax
    shl $3, %eax
    neg %eax
    add card_x, %eax
    add card_w, %eax
    lea (,%esi,4), %ecx
    sub %ecx, %eax
    mov pr_col, %ecx
    cmpl $C_OK, %ecx
    jne prw_rc
    mov $C_TEXT, %ecx
prw_rc:
    mov %esi, %edx
    mov $pn_buf2, %esi
    call ui_puts
    popal
    ret

# pn_footer: separator, small fir, "Tannenbaum Media", version/RAM/uptime.
pn_footer:
    pushal
    mov ui_s, %esi
    mov card_x, %eax
    mov pn_fy, %ebx
    lea (,%esi,8), %edx
    sub %edx, %ebx
    mov card_w, %ecx
    mov $1, %edx
    push %esi
    mov $C_BORDER, %esi
    call gfx_fillrect
    pop %esi
    lea 1(%esi), %ebp            # fir scale = u + 1 (24 | 36 px)
    lea (,%esi,4), %eax
    add card_x, %eax
    imul $40, %esi, %ebx
    lea (%ebp,%ebp,2), %edx
    shl $2, %edx                 # 12 * scale
    sub %edx, %ebx
    shr $1, %ebx
    add pn_fy, %ebx
    add %edx, %eax
    lea (,%esi,8), %ecx
    add %ecx, %eax
    mov %eax, pn_tx              # text x after the fir
    sub %ecx, %eax
    sub %edx, %eax
    mov $icon_fir, %edi
    mov $C_BRAND_MID, %esi
    call gfx_mask12
    mov ui_s, %esi
    mov pn_tx, %eax
    lea (,%esi,4), %ebx
    add pn_fy, %ebx
    mov $C_TEXT2, %ecx
    mov $1, %edx
    mov $-1, %ebp
    mov $pn_s_tbm, %esi
    call ui_puts
    call pn_uptime
    popal
    ret

pn_uptime:                       # "v2.87  127 MB  up 7s  " (opaque, 1x)
    pushal
    mov $pn_buf, %edi
    mov $pn_s_ver, %esi
    call bputs
    mov (E820_TOTAL), %eax
    shr $20, %eax
    call bdec32
    mov $pn_s_mb, %esi
    call bputs
    mov ticks, %eax
    xor %edx, %edx
    mov $18, %ecx
    div %ecx
    mov $0x73, %bl               # 's'
    cmp $100, %eax
    jb pu_u
    xor %edx, %edx
    mov $60, %ecx
    div %ecx
    mov $0x6d, %bl               # 'm'
    cmp $100, %eax
    jb pu_u
    xor %edx, %edx
    div %ecx
    mov $0x68, %bl               # 'h'
pu_u:
    call bdec32
    mov %bl, (%edi)
    movw $0x2020, 1(%edi)
    movb $0, 3(%edi)
    mov pn_tx, %eax
    mov ui_s, %ebx
    shl $2, %ebx
    add pn_fy, %ebx
    add $18, %ebx
    mov $C_MUTED, %ecx
    mov $1, %edx
    mov $C_SURFACE, %ebp
    mov $pn_buf, %esi
    call ui_puts
    popal
    ret

# panel_handle_click: EAX = 1 when the click was inside the panel (and
#   handled), 0 otherwise. Call it from gui_handle_click right after
#   menu_handle_click. An open chooser closes on any click.
panel_handle_click:
    pushal
    movl $0, 28(%esp)
    cmpb $0, desk_active
    je phc_ret
    movb $1, pn_busy
    mov panel_x, %ecx
    mov panel_y, %edx
    mov panel_w, %esi
    mov panel_h, %edi
    call hit_rect
    test %eax, %eax
    jnz phc_in
    cmpb $0, pn_choose           # outside: just close the chooser
    je phc_done
    call pn_close
    jmp phc_done
phc_in:
    movl $1, 28(%esp)
    cmpb $0, pn_choose
    je phc_nc
    xor %ebx, %ebx
phc_chip:
    call pn_chip_rect
    call hit_rect
    test %eax, %eax
    jnz phc_pick
    inc %ebx
    cmp $4, %ebx
    jb phc_chip
    call pn_close
    jmp phc_done
phc_pick:
    call pn_close
    mov $pn_s_spawncmd, %esi
    call gui_push_str
    movzbl pn_choice(%ebx), %eax
    mov type_names(,%eax,4), %esi
    call gui_inject              # "spawn <type>" + Enter
    jmp phc_done
phc_nc:
    mov card_x, %ecx
    mov card_w, %esi
    mov pn_sy, %edx              # Spawn button
    mov ui_s, %edi
    shl $5, %edi
    call hit_rect
    test %eax, %eax
    jnz phc_open
    mov pn_ey, %edx              # empty-slot cards -> chooser too
    mov pn_my, %edi
    sub %edx, %edi
    call hit_rect
    test %eax, %eax
    jnz phc_open
    mov card_y, %edx             # agent cards -> task table
    mov pn_ey, %edi
    sub %edx, %edi
    call hit_rect
    test %eax, %eax
    jz phc_hdr
    mov $pn_s_tasks, %esi
    jmp phc_inj
phc_hdr:
    mov panel_y, %edx            # header -> agent roster
    mov card_y, %edi
    sub %edx, %edi
    call hit_rect
    test %eax, %eax
    jz phc_done
    mov $pn_s_agents, %esi
phc_inj:
    call gui_inject
    jmp phc_done
phc_open:
    movb $1, pn_choose
    call pn_spawn
phc_done:
    movb $0, pn_busy
phc_ret:
    popal
    ret
pn_close:
    movb $0, pn_choose
    call pn_spawn
    ret

pn_strlen:                       # EDI = asciz -> ECX = length (EDI kept)
    push %edi
    push %eax
    xor %eax, %eax
    xor %ecx, %ecx
    dec %ecx
    repne scasb
    not %ecx
    dec %ecx
    pop %eax
    pop %edi
    ret

pn_puts_sp:                      # spaced 1x label: ESI str, EAX x, EBX y, ECX fg
    pushal
    mov %eax, gtx_x
    mov %ebx, gtx_y
    mov %ecx, gtx_fg
    movl $1, gtx_scale
    movl $10, gtx_adv
    movb $1, gtx_tr
    call gfx_puts
    popal
    ret

# --- agents panel data (WP4) ---------------------------------------
.equ C_BRAND_MID, 0x4F9E9B       # the small fir in the footer
pn_cache:   .fill 64, 1, 0xff    # agents_tbl as last drawn (0xff = never)
pn_tcache:  .fill 128, 1, 0xff   # tasks_tbl as last drawn
pn_active:  .long 0              # used slots
pn_ncards:  .long 0              # visible agent cards
pn_nempty:  .long 0              # empty-slot cards shown (0..2)
pn_rows:    .long 0              # RECENT rows (3..5)
pn_ey:      .long 0              # y: first empty card
pn_my:      .long 0              #    "+ N more" line
pn_sy:      .long 0              #    Spawn button / chooser
pn_ry:      .long 0              #    RECENT TASKS header
pn_fy:      .long 0              #    footer
pn_tx:      .long 0              # footer text x
pn_slots:   .fill 8, 1, 0        # visible card index -> agent slot
pn_choose:  .byte 0              # 1 = type chooser shown instead of the button
pn_busy:    .byte 0              # 1 = a paint is in progress (tick skips)
pn_choice:  .byte 0, 3, 2, 6     # chooser chips: math prime count gcd
pc_slot:    .long 0              # pn_card temps
pc_y:       .long 0
pc_ty:      .long 0
pc_cx:      .long 0
pc_cy:      .long 0
pcd_col:     .long 0
pc_lbl:     .long 0
pc_typ:     .long 0
pb_slot:    .long 0              # pn_bar temps
pb_x:       .long 0
pb_y:       .long 0
pb_w:       .long 0
ps_cw:      .long 0              # chooser chip width
pr_y:       .long 0              # pn_row temps
pr_col:     .long 0
pr_rl:      .long 0
pn_buf:     .fill 48, 1, 0       # own scratch (gtx_buf belongs to the shell path)
pn_buf2:    .fill 16, 1, 0
pn_save:    .fill 256, 1, 0      # gfx_state_save area (scratch block + pen)
pn_s_of:    .asciz " of 8 slots "
pn_s_work:  .asciz "WORKING"
pn_s_dn:    .asciz "DONE"
pn_s_idle:  .asciz "IDLE"
pn_s_slot:  .asciz "slot "
pn_s_meta:  .asciz "  ring 3  stack 4 KB"
pn_s_done:  .asciz " done"
pn_s_empty: .asciz "empty slot "
pn_s_hidden:.asciz " hidden agents"
pn_s_free:  .asciz " more free slots"
pn_s_spawn: .asciz "Spawn agent"
pn_s_recent:.asciz "RECENT TASKS"
pn_s_none:  .asciz "no tasks yet"
pn_s_wait:  .asciz "wait"
pn_s_err:   .asciz "error"
pn_s_dep:   .asciz "dep"
pn_s_tbm:   .asciz "Tannenbaum Media"
pn_s_ver:   .asciz "v2.87  "
pn_s_mb:    .asciz " MB  up "
pn_s_spawncmd: .asciz "spawn "
pn_s_tasks: .asciz "tasks"
pn_s_agents:.asciz "agents"


# =====================================================================
#  MENU BAR (WP2): the dropdowns under the five titles, the power button's
#  "Reboot?" confirm popover, hover states (titles, rows, title-bar chips,
#  power button) and the click dispatch (menu_handle_click, first stop of
#  gui_handle_click). A dropdown is painted over whatever is there
#  (wallpaper, terminal title bar, console, agents panel): the pixels
#  underneath are copied to DD_SAVE first (dd_save) and put back on close
#  (dd_restore); the console part is then repainted from CONSOLE_SHADOW
#  (con_repaint_rect) only if its checksum changed while the menu was open
#  (text that arrived underneath), otherwise the restored pixels are exact.
#  Look (SPEC 4.4/4.5, concept C): gfx_shadow + SURFACE panel, BORDER2
#  frame, r = 8u; rows 18u high
#  with the command at scale u (TEXT2) and a 1x description right-aligned
#  (MUTED, u = 2 only); group headers 20 | 24 px, 1x MUTED letter-spaced
#  (gtx_adv 10). Hover row = SURFACE2 rounded row + 2u ACCENT bar + TEXT.
#  Title: open = ACCENT_BG pill + ACCENT2 text, hover = SURFACE3 + TEXT.
#  Chips / power: hover = BORDER2 frame + TEXT, open = ACCENT_BG + ACCENT2.
#  State: menu_open (!= 0 while a dropdown is up - WP4's desktop_tick skips
#  the panel refresh then), menu_cur (0..4 title, MENU_PWR, 0xff none), menu_hov_t (what the
#  mouse is over: title, HT_PWR, HT_HELP, HT_CLEAR, 0xff), menu_hov_r (row
#  of the open dropdown, 0xff). Hover comes from desk_hover (kgetch idle
#  loop), Esc / any key closes (menu_key from kgetch), the status row
#  repaint pauses while a dropdown is open (draw_status gate).
#  Row = 3 words: label, description, command - string offsets from mstr0
#  (desc 0 = none; command 0 = group header, < 16 = an MA_* action).
# =====================================================================
.equ MENU_PWR,   5               # pseudo menu: the power button's confirm
.equ HT_PWR,     5               # hover targets beyond the titles 0..4
.equ HT_HELP,    6
.equ HT_CLEAR,   7
.equ MA_REBOOT,   1              # row actions (command field < 16)
.equ MA_WISH,     2              #   open the confirm / focus the wish field /
.equ MA_DOREBOOT, 3              #   reboot now / just close
.equ MA_CLOSE,    4
.equ DD_SAVE, 0x1400000          # save-under buffer, 20 MB..22 MB: above the
                                 #   2-18 MB RAM test and the PXE stash (19 MB),
                                 #   below the ring-3 stacks (30 MB)

# menu_handle_click: dispatch a latched click (click_x/click_y). Returns
#   EAX = 1 consumed, 0 = fall through (chips / wish field). With a dropdown
#   open: row -> close + run; the open title / power button -> close; another
#   title or the power button -> switch; inside the panel -> eat; outside ->
#   close and fall through. Closed: a title / the power button opens.
menu_handle_click:
    pushal
    movl $0, mhc_res
    mov click_x, %ecx
    mov click_y, %edx
    call desk_hit_at             # EAX = target (title / HT_* / 0xff)
    cmpb $0xff, menu_cur
    je mhc_closed
    mov %eax, %ebx               # EBX = target
    call menu_row_at             # EAX = row or -1
    test %eax, %eax
    js mhc_norow
    call menu_row_pos            # EBX = row record
    mov %ebx, %esi
    call menu_close
    call menu_row_run            # ESI = row -> inject / action
    jmp mhc_eat
mhc_norow:
    call dd_contains             # a click on the panel (header / padding)
    test %eax, %eax
    jnz mhc_eat
    movzbl menu_cur, %eax
    cmp %eax, %ebx               # the open title (or power button) again
    je mhc_close_eat
    cmp $MENU_PWR, %ebx          # another title / the power button -> switch
    ja mhc_close_fall
    call menu_close
    mov %ebx, %eax
    call menu_open_idx
    jmp mhc_eat
mhc_close_fall:                  # outside: close, let chips / wish see it
    call menu_close
    jmp mhc_done
mhc_close_eat:
    call menu_close
    jmp mhc_eat
mhc_closed:
    cmp $MENU_PWR, %eax          # title or power button -> open its dropdown
    ja mhc_done
    call menu_open_idx
mhc_eat:
    movl $1, mhc_res
mhc_done:
    popal
    mov mhc_res, %eax
    ret

# menu_row_run: ESI = row record -> inject its command string
#   or run the MA_* action. The dropdown is already closed.
menu_row_run:
    push %esi
    push %eax
    movzwl 4(%esi), %esi
    cmp $16, %esi
    jb mrr_act
    add $mstr0, %esi
    jmp mrr_inject
mrr_act:
    cmp $MA_REBOOT, %esi
    jne mrr_2
    mov $MENU_PWR, %eax
    call menu_open_idx
    jmp mrr_ret
mrr_2:
    cmp $MA_WISH, %esi
    jne mrr_3
    call wish_edit
    jmp mrr_ret
mrr_3:
    cmp $MA_DOREBOOT, %esi
    jne mrr_ret
    mov $bc_reboot, %esi
mrr_inject:
    call gui_inject
mrr_ret:
    pop %eax
    pop %esi
    ret

# menu_key: AX = key from kgetch while a dropdown is open -> close it.
#   Esc is swallowed (EAX = 0), every other key passes through unchanged.
menu_key:
    cmpb $0xff, menu_cur
    je mk_ret
    push %eax
    call menu_close
    pop %eax
    cmp $0x1b, %al
    jne mk_ret
    xor %eax, %eax
mk_ret:
    ret

# desk_hit_at: ECX = x, EDX = y -> EAX = title 0..4 (full bar height),
#   HT_PWR, HT_HELP, HT_CLEAR or 0xff. Other registers preserved.
desk_hit_at:
    push %ebx
    push %esi
    mov $0xff, %eax
    cmp top_h, %edx
    jae dha_body
    xor %ebx, %ebx
dha_t:
    mov %ecx, %esi
    sub menu_x(,%ebx,4), %esi
    js dha_tn
    cmp menu_w(,%ebx,4), %esi
    jae dha_tn
    mov %ebx, %eax
    jmp dha_done
dha_tn:
    inc %ebx
    cmp $MENU_N, %ebx
    jb dha_t
    mov %ecx, %esi               # power button (full bar height)
    sub pwr_x, %esi
    js dha_done
    cmp pwr_s, %esi
    jae dha_done
    mov $HT_PWR, %eax
    jmp dha_done
dha_body:
    mov %edx, %esi               # title-bar chips help / clear
    sub chip_y, %esi
    js dha_done
    cmp chip_h, %esi
    jae dha_done
    mov %ecx, %esi
    sub chip_help_x, %esi
    js dha_c2
    cmp chip_help_w, %esi
    jae dha_c2
    mov $HT_HELP, %eax
    jmp dha_done
dha_c2:
    mov %ecx, %esi
    sub chip_clear_x, %esi
    js dha_done
    cmp chip_clear_w, %esi
    jae dha_done
    mov $HT_CLEAR, %eax
dha_done:
    pop %esi
    pop %ebx
    ret

# dd_contains: ECX = x, EDX = y -> EAX = 1 if inside the open dropdown's
#   panel rect (dd_x/y/w/h), else 0.
dd_contains:
    push %esi
    mov %ecx, %esi
    sub dd_x, %esi
    js ddc_no
    cmp dd_w, %esi
    jae ddc_no
    mov %edx, %esi
    sub dd_y, %esi
    js ddc_no
    cmp dd_h, %esi
    jae ddc_no
    mov $1, %eax
    pop %esi
    ret
ddc_no:
    xor %eax, %eax
    pop %esi
    ret

# menu_row_h: EBX = row record -> EDX = its height (header 20 | 24 px,
#   command row 18u).
menu_row_h:
    cmpw $0, 4(%ebx)
    jne mrh_row
    mov $20, %edx
    cmpl $2, ui_s
    jb mrh_ret
    mov $24, %edx
    ret
mrh_row:
    imul $18, ui_s, %edx
mrh_ret:
    ret

# menu_row_pos: EAX = row index of the open dropdown -> EBX = row record,
#   ECX = row y, EDX = row height. Rows start at dd_y + 8u.
menu_row_pos:
    push %esi
    push %edi
    movzbl menu_cur, %edi
    mov menu_tbl(,%edi,4), %ebx
    mov ui_s, %edx
    mov dd_y, %ecx
    lea (%ecx,%edx,8), %ecx
    mov %eax, %esi
mrp_l:
    call menu_row_h
    test %esi, %esi
    jz mrp_done
    add %edx, %ecx
    add $6, %ebx
    dec %esi
    jmp mrp_l
mrp_done:
    pop %edi
    pop %esi
    ret

# menu_row_at: ECX = x, EDX = y -> EAX = index of the command row under
#   that point in the open dropdown, -1 for none / a header. Preserves the
#   other registers.
menu_row_at:
    pushal
    movl $-1, mra_res
    imul $6, ui_s, %esi          # rows span x + 6u .. x + w - 6u
    mov %ecx, %eax
    sub dd_x, %eax
    sub %esi, %eax
    js mra_done
    mov dd_w, %ebx
    sub %esi, %ebx
    sub %esi, %ebx
    cmp %ebx, %eax
    jae mra_done
    mov %edx, %edi               # EDI = y
    xor %eax, %eax
    movzbl menu_cur, %ebx
    movzbl menu_cnt(%ebx), %ebp
mra_l:
    cmp %ebp, %eax
    jae mra_done
    push %eax
    call menu_row_pos            # EBX record, ECX y, EDX h
    pop %eax
    mov %edi, %esi
    sub %ecx, %esi
    js mra_done                  # above this row (rows are sorted) -> none
    cmp %edx, %esi
    jae mra_n
    cmpw $0, 4(%ebx)             # headers don't hit
    je mra_done
    mov %eax, mra_res
    jmp mra_done
mra_n:
    inc %eax
    jmp mra_l
mra_done:
    popal
    mov mra_res, %eax
    ret

# menu_geom: EAX = menu index -> dd_x/dd_y/dd_w/dd_h (panel) and
#   dd_sx/sy/sw/sh (panel + shadow + 1 px guard).
#   Width from menu_wd (u = 1 | 2 column), y = top_h + 4u, x under the
#   title (right-aligned under the power button for MENU_PWR), kept on
#   screen. Height = 16u + the rows.
menu_geom:
    pushal
    mov %eax, %edi
    mov ui_s, %esi
    movzwl menu_wd(,%edi,4), %ecx
    cmp $2, %esi
    jb mg_w
    movzwl menu_wd+2(,%edi,4), %ecx
mg_w:
    mov %ecx, dd_w
    mov top_h, %eax
    lea (%eax,%esi,4), %eax
    mov %eax, dd_y
    cmp $MENU_PWR, %edi
    jne mg_title
    mov pwr_x, %eax
    add pwr_s, %eax
    sub %ecx, %eax
    jmp mg_x
mg_title:
    mov menu_x(,%edi,4), %eax
mg_x:
    mov fb_w, %ebx
    sub %ecx, %ebx
    sub $8, %ebx
    cmp %ebx, %eax
    jle mg_x2
    mov %ebx, %eax
mg_x2:
    cmp $2, %eax
    jge mg_x3
    mov $2, %eax
mg_x3:
    mov %eax, dd_x
    imul $16, %esi, %eax         # height: 16u padding + rows
    mov menu_tbl(,%edi,4), %ebx
    movzbl menu_cnt(%edi), %ecx
mg_h:
    call menu_row_h
    add %edx, %eax
    add $6, %ebx
    loop mg_h
    mov %eax, dd_h
    mov dd_x, %eax               # save-under rect: shadow is +6 right, +8 down
    dec %eax
    mov %eax, dd_sx
    mov dd_y, %eax
    dec %eax
    mov %eax, dd_sy
    mov dd_w, %eax
    add $8, %eax
    mov %eax, dd_sw
    mov dd_h, %eax
    add $10, %eax
    mov %eax, dd_sh              # (x is clamped above; tallest dropdown 348 |
    popal                        #   638 px, every fitting mode is >= 768 high)
    ret

# dd_save / dd_restore: copy the dd_s* screen rect to / from DD_SAVE.
#   Cursor must be hidden (the caller does that).
dd_save:
    pushal
    xor %ebp, %ebp               # EBP = 0 screen -> buffer, 1 buffer -> screen
    jmp ddx
dd_restore:
    pushal
    mov $1, %ebp
ddx:
    mov $DD_SAVE, %edi
    mov dd_sy, %ebx
    mov dd_sh, %edx
    test %edx, %edx
    jz ddx_done
ddx_r:
    mov %ebx, %eax
    imul fb_ppsl, %eax
    add dd_sx, %eax
    shl $2, %eax
    add fb_base, %eax
    mov %eax, %esi               # ESI = screen row, EDI = buffer
    test %ebp, %ebp
    jz ddx_go
    xchg %esi, %edi
ddx_go:
    mov dd_sw, %ecx
    rep movsl
    test %ebp, %ebp
    jz ddx_n
    mov %esi, %edi               # buffer pointer back into EDI
ddx_n:
    inc %ebx
    dec %edx
    jnz ddx_r
ddx_done:
    popal
    ret

# menu_draw_dd: paint the open dropdown (shadow, panel, every row with its
#   hover state). Cursor must be hidden.
menu_draw_dd:
    pushal
    mov dd_x, %eax
    mov dd_y, %ebx
    mov dd_w, %ecx
    mov dd_h, %edx
    mov $2, %esi                 # shadow (grow 2), then the panel
    call gfx_shadow
    mov $C_SURFACE, %esi
    mov $C_BORDER2, %edi
    mov ui_s, %ebp
    shl $3, %ebp                 # r = 8u
    call gfx_rrect_b
    xor %eax, %eax
    movzbl menu_cur, %ebx
    movzbl menu_cnt(%ebx), %edi
mdd_l:
    cmp %edi, %eax
    jae mdd_done
    xor %ebx, %ebx
    cmp %al, menu_hov_r
    jne mdd_n
    inc %ebx
mdd_n:
    call menu_draw_row
    inc %eax
    jmp mdd_l
mdd_done:
    popal
    ret

# menu_draw_row: EAX = row index, EBX = 1 hover / 0 normal. Header rows:
#   1x MUTED, letter-spaced. Command rows: rounded row background (SURFACE
#   = erase, SURFACE2 = hover) + ACCENT bar, label at scale u, 1x
#   description right-aligned when u = 2.
menu_draw_row:
    pushal
    mov %ebx, mdr_hov
    call menu_row_pos            # EBX record, ECX y, EDX h
    mov %ecx, mdr_y
    mov %edx, mdr_h
    mov %ebx, %edi               # EDI = record
    mov ui_s, %esi
    cmpw $0, 4(%edi)
    jne mdr_row
    imul $12, %esi, %eax         # header text at (x + 12u, y + (h-16)/2)
    add dd_x, %eax
    mov %eax, gtx_x
    mov %edx, %ebx
    sub $16, %ebx
    shr $1, %ebx
    add %ecx, %ebx
    mov %ebx, gtx_y
    movl $C_MUTED, gtx_fg
    movl $1, gtx_scale
    movl $10, gtx_adv
    movb $1, gtx_tr
    movzwl (%edi), %esi
    add $mstr0, %esi
    call gfx_puts
    movl $0, gtx_adv
    jmp mdr_done
mdr_row:
    imul $6, %esi, %eax
    add dd_x, %eax               # row rect (x + 6u, y, w - 12u, h)
    mov mdr_y, %ebx
    mov dd_w, %ecx
    imul $12, %esi, %edx
    sub %edx, %ecx
    mov mdr_h, %edx
    mov %esi, %ebp
    shl $2, %ebp                 # r = 4u
    mov $C_SURFACE, %esi
    cmpl $0, mdr_hov
    je mdr_bg
    mov $C_SURFACE2, %esi
mdr_bg:
    call gfx_rrect
    mov ui_s, %esi
    cmpl $0, mdr_hov
    je mdr_lbl
    imul $3, %esi, %ecx          # accent bar (x + 6u, y + 3u, 2u, h - 6u)
    add %ecx, %ebx
    sub %ecx, %edx
    sub %ecx, %edx
    lea (%esi,%esi), %ecx
    push %esi
    mov $C_ACCENT, %esi
    call gfx_fillrect
    pop %esi
mdr_lbl:
    imul $14, %esi, %eax         # label at (x + 14u, y + u), scale u
    add dd_x, %eax
    mov mdr_y, %ebx
    add %esi, %ebx
    mov $C_TEXT2, %ecx
    cmpl $0, mdr_hov
    je mdr_lc
    mov $C_TEXT, %ecx
mdr_lc:
    mov %esi, %edx
    mov $-1, %ebp
    movzwl (%edi), %esi
    add $mstr0, %esi
    call ui_puts
    mov ui_s, %esi
    cmp $2, %esi                 # description: 1x MUTED, right-aligned, u = 2
    jb mdr_done
    movzwl 2(%edi), %esi
    test %esi, %esi
    jz mdr_done
    add $mstr0, %esi
    call mn_strlen               # ECX = length
    shl $3, %ecx
    mov dd_x, %eax
    add dd_w, %eax
    sub %ecx, %eax
    mov ui_s, %ebx
    imul $12, %ebx, %ebx
    sub %ebx, %eax
    mov mdr_h, %ebx
    sub $16, %ebx
    shr $1, %ebx
    add mdr_y, %ebx
    mov $C_MUTED, %ecx
    mov $1, %edx
    mov $-1, %ebp
    call ui_puts
mdr_done:
    popal
    ret

# mn_strlen: ESI = asciz -> ECX = length. Preserves the rest.
mn_strlen:
    push %esi
    xor %ecx, %ecx
mnl_l:
    cmpb $0, (%esi)
    je mnl_d
    inc %esi
    inc %ecx
    jmp mnl_l
mnl_d:
    pop %esi
    ret

# desk_elem_state: EAX = target -> EBX = 2 open (its dropdown is up),
#   1 hover, 0 normal.
desk_elem_state:
    xor %ebx, %ebx
    cmp $MENU_PWR, %eax
    ja des_hov
    cmp %al, menu_cur
    jne des_hov
    mov $2, %ebx
    ret
des_hov:
    cmp %al, menu_hov_t
    jne des_ret
    mov $1, %ebx
des_ret:
    ret

# desk_elem_refresh: EAX = target (0xff = nothing) -> redraw it in its
#   current state (menu_cur / menu_hov_t). Cursor must be hidden.
desk_elem_refresh:
    pushal
    cmp $HT_CLEAR, %eax
    ja der_done
    call desk_elem_state         # EBX = state
    cmp $MENU_N, %eax
    jb der_title
    cmp $HT_PWR, %eax
    je der_pwr
    sub $HT_HELP, %eax           # 0 = help, 1 = clear
    call menu_chip_draw
    jmp der_done
der_pwr:
    call menu_pwr_draw
    jmp der_done
der_title:
    call menu_title_draw
der_done:
    popal
    ret

# menu_title_draw: EAX = title 0..4, EBX = state (0 normal: flat SURFACE2 +
#   TEXT2, 1 hover: SURFACE3 pill + TEXT, 2 open: ACCENT_BG pill + ACCENT2).
menu_title_draw:
    pushal
    mov %eax, %edi
    mov %ebx, mtd_st
    mov menu_x(,%edi,4), %eax
    mov menu_y, %ebx
    mov menu_w(,%edi,4), %ecx
    mov menu_h, %edx
    mov mtd_st, %esi
    test %esi, %esi
    jnz mtd_pill
    mov $C_SURFACE2, %esi
    call gfx_fillrect
    jmp mtd_text
mtd_pill:
    mov mst_pill(,%esi,4), %esi
    mov ui_s, %ebp
    shl $2, %ebp
    call gfx_rrect
mtd_text:
    mov ui_s, %esi
    imul $8, %esi, %eax
    add menu_x(,%edi,4), %eax
    mov menu_y, %ebx
    lea (%ebx,%esi,2), %ebx
    mov mtd_st, %ecx
    mov mst_text(,%ecx,4), %ecx
    mov %esi, %edx
    mov $-1, %ebp
    mov menu_lbl(,%edi,4), %esi
    call ui_puts
    popal
    ret

# menu_pwr_draw: EBX = state -> the power button (chrome + icon).
menu_pwr_draw:
    pushal
    mov mst_fill(,%ebx,4), %esi
    mov mst_bord(,%ebx,4), %edi
    mov mst_text(,%ebx,4), %edx
    mov %edx, mtd_st
    mov pwr_x, %eax
    mov pwr_y, %ebx
    mov pwr_s, %ecx
    mov pwr_s, %edx
    mov ui_s, %ebp
    shl $2, %ebp
    call gfx_rrect_b
    mov ui_s, %ebp
    imul $5, %ebp, %ebx
    add %ebx, %eax
    add pwr_y, %ebx
    mov $icon_power, %edi
    mov $8, %ecx
    mov $8, %edx
    mov mtd_st, %esi
    call gfx_mask
    popal
    ret

# menu_chip_draw: EAX = 0 help | 1 clear, EBX = state -> the title-bar chip.
#   One look for both owners: the state goes into WP3's chip_help_st /
#   chip_clear_st and WP3's term_chip_draw paints it (chip_cols), so a hover
#   and the terminal frame's own repaint can never disagree.
menu_chip_draw:
    pushal
    mov %ebx, %esi               # ESI = state for term_chip_draw
    test %eax, %eax
    jnz mcd_clear
    mov %bl, chip_help_st
    mov chip_help_x, %eax
    mov chip_help_w, %ecx
    mov $lbl_help, %edi
    jmp mcd_draw
mcd_clear:
    mov %bl, chip_clear_st
    mov chip_clear_x, %eax
    mov chip_clear_w, %ecx
    mov $lbl_clear, %edi
mcd_draw:
    call term_chip_draw
    popal
    ret

# menu_open_idx: EAX = menu index (0..4, MENU_PWR) -> open its dropdown:
#   geometry, hide the cursor, save the pixels underneath, paint it, mark
#   the title / power button open. Interrupts off while painting so the
#   timer's cursor_tick cannot bake the arrow into the save-under.
menu_open_idx:
    pushal
    pushfl
    cli
    mov %al, menu_cur
    movb $1, menu_open
    movb $0xff, menu_hov_r
    call menu_geom
    call cursor_hide
    call dd_save
    call con_shadow_sum
    mov %eax, dd_csum            # console text at open time
    call menu_draw_dd
    movzbl menu_cur, %eax
    call desk_elem_refresh
    popfl
    popal
    ret

# menu_close: put the saved pixels back, refresh the console part from
#   CONSOLE_SHADOW, title / power button back to normal. No-op if closed.
menu_close:
    cmpb $0xff, menu_cur
    je mc_ret
    pushal
    pushfl
    cli
    call cursor_hide
    call dd_restore
    movzbl menu_cur, %eax
    movb $0xff, menu_cur
    movb $0, menu_open
    movb $0xff, menu_hov_r
    movb $0xff, menu_hov_t       # re-evaluated by the next desk_hover
    call desk_elem_refresh
    call con_shadow_sum          # console unchanged while open? the restored
    cmp dd_csum, %eax            #   pixels are exact - skip the (slow) repaint
    je mc_done
    mov dd_sx, %eax              # console client rect intersect save rect
    cmp con_ox, %eax
    jge mc_x0
    mov con_ox, %eax
mc_x0:
    mov dd_sx, %ecx
    add dd_sw, %ecx
    mov con_ox, %edx
    add con_w, %edx
    cmp %edx, %ecx
    jle mc_x1
    mov %edx, %ecx
mc_x1:
    sub %eax, %ecx
    jle mc_done
    mov dd_sy, %ebx
    cmp con_oy, %ebx
    jge mc_y0
    mov con_oy, %ebx
mc_y0:
    mov dd_sy, %edx
    add dd_sh, %edx
    mov con_oy, %esi
    add con_h, %esi
    cmp %esi, %edx
    jle mc_y1
    mov %esi, %edx
mc_y1:
    sub %ebx, %edx
    jle mc_done
    call con_repaint_rect
mc_done:
    popfl
    popal
mc_ret:
    ret

# con_shadow_sum: EAX = checksum of CONSOLE_SHADOW (80x25 char+attr words),
#   so menu_close can tell whether any console text changed under a dropdown.
con_shadow_sum:
    push %ecx
    push %esi
    mov $CONSOLE_SHADOW, %esi
    mov $1000, %ecx
    xor %eax, %eax
css_l:
    rol $3, %eax
    add (%esi), %eax
    add $4, %esi
    loop css_l
    pop %esi
    pop %ecx
    ret

# desk_hover: from the kgetch idle loop (mouse present) - hover states for
#   the dropdown rows, menu titles, power button and chips, and switching
#   between dropdowns by hovering another title. Only redraws on a change.
desk_hover:
    cmpb $0, desk_active
    je dh_ret
    cmpb $0, compositor_active
    jne dh_ret
    cmpb $0, fg_prog
    jne dh_ret
    pushal
    pushfl
    cli                          # gtx_* pen state is global: no timer painting
    call wish_hover_upd          # WP3's idle wish field hover ring
    mov mouse_x, %ecx            #   (desktop_tick) in the middle of ours
    mov mouse_y, %edx
    call desk_hit_at             # EAX = target
    cmpb $0xff, menu_cur
    je dh_t
    push %eax
    call menu_row_at             # EAX = row or -1
    and $0xff, %eax
    movzbl menu_hov_r, %ebx
    cmp %eax, %ebx
    je dh_rsame
    call cursor_hide
    mov %al, menu_hov_r
    push %eax
    mov %ebx, %eax               # old row back to normal
    cmp $0xff, %eax
    je dh_rnew
    xor %ebx, %ebx
    call menu_draw_row
dh_rnew:
    pop %eax
    cmp $0xff, %eax
    je dh_rsame
    mov $1, %ebx
    call menu_draw_row
dh_rsame:
    pop %eax
    cmp $MENU_N, %eax            # hovering another title -> switch dropdowns
    jae dh_inpanel
    cmp %al, menu_cur
    je dh_done
    push %eax
    call menu_close
    pop %eax
    call menu_open_idx
    jmp dh_done
dh_inpanel:
    call dd_contains             # inside the panel: nothing else hovers
    test %eax, %eax
    jz dh_t2
    mov $0xff, %eax
    jmp dh_t
dh_t2:
    mov mouse_x, %ecx
    mov mouse_y, %edx
    call desk_hit_at
dh_t:
    cmp %al, menu_hov_t
    je dh_done
    call cursor_hide
    movzbl menu_hov_t, %ebx
    mov %al, menu_hov_t
    push %eax
    mov %ebx, %eax
    call desk_elem_refresh       # old element: normal (or open)
    pop %eax
    call desk_elem_refresh       # new element: hover
dh_done:
    popfl
    popal
dh_ret:
    ret

# wish_hover_upd: wish_hover = pointer over the wish field (and no dropdown
#   open); on a change repaint the field via wish_render. Called from
#   desk_hover with interrupts off. Preserves all registers.
wish_hover_upd:
    pushal
    xor %ebx, %ebx
    cmpb $0xff, menu_cur
    jne whu_set
    mov mouse_x, %eax
    sub wish_x, %eax
    js whu_set
    cmp wish_w, %eax
    jae whu_set
    mov mouse_y, %eax
    sub wish_y, %eax
    js whu_set
    cmp wish_h, %eax
    jae whu_set
    inc %ebx
whu_set:
    cmp %bl, wish_hover
    je whu_ret
    mov %bl, wish_hover
    call cursor_hide
    call wish_render
whu_ret:
    popal
    ret

# =====================================================================
#  WISH FIELD (WP3 owns the final look) - rect wish_x/y/w/h from desk_layout.
# =====================================================================
# wish_render: the complete field in its current state:
#   idle      BORDER ring (BORDER2 when wish_hover), sprout, MUTED placeholder
#   typing    ACCENT ring + ACCENT_BG inner glow, focus underline (hgrad
#             ACCENT -> ACCENT_DEEP), typed text TEXT, blinking caret, "n/63"
#             hint near the limit (WARN when full)
#   planted   (wish_state 2, ~2 s after Enter) "planted" + check mark in
#             accent, the wish echoed in TEXT2
#   and the ENTER chip (1x). Runs with interrupts off: the ISR's desk_refresh
#   shares the gtx_* pen. Leaves wish_tx/ty (text origin), wish_cx (caret x),
#   wish_hx/hy (ENTER chip) for the caret blinker.
wish_render:
    cmpb $0, desk_active
    je wrn_ret
    pushal
    pushfl
    cli
    pushl desk_active            # save the shared text pen (gb_epx/gtx_tr ..
    pushl gb_scale               #   gtx_adv): wish_tick renders from the timer
    pushl gb_rowskip             #   path while the main thread may be mid-text
    pushl gtx_x
    pushl gtx_y
    pushl gtx_fg
    pushl gtx_bg
    pushl gtx_scale
    pushl gtx_adv
    call cursor_hide
    mov ui_s, %esi
    mov wish_x, %eax
    mov wish_y, %ebx
    mov wish_w, %ecx
    mov wish_h, %edx
    lea (,%esi,4), %ebp          # R_SM
    cmpb $0, in_wish
    jne wrn_focus
    mov $C_BORDER, %edi
    cmpb $0, wish_hover
    je wrn_idle
    mov $C_BORDER2, %edi
wrn_idle:
    mov $C_INPUTBG, %esi
    call gfx_rrect_b
    jmp wrn_icon
wrn_focus:
    mov $C_ACCENT, %edi          # accent ring ...
    mov $C_ACCENT_BG, %esi
    call gfx_rrect_b
    add $2, %eax                 # ... with a 1 px ACCENT_BG glow inside it
    add $2, %ebx
    sub $4, %ecx
    sub $4, %edx
    sub $2, %ebp
    mov $C_INPUTBG, %esi
    call gfx_rrect
    mov ui_s, %esi
    movl $C_ACCENT, grd_c0       # focus underline
    movl $C_ACCENT_DEEP, grd_c1
    mov wish_x, %eax
    lea 1(%eax,%esi,4), %eax
    mov wish_y, %ebx
    add wish_h, %ebx
    dec %ebx
    sub %esi, %ebx
    sub %esi, %ebx
    mov wish_w, %ecx
    sub $2, %ecx
    lea (,%esi,8), %edx
    sub %edx, %ecx
    lea (%esi,%esi), %edx
    call gfx_hgrad
wrn_icon:
    mov ui_s, %esi
    imul $10, %esi, %eax         # sprout icon at x+10u, vertically centred
    add wish_x, %eax
    mov wish_h, %ebx
    imul $12, %esi, %ecx
    sub %ecx, %ebx
    shr $1, %ebx
    add wish_y, %ebx
    mov %ebx, wish_iy
    mov %esi, %ebp
    mov $icon_sprout, %edi
    mov $C_ACCENT, %esi
    call gfx_mask12
    mov ui_s, %esi
    mov wish_x, %eax             # ENTER chip rect (1x, 52x20) at x+w-10u-52
    add wish_w, %eax
    imul $10, %esi, %ecx
    sub %ecx, %eax
    sub $52, %eax
    mov %eax, wish_hx
    mov wish_h, %ebx
    sub $20, %ebx
    shr $1, %ebx
    add wish_y, %ebx
    mov %ebx, wish_hy
    imul $30, %esi, %eax         # text from x+30u, ty = y + (h-16u)/2
    add wish_x, %eax
    mov %eax, wish_tx
    mov wish_h, %ebx
    lea (,%esi,8), %ecx
    sub %ecx, %ebx
    sub %ecx, %ebx
    shr $1, %ebx
    add wish_y, %ebx
    mov %ebx, wish_ty
    mov %esi, %edx
    mov $-1, %ebp
    cmpb $2, wish_state
    je wrn_planted
    cmpb $0, in_wish
    jne wrn_typed
    cmpb $0, wish_len
    jne wrn_typed
    mov $C_MUTED, %ecx           # placeholder when empty + unfocused
    mov $dsk_wish, %esi
    call ui_puts
    jmp wrn_enter
wrn_typed:
    mov $C_TEXT, %ecx
    mov $wish_buf, %esi
    call ui_puts
    mov ui_s, %esi
    mov gtx_x, %eax              # caret 2u x 16u after the text
    lea (%eax,%esi,2), %eax
    mov %eax, wish_cx
    cmpb $0, in_wish
    je wrn_enter
    movb $1, wish_blink
    call wish_caret_draw
    cmpb $WISH_NEAR, wish_len    # "n/63" hint when the limit is near
    jb wrn_enter
    mov $gtx_buf, %edi
    movzbl wish_len, %eax
    call bdec32
    movb $0x2f, (%edi)           # '/'
    movb $0x36, 1(%edi)          # "63"
    movb $0x33, 2(%edi)
    movb $0, 3(%edi)
    mov $gtx_buf, %esi
    mov wish_hx, %eax
    sub $48, %eax                # 5 chars 1x + gap, left of the chip
    mov wish_hy, %ebx
    add $2, %ebx
    mov $C_MUTED, %ecx
    cmpb $WISH_MAX, wish_len
    jb wrn_cnt
    mov $C_WARN, %ecx            # full: no more characters accepted
wrn_cnt:
    mov $1, %edx
    mov $-1, %ebp
    call ui_puts
    jmp wrn_enter
wrn_planted:
    mov $C_ACCENT2, %ecx         # "planted" + check mark, then the wish (dim)
    mov $lbl_planted, %esi
    call ui_puts
    mov ui_s, %esi
    mov gtx_x, %eax
    lea (%eax,%esi,4), %eax
    mov wish_iy, %ebx
    mov %esi, %ebp
    mov $icon_check, %edi
    mov $C_ACCENT, %esi
    call gfx_mask12
    mov ui_s, %esi
    lea (%eax,%esi,8), %eax
    lea (%eax,%esi,8), %eax
    lea (%eax,%esi,4), %eax      # text start = check + 12u + 8u
    mov wish_hx, %ecx            # fit: at most (chip_x - 8u - start) / 8u chars
    sub %eax, %ecx
    lea (,%esi,8), %edx
    sub %edx, %ecx
    jle wrn_enter
    push %eax
    mov %ecx, %eax
    xor %edx, %edx
    lea (,%esi,8), %ecx
    div %ecx
    cmp $WISH_MAX, %eax
    jae wrn_pl_fit
    movb $0, wish_last(%eax)     # truncate the echo to the room there is
wrn_pl_fit:
    pop %eax
    mov wish_ty, %ebx
    mov $C_TEXT2, %ecx
    mov %esi, %edx
    mov $-1, %ebp
    mov $wish_last, %esi
    call ui_puts
wrn_enter:
    mov wish_hx, %eax            # ENTER chip (1x, 52x20)
    mov wish_hy, %ebx
    mov $52, %ecx
    mov $20, %edx
    mov $C_SURFACE2, %esi
    mov $C_BORDER, %edi
    mov $C_MUTED, %ebp
    cmpb $0, in_wish
    je wrn_chip
    mov $C_SURFACE3, %esi
    mov $C_BORDER2, %edi
    mov $C_TEXT2, %ebp
wrn_chip:
    push %ebp
    mov $4, %ebp
    call gfx_rrect_b
    pop %ecx
    add $6, %eax
    add $2, %ebx
    mov $1, %edx
    mov $-1, %ebp
    mov $lbl_enter, %esi
    call ui_puts
    popl gtx_adv                 # restore the text pen
    popl gtx_scale
    popl gtx_bg
    popl gtx_fg
    popl gtx_y
    popl gtx_x
    popl gb_rowskip
    popl gb_scale
    popl desk_active
    popfl
    popal
wrn_ret:
    ret

# wish_caret_draw: the caret at (wish_cx, wish_ty), 2u x 16u - ACCENT when
#   wish_blink is set, field background otherwise (the blinker toggles it).
wish_caret_draw:
    cmpb $0, desk_active
    je wcd_ret
    pushal
    mov ui_s, %esi
    mov wish_cx, %eax
    mov wish_ty, %ebx
    lea (%esi,%esi), %ecx
    lea (,%esi,8), %edx
    add %edx, %edx
    mov $C_ACCENT, %esi
    cmpb $0, wish_blink
    jne wcd_go
    mov $C_INPUTBG, %esi
wcd_go:
    call gfx_fillrect
    popal
wcd_ret:
    ret

# wish_tick: from desktop_tick (~1/s): the "planted" feedback expires.
wish_tick:
    cmpb $2, wish_state
    jne wtk_ret
    push %eax
    mov ticks, %eax
    cmp wish_until, %eax
    pop %eax
    jb wtk_ret
    movb $0, wish_state
    call wish_render
wtk_ret:
    ret

# gui_push_str: push the asciz string at ESI into the keyboard buffer (no CR),
#   so a GUI action feeds the shell exactly as if it had been typed.
gui_push_str:
    pushal
gps3_l:
    movzbl (%esi), %eax
    test %al, %al
    jz gps3_d
    push %esi
    call push_key
    pop %esi
    inc %esi
    jmp gps3_l
gps3_d:
    popal
    ret

# gui_inject: push ESI string + a CR (Enter) -> the shell runs it as a command.
gui_inject:
    call gui_push_str
    push %eax
    mov $0x0d, %eax
    call push_key
    pop %eax
    ret

# gui_handle_click: dispatch the latched click (click_x/click_y) from kgetch:
#   menu_handle_click (WP2) first, then the title-bar chips, then the wish
#   field. All rects come from desk_layout.
gui_handle_click:
    cmpb $0, desk_active
    je ghc_ret
    push %ecx
    push %edx
    push %esi
    push %edi
    call menu_handle_click
    test %eax, %eax
    jnz ghc_done
    call panel_handle_click      # WP4: agents panel (cards, Spawn chooser)
    test %eax, %eax
    jnz ghc_done
    mov chip_help_x, %ecx
    mov chip_y, %edx
    mov chip_help_w, %esi
    mov chip_h, %edi
    call hit_rect
    test %eax, %eax
    jz ghc_clear
    mov $lbl_help, %esi
    call gui_inject
    jmp ghc_done
ghc_clear:
    mov chip_clear_x, %ecx
    mov chip_clear_w, %esi
    call hit_rect
    test %eax, %eax
    jz ghc_wish
    mov $lbl_clear, %esi
    call gui_inject
    jmp ghc_done
ghc_wish:
    mov wish_x, %ecx
    mov wish_y, %edx
    mov wish_w, %esi
    mov wish_h, %edi
    call hit_rect
    test %eax, %eax
    jz ghc_done
    call wish_edit
ghc_done:
    pop %edi
    pop %esi
    pop %edx
    pop %ecx
ghc_ret:
    ret

# wish_edit: interactive wish field. Reads keys (and watches for a click that
#   leaves the field); Enter injects "netwish <text>" into the shell and shows
#   the "planted" feedback, Esc clears the field and leaves, a click outside
#   leaves (text kept). The caret blinks from the tick counter while idle. The
#   cursor keeps moving (timer ISR) the whole time.
wish_edit:
    pushal
    movb $1, in_wish
    movb $0, wish_state
    call wish_render
we_loop:
    cmpb $0, click_pending       # a click while editing?
    je we_key
    movb $0, click_pending
    mov wish_x, %ecx
    mov wish_y, %edx
    mov wish_w, %esi
    mov wish_h, %edi
    call hit_rect
    test %eax, %eax
    jz we_exit                   # clicked outside the field -> leave
    jmp we_loop
we_key:
    mov kb_tail, %al
    cmp kb_head, %al
    je we_idle
    movzbl kb_tail, %ebx
    movzwl kbuf(,%ebx,2), %eax
    mov kb_tail, %bl
    inc %bl
    and $63, %bl
    mov %bl, kb_tail
    cmp $0x0d, %al
    je we_send
    cmp $0x1b, %al               # Esc: clear + leave
    je we_clear
    cmp $0x08, %al               # Backspace
    je we_bs
    cmp $0x20, %al
    jb we_loop
    movzbl wish_len, %edx
    cmp $WISH_MAX, %edx          # full: the WARN "63/63" hint already shows
    jae we_loop
    mov %al, wish_buf(%edx)
    inc %edx
    mov %dl, wish_len
    movb $0, wish_buf(%edx)
    call wish_render
    jmp we_loop
we_bs:
    movzbl wish_len, %edx
    test %edx, %edx
    jz we_loop
    dec %edx
    mov %dl, wish_len
    movb $0, wish_buf(%edx)
    call wish_render
    jmp we_loop
we_idle:
    mov ticks, %eax              # caret blink: toggle every 8 ticks (~0.45 s)
    shr $3, %eax
    and $1, %eax
    cmp %al, wish_blink
    je we_hlt
    mov %al, wish_blink
    call wish_caret_draw
we_hlt:
    hlt
    jmp we_loop
we_send:
    cmpb $0, wish_len
    je we_exit
    mov $we_pfx, %esi            # inject "netwish <text>\r" to the shell
    call gui_push_str
    mov $wish_buf, %esi
    call gui_push_str
    push %eax
    mov $0x0d, %eax
    call push_key
    pop %eax
    mov $wish_buf, %esi          # keep a copy for the "planted" echo
    mov $wish_last, %edi
    mov $72/4, %ecx
    rep movsl
    movb $2, wish_state
    mov ticks, %eax
    add $36, %eax                # ~2 s
    mov %eax, wish_until
we_clear:
    movb $0, wish_len            # clear the field
    movb $0, wish_buf
we_exit:
    movb $0, in_wish
    call wish_render
    popal
    ret

# desktop_tick: refresh the live top-bar values (~1/s, from draw_status).
#   Gated on desk_active and !compositor_active; hides the cursor first
#   (it runs from the timer path, see SPEC section 7).
desktop_tick:
    cmpb $0, desk_active
    je dtk_ret
    pushfl                       # atomic vs. the gate: draw_status also runs on
    cli                          #   the shell thread (run/spawn/kill), and a
    cmpb $0, compositor_active   #   program that grabs the FB (KBGRAB/FGRAB)
    jne dtk_out                  #   right then must not get this paint on top
    call cursor_hide             #   of its first frame - so check + paint with
    call gfx_state_save          #   interrupts off. Timer path: keep the
    call desk_refresh            #   interrupted paint's pen/scratch intact
    call gfx_state_restore       #   (save/restore are not nested: panel_refresh
    call wish_tick               #   has its own). WP3: "planted" expiry.
    cmpb $0, menu_open           # WP2 dropdown up: it covers the panel,
    jne dtk_out                  #   skip the delta repaint until it closes
    call panel_refresh           # WP4: agent cards / recent tasks delta
dtk_out:
    popfl
dtk_ret:
    ret

# draw_clock: HH:MM:SS at (clock_x, clock_y), UI scale, opaque on the bar.
#   Reads the RTC (BCD).
draw_clock:
    cmpb $0, desk_active
    je dck_ret
    pushal
    call cmos_wait
    mov $gtx_buf, %edi
    mov $0x04, %bl               # hours
    call cmos_read
    call clk_digits
    movb $0x3a, (%edi)           # ':'
    inc %edi
    mov $0x02, %bl               # minutes
    call cmos_read
    call clk_digits
    movb $0x3a, (%edi)
    inc %edi
    mov $0x00, %bl               # seconds
    call cmos_read
    call clk_digits
    movb $0, (%edi)
    mov $gtx_buf, %esi
    mov clock_x, %eax
    mov clock_y, %ebx
    mov $C_TEXT, %ecx
    mov ui_s, %edx
    mov $C_SURFACE2, %ebp
    call ui_puts
    popal
dck_ret:
    ret
clk_digits:                      # AL=BCD byte -> two ASCII digits at (EDI)
    push %eax
    shr $4, %al
    add $0x30, %al
    mov %al, (%edi)
    inc %edi
    pop %eax
    and $0x0f, %al
    add $0x30, %al
    mov %al, (%edi)
    inc %edi
    ret

stat_stosw:                      # stosw + framebuffer mirror - the
    stosw                        # three status-line writers use this
    cmpb $0, fb_active
    je sts_ret
    push %edi
    sub $2, %edi
    call fb_cell_edi
    pop %edi
sts_ret:
    ret

# putc: print AL (CR/LF/BS understood), mirrors to COM1.
#   Atomic (pushfl/cli): multiple threads can call putc without
#   cursor updates and characters getting chopped up.
putc:
    pushfl
    cli
    cmpl $1, cpu_count           # SMP: serialise the console so an agent printing on
    jbe pc_lk1                   #   an AP doesn't interleave with the BSP. cli above
    push %eax                    #   keeps it reentrancy-safe on THIS core (IF=0).
    mov $putc_lock, %eax ; call spin_lock
    pop %eax
pc_lk1:
    cmp $0x80, %al               # CP437 graphics (logo blocks/shades) go out
    jae pc_ser8                  #   as UTF-8 so a serial terminal shows them
    call serial_putc
    jmp pc_ser_d
pc_ser8:
    call serial_cp437
pc_ser_d:
    cmpb $0, exec_cap            # EXEC chain running? mirror into its reply buf
    je pc_nocap
    call exec_capture
pc_nocap:
    pushal
    mov %al, %bl
    cmp $0x0d, %bl
    je pc_cr
    cmp $0x0a, %bl
    je pc_lf
    cmp $0x08, %bl
    je pc_bs
    call pc_pos                  # EDI = VGA address of the cursor
    mov cur_attr, %ah
    mov %bl, %al
    mov %ax, (%edi)
    mov %edi, %edx               # mirror char+attr into the readable console
    sub $0xb8000, %edx           #   shadow (0xB8000 is graphics RAM in LFB mode,
    mov %ax, CONSOLE_SHADOW(%edx) #   so the compositor reads this instead)
    call fb_cell_edi             # mirror into the UEFI framebuffer
    movl $-1, caret_pos          # (that cell held the caret - it is gone now)
    incb cur_x
    cmpb $80, cur_x
    jb pc_fin
    movb $0, cur_x
pc_lf:
    incb cur_y
    cmpb $25, cur_y
    jb pc_fin
    call scroll_up
    movb $24, cur_y
    jmp pc_fin
pc_cr:
    movb $0, cur_x
    jmp pc_fin
pc_bs:
    cmpb $0, cur_x
    je pc_fin
    decb cur_x
pc_fin:
    call move_cursor
    popal
    cmpl $1, cpu_count
    jbe pc_lk2
    push %eax
    mov $putc_lock, %eax ; call spin_unlock
    pop %eax
pc_lk2:
    popfl
    ret

# pc_pos: EDI = 0xB8000 + (cur_y*80 + cur_x)*2   (clobbers EDX)
pc_pos:
    movzbl cur_y, %edi
    imul $80, %edi, %edi
    movzbl cur_x, %edx
    add %edx, %edi
    lea 0xb8000(,%edi,2), %edi
    ret

# scroll_up: lines 2..24 up, clear line 24 (line 0 = status)
scroll_up:
    pushal
    call con_caret_hide          # lift the desktop text caret before the pixels move
    mov $0xb8000+160, %edi
    mov $0xb8000+320, %esi
    mov $1840, %ecx              # 23 lines x 80 words
    rep movsw
    mov cur_attr, %ah
    mov $0x20, %al
    mov $80, %ecx
    rep stosw
    mov $CONSOLE_SHADOW+160, %edi   # same scroll in the readable shadow
    mov $CONSOLE_SHADOW+320, %esi
    mov $1840, %ecx
    rep movsw
    mov cur_attr, %ah
    mov $0x20, %al
    mov $80, %ecx
    rep stosw
    call fb_scroll               # same motion in the framebuffer
    popal
    ret

# move_cursor: track the hardware cursor (CRTC 0x3D4/0x3D5)
move_cursor:
    pushal
    movzbl cur_y, %ebx
    imul $80, %ebx, %ebx
    movzbl cur_x, %eax
    add %eax, %ebx
    mov $0x3d4, %dx
    mov $0x0e, %al
    out %al, %dx
    inc %dx
    mov %bh, %al
    out %al, %dx
    dec %dx
    mov $0x0f, %al
    out %al, %dx
    inc %dx
    mov %bl, %al
    out %al, %dx
    call con_caret_move          # desktop: the accent block caret follows (WP3)
    popal
    ret

# exec_flush: an EXEC chain finished - broadcast the captured console
#   output on the :4711 return channel (same as STATUS/RESULTS), as
#   "AGENTOS-OUT <text>" chunks of <=200 B + a final "AGENTOS-END" so
#   net-exec.sh knows the command is done. Sent through net_udp_bcast, which
#   unicasts to the requester when a reply address is known and falls
#   back to the broadcast return channel otherwise.
exec_flush:
    pushal
    pushfl                       # atomic check-and-clear: chain-end and idle-loop
    cli                          #   can both reach here - only the first ships.
    cmpb $0, exec_cap
    je ef_skip                   #   popfl restores IF (on in shell context)
    movb $0, exec_cap
    popfl
    movzwl exec_olen, %ebp       # EBP = bytes left, EBX = read cursor
    mov $EXEC_OUT, %ebx
ef_loop:
    mov $REPLY_SCRATCH, %edi
    mov $exec_out_pfx, %esi      # "AGENTOS-OUT "
    call bputs
    mov %ebp, %ecx               # chunk = min(left, 200) - REPLY_SCRATCH is 256
    cmp $200, %ecx
    jbe ef_n
    mov $200, %ecx
ef_n:
    sub %ecx, %ebp
    jecxz ef_send
ef_cp:
    mov (%ebx), %al
    mov %al, (%edi)
    inc %ebx
    inc %edi
    dec %ecx
    jnz ef_cp
ef_send:
    mov $REPLY_SCRATCH, %esi
    mov %edi, %ecx
    sub %esi, %ecx
    call net_udp_bcast           # (unicast when a reply address is set)
    test %ebp, %ebp
    jnz ef_loop
    mov $exec_end_str, %esi      # terminator so net-exec.sh knows it's done
    mov $11, %ecx
    call net_udp_bcast
    popal
    ret
ef_skip:
    popfl
    popal
    ret

# exec_capture: putc hook while an EXEC chain runs - append AL to the
#   output buffer (drops past 1400 B; the reply says what fit).
exec_capture:
    push %ebx
    movzwl exec_olen, %ebx
    cmp $1400, %ebx
    jae ec_full
    mov %al, EXEC_OUT(%ebx)
    inc %ebx
    mov %bx, exec_olen
ec_full:
    pop %ebx
    ret

# fg_release: a foreground ring-3 game ends (quit/kill/#PF) - give the
#   keyboard back AND repaint the screen. Games paint the framebuffer
#   directly, so on real-hardware 1080p the desktop+console were left
#   trashed after every game (QEMU's serial suites can't see pixels -
#   found on the test PC). Non-game programs (llm/askd/net) never
#   set fg_prog, so their exits stay repaint-free.
fg_release:
    cmpb $0, fg_prog
    je fgr_ret
    movb $0, fg_prog
    call screen_repaint
    cmpb $0, fb_active           # the repaint cleared the console - and with it
    je fgr_ret                   #   the "tannx> " the shell printed when the
    cmpb $0, compositor_active   #   program started. A lone Enter for the idle
    jne fgr_ret                  #   shell line brings a fresh prompt back
    cmpl $0, pending_ptr         #   (not mid-chain: there the next statement
    jne fgr_ret                  #   runs anyway and owns the line)
    push %eax
    mov $0x000d, %eax
    call push_key
    pop %eax
fgr_ret:
    ret

# screen_repaint: rebuild the UI after a game trashed the framebuffer:
#   desktop chrome (desktop_init is re-runnable, guards inside) + a clean
#   console with a fresh status line (cls). The console HISTORY cannot be
#   restored: in a VBE/GOP graphics mode the 0xB8000 cells are write-only
#   mirrors - reading them back yields 0xFF garbage (the same reason the
#   old kernel snake kept a shadow at 0x19000). No-op on plain VGA text.
screen_repaint:
    cmpb $0, fb_active
    je srp_ret
    cmpb $0, compositor_active    # the compositor owns the FB - it redraws Dark
    jne srp_ret                   #   Glass when the game exits; don't flash the
    pushal                        #   old kernel desktop underneath it
    call desktop_init            # background, taskbar, panels, wish bar
    call cls                     # console client area + status line
    popal
srp_ret:
    ret

cls:
    pushal
    mov $0xb8000+160, %edi
    mov cur_attr, %ah
    mov $0x20, %al
    mov $1920, %ecx              # 24 lines x 80
    rep stosw
    mov $CONSOLE_SHADOW+160, %edi   # clear the readable shadow too
    mov cur_attr, %ah
    mov $0x20, %al
    mov $1920, %ecx
    rep stosw
    call fb_clear                # same in the framebuffer
    movb $0, cur_x
    movb $1, cur_y
    call move_cursor
    call draw_status
    popal
    ret

# puts: null-terminated string at ESI (clobbers EAX, ESI)
puts:
    lodsb
    test %al, %al
    jz puts_done
    call putc
    jmp puts
puts_done:
    ret

# logo_palette: the boot logo's teals. Colours 2 (green), 3 (cyan) and 9
#   (light blue) are otherwise unused by the OS; in VGA text mode their DAC
#   entries (2, 3 and 57 - the default attribute-controller mapping) become
#   the Tannenbaum Media teals. vga_pal carries the same values for the
#   framebuffer console. In LFB mode the DAC is irrelevant, so skip it.
logo_palette:
    cmpb $0, fb_active
    jne lpal_ret
    pushal
    mov $logo_dac, %esi
    mov $3, %ecx
lpal_l:
    mov $0x3c8, %dx              # DAC write index
    lodsb
    out %al, %dx
    inc %dx                      # 0x3C9: R, G, B (6 bit each)
    lodsb
    out %al, %dx
    lodsb
    out %al, %dx
    lodsb
    out %al, %dx
    loop lpal_l
    popal
lpal_ret:
    ret

logo_dac:                        # DAC index, R, G, B (0..63)
    .byte 2, 10, 26, 24          # #2A6B60 deep teal (tree body)
    .byte 3, 27, 49, 45          # #6FC6B4 light teal (lit rims)
    .byte 57, 11, 53, 47         # #2DD4BF aurora teal ("Forest")

# puts_attr: like puts, but the byte 0x01 is an escape - the byte after it
#   becomes cur_attr. Lets data carry per-character colours (the boot logo).
#   Leaves cur_attr at the last colour set; clobbers EAX, ESI.
puts_attr:
    lodsb
    test %al, %al
    jz pa_done
    cmp $0x01, %al
    jne pa_put
    lodsb
    mov %al, cur_attr
    jmp puts_attr
pa_put:
    call putc
    jmp puts_attr
pa_done:
    ret

# putsc: print ESI in a one-off color. AL = VGA attribute. Saves and
#   restores cur_attr, so it does not disturb the surrounding text.
putsc:
    push %ebx
    movzbl cur_attr, %ebx
    movb %al, cur_attr
    call puts
    mov %bl, cur_attr
    pop %ebx
    ret

# puts_more: like puts but pauses every 22 lines with a "-- more --"
#   prompt (any key continues, 'q' aborts) so long output (help/about)
#   does not scroll off the 24-row screen. Shell-side only.
puts_more:
    movb $0, more_cnt
pm_loop:
    lodsb
    test %al, %al
    jz pm_done
    call putc
    cmp $0x0a, %al               # line feed -> count a screen row
    jne pm_loop
    incb more_cnt
    cmpb $22, more_cnt
    jb pm_loop
    push %esi                    # --- pause ---
    mov $msg_more, %esi
    call puts
    call kgetch                  # AL = key (keyboard or serial)
    push %eax
    mov $msg_more_clr, %esi      # wipe the prompt line
    call puts
    pop %eax
    pop %esi
    cmp $0x71, %al               # 'q' aborts the rest
    je pm_done
    movb $0, more_cnt
    jmp pm_loop
pm_done:
    ret

crlf:
    push %eax
    mov $0x0d, %al
    call putc
    mov $0x0a, %al
    call putc
    pop %eax
    ret

# =====================================================================
#  Status line (line 0) - directly into VGA memory, ISR-safe
# =====================================================================
draw_status:
    pushal
    call desktop_tick            # refresh the GUI system panel (~1/s)
    cmpb $0, menu_open           # WP2: a dropdown may cover row 0 - skip it
    jne st_done
    mov $0xb8000, %edi
    mov $stat_txt1, %esi
    call vga_puts
    mov ticks, %eax
    xor %edx, %edx
    mov $18, %ecx
    div %ecx
    call vga_dec
    mov $stat_txt2, %esi
    call vga_puts
    xor %ebx, %ebx               # count active agents
    xor %ecx, %ecx
st_acnt:
    cmpb $0, agents_tbl(,%ebx,8)
    je st_ac2
    inc %ecx
st_ac2:
    inc %ebx
    cmp $8, %ebx
    jb st_acnt
    mov %ecx, %eax
    call vga_dec
    mov $stat_txt_t, %esi
    call vga_puts
    xor %ebx, %ebx               # count open tasks
    xor %ecx, %ecx
st_tcnt:
    mov %ebx, %edx
    shl $4, %edx
    cmpb $0, tasks_tbl(%edx)
    je st_tc2
    cmpb $2, tasks_tbl+2(%edx)
    je st_tc2
    inc %ecx
st_tc2:
    inc %ebx
    cmp $8, %ebx
    jb st_tcnt
    mov %ecx, %eax
    call vga_dec
    mov $stat_txt3, %esi
    call vga_puts
    xor %ebx, %ebx               # count runnable threads (incl. shell)
    xor %ecx, %ecx
st_thr:
    cmpb $1, tcb_state(%ebx)
    jne st_th2
    inc %ecx
st_th2:
    inc %ebx
    cmp $9, %ebx
    jb st_thr
    mov %ecx, %eax
    call vga_dec
st_fill:
    cmp $0xb8000+160, %edi
    jae st_done
    mov $0x20, %al
    call stat_attr_lbl
    call stat_stosw
    jmp st_fill
st_done:
    popal
    ret

# Status-line attributes: white on blue (0x1F) on the plain console; on the
#   desktop the same cells become a subtle strip - bg 1 = SURFACE2 via
#   desk_bgpal, labels fg 7 (TEXT2 tone), values fg 11 (accent).
stat_attr_lbl:                   # -> AH = label attribute
    mov $0x1f, %ah
    cmpb $0, desk_active
    je sal_r
    mov $0x17, %ah
sal_r:
    ret
stat_attr_val:                   # -> AH = value attribute
    mov $0x1f, %ah
    cmpb $0, desk_active
    je sav_r
    mov $0x1b, %ah
sav_r:
    ret

vga_puts:
    lodsb
    test %al, %al
    jz vp_done
    call stat_attr_lbl
    call stat_stosw
    jmp vga_puts
vp_done:
    ret

vga_dec:
    push %eax
    push %ebx
    push %ecx
    push %edx
    mov $10, %ebx
    xor %ecx, %ecx
vd_div:
    xor %edx, %edx
    div %ebx
    push %edx
    inc %ecx
    test %eax, %eax
    jnz vd_div
vd_out:
    pop %eax
    add $0x30, %al
    call stat_attr_val
    call stat_stosw
    loop vd_out
    pop %edx
    pop %ecx
    pop %ebx
    pop %eax
    ret

# =====================================================================
#  Input: readline (uses kgetch - keyboard OR COM1)
# =====================================================================
readline:
    mov $linebuf, %edi
rl_loop:
    call kgetch
    cmp $0x0d, %al
    je rl_done
    cmp $0x08, %al
    je rl_bs
    test %al, %al                # AL=0 -> special key
    jz rl_ext
    cmp $0x20, %al
    jb rl_loop
    cmp $linebuf+LINEMAX, %edi
    jae rl_loop
    stosb
    call putc
    jmp rl_loop
rl_bs:
    cmp $linebuf, %edi
    je rl_loop
    dec %edi
    mov $0x08, %al
    call putc
    mov $0x20, %al
    call putc
    mov $0x08, %al
    call putc
    jmp rl_loop
rl_ext:
    cmp $0xEE, %ah               # remote EXEC waiting: abandon this line so the
    je rl_abort                  #   shell loop can stage the wire command
    cmp $0x48, %ah               # arrow up?
    jne rl_loop
rl_clr:
    cmp $linebuf, %edi
    je rl_recall
    dec %edi
    mov $0x08, %al
    call putc
    mov $0x20, %al
    call putc
    mov $0x08, %al
    call putc
    jmp rl_clr
rl_recall:
    mov $histbuf, %esi
rl_rc:
    lodsb
    test %al, %al
    jz rl_loop
    stosb
    call putc
    jmp rl_rc
rl_done:
    movb $0, (%edi)
    cmpb $0, linebuf
    je rl_nl
    mov $linebuf, %esi
    mov $histbuf, %edi
rl_cp:
    lodsb
    stosb
    test %al, %al
    jnz rl_cp
rl_nl:
    call crlf
    ret
rl_abort:
    movb $0, linebuf             # return an empty line (any half-typed text is
    call crlf                    #   dropped - the wire command takes the turn)
    ret

# pend_copy: copy the asciz at ESI into EDI (PEND_BUF), bounded to 511 bytes.
#   Stages a typed line so ';' command chaining can walk it.
pend_copy:
    push %eax
    push %ecx
    xor %ecx, %ecx
pc_l:
    movb (%esi), %al
    mov %al, (%edi)
    test %al, %al
    je pc_done
    inc %esi
    inc %edi
    inc %ecx
    cmp $511, %ecx
    jb pc_l
    movb $0, (%edi)              # truncate
pc_done:
    pop %ecx
    pop %eax
    ret

# pend_next: take the next ';'-separated command from pending_ptr into linebuf
#   (leading spaces trimmed, capped at LINEMAX chars). Advances pending_ptr past the
#   ';'. At the end of the buffer pending_ptr is cleared to 0.
pend_next:
    push %eax
    push %esi
    push %edi
    mov pending_ptr, %esi
pn_skipsp:
    movb (%esi), %al             # trim leading spaces of the segment
    cmp $0x20, %al
    jne pn_copy
    inc %esi
    jmp pn_skipsp
pn_copy:
    mov $linebuf, %edi
    xor %eax, %eax               # AL reused; ECX-free char count via EDI delta
pn_l:
    movb (%esi), %al
    test %al, %al
    je pn_end                    # end of the whole buffer
    cmp $0x3b, %al               # ';' separator
    je pn_sep
    mov %al, (%edi)
    inc %esi
    inc %edi
    lea linebuf+LINEMAX, %eax    # cap the segment length
    cmp %eax, %edi
    jb pn_l
pn_drain:                        # segment too long: skip to the next ';' or end
    movb (%esi), %al
    test %al, %al
    je pn_end
    cmp $0x3b, %al
    je pn_sep
    inc %esi
    jmp pn_drain
pn_sep:
    inc %esi                     # consume the ';'
    movb $0, (%edi)              # terminate this segment
    mov %esi, pending_ptr        # more may follow
    jmp pn_ret
pn_end:
    movb $0, (%edi)
    movl $0, pending_ptr         # whole line consumed
pn_ret:
    pop %edi
    pop %esi
    pop %eax
    ret

# try_cmd: does linebuf start with the command in EDI (+ end/space)?
#   Hit: CF=0, arg_ptr points to the arguments. Otherwise CF=1.
try_cmd:
    mov $linebuf, %esi
tc_loop:
    mov (%edi), %al
    test %al, %al
    jz tc_endcmd
    cmpb %al, (%esi)
    jne tc_no
    inc %esi
    inc %edi
    jmp tc_loop
tc_endcmd:
    mov (%esi), %al
    test %al, %al
    jz tc_hit
    cmp $0x20, %al
    jne tc_no
tc_skip:
    inc %esi
    cmpb $0x20, (%esi)
    je tc_skip
tc_hit:
    mov %esi, arg_ptr
    clc
    ret
tc_no:
    stc
    ret

# =====================================================================
#  Helper routines (parser, number output, CMOS)
# =====================================================================
starts_with:
    push %esi
sw_loop:
    mov (%edi), %al
    test %al, %al
    jz sw_endk
    cmp %al, (%esi)
    jne sw_no
    inc %esi
    inc %edi
    jmp sw_loop
sw_endk:
    mov (%esi), %al
    test %al, %al
    jz sw_ok
    cmp $0x20, %al
    jne sw_no
sw_skip:
    inc %esi
    cmpb $0x20, (%esi)
    je sw_skip
sw_ok:
    pop %ecx                     # discard the saved ESI
    clc
    ret
sw_no:
    pop %esi
    stc
    ret

parse_type:
    mov $tn_math, %edi
    call starts_with
    jnc pt_t_math
    mov $tn_scan, %edi
    call starts_with
    jnc pt_t_scan
    mov $tn_count, %edi
    call starts_with
    jnc pt_t_count
    mov $tn_prime, %edi
    call starts_with
    jnc pt_t_prime
    mov $tn_gcd, %edi
    call starts_with
    jnc pt_t_gcd
    mov $tn_fault, %edi
    call starts_with
    jnc pt_t_fault
    mov $tn_ask, %edi            # typ 5: the LLM agent (ring-3 askd daemon)
    call starts_with
    jnc pt_t_ask
    stc
    ret
pt_t_ask:
    mov $5, %al
    clc
    ret
pt_t_math:
    mov $0, %al
    clc
    ret
pt_t_scan:
    mov $1, %al
    clc
    ret
pt_t_count:
    mov $2, %al
    clc
    ret
pt_t_prime:
    mov $3, %al
    clc
    ret
pt_t_gcd:
    mov $6, %al
    clc
    ret
pt_t_fault:
    mov $7, %al
    clc
    ret

skip_spaces:
    cmpb $0x20, (%esi)
    jne ss_done
    inc %esi
    jmp skip_spaces
ss_done:
    ret

# parse_dec: decimal number at ESI -> EAX. CF=1 if no digit.
parse_dec:
    push %ebx
    push %ecx
    xor %eax, %eax
    xor %ecx, %ecx
pd2_loop:
    movzbl (%esi), %ebx
    cmp $0x30, %bl
    jb pd2_done
    cmp $0x39, %bl
    ja pd2_done
    imul $10, %eax, %eax
    sub $0x30, %ebx
    add %ebx, %eax
    inc %esi
    inc %ecx
    jmp pd2_loop
pd2_done:
    test %ecx, %ecx
    jz pd2_err
    pop %ecx
    pop %ebx
    clc
    ret
pd2_err:
    pop %ecx
    pop %ebx
    stc
    ret

# parse_hex: hex number at ESI (optional 0x) -> EAX. CF=1 if empty.
parse_hex:
    push %ebx
    push %ecx
    xor %eax, %eax
    xor %ecx, %ecx
    cmpb $0x30, (%esi)
    jne ph_loop
    cmpb $0x78, 1(%esi)
    jne ph_loop
    add $2, %esi
ph_loop:
    movzbl (%esi), %ebx
    cmp $0x30, %bl
    jb ph_done
    cmp $0x39, %bl
    jbe ph_dig
    or $0x20, %bl
    cmp $0x61, %bl
    jb ph_done
    cmp $0x66, %bl
    ja ph_done
    sub $0x57, %ebx
    jmp ph_add
ph_dig:
    sub $0x30, %ebx
ph_add:
    shl $4, %eax
    or %ebx, %eax
    inc %esi
    inc %ecx
    jmp ph_loop
ph_done:
    test %ecx, %ecx
    jz ph_err
    pop %ecx
    pop %ebx
    clc
    ret
ph_err:
    pop %ecx
    pop %ebx
    stc
    ret

phex_nib:
    and $0x0f, %al
    cmp $10, %al
    jb phn_dig
    add $0x57, %al
    jmp phn_out
phn_dig:
    add $0x30, %al
phn_out:
    call putc
    ret

phex8:
    push %ebx
    mov %al, %bl
    shr $4, %al
    call phex_nib
    mov %bl, %al
    call phex_nib
    pop %ebx
    ret

phex16:
    push %eax
    mov %ah, %al
    call phex8
    pop %eax
    call phex8
    ret

phex32:
    push %eax
    shr $16, %eax
    call phex16
    pop %eax
    call phex16
    ret

# --- buffer formatters for nicdbg: like phex/puts but write ASCII into
#   (EDI) and advance EDI, instead of printing to the screen. Used to
#   build the UDP telemetry payload. Preserve EAX/EBX; clobber ESI only
#   where noted; advance EDI.
bputs:                            # copy asciz at ESI to (EDI); ESI/EAX clobbered
    lodsb
    test %al, %al
    jz bputs_d
    stosb
    jmp bputs
bputs_d:
    ret
bsp:                              # append a single space
    push %eax
    mov $0x20, %al
    stosb
    pop %eax
    ret
bnib:                             # low nibble of AL -> one ASCII hex char at (EDI)
    and $0x0f, %al
    cmp $10, %al
    jb bnib_d
    add $0x57, %al                # a-f
    jmp bnib_o
bnib_d:
    add $0x30, %al                # 0-9
bnib_o:
    stosb
    ret
bhex8:                            # AL -> two hex chars at (EDI)
    push %eax
    push %ebx
    mov %al, %bl
    shr $4, %al
    call bnib
    mov %bl, %al
    call bnib
    pop %ebx
    pop %eax
    ret
bhex16:                           # AX -> four hex chars
    push %eax
    mov %ah, %al
    call bhex8
    pop %eax
    call bhex8
    ret
bhex32:                           # EAX -> eight hex chars
    push %eax
    shr $16, %eax
    call bhex16
    pop %eax
    call bhex16
    ret
bdec32:                           # EAX -> decimal ASCII at (EDI), advance EDI
    push %eax
    push %ebx
    push %ecx
    push %edx
    mov $10, %ebx
    xor %ecx, %ecx                # digit count
    test %eax, %eax
    jnz bd_div
    movb $0x30, (%edi)            # special-case zero
    inc %edi
    jmp bd_done
bd_div:
    xor %edx, %edx
    div %ebx                      # EAX/=10, EDX=remainder
    push %edx                     # push digits (least-significant first)
    inc %ecx
    test %eax, %eax
    jnz bd_div
bd_emit:
    pop %edx                      # pop them back -> most-significant first
    add $0x30, %dl
    mov %dl, (%edi)
    inc %edi
    dec %ecx
    jnz bd_emit
bd_done:
    pop %edx
    pop %ecx
    pop %ebx
    pop %eax
    ret

print_bcd:
    push %eax
    mov %al, %ah
    shr $4, %al
    and $0x0f, %al
    add $0x30, %al
    call putc
    mov %ah, %al
    and $0x0f, %al
    add $0x30, %al
    call putc
    pop %eax
    ret

cmos_read:
    mov %bl, %al
    out %al, $0x70
    nop
    in $0x71, %al
    ret

cmos_wait:
    mov $0x0a, %bl
    call cmos_read
    test $0x80, %al
    jnz cmos_wait
    ret

store4:
    mov %eax, (%edi)
    mov %ebx, 4(%edi)
    mov %ecx, 8(%edi)
    mov %edx, 12(%edi)
    add $16, %edi
    ret

# print_dec32: print EAX in decimal, preserves all registers
print_dec32:
    pushal
    mov $10, %ebx
    xor %ecx, %ecx
pd_div:
    xor %edx, %edx
    div %ebx
    push %edx
    inc %ecx
    test %eax, %eax
    jnz pd_div
pd_out:
    pop %eax
    add $0x30, %al
    call putc
    loop pd_out
    popal
    ret

slot_ptr:                        # EBX = agent -> EDI = entry
    mov %ebx, %edi
    shl $3, %edi
    add $agents_tbl, %edi
    ret

task_ptr:                        # EBX = task -> EDI = entry
    mov %ebx, %edi
    shl $4, %edi
    add $tasks_tbl, %edi
    ret

name_ptr:                        # EBX = agent -> ESI = name
    mov agent_names(,%ebx,4), %esi
    ret

# ---------------------------------------------------------------------
#  Data
# ---------------------------------------------------------------------
prompt:   .asciz "tannx> "
.equ LINEMAX, 254                # max chars per typed line / ';' segment (
                                 #   was 62 - LLM-written script lines outgrew it)
linebuf:  .fill 256, 1, 0        # LINEMAX + room for the terminator
histbuf:  .fill 256, 1, 0        # arrow-up recall copy - same size as linebuf
arg_ptr:  .long 0
anyflag:  .byte 0
ticks:    .long 0
stat_cnt: .byte 18
cur_attr: .byte 0x0a
cur_x:    .byte 0
cur_y:    .byte 1
rnd_seed: .long 0x1337
spk_off:  .long 0                # tick at which to silence a game blip (0 = idle)
calc_ptr: .long 0                # calc: current parse cursor
calc_err: .byte 0                # calc: 1 = syntax error / divide by zero
.balign 4
heap_base: .long 0x50000         # kernel heap arena (relocated to high RAM by
heap_top:  .long 0x90000         #   highmem_init when >=96 MB; else this 256 KB)
cpu_count: .long 1               # SMP: logical processors (1 = no SMP)
ap_online: .long 0               # SMP: APs that reached 32-bit ap_entry32
bsp_apic:  .long 0               # SMP: the boot processor's APIC ID
.balign 4
ap_idtr:   .word 0               # SMP: the APs' IDTR (limit + base, filled at boot)
           .long 0
.balign 4
# Per-core worker job slots (indexed by APIC ID, up to 8 cores). The BSP fills
# lo/hi and raises go; the AP counts primes in [lo,hi], posts res, raises done.
ap_lo:     .long 0,0,0,0,0,0,0,0
ap_hi:     .long 0,0,0,0,0,0,0,0
ap_go:     .long 0,0,0,0,0,0,0,0
ap_res:    .long 0,0,0,0,0,0,0,0
ap_done:   .long 0,0,0,0,0,0,0,0
core_runs: .long 0,0,0,0,0,0,0,0   # SMP: how many times each core resumed a thread
pb_n:      .long 0              # pbench: range + timing + results
pb_chunk:  .long 0
pb_t0:     .long 0
pb_t1:     .long 0
pb_t2:     .long 0
pb_total1: .long 0
gln_x0: .long 0                  # gfx_line endpoints + Bresenham state
gln_y0: .long 0
gln_x1: .long 0
gln_y1: .long 0
gln_col:.long 0
gln_dx: .long 0
gln_dy: .long 0
gln_sx: .long 0
gln_sy: .long 0
gln_err:.long 0
gln_cx: .long 0
gln_cy: .long 0
gcr_cx: .long 0                  # gfx_circle centre / radius
gcr_cy: .long 0
gcr_r:  .long 0
gci_x:  .long 0                  # midpoint-circle state
gci_y:  .long 0
gci_err:.long 0
gdcx:   .long 0                  # gfx demo: screen centre
gdcy:   .long 0
note_div: .word 2712,2415,4554,4058,3616,3419,3044   # a,b,c,d,e,f,g PIT divisors
play_jingle: .asciz "cdefgabagfedc"                  # default tune for bare 'play'
.balign 4
boot_uefi:.byte 0                # 1 = entered via the UEFI stub
.balign 4
net_present: .byte 0            # NIC found+initialized: 0 none, 1 RTL8139, 2 e1000,
                                #   3 RTL8168, 4 virtio-net
.balign 4
nic_io:      .long 0            # RTL8139 I/O base port
e1000_mmio:  .long 0            # e1000 MMIO base
r8168_mmio:  .long 0            # RTL8168 MMIO base
vnet_io:     .long 0            # virtio-net legacy I/O base
vnet_tx_avail: .long 0          # virtio-net TX avail running index
vnet_rx_avail: .long 0          # virtio-net RX avail running index (replenish)
vnet_rx_used:  .long 0          # virtio-net RX used index consumed
.balign 4
rtl_rxoff:   .long 0            # RTL8139 RX ring read offset
rtl_txd:     .byte 0            # RTL8139 next TX descriptor (round-robin 0..3)
.balign 4
net_last_syscall: .long 0x80000000  # tick of the last NET syscall (net_poll yields ~30s after)
nro_dst:     .long 0            # net_rx_one scratch (dest / lengths / return)
nro_rlen:    .long 0
nro_flen:    .long 0
nro_retval:  .long 0
r8168_rxidx: .long 0            # RTL8168 RX descriptor index (0-3)
inbox_full:  .byte 0            # 1 = an unread inbox message is waiting
.balign 4
nh_paylen:   .long 0            # net_handle: received UDP payload length
rx_seen:     .long 0            # diag: frames net_poll drained from the RX ring
nh_hits:     .long 0            # diag: datagrams that matched UDP port 4713
nh_rep_buf:  .long 0            # nh_report: payload build pointer
wish_acked:  .byte 0            # netwish: dev box acked the last wish
nw_pay:      .long 0            # netwish: payload pointer (for resends)
nw_plen:     .long 0            # netwish: payload length
nic_mac:     .byte 0,0,0,0,0,0  # our MAC address

# --- framebuffer console state ---------------------------------
.balign 4
fb_active:  .byte 0              # 1 = render the 80x25 grid into GOP
compositor_active: .byte 0       # 1 = a ring-3 compositor (user/gui.c) owns the
                                 #   framebuffer; the kernel stops drawing it
.balign 4
fb_base:    .long 0              # linear framebuffer (below 4 GB)
fb_ppsl:    .long 0              # pixels per scanline
fb_rowskip: .long 0              # bytes from glyph row end to next start
fb_rowskip2:.long 0              # same for the 2x font (16 px cell width)
fb_scale:   .long 2              # console font scale (1..4), set from vres in fb_init
fb_rowskip_s:.long 0             # row-skip for the scaled cell ((ppsl - 8*scale)*4)
# Scale2x temps live in scratch RAM, NOT in the kernel image: they are written
#   per pixel, and under QEMU TCG a store into a 4 KB page that also holds
#   translated code takes the self-modifying-code slow path - with the
#   desktop code shifting the image, they landed in putc/draw_status's page
#   and the console ran ~20x slower (WP3). 0x134C00..0x134C24 is free scratch
#   (after inbox_buf, before EXEC_CMD), zeroed at boot.
.equ epx_buf, 0x134C00           # 16 glyph rows + a 0 guard above/below (18 B)
.equ epx_a,   0x134C12           # the 3 active rows (above / current / below)
.equ epx_e,   0x134C13
.equ epx_d,   0x134C14
.equ epx_P,   0x134C15           # extracted neighbour bits (0/1) for one src px
.equ epx_Av,  0x134C16
.equ epx_Bv,  0x134C17
.equ epx_Cv,  0x134C18
.equ epx_Dv,  0x134C19
.equ epx_px,  0x134C1C           # Scale2x src column / row counters
.equ epx_py,  0x134C20
fb_w:       .long 0              # horizontal resolution (pixels)
fb_h:       .long 0              # vertical resolution (pixels)
.equ MENU_N, 5                   # menu titles in the top bar
con_ox:     .long 0              # console window pixel offset X (0 = top-left)
con_oy:     .long 0              # console window pixel offset Y
con_off:    .long 0              # precomputed con_oy*ppsl + con_ox (pixels)
con_w:      .long 1280           # console pixel width  = 640 * fb_scale
con_h:      .long 800            # console pixel height = 400 * fb_scale
desk_active:.byte 0              # 1 = the graphical desktop is laid out
gb_epx:     .byte 1              # glyph_blit: 1 = Scale2x at gb_scale 2
gtx_tr:     .byte 0              # gfx_char: 1 = transparent background
.balign 4
gb_scale:   .long 1              # glyph_blit pixel scale (1..4)
gb_rowskip: .long 0              # glyph_blit: (ppsl - 8*gb_scale)*4
gtx_x:      .long 0              # gfx_puts pen position + colors
gtx_y:      .long 0
gtx_fg:     .long 0xffffff
gtx_bg:     .long 0
gtx_scale:  .long 1              # gfx_char glyph scale 1 | 2
gtx_adv:    .long 0              # gfx_puts advance per char (0 = 8*scale)
gtx_buf:    .fill 40, 1, 0       # gfx_line / clock / pill scratch string

# --- desktop design tokens (SPEC.md section 3), 0x00RRGGBB -------------
.equ C_BG_TOP,     0x0A1614      # wallpaper row 0
.equ C_BG_BOT,     0x122823      # wallpaper last row
.equ C_SURFACE,    0x122421      # panels, dropdowns
.equ C_SURFACE2,   0x183029      # top bar, title bars, hover rows
.equ C_SURFACE3,   0x1E3A33      # chips / pills / buttons
.equ C_CONBG,      0x0C1917      # terminal client = console bg 0
.equ C_INPUTBG,    0x0E1E1B      # wish field
.equ C_BORDER,     0x1F3A35
.equ C_BORDER2,    0x2B4F49
.equ C_TEXT,       0xE6F1EE
.equ C_TEXT2,      0x8FB3AC
.equ C_MUTED,      0x567A74
.equ C_ACCENT,     0x2DD4BF
.equ C_ACCENT2,    0x5EEAD4
.equ C_ACCENT_BG,  0x163D36
.equ C_ACCENT_DEEP,0x0F5132
.equ C_OK,         0x4ADE80
.equ C_WARN,       0xFBBF24
.equ C_ERR,        0xF87171
.equ C_INFO,       0x60A5FA

# --- desktop layout: written ONCE by desk_layout, read by every drawer and
#     hit test (concept C "Workspace"; all values in screen pixels) --------
ui_s:       .long 1              # UI scale u = min(fb_scale, 2)
desk_fit:   .long 0              # 1 = the desktop fits this mode
dk_margin:  .long 0              # MARGIN = 10u
top_h:      .long 0              # top bar height = 24u
title_h:    .long 0              # terminal title bar height = 20u
brand_img:  .long 0              # brand RLE asset (brand_u1 | brand_u2)
brand_x:    .long 0              # brand blit position (MARGIN, 2u)
brand_y:    .long 0
brand_w:    .long 0              # brand asset width
menu_x:     .fill MENU_N, 4, 0   # menu title boxes: x, w (height menu_h at menu_y)
menu_w:     .fill MENU_N, 4, 0   #   titles menu_lbl[i]; text at (x+8u, menu_y+2u)
menu_y:     .long 0
menu_h:     .long 0
pill_y:     .long 0              # status pills: y, h, text y, per pill x / w /
pill_h:     .long 0              #   value-text x (AGENTS has a dot at x+12u)
pill_ty:    .long 0
pill_ag_x:  .long 0
pill_ag_w:  .long 0
pill_ag_vx: .long 0
pill_th_x:  .long 0
pill_th_w:  .long 0
pill_th_vx: .long 0
pill_up_x:  .long 0
pill_up_w:  .long 0
pill_up_vx: .long 0
clock_x:    .long 0              # HH:MM:SS text origin
clock_y:    .long 0
pwr_x:      .long 0              # power button (pwr_s square)
pwr_y:      .long 0
pwr_s:      .long 0
term_x:     .long 0              # terminal window rect
term_y:     .long 0
term_w:     .long 0
term_h:     .long 0
chip_y:     .long 0              # title-bar chips help / clear
chip_h:     .long 0
chip_help_x:.long 0
chip_help_w:.long 0
chip_clear_x:.long 0
chip_clear_w:.long 0
wish_x:     .long 0              # wish field rect
wish_y:     .long 0
wish_w:     .long 0
wish_h:     .long 0
panel_x:    .long 1316           # agents panel rect
panel_y:    .long 0
panel_w:    .long 0
panel_h:    .long 0
card_x:     .long 0              # card area inside the panel (below the header)
card_y:     .long 0
card_w:     .long 0
card_h:     .long 0
fir_img:    .long 0              # fir silhouette asset (fir_u1 | fir_u2)
fir_wall_x: .long 0              # ... on the wallpaper (bottom right)
fir_wall_y: .long 0
term_fir_img:.long 0             # ... inside the terminal (0 = none)
fir_term_x: .long 0              # its screen rect (for partial repaints)
fir_term_y: .long 0
fir_term_w: .long 0
fir_term_h: .long 0
term_bg_col:.long 0              # con_bg_fill_rect flat colour (CONBG | black)
term_fir_pal:                    # the fir's tones inside the terminal
    .long 0, 0x102320, 0x142927  #   (index 0 transparent)

# --- primitive scratch (memory temps, all routines are pushal-safe) ------
grd_c0:     .long 0              # gfx_vgrad / gfx_hgrad / grd_lerp colours
grd_c1:     .long 0
vg_x:       .long 0
vg_y:       .long 0
vg_w:       .long 0
vg_h:       .long 0
sh_x:       .long 0              # gfx_shadow
sh_y:       .long 0
sh_w:       .long 0
sh_h:       .long 0
sh_g:       .long 0
sh_d:       .long 0
sh_lx:      .long 0
sh_lw:      .long 0
rr_x:       .long 0              # gfx_rrect
rr_y:       .long 0
rr_w:       .long 0
rr_h:       .long 0
rr_r:       .long 0
rr_col:     .long 0
mk_x:       .long 0              # gfx_mask
mk_y:       .long 0
mk_w:       .long 0
mk_h:       .long 0
mk_col:     .long 0
mk_s:       .long 0
clip_x0:    .long 0              # draw_rle clip rect (x1/y1 exclusive)
clip_y0:    .long 0
clip_x1:    .long 0
clip_y1:    .long 0
rle_x:      .long 0              # draw_rle scratch
rle_y:      .long 0
rle_w:      .long 0
rle_h:      .long 0
rle_pal:    .long 0
rle_rows:   .long 0
rle_run:    .long 0
rle_row:    .long 0
rle_r0:     .long 0
rle_r1:     .long 0
rle_c0:     .long 0
rle_c1:     .long 0
rle_pal_ovr:.long 0              # != 0: palette pointer override for draw_rle
crt_x:      .long 0              # con_repaint_rect scratch
crt_y:      .long 0
crt_w:      .long 0
crt_h:      .long 0
crt_c0v:    .long 0
crt_c1v:    .long 0
crt_r1v:    .long 0
cell_tr:    .byte 0              # 1 = fb_cell_edi paints the glyph only (bg kept)
.balign 4

# rounded-corner inset tables: rr_tab holds ins[0..r-1] for r = 1..24 back to
#   back (row 0 = outermost), rr_off[r-1] = its byte offset. Generated from
#   ins[i] = r - round(sqrt(r^2 - (r-i-0.5)^2)) (SPEC.md section 4.2).
rr_off: .word 0,1,3,6,10,15,21,28,36,45,55,66,78,91,105,120,136,153,171,190,210,231,253,276
rr_tab:
    .byte 0
    .byte 1,0
    .byte 1,0,0
    .byte 2,1,0,0
    .byte 3,1,1,0,0
    .byte 4,2,1,1,0,0
    .byte 4,3,2,1,0,0,0
    .byte 5,3,2,1,1,0,0,0
    .byte 6,4,3,2,1,1,0,0,0
    .byte 7,5,3,2,2,1,1,0,0,0
    .byte 8,5,4,3,2,1,1,1,0,0,0
    .byte 9,6,5,4,3,2,1,1,1,0,0,0
    .byte 9,7,5,4,3,2,2,1,1,0,0,0,0
    .byte 10,8,6,5,4,3,2,2,1,1,0,0,0,0
    .byte 11,8,7,5,4,3,3,2,1,1,1,0,0,0,0
    .byte 12,9,7,6,5,4,3,2,2,1,1,1,0,0,0,0
    .byte 13,10,8,7,5,4,4,3,2,2,1,1,1,0,0,0,0
    .byte 14,11,9,7,6,5,4,3,3,2,2,1,1,1,0,0,0,0
    .byte 15,12,10,8,7,6,5,4,3,3,2,2,1,1,1,0,0,0,0
    .byte 16,12,10,9,7,6,5,4,4,3,2,2,1,1,1,1,0,0,0,0
    .byte 16,13,11,9,8,7,6,5,4,3,3,2,2,1,1,1,0,0,0,0,0
    .byte 17,14,12,10,9,7,6,5,5,4,3,3,2,2,1,1,1,0,0,0,0,0
    .byte 18,15,13,11,9,8,7,6,5,4,4,3,3,2,2,1,1,1,0,0,0,0,0
    .byte 19,16,13,12,10,9,8,7,6,5,4,4,3,2,2,2,1,1,1,0,0,0,0,0

# 12x12 icons (.word per row, MSB = left; SPEC.md section 4.7) for gfx_mask12,
#   icon_power is 8x8 (gfx_mask with ECX=EDX=8).
.balign 2
icon_system:   .word 0x0000,0x7fe0,0x0c00,0x1e00,0x7fe0,0x0000,0x7fe0,0x0180,0x03c0,0x7fe0,0x0000,0x0000
icon_agents:   .word 0x0600,0x0f00,0x0f00,0x0600,0x0900,0x1080,0x2040,0x70e0,0xf9f0,0xf9f0,0x70e0,0x0000
icon_hardware: .word 0x2480,0x2480,0xffe0,0x8020,0x9f20,0x9120,0x9120,0x9f20,0x8020,0xffe0,0x2480,0x2480
icon_games:    .word 0x0000,0x0000,0x7fe0,0xfff0,0xdff0,0x8f50,0xdfb0,0xfff0,0xf0f0,0xe070,0x0000,0x0000
icon_help:     .word 0x1f80,0x30c0,0x30c0,0x00c0,0x0180,0x0700,0x0600,0x0600,0x0000,0x0600,0x0600,0x0000
icon_search:   .word 0x1e00,0x2100,0x4080,0x4080,0x4080,0x4080,0x2100,0x1e80,0x00c0,0x0060,0x0030,0x0000
icon_sprout:   .word 0x0000,0x0200,0x0700,0x0d80,0x1240,0x0200,0x0200,0x0200,0x0200,0x1fc0,0x0f80,0x0000
icon_chev_r:   .word 0x0000,0x0000,0x0400,0x0600,0x0300,0x0180,0x0180,0x0300,0x0600,0x0400,0x0000,0x0000
icon_power:    .word 0x1800,0x5a00,0x9900,0x9900,0x8100,0x8100,0x4200,0x3c00
icon_fir:      .word 0x0c00,0x1e00,0x3f00,0x1e00,0x3f00,0x7f80,0x3f00,0x7f80,0xffc0,0x0600,0x0600,0x1f80
.balign 4
menu_lbl:   .long m_system, m_agents, m_hardware, m_games, m_help
menu_len:   .byte 6, 6, 8, 5, 4
m_system:   .asciz "System"
m_agents:   .asciz "Agents"
m_hardware: .asciz "Hardware"
m_games:    .asciz "Games"
m_help:     .asciz "Help"
lbl_agents: .asciz "AGENTS "
lbl_threads:.asciz "THREADS "
lbl_up:     .asciz "UP "
lbl_help:   .asciz "help"
lbl_clear:  .asciz "clear"
lbl_enter:  .asciz "ENTER"
lbl_agents_hdr: .asciz "Agents"
dsk_term:   .asciz "Terminal"
dsk_term2:  .asciz "80x25"
dsk_term3:  .asciz "ring 3"
dsk_wish:   .asciz "Plant a wish - what should TannX learn next?"
lbl_planted:.asciz "planted"

# --- WP3: console colours, caret, chips, wish state -------------------------
# desk_pal: the 16 VGA foreground indices re-tuned to the brand for the desktop
#   console (fb_cell_edi when desk_active; games + the plain console keep
#   vga_pal). 10 = the shell's body attr -> TEXT; 11 = prompt/labels -> ACCENT;
#   2/3/9 stay the logo teals (the boot banner uses them); 14 notifications ->
#   WARN; 12 faults -> ERR; 7/8 dim/muted; 15 bright.
.balign 4
desk_pal:
    .long C_CONBG,  0x3B82F6, 0x2A6B60, 0x6FC6B4
    .long 0xEF4444, 0xC084FC, 0xD97706, 0xB4C9C4
    .long 0x6B8F88, C_ACCENT, C_TEXT,   C_ACCENT
    .long C_ERR,    0xD8B4FE, C_WARN,   0xF6FBF9
# desk_bgpal: background indices 0..7 - 0 = TRANSPARENT (the terminal
#   background incl. the faint fir shows through), 1 = SURFACE2 (status strip),
#   the rest tinted brand surfaces.
desk_bgpal:
    .long -1, C_SURFACE2, 0x2A6B60, 0x134E4A
    .long 0x7F1D1D, 0x581C87, 0x78350F, 0x8FB3AC
chip_cols:                       # title-bar chips: {fill, border, text} per state
    .long C_SURFACE3,  C_BORDER,  C_TEXT2     # 0 normal
    .long C_SURFACE3,  C_BORDER2, C_TEXT      # 1 hover
    .long C_ACCENT_BG, C_ACCENT,  C_ACCENT2   # 2 pressed
caret_pos:  .long -1             # console caret: painted cell index, -1 = none
fbc_cx:     .long 0              # fb_cell_edi: the cell's screen x/y
fbc_cy:     .long 0
wish_until: .long 0              # tick when the "planted" feedback expires
wish_tx:    .long 0              # wish_render layout for the caret blinker
wish_ty:    .long 0
wish_cx:    .long 0
wish_iy:    .long 0
wish_hx:    .long 0
wish_hy:    .long 0
wish_last:  .fill 72, 1, 0       # the wish just planted (echoed in the feedback)
chip_help_st:  .byte 0           # 0 normal, 1 hover, 2 pressed (WP2 hover sets)
chip_clear_st: .byte 0
wish_hover: .byte 0              # 1 = pointer over the idle wish field (WP2 sets)
wish_state: .byte 0              # 0 idle/typing, 2 = "planted" feedback showing
wish_blink: .byte 0              # caret phase (1 = visible)
.equ WISH_MAX,  63               # wish_buf characters (buffer is 72)
.equ WISH_NEAR, 48               # from here the "n/63" hint shows
.balign 2
icon_check:    .word 0x0000,0x0020,0x0060,0x00c0,0x0180,0x6300,0x7600,0x3e00,0x1c00,0x0800,0x0000,0x0000
.balign 4

# --- PS/2 mouse + cursor state ---------------------------------------
.balign 4
mouse_x:    .long 0              # cursor X (top-left of the sprite), pixels
mouse_y:    .long 0              # cursor Y
mouse_px:   .long 0xffffffff     # last drawn X (sentinel: nothing drawn yet)
mouse_py:   .long 0              # last drawn Y
# The four big zero-only scratch buffers moved OUT of the
# kernel image into free 1 MB RAM (after the AC97 PCM buffer) - 2576
# bytes of .fill reclaimed from the 64 KB budget. They are zeroed once
# at boot (see the rep stosl before tss_init).
.equ SCRATCH_BASE,    0x134000
.equ tss,             0x134000   # 8 x 104 B Task State Segments (one per core)
.equ cursor_save_buf, 0x134400   # 16x16x4 saved-under pixels (mouse)
.equ fs_buf,          0x134800   # 512 B AgentFS/ATA sector buffer
.equ inbox_buf,       0x134A00   # 208 B last UDP control message
.equ EXEC_CMD,        0x135000   # 208 B wire EXEC command staging
.equ EXEC_OUT,        0x135100   # 1400 B captured console output for the reply
.equ SLOT_RAM,        0x136000   # 17 x 512 B RAM-backed slots (LBA 257-273) for
                                 #   diskless/foreign-disk boots; volatile, zeroed at boot
.equ CONSOLE_SHADOW,  0x138200   # readable 80x25 char/attr mirror of the text
                                 #   console (0xB8000 is graphics RAM in LFB mode, not
                                 #   read-back-able) so the ring-3 compositor can render it
click_x:    .long 0              # latched left-click position (from the ISR)
click_y:    .long 0
in_wish:    .byte 0              # 1 = the wish field has keyboard focus
mouse_btn_prev: .byte 0          # previous left-button state (for press edges)
.balign 4
mouse_irqs: .long 0              # IRQ12 count (telemetry: rises when moved)
mouse_pkts: .long 0              # complete mouse packets (telemetry)
poll_aux:   .long 0              # 8042 bytes seen with the aux flag (mouse)
poll_kbd:   .long 0              # 8042 bytes seen without it (diagnostic)
click_pending:  .byte 0          # 1 = an unhandled left click is waiting
wish_len:   .byte 0              # characters in wish_buf
.balign 4
wish_buf:   .fill 72, 1, 0       # the wish text being composed in the field
mouse_present: .byte 0           # 1 = a PS/2 mouse answered at init
mouse_phase:.byte 0              # packet byte index 0..2
mouse_flags:.byte 0              # packet byte 0 (buttons + sign bits)
mouse_dx:   .byte 0              # packet byte 1 (X movement)
mouse_btn:  .byte 0              # current button state (bits 0..2)
ms_cfg:     .byte 0              # 8042 config byte scratch
.balign 4
# 16x16 arrow cursor: 0 = transparent, 1 = black outline, 2 = white fill
cursor_img:
    .byte 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 1,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 1,2,1,0,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 1,2,2,1,0,0,0,0,0,0,0,0,0,0,0,0
    .byte 1,2,2,2,1,0,0,0,0,0,0,0,0,0,0,0
    .byte 1,2,2,2,2,1,0,0,0,0,0,0,0,0,0,0
    .byte 1,2,2,2,2,2,1,0,0,0,0,0,0,0,0,0
    .byte 1,2,2,2,2,2,2,1,0,0,0,0,0,0,0,0
    .byte 1,2,2,2,2,2,2,2,1,0,0,0,0,0,0,0
    .byte 1,2,2,2,2,2,2,2,2,1,0,0,0,0,0,0
    .byte 1,2,2,2,2,2,1,1,1,1,1,0,0,0,0,0
    .byte 1,2,2,1,2,2,1,0,0,0,0,0,0,0,0,0
    .byte 1,2,1,0,1,2,2,1,0,0,0,0,0,0,0,0
    .byte 1,1,0,0,1,2,2,1,0,0,0,0,0,0,0,0
    .byte 1,0,0,0,0,1,2,2,1,0,0,0,0,0,0,0
    .byte 0,0,0,0,0,1,1,1,1,0,0,0,0,0,0,0

we_pfx:     .asciz "netwish "
.balign 4
# --- menu bar state + tables (WP2) ----------------------------------------
.balign 4
mhc_res:    .long 0              # menu_handle_click result
mra_res:    .long 0              # menu_row_at result
mdr_y:      .long 0              # menu_draw_row scratch
mdr_h:      .long 0
mdr_hov:    .long 0
mtd_st:     .long 0              # title / power / chip draw scratch
dd_x:       .long 0              # the open dropdown's panel rect
dd_y:       .long 0
dd_w:       .long 0
dd_h:       .long 0
dd_sx:      .long 0              # its save-under rect (panel + shadow)
dd_sy:      .long 0
dd_sw:      .long 0
dd_sh:      .long 0
dd_csum:    .long 0              # CONSOLE_SHADOW checksum when it opened
menu_open:  .byte 0              # != 0 while any dropdown is open (WP4: skip panel_refresh)
menu_cur:   .byte 0xff           # which one: 0..4 title, MENU_PWR, 0xff none
menu_hov_t: .byte 0xff           # hovered title / HT_PWR / HT_HELP / HT_CLEAR / 0xff
menu_hov_r: .byte 0xff           # hovered command row of the open dropdown / 0xff
.balign 4
mst_pill:    .long C_SURFACE2, C_SURFACE3, C_ACCENT_BG   # title bg: normal/hover/open
mst_fill:    .long C_SURFACE3, C_SURFACE3, C_ACCENT_BG   # chip + power fill
mst_bord:    .long C_BORDER,   C_BORDER2,  C_ACCENT      #   border
mst_text:    .long C_TEXT2,    C_TEXT,     C_ACCENT2     #   text / icon
# Dropdown tables: 6-byte rows (.word label, description, command - all
#   string offsets from mstr0 = menu_tbl - 4096, so lbl_help / lbl_clear
#   from the top-bar block above are in reach too; description 0 = none,
#   command 0 = a group header, < 16 = an MA_* action). Labels double as
#   the injected command.
#   Every command of the old button row / command list (help dmesg selftest
#   clear reboot, sysinfo .. invaders) is in here.
.macro MH lbl                    # group header
    .word \lbl-mstr0, 0, 0
.endm
.macro MR lbl, dsc               # command row (label = command)
    .word \lbl-mstr0, \dsc-mstr0, \lbl-mstr0
.endm
.macro MA lbl, dsc, act          # action row
    .word \lbl-mstr0, \dsc-mstr0, \act
.endm
.set mstr0, menu_tbl - 4096
menu_tbl:   .long mt_system, mt_agents, mt_hardware, mt_games, mt_help, mt_power
menu_cnt:   .byte (mt_agents-mt_system)/6, (mt_hardware-mt_agents)/6
            .byte (mt_games-mt_hardware)/6, (mt_help-mt_games)/6
            .byte (mt_power-mt_help)/6, (mt_end-mt_power)/6
.balign 2
menu_wd:    .word 220,520, 220,520, 220,520, 200,440, 200,440, 160,300  # px, u=1 | u=2
mt_system:
    MH mh_info
    MR cm1, md_sysinfo
    MR cm2, md_cpuid
    MR ms_cpu, md_cpu
    MR cm6, md_mem
    MR cm7, md_uptime
    MR cm5, md_date
    MR cm8, md_dmesg
    MH mh_tools
    MR ms_calc, md_calc
    MR cm18, md_selftest
    MR ms_display, md_display
    MH mh_session
    MR lbl_help, md_help
    MR lbl_clear, md_clear
    MA bc_reboot, md_reboot, MA_REBOOT
mt_agents:
    MH mh_spawn
    MR cm11, md_smath
    MR ma_sprime, md_sprime
    MR ma_scount, md_scount
    MR ma_sgcd, md_sgcd
    MH mh_tasks
    MR cm12, md_tmath
    MR ma_tprime, md_tprime
    MR ma_tcount, md_tcount
    MR ma_tgcd, md_tgcd
    MH mh_manage
    MR ma_agents, md_agents
    MR cm13, md_tasks
    MR cm14, md_top
    MR cm15, md_reap
    MR ma_kill, md_kill
mt_hardware:
    MH mh_bus
    MR cm3, md_lspci
    MR mw_usb, md_usb
    MH mh_storage
    MR cm4, md_ahci
    MR mw_nvme, md_nvme
    MR mw_smart, md_smart
    MH mh_network
    MR cm9, md_net
    MR cm10, md_nicdbg
    MH mh_tests
    MR cm16, md_hwtest
    MR cm17, md_cputest
    MR mw_ramtest, md_ramtest
    MR mw_temp, md_temp
mt_games:
    MH mh_ring3
    MR cm19, md_snake
    MR cm20, md_invaders
    MR ap_forest, md_forest
    MR ap_rain, md_rain
    MR ap_synth, md_synth
    MR mg_run, md_run
mt_help:
    MH mh_af
    MR ap_tour, md_tour
    MR lbl_help, md_help
    MR mp_about, md_about
    MA mp_wish, md_wish, MA_WISH
    MH mh_apps
    MR ap_chat, md_chat
    MR ap_edit, md_edit
    MR ap_sysmon, md_sysmon
    MR ap_www, md_www
    MR ap_files, md_files
    MR ap_cast, md_cast
    MR ap_shot, md_shot
    MR ap_rec, md_rec
    MR ap_voice, md_voice
    MR ap_fetch, md_fetch
mt_power:
    MH mh_reboot
    MA mp_yes, md_yes, MA_DOREBOOT
    MA mp_no, md_no, MA_CLOSE
mt_end:
# group headers (1x, letter-spaced)
mh_info:    .asciz "INFO"
mh_tools:   .asciz "TOOLS"
mh_session: .asciz "SESSION"
mh_spawn:   .asciz "SPAWN"
mh_tasks:   .asciz "TASKS"
mh_manage:  .asciz "MANAGE"
mh_bus:     .asciz "BUS"
mh_storage: .asciz "STORAGE"
mh_network: .asciz "NETWORK"
mh_tests:   .asciz "TESTS"
mh_ring3:   .asciz "RING 3"
mh_af:      .asciz "TANNX OS"
mh_apps:    .asciz "APPS"
mh_reboot:  .asciz "REBOOT?"
# commands (= labels)
bc_reboot:  .asciz "reboot"
cm1:  .asciz "sysinfo"
cm2:  .asciz "cpuid"
cm3:  .asciz "lspci"
cm4:  .asciz "ahci"
cm5:  .asciz "date"
cm6:  .asciz "mem"
cm7:  .asciz "uptime"
cm8:  .asciz "dmesg"
cm9:  .asciz "net"
cm10: .asciz "nicdbg"
cm11: .asciz "spawn math"
cm12: .asciz "task math 7 * 6"
cm13: .asciz "tasks"
cm14: .asciz "top"
cm15: .asciz "reap"
cm16: .asciz "hwtest"
cm17: .asciz "cputest 2"
cm18: .asciz "selftest"
cm19: .asciz "snake"
cm20: .asciz "invaders"
ms_cpu:     .asciz "cpu"
ms_calc:    .asciz "calc (2+3)*4"
ms_display: .asciz "display"
ma_sprime:  .asciz "spawn prime"
ma_scount:  .asciz "spawn count"
ma_sgcd:    .asciz "spawn gcd"
ma_tprime:  .asciz "task prime 100"
ma_tcount:  .asciz "task count 1000"
ma_tgcd:    .asciz "task gcd 84 36"
ma_agents:  .asciz "agents"
ma_kill:    .asciz "kill 0"
mw_usb:     .asciz "usb"
mw_nvme:    .asciz "nvme"
mw_smart:   .asciz "smart"
mw_ramtest: .asciz "ramtest 16"
mw_temp:    .asciz "temp"
mg_run:     .asciz "run"
mp_about:   .asciz "about"
ap_tour:    .asciz "run tour"
ap_forest:  .asciz "forest"
ap_fetch:   .asciz "fetch"
ap_rain:    .asciz "run rain"
ap_synth:   .asciz "run synth"
ap_chat:    .asciz "run chat"
ap_edit:    .asciz "run edit NOTE.TXT"
ap_sysmon:  .asciz "run sysmon"
ap_www:     .asciz "run www"
ap_files:   .asciz "run files"
ap_cast:    .asciz "run cast"
ap_shot:    .asciz "run shot"
ap_rec:     .asciz "run rec"
ap_voice:   .asciz "run voice"
mp_wish:    .asciz "Plant a wish"
mp_yes:     .asciz "yes"
mp_no:      .asciz "no"
# descriptions (1x, u = 2 only)
md_sysinfo: .asciz "CPU, board, RAM"
md_cpuid:   .asciz "vendor + model"
md_cpu:     .asciz "cores + scheduling"
md_mem:     .asciz "memory + heap"
md_uptime:  .asciz "seconds since boot"
md_date:    .asciz "RTC clock"
md_dmesg:   .asciz "kernel log"
md_calc:    .asciz "calculator"
md_selftest:.asciz "CPU + RAM -> dmesg"
md_display: .asciz "framebuffer info"
md_help:    .asciz "all commands"
md_clear:   .asciz "clear the console"
md_reboot:  .asciz "asks first"
md_smath:   .asciz "math agent, ring 3"
md_sprime:  .asciz "prime agent"
md_scount:  .asciz "count agent"
md_sgcd:    .asciz "gcd agent"
md_tmath:   .asciz "work for math"
md_tprime:  .asciz "the 100th prime"
md_tcount:  .asciz "sum 1..1000"
md_tgcd:    .asciz "gcd of 84, 36"
md_agents:  .asciz "slots + stats"
md_tasks:   .asciz "table + results"
md_top:     .asciz "live view, q quits"
md_reap:    .asciz "free idle agents"
md_kill:    .asciz "stop slot 0"
md_lspci:   .asciz "PCI bus scan"
md_usb:     .asciz "xHCI host, ring 3"
md_ahci:    .asciz "SATA controller"
md_nvme:    .asciz "NVMe, ring 3"
md_smart:   .asciz "drive health"
md_net:     .asciz "NIC + IPv4"
md_nicdbg:  .asciz "NIC ring debug"
md_hwtest:  .asciz "full diagnostics"
md_cputest: .asciz "CPU benchmark"
md_ramtest: .asciz "test 16 MB RAM"
md_temp:    .asciz "CPU temperature"
md_snake:   .asciz "the classic"
md_invaders:.asciz "space invaders"
md_run:     .asciz "video player"
md_about:   .asciz "what this OS is"
md_forest:  .asciz "agents as trees"
md_rain:    .asciz "screensaver"
md_synth:   .asciz "keys play notes"
md_tour:    .asciz "start here"
md_chat:    .asciz "talk to the model"
md_edit:    .asciz "text editor"
md_sysmon:  .asciz "live monitor"
md_www:     .asciz "web via proxy"
md_files:   .asciz "FAT file manager"
md_cast:    .asciz "to a Chromecast"
md_shot:    .asciz "screenshot"
md_rec:     .asciz "sound recorder"
md_voice:   .asciz "speak a wish"
md_fetch:   .asciz "system card"
md_wish:    .asciz "focus the wish field"
md_yes:     .asciz "warm reboot now"
md_no:      .asciz "keep running"

vga_pal:                         # the 16 VGA colors as 0x00RRGGBB (BGRx)
    .long 0x000000, 0x0000AA, 0x2A6B60, 0x6FC6B4   # 2/3/9: Tannenbaum Media teals
    .long 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA   #   (logo only - see logo_palette)
    .long 0x555555, 0x2DD4BF, 0x55FF55, 0x55FFFF
    .long 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF
spawn_type:   .byte 0
task_type_tmp:.byte 0
.balign 4
top_until:    .long 0
more_cnt:     .byte 0            # puts_more: rows printed since last pause
sn_delta:     .long -80, 80, -1, 1   # up, down, left, right (in cells)
game_gfx:     .byte 0           # 1 = render snake/invaders cells as sprites
fg_prog:      .byte 0           # 1 = a ring-3 game owns the keyboard (input -> key_ring only)
abort_req:    .byte 0           # 1 = AGENTOS-ABORT arrived; do_wait/sh_chain bail out
game_quit_req:.byte 0           # set by game_pause when q is pressed while paused
.balign 4
snake_buf:    .long 0
snake_head:   .long 0
snake_tail:   .long 0
snake_len:    .long 0
snake_score:  .long 0            # live score, +10 per food (M4 HUD)
snake_dir:    .long 0
inv_alive:    .long 0            # Space Invaders: 32-bit alive mask (4x8)
inv_x:        .long 0            # block top-left column
inv_y:        .long 0            # block top row
inv_dir:      .long 0            # +1 right / -1 left
inv_score:    .long 0
inv_period:   .long 0            # frames between block moves
inv_timer:    .long 0
inv_until:    .long 0
inv_minc:     .long 0            # alive column/row offset bounds (inv_bounds)
inv_maxc:     .long 0
inv_maxr:     .long 0
inv_dead:     .byte 0
ship_col:     .long 0
pb_active:    .byte 0            # (legacy; multi-bullet uses the pb_r/pb_c slots)
.balign 4
pb_row:       .long 0            # scratch: the bullet currently being stepped
pb_col:       .long 0
pb_r:         .long 0,0,0,0,0,0  # 6 bullet slots - row (0 = free slot)
pb_c:         .long 0,0,0,0,0,0  # 6 bullet slots - column
pb_cool:      .long 0            # frames until the ship may fire again (rapid fire)
ab_active:    .byte 0            # alien bomb
ab_row:       .long 0
ab_col:       .long 0
ab_timer:     .long 0
inv_lives:    .long 0            # ships left (3 at start)
inv_wave:     .long 0            # current wave (1+)
ufo_active:   .byte 0            # mothership on screen?
.balign 4
ufo_col:      .long 0
ufo_dir:      .long 0
ufo_movetimer:.long 0            # frames between UFO steps
ufo_timer:    .long 0            # frames until the next UFO spawns
pu_active:    .byte 0            # power-up capsule falling?
.balign 4
pu_col:       .long 0
pu_row:       .long 0
pu_type:      .long 0            # 0 = extra life, 1 = spread shot
pu_movetimer: .long 0
spread_timer: .long 0            # frames of spread shot left
inv_row_attr: .byte 0x0B,0x0D,0x0A,0x0E   # alien colour per row: cyan/magenta/green/yellow
inv_row_pts:  .byte 40,30,20,10           # alien points per row (top worth most)
.balign 4
task_id_tmp:  .byte 0
# --- Threads: 0 = shell, 1-8 = agents ---
cur_thread:   .byte 0,0,0,0,0,0,0,0   # per-core current thread, indexed by APIC ID
tcb_running:  .byte 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff  # which core runs thread N (0xff=none)
.balign 4
sched_lock:   .long 0                 # run-queue spinlock (multi-core scheduler)
putc_lock:    .long 0                 # console spinlock - only taken when cpu_count>1
tbl_lock:     .long 0                 # agents/tasks table spinlock (claim/finish)
snd_nam:      .long 0                 # AC97 mixer I/O base (BAR0), 0 = not probed
snd_nabm:     .long 0                 # AC97 bus-master I/O base (BAR1)
runprog_slot: .byte 0xff              # agent slot of the last 'run'-style program
script_slot:  .byte 0xff              # AgentFS slot of the last 'script' (repeat)
rep_count:    .long 0                 # 'repeat': remaining re-runs of script_slot
wt_start:     .long 0                 # 'waittask'/'waitall': timeout base tick
wa_prev:      .long 0                 # 'waitall': pending count last scan (progress detect)
atp_round:    .long 0                 # llmscript generations since the last
                                      #   'autopilot' launch - the free-running
                                      #   loop bumps it once per round (one LLM
                                      #   round-trip), so STATUS shows liveness
atp_mission:  .fill 48, 1, 0          # the current autopilot mission (text
                                      #   after "autopilot " in the llmscript arg),
                                      #   broadcast in STATUS as mis=<text>
sreg:         .long 0                 # script register A ('set' / '$')
sreg2:        .long 0                 # script register B ('setb' / '#')
set_ptr:      .long 0                 # do_set/do_setb target (-> sreg or sreg2)
if_left:      .long 0                 # do_if: stashed left-operand value
exec_req:     .byte 0                 # wire EXEC waiting to be staged
exec_cap:     .byte 0                 # capture putc into EXEC_OUT
exec_olen:    .word 0                 # captured bytes
exec_deadline:.long 0                 # tick to force-flush a hung capture
exec_prog0:   .byte 0                 # runprog_slot snapshot at EXEC stage
nh_exec_str:  .ascii "EXEC "
exec_out_pfx: .asciz "AGENTOS-OUT "
exec_end_str: .ascii "AGENTOS-END"
shell_safe_esp:.long 0           # ESP anchor: the shell rescues itself here after #PF
pending_ptr:   .long 0           # shell: next ';'-chained command (0 = none pending)
tcb_state:    .byte 1            # shell always runs
              .fill 8, 1, 0
tcb_esp:      .fill 36, 1, 0     # 9 x saved ESP
# tss: moved to SCRATCH_BASE
kb_head:  .byte 0
kb_tail:  .byte 0
kb_shift: .byte 0
kb_e0:    .byte 0
kb_ctrl:  .byte 0               # left Ctrl held (Ctrl+letter -> control code for fg_prog)
fb_owner: .byte 0               # TID that borrowed compositor_active (forest / SYS_KBGRAB), 0 = none
kbuf:     .fill 128, 1, 0
# ABI v2: ring-3 key ring (SYS_GETKEY) + userspace heap break
key_ring: .fill 64, 1, 0
kr_head:  .byte 0
kr_tail:  .byte 0
.balign 4
user_brk: .long 0x00800000        # current sbrk break (= USER_HEAP_BASE)
pxe_prog_present: .long 0         # pxe_stage found a program in the boot image
pxe_prog_len:     .long 0         # its length in bytes (PXE_STASH -> 0x400000)
ramdisk_sectors:  .long 0         # PXE video-clip RAM disk size (0 = none)
esc_state:.byte 0
esc_digit:.byte 0               # the digit of a pending ESC [ <n> ~ serial sequence
fs_armed: .byte 0
fs_ram:   .byte 0               # 1 = slots are RAM-backed (no TannX OS medium)
ahci_persist: .byte 0            # a blessed AHCI SATA disk is the persist medium
# fs_buf: moved to SCRATCH_BASE+0x800
cpu_buf:  .fill 64, 1, 0
feat_ecx: .long 0               # cpuid leaf 1 ECX/EDX feature dwords
feat_edx: .long 0
feat_val: .long 0               # print_feats: the feature dword being decoded
# inbox_buf: moved to SCRATCH_BASE+0xA00
.balign 4
smb_addr:  .long 0               # SMBIOS structure table address
smb_cnt:   .long 0               # SMBIOS structure count
ram_speed: .long 0               # first DIMM speed (MT/s) for sysinfo
ct_start:  .long 0               # cputest: RDTSC start value
ct_chunks: .long 10              # cputest: number of 50M-iteration chunks (configurable)
ahci_abar: .long 0               # mapped AHCI HBA base (ABAR), 0 = none
ahci_pbase:.long 0               # active SATA port register base
ahci_wflag:.byte 0               # ahci_exec direction (0 read, 1 write)
ahci_aflag:.byte 0               # ahci_exec ATAPI packet (A bit in cmd hdr)
ahci_devtype:.byte 0             # active device (0 SATA HDD, 1 ATAPI)
.balign 4
ahci_lba:  .long 0               # aread LBA argument
rt_mb:     .long 16              # ramtest: megabytes to test (configurable, capped to RAM)
ct_ticks0: .long 0               # cputest: timer ticks at start
ct_cycles: .long 0               # cputest: measured cycle delta
ct_ticksd: .long 0               # cputest: measured tick delta
cpu_mhz:   .long 0               # hwtest: measured CPU MHz (for the bw ladder)
hw_miters: .long 0               # hwtest: CPU throughput, millions of iters/s
hw_ram_err:.long 0               # hwtest: RAM error count
hw_bw_lbl: .long 0               # hwtest: current bandwidth-row label ptr
hw_bw_last:.long 0               # hwtest: last bandwidth result (MB/s)
hw_bw_res: .long 0,0,0,0         # hwtest: L1/L2/L3/RAM bandwidth (MB/s)
hw_cpu_fault: .byte 0            # hwtest: 1 = the CPU fault check disagreed
sse_ok:    .byte 0               # 1 = SSE enabled (wide bandwidth loads)
.balign 4
ct_csum:   .long 0               # cputest: workload checksum
pci_last:  .long 0               # net probe: last printed vendor:device (de-dup)
lu_vd:     .long 0               # log_usb: current device:vendor
lu_cl:     .long 0               # log_usb: current class/subclass/prog-if/rev
xhci_base: .long 0               # xHCI MMIO base (mapped)
xhci_op:   .long 0               # xHCI operational register base
ehci_base: .long 0               # EHCI MMIO base (current controller)
ehci_op:   .long 0               # EHCI operational register base
ehci_bdf:  .long 0               # EHCI PCI BDF (for the EECP handoff)
ehci_legsup: .long 0             # USBLEGSUP snapshot after the BIOS->OS handoff
ehci_legctl: .long 0             # USBLEGCTLSTS snapshot (BIOS SMI enables)
ehci_port: .long 0               # connected port index
ehci_dlen: .long 0               # control transfer data length
ehci_din:  .long 0               # control transfer direction (1 IN)
ehci_qhchar:.long 0              # queue head endpoint characteristics
ehci_hubports:.long 0            # downstream port count of an enumerated hub
ehci_connmask:.long 0            # bitmap of connected downstream ports (auto-scan)
ehci_quiet:.byte 0               # 1 = suppress "no device"/"error" prints (boot scan)
.balign 4
ehci_skip: .long 0               # which EHCI controller ehcitest targets
ehci_cfgval:.byte 0              # device bConfigurationValue
ehci_epaddr:.byte 0              # HID interrupt-IN endpoint address (0 = none)
ehci_epint:.byte 0               # endpoint bInterval
ehci_hidproto:.byte 0            # HID boot protocol: 1 keyboard, 2 mouse, 0 unknown
ehci_hid_active:.byte 0          # 1 = the mouse interrupt QH is armed
ehci_kbd_active:.byte 0          # 1 = the keyboard interrupt QH is armed
ehci_tog_m:.byte 0               # mouse interrupt data toggle
ehci_tog_k:.byte 0               # keyboard interrupt data toggle
.balign 4
ehci_eps:  .long 0               # endpoint speed bits for the QH char (0 full / 0x1000 low)
ehci_mps_m:.long 0               # mouse interrupt maxpacket
ehci_mps_k:.long 0               # keyboard interrupt maxpacket
ehci_kbd_diag:.long 0            # diagnostic: broadcast the first N keyboard reports
ehci_kbd_hbnext:.long 0          # next tick for the keyboard QH heartbeat
kbd_pushes:.long 0               # diagnostic: keys fed to push_key from USB
ehci_devaddr:.byte 0             # USB address assigned to the device being enumerated
ehci_nextaddr:.byte 2            # next free downstream address (RMH is 1)
usb_kbd_prev:.byte 0,0,0,0,0,0,0,0   # previous keyboard report (new-press detection)
.balign 4
# HID boot-keyboard usage code -> ASCII (US layout), indexed 0x00..0x38.
hid2ascii:
    .byte 0,0,0,0
    .ascii "abcdefghijklmnopqrstuvwxyz"
    .ascii "1234567890"
    .byte 0x0d,0x1b,0x08,0x09,0x20
    .ascii "-=[]\\"
    .byte 0x23
    .ascii ";'`,./"
hid2ascii_shift:
    .byte 0,0,0,0
    .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    .ascii "!@#$%^&*()"
    .byte 0x0d,0x1b,0x08,0x09,0x20
    .ascii "_+{}|"
    .byte 0x7e
    .ascii ":\"~<>?"
.balign 4
usb_autostart:.byte 0            # 1 = idle loop auto-runs usb_init once after boot
                                 #   (OFF: boot auto-enum wedges the RMH on real HW;
                                 #    the remote EHCITEST trigger is the reliable path)
.balign 4
ehci_compl:.long 0               # diagnostic: HID interrupt completions seen this run
.balign 4
ehci_epmps:.word 0               # endpoint wMaxPacketSize
ehci_tog:  .byte 0               # interrupt data toggle
.balign 4
ehci_lastrep:.long 0             # last HID report (to broadcast only changes)
ehci_togsave:.long 0            # data toggle bit kept from the controller (DTC=0)
ehci_hbnext:.long 0             # next tick at which the poll loop emits a heartbeat
ehci_curcfg:.byte 0             # GET_CONFIGURATION result
.balign 4
ehci_diagn:.long 0             # diagnostic: emit first N reports unconditionally
ehci_qhcaps:.long 0x40000000     # QH endpoint capabilities (Mult / split fields)
ehci_dport:.long 0               # downstream hub port to enumerate (0 = none)
lp_vd:     .long 0               # lspci: current device:vendor
lp_class:  .long 0               # lspci: current class/subclass/prog-if/rev
pci_class_tbl:                   # {class byte, name}, 0xFF = default
    .byte 0x01; .asciz "storage"
    .byte 0x02; .asciz "network"
    .byte 0x03; .asciz "display"
    .byte 0x04; .asciz "multimedia"
    .byte 0x06; .asciz "bridge"
    .byte 0x07; .asciz "comm"
    .byte 0x08; .asciz "system"
    .byte 0x0c; .asciz "serial-bus"
    .byte 0xff; .asciz "other"
pci_stor_tbl:                    # storage subclass {byte, name}
    .byte 0x01; .asciz "(IDE)"
    .byte 0x04; .asciz "(RAID)"
    .byte 0x05; .asciz "(ATA)"
    .byte 0x06; .asciz "(SATA/AHCI)"
    .byte 0x08; .asciz "(NVMe)"
    .byte 0xff; .asciz "(?)"
notify_task: .long 0             # sys_finish: task to announce as done
wd_start:    .long 0,0,0,0,0,0,0,0  # A4: per-agent watchdog start tick
slp_val:     .long 0            # ACPI SLP_TYPa|SLP_EN to write at power off
pm1a_port:   .long 0            # PM1a_CNT I/O port (from the FADT)
selftest_req: .byte 0           # remote SELFTEST requested (run from shell idle)
ehcitest_req: .byte 0           # remote EHCITEST requested (USB enum from idle)
run_req:      .byte 0           # remote RUNPROG requested (launch ring-3 program)
log_pos:     .long 0            # dmesg ring write index
log_wrapped: .byte 0            # ring has wrapped at least once
temp_tjmax:  .long 0             # CPU temp: TjMax from MSR 0x1A2

agents_tbl: .fill 64, 1, 0       # 8 x 8 bytes (layout: docs/ARCHITECTURE.md)
tasks_tbl:  .fill 128, 1, 0      # 8 x 16 bytes

agent_names: .long an0, an1, an2, an3, an4, an5, an6, an7
an0: .asciz "core"
an1: .asciz "scout"
an2: .asciz "coder"
an3: .asciz "guard"
an4: .asciz "muse"
an5: .asciz "probe"
an6: .asciz "spark"
an7: .asciz "relay"

tn_math:  .asciz "math"
tn_scan:  .asciz "scan"
tn_count: .asciz "count"
tn_prime: .asciz "prime"
tn_prog:  .asciz "prog"
tn_ask:   .asciz "ask"
tn_gcd:   .asciz "gcd"
tn_fault: .asciz "fault"
type_names: .long tn_math, tn_scan, tn_count, tn_prime, tn_prog, tn_ask, tn_gcd, tn_fault

astate_names: .long as0, as1
as0: .asciz "idle"
as1: .asciz "busy"

tstate_names: .long ts0, ts1, ts2, ts3, ts4
ts0: .asciz "waiting"
ts1: .asciz "running"
ts2: .asciz "done"
ts3: .asciz "ERROR"
ts4: .asciz "blocked"

# Scancode set 1 -> ASCII
kbmap:
    .byte 0, 27
    .ascii "1234567890-="
    .byte 8, 9
    .ascii "qwertyuiop[]"
    .byte 13, 0
    .ascii "asdfghjkl;'`"
    .byte 0
    .ascii "\\"
    .ascii "zxcvbnm,./"
    .byte 0
    .ascii "*"
    .byte 0
    .ascii " "
kbmap_sh:
    .byte 0, 27
    .ascii "!@#$%^&*()_+"
    .byte 8, 9
    .ascii "QWERTYUIOP{}"
    .byte 13, 0
    .ascii "ASDFGHJKL:\"~"
    .byte 0
    .ascii "|"
    .ascii "ZXCVBNM<>?"
    .byte 0
    .ascii "*"
    .byte 0
    .ascii " "

# German layout (QWERTZ). Umlauts/sz/section sign have no ASCII and
# stay dead (0 = the ISR drops the key). AltGr is not tracked, so
# @ [ ] { } \ | ~ are unreachable in DE mode - 'kbd us' brings them back.
kbmap_de:
    .byte 0, 27
    .ascii "1234567890"
    .byte 0                      # 0x0C sz ligature - dead
    .ascii "'"                   # 0x0D acute accent -> apostrophe
    .byte 8, 9
    .ascii "qwertzuiop"          # z sits on the US-y position
    .byte 0                      # 0x1A ue - dead
    .ascii "+"
    .byte 13, 0
    .ascii "asdfghjkl"
    .byte 0, 0                   # 0x27 oe, 0x28 ae - dead
    .ascii "^"
    .byte 0
    .ascii "#"
    .ascii "yxcvbnm,.-"          # y sits on the US-z position
    .byte 0
    .ascii "*"
    .byte 0
    .ascii " "
kbmap_de_sh:
    .byte 0, 27
    .ascii "!\""
    .byte 0                      # shift-3 = section sign - dead
    .ascii "$%&/()="             # the famous shift-7 = /
    .ascii "?`"
    .byte 8, 9
    .ascii "QWERTZUIOP"
    .byte 0                      # Ue - dead
    .ascii "*"
    .byte 13, 0
    .ascii "ASDFGHJKL"
    .byte 0, 0                   # Oe, Ae - dead
    .byte 0                      # shift-^ = degree sign - dead
    .byte 0
    .ascii "'"
    .ascii "YXCVBNM;:_"
    .byte 0
    .ascii "*"
    .byte 0
    .ascii " "

.balign 4
kbmap_ptr:    .long kbmap        # active layout, switched by 'kbd'
kbmap_sh_ptr: .long kbmap_sh

# Command names
cs_help:   .asciz "help"
cs_about:  .asciz "about"
cs_clear:  .asciz "clear"
cs_cls:    .asciz "cls"
cs_echo:   .asciz "echo"
cs_agents: .asciz "agents"
cs_ps:     .asciz "ps"
cs_spawn:  .asciz "spawn"
cs_kill:   .asciz "kill"
cs_reap:   .asciz "reap"
cs_tick:   .asciz "tick"
cs_run:    .asciz "run"
cs_llm:    .asciz "llm"
cs_offload: .asciz "offload"
cs_llmscript: .asciz "llmscript"
sa_llms:   .asciz "llms"
cs_hda:    .asciz "hda"
cs_vgpu:   .asciz "vgpu"
cs_nvme:   .asciz "nvme"
cs_httpd:  .asciz "httpd"
cs_usb:    .asciz "usb"
cs_vblk:   .asciz "vblk"
cs_auto:   .asciz "auto"
cs_color:  .asciz "color"
cs_rnd:    .asciz "rnd"
cs_calc:   .asciz "calc"
cs_gfx:    .asciz "gfx"
cs_beep:   .asciz "beep"
cs_play:   .asciz "play"
cs_sound:  .asciz "sound"
cs_lines:  .asciz "lines"
cs_task:   .asciz "task"
cs_tasks:  .asciz "tasks"
cs_queue:  .asciz "queue"
cs_date:   .asciz "date"
cs_time:   .asciz "time"
cs_dump:   .asciz "dump"
cs_cpuid:  .asciz "cpuid"
cs_cpu:    .asciz "cpu"
cs_smp:    .asciz "smp"
cs_smpon:  .asciz "smpon"
msg_smpon:  .asciz "SMP armed - the other cores run agent threads now ('smp' shows it).\r\n"
msg_smpon2: .asciz "SMP is already on.\r\n"
msg_smpon3: .asciz "single core (or no SMP here) - nothing to wake.\r\n"
cs_pbench: .asciz "pbench"
cs_selftest: .asciz "selftest"
cs_sysinfo:.asciz "sysinfo"
cs_display:.asciz "display"
cs_cputest:.asciz "cputest"
cs_ramtest:.asciz "ramtest"
cs_hwtest: .asciz "hwtest"
cs_ehcitest: .asciz "ehcitest"
cs_smart:  .asciz "smart"
cs_disktest:.asciz "disktest"
cs_temp:   .asciz "temp"
cs_inbox:  .asciz "inbox"
cs_nicdbg: .asciz "nicdbg"
# Wire-protocol tokens. The "AGENTOS-*" strings below (and AGENTOS-OUT /
# AGENTOS-END / AGENTOS-WISH / AGENTOS-WISHES / AGENTOS-PROXY in user/net.c)
# are PROTOCOL CONSTANTS shared with the host-side tools (l2tap.py, the
# test suites, the proxy scripts). They are deliberately NOT product
# branding and must stay byte-identical when anything else is renamed.
nh_reboot_str: .ascii "AGENTOS-REBOOT"
nh_abort_str:  .ascii "AGENTOS-ABORT"
nh_status_str: .ascii "STATUS"
nh_mission_str:.ascii "MISSION "
nh_results_str: .ascii "RESULTS"
nh_dmesg_str:  .ascii "DMESG"
nh_selftest_str: .ascii "SELFTEST"
nh_ehci_str: .ascii "EHCITEST"
nh_run_str:  .ascii "RUNPROG"
nh_wishack_str: .ascii "AGENTOS-WISH-ACK"
nh_tag_reboot: .asciz "ACK-REBOOT"
nh_tag_stat:   .asciz "STAT"
nh_rslt_tag:   .asciz "RSLT"
nh_dmsg_tag:   .asciz "DMSG\r\n"
nh_done_tag:   .asciz "DONE a"
nh_rslt_sp:    .asciz " t"
nh_rslt_sp2:   .asciz " "
nh_rslt_eq:    .asciz "="
nh_rslt_neg:   .asciz "-"
nh_rslt_err:   .asciz "=ERR"
nh_rep_pfx:    .asciz "AgentOS/32 v2.87 "
nh_rep_up:     .asciz " up="
nh_rep_ms:     .asciz " ms="
nh_rep_irq:    .asciz " pkt="
nh_rep_pa:     .asciz " a="
nh_rep_pk:     .asciz " k="
nh_rep_atp:    .asciz " atp="
nh_rep_res:    .asciz " res="
nh_rep_mis:    .asciz " mis="
nh_rep_rx:     .asciz "s rx="
nh_rep_hit:    .asciz " hit="
nh_rep_in:     .asciz " in="
cs_save:   .asciz "save"
cs_load:   .asciz "load"
cs_script: .asciz "script"
cs_sleep:  .asciz "sleep"
cs_wait:   .asciz "wait"
cs_waittask: .asciz "waittask"
cs_waitall: .asciz "waitall"
cs_autopilot: .asciz "autopilot"
cs_if:     .asciz "if"
cs_repeat: .asciz "repeat"
cs_set:    .asciz "set"
cs_setb:   .asciz "setb"
cs_ls:     .asciz "ls"
cs_del:    .asciz "del"
cs_diskon: .asciz "diskon"
cs_ahcibless: .asciz "ahcibless"
cs_confirm: .asciz "confirm"
cs_persist: .asciz "persist"
cs_uptime: .asciz "uptime"
cs_dmesg:  .asciz "dmesg"
cs_mem:    .asciz "mem"
cs_heap:   .asciz "heap"
cs_top:    .asciz "top"
cs_banner: .asciz "banner"
cs_kbd:    .asciz "kbd"
cs_gui:    .asciz "gui"
cs_fetch:  .asciz "fetch"
cs_forest: .asciz "forest"
cs_snake:  .asciz "snake"
cs_invaders: .asciz "invaders"
cs_wish:   .asciz "wish"
cs_wishes: .asciz "wishes"
cs_sendwishes: .asciz "sendwishes"
cs_net:        .asciz "net"
cs_lspci:      .asciz "lspci"
cs_ahci:       .asciz "ahci"
cs_aread:      .asciz "aread"
cs_awrite:     .asciz "awrite"
cs_cdread:     .asciz "cdread"
cs_netwish:    .asciz "netwish"
msg_sw_head:   .asciz "<<AGENTOS-WISHES\r\n"
msg_sw_line:   .asciz "WISH:"
msg_sw_tail:   .asciz "AGENTOS-END\r\n"
nw_prefix:     .asciz "AGENTOS-WISH: "
msg_net_up:    .asciz "NIC up ("
msg_drv_rtl:   .asciz "RTL8139)"
msg_drv_e1000: .asciz "e1000)"
msg_drv_r8168: .asciz "RTL8168)"
msg_done1:     .asciz "\r\n>> Agent ["
msg_done2:     .asciz "] "
msg_done3:     .asciz " done = "
msg_done4:     .asciz "\r\n"
msg_wd1:       .asciz "\r\n!! Agent ["
msg_wd2:       .asciz "] watchdog-killed (ran too long).\r\n"
logm_boot:     .asciz "AgentOS/32 v2.87: boot\r\n"
logm_net:      .asciz "net: NIC up\r\n"
logp_cpu:      .asciz "cpu: "
logp_cores:    .asciz " cores "
logp_feat:     .asciz " feat "
logp_slash:    .asciz "/"
logp_crlf:     .asciz "\r\n"
logp_ram:      .asciz "ram: "
logp_mb:       .asciz " MB (E820)\r\n"
logp_cpb:      .asciz "cpu-bench: "
logp_cyc:      .asciz " cyc ~"
logp_mhz:      .asciz " MHz\r\n"
logp_rmt:      .asciz "ram-test: "
logp_rme:      .asciz " MB errors "
logp_pcis:     .asciz "stor: "
logp_colon:    .asciz ":"
logp_sp1:      .asciz " "
logp_none:     .asciz "none"
logp_ahci:     .asciz "ahci: "
logp_ahn:      .asciz "none\r\n"
logp_mbz:      .asciz " MB\r\n"
logp_ard:      .asciz "ahci-rd: lba0 "
logp_rde:      .asciz "read FAILED\r\n"
logp_pi:       .asciz "PI "
logp_usb:      .asciz "usb: "
logp_usb_bar:  .asciz " bar0="
logp_uhci:     .asciz "UHCI"
logp_ohci:     .asciz "OHCI"
logp_ehci:     .asciz "EHCI"
logp_xhci_t:   .asciz "xHCI"
logp_usb_q:    .asciz "USB?"
logp_xhci:     .asciz "xhci: slots="
logp_xh_p:     .asciz " ports="
logp_xh_cc:    .asciz " conn="
logp_ehci2:    .asciz "ehci: "
logp_eh_p:     .asciz " ports="
logp_ehd:      .asciz "ehci-dev: "
logp_ehcl:     .asciz " class "
logp_hub:      .asciz "usb-hub: ports="
logp_hub_c:    .asciz " conn="
logp_hid:      .asciz "usb-hid: "
logp_dn:       .asciz "ehci-dn: pstat="
logp_ep:       .asciz "usb-ep: ep="
logp_ep_m:     .asciz " mps="
logp_ep_i:     .asciz " int="
logp_ep_c:     .asciz " cfg="
logp_rep:      .asciz "usb-rep: "
logp_hb:       .asciz "usb-poll: tok="
logp_proto:    .asciz " proto="
logp_mxy:      .asciz " mxy="
logp_compl:    .asciz " c="
logp_scan:     .asciz "usb-scan: skip="
logp_scan_p:   .asciz " port="
logp_scan_e:   .asciz " ep="
logp_kbd:      .asciz "usb-kbd: "
logp_kbdep:    .asciz "usb-kbd-ep: ep="
logp_kbhb:     .asciz "usb-kbd-hb: tok="
logp_push:     .asciz " p="
logp_ht:       .asciz " ht="
logp_ukey:     .asciz "usb-key a="
logp_leg:      .asciz "usb-leg sup="
logp_leg2:     .asciz " ctl="
logp_tok:      .asciz " tok="
logp_sts:      .asciz " sts="
logp_ehdbg:    .asciz "ehci-dbg: port="
logp_ehsts:    .asciz " sts="
logp_eht0:     .asciz " t0="
logp_eht2:     .asciz " t2="
logp_atapi:    .asciz "ATAPI\r\n"
logp_acap:     .asciz "atapi-cap: "
logp_blk:      .asciz " blocks\r\n"
logp_nomed:    .asciz "no media\r\n"
logm_wd:       .asciz "watchdog: killed a runaway agent\r\n"
logm_restore:  .asciz "tasks: restored from disk\r\n"
msg_persisted: .asciz "persist: task results written to disk (survive reboot).\r\n"
msg_abless_ok: .asciz "ahcibless: SATA disk dedicated to TannX OS (marker at LBA 256).\r\nPersist/reboot now save task results here; the next boot restores them.\r\n"
msg_abless_warn:.asciz "ahcibless WRITES the TannX OS marker to LBA 256 of the SATA disk.\r\nOnly do this on a disk you dedicate to TannX OS - it is destructive.\r\nRe-run as: ahcibless confirm\r\n"
msg_abless_nothdd:.asciz "ahcibless: the AHCI device is not a writable SATA HDD (ATAPI?).\r\n"
msg_net_mac:   .asciz " MAC "
msg_net_none:  .asciz "No supported NIC (RTL8139/e1000/RTL8168/virtio-net). PCI Ethernet controllers found:\r\n"
msg_net_pci:   .asciz "  net @bus "
msg_lspci:     .asciz "PCI devices (bus:dev.func vendor:device class):\r\n"
msg_ahci_h:    .asciz "AHCI: "
msg_ahci_model:.asciz "model "
msg_ahci_sect: .asciz "  sectors "
msg_ahci_mb:   .asciz " ("
msg_ahci_mbe:  .asciz " MB)\r\n"
msg_ahci_no:   .asciz "no AHCI controller\r\n"
msg_ahci_np:   .asciz "controller present, no active SATA port\r\n"
msg_ahci_ie:   .asciz "IDENTIFY failed (controller/disk not ready)\r\n"
msg_ahci_atapi:.asciz "  ATAPI (optical/packet device)\r\n"
msg_ahci_cap:  .asciz "  media: "
msg_ahci_blocks:.asciz " blocks ("
msg_ahci_nomedia:.asciz "  (no media / drive not ready)\r\n"
msg_cdread_u:  .asciz "usage: cdread <lba-hex>  (reads one 2048-byte block)\r\n"
msg_cd_nota:   .asciz "cdread: the AHCI device is not ATAPI (use aread)\r\n"
msg_cd_err:    .asciz "cdread: read failed (no media / bad LBA)\r\n"
msg_aread_u:   .asciz "usage: aread <lba-hex>\r\n"
msg_aread_e:   .asciz "aread: read failed\r\n"
msg_awrite_u:  .asciz "usage: awrite <lba-hex> <pattern-hex32>  (writes 1 sector!)\r\n"
msg_awrite_ok: .asciz "awrite: sector written\r\n"
msg_net_pci2:  .asciz "  vendor:device "
msg_nw_ok:     .asciz "Wish broadcast over UDP (255.255.255.255:4711).\r\n"
msg_nw_ack:    .asciz "netwish: delivered (ack from dev box).\r\n"
msg_nw_noack:  .asciz "netwish: no ack - is wishd running on the dev box?\r\n"
msg_nw_usage:  .asciz "Usage: netwish <text>\r\n"
kb_de_str: .asciz "de"
kb_us_str: .asciz "us"
cs_alloc:  .asciz "alloc"
cs_free:   .asciz "free"
cs_hello:  .asciz "hello"
cs_reboot: .asciz "reboot"
cs_halt:   .asciz "halt"
cs_poweroff: .asciz "poweroff"

# Status line
stat_txt1: .asciz " TannX OS v2.87  uptime:"
stat_txt2: .asciz "s  agents:"
stat_txt_t:.asciz "  open:"
stat_txt3: .asciz "  threads:"

# Texts
# Boot logo: generated by logo/mklogo.py (CP437 half blocks + shades, the
#   colours as 0x01 <attr> escapes for puts_attr). make LOGO=A|B|C picks it.
banner:
.ifdef LOGO_B
    .include "logo/banner-B.inc"
.else
.ifdef LOGO_C
    .include "logo/banner-C.inc"
.else
    .include "logo/banner-A.inc"
.endif
.endif

msg_welcome:                     # puts_attr string: grey text, 'help' in white
    .byte 0x01, 0x07
    .ascii "Welcome to TannX OS! No BIOS from here on. '"
    .byte 0x01, 0x0f
    .ascii "help"
    .byte 0x01, 0x07
    .asciz "' shows everything.\r\n\r\n"

help_text:
    .ascii "TannX OS - the agents do the work:\r\n"
    .ascii "  chain commands with ';'  e.g.  spawn math; task math 6 * 7; tick\r\n"
    .ascii "  spawn <type>  - start an agent. type: math | scan | count | prime | gcd |\r\n"
    .ascii "                    fault (crash test; the agent dies, the OS lives) | ask\r\n"
    .ascii "  agents | ps   - agents with type, status, statistics\r\n"
    .ascii "  top           - live agent view (1 s refresh), 'q' quits\r\n"
    .ascii "  task <...>    - queue a task:\r\n"
    .ascii "                    task math <a> <op> <b>   (e.g. task math 1337 * 42)\r\n"
    .ascii "                    task scan <hexaddr>      (memory checksum)\r\n"
    .ascii "                    task count <n>           (sum 1..n)\r\n"
    .ascii "                    task prime <n>           (n-th prime)\r\n"
    .ascii "                    task gcd <a> <b>         (greatest common divisor)\r\n"
    .ascii "                    task count|prime @<id>    (pipeline: use task <id>'s result)\r\n"
    .ascii "  tasks | queue - show tasks + results\r\n"
    .ascii "  tick         - snapshot of the task queue\r\n"
    .ascii "  run [net]    - launch the ring-3 C program (video player; 'run net' =\r\n"
    .ascii "                  userspace TCP/IP: DHCP, DNS, ping, HTTP GET off the net)\r\n"
    .ascii "  auto          - (deprecated no-op) agents always run in the background\r\n"
    .ascii "  kill <0-7>    - stop an agent   reap - free idle agents + clear done tasks\r\n"
    .ascii "System:\r\n"
    .ascii "  calc <expr>   - integer calculator: + - * / % and ( ), e.g. calc (2+3)%4\r\n"
    .ascii "  gfx           - framebuffer graphics demo (line/circle primitives)\r\n"
    .ascii "  play [notes]  - PC-speaker melody (letters a-g), e.g. play cdefgab\r\n"
    .ascii "  date | time   - real date/time from the RTC chip\r\n"
    .ascii "  dump <hex>    - 128 bytes of memory - full 32-bit addresses (dump b8000!)\r\n"
    .ascii "  cpuid         - CPU vendor and model\r\n"
    .ascii "  cpu           - CPU core/thread count + scheduling model\r\n"
    .ascii "  smpon         - WAKE the other cores (off at boot: a\r\n"
    .ascii "                    faulting AP boot-loops real hardware - opt in!)\r\n"
    .ascii "  smp           - multi-core telemetry: cores woken + work done\r\n"
    .ascii "  pbench [N]    - count primes up to N on 1 core vs all cores (speed-up)\r\n"
    .ascii "  sysinfo       - CPU, mainboard (SMBIOS) and RAM of this machine\r\n"
    .ascii "  display       - firmware framebuffer geometry (resolution, fb base, size)\r\n"
    .ascii "  cputest [N]   - CPU ALU benchmark, N x 50M iters (default 10)\r\n"
    .ascii "  ramtest [MB]  - test MB of RAM, default 16, capped to real RAM (E820)\r\n"
    .ascii "  hwtest [MB]   - full diag: CPU torture+faultcheck, cache/mem bw, RAM\r\n"
    .ascii "  selftest      - run CPU + RAM tests, results to dmesg (also remote: SELFTEST)\r\n"
    .ascii "  smart | disktest - drive health (SMART) / read speed test\r\n"
    .ascii "  temp          - CPU temperature (Intel digital thermal sensor)\r\n"
    .ascii "  (test the protection: 'dump 0' recovers; 'task scan 0' and\r\n"
    .ascii "   'task scan b8000' each cost one ring-3 agent - nothing more)\r\n"
    .ascii "  wish <text>   - whatever is missing: wish for it, the LLM\r\n"
    .ascii "                  builds it next session ('wishes' lists, needs diskon)\r\n"
    .ascii "  sendwishes    - beam pending wishes to the dev box over COM1\r\n"
    .ascii "  net           - NIC status/probe (RTL8139|e1000|RTL8168|virtio)  netwish <text>\r\n"
    .ascii "  offload <job> - ship a compute job to the proxy (mandel <n> | sum <n>)\r\n"
    .ascii "  llm [@be] <text> - ask an LLM (llm-proxy.py on the dev box); @be picks\r\n"
    .ascii "                    the model: @claude @api @openai @ollama  (@list shows)\r\n"
    .ascii "  llmscript <slot> <task> - the LLM WRITES a script into the slot (needs\r\n"
    .ascii "                    diskon); run it with 'script <slot>'\r\n"
    .ascii "  spawn ask     - the LLM AGENT: claims 'task ask <slot>' work, answers\r\n"
    .ascii "                    the slot's text INTO the slot (load <slot> shows it)\r\n"
    .ascii "  sound         - AC97 tone: detect, init, 1 s of 440 Hz over PCM-out DMA\r\n"
    .ascii "  hda           - Intel HDA tone: the ring-3 C driver, same idea\r\n"
    .ascii "  script <slot> - run an AgentFS slot as commands (','/newline separate;\r\n"
    .ascii "                    save 4 spawn prime, task prime 100, tasks); ESC aborts\r\n"
    .ascii "  sleep <n>     - pause n ticks (18 = 1 s) - script pacing\r\n"
    .ascii "  if <L> =|!|<|> <R> <cmd> - branch; L/R = task#, $ (reg A), # (reg B), or @<t>\r\n"
    .ascii "  repeat <n>    - as a script's last line: run the slot n times total\r\n"
    .ascii "  set / setb <n>|@<t>|+|-|*|/ <n> - two registers; '$'=A, '#'=B substitute\r\n"
    .ascii "  waittask <t>  - block until agent task t is done (pipeline join, not sleep)\r\n"
    .ascii "  waitall       - block until ALL agent tasks are done (fan-out join)\r\n"
    .ascii "  wait          - block until the last 'run'-style program exits\r\n"
    .ascii "  autopilot [m] - the OS flies itself: ask the LLM, do it, repeat\r\n"
    .ascii "                    (slot 7 scratch, needs diskon; ESC/Ctrl+C stops)\r\n"
    .ascii "  lspci         - list all PCI devices with class (storage: IDE/SATA/NVMe)\r\n"
    .ascii "  ahci          - detect the SATA/AHCI disk + IDENTIFY (model, size)\r\n"
    .ascii "  aread <lba>   - read one sector over AHCI and hexdump it\r\n"
    .ascii "  awrite <l> <p>- write one AHCI sector, filled with pattern p (destructive)\r\n"
    .ascii "  cdread <lba>  - read one 2048-byte block from the ATAPI/optical device\r\n"
    .ascii "  ahcibless     - dedicate a SATA disk to TannX OS persistence (needs 'confirm')\r\n"
    .ascii "  inbox         - last text received on UDP :4713 (control needs REMOTE_CTL)\r\n"
    .ascii "Disk (own ATA driver, LBA 257-264):\r\n"
    .ascii "  save <0-7> <text> - write slot (run 'diskon' first)\r\n"
    .ascii "  load <0-7> | ls   - read slot / list all slots\r\n"
    .ascii "  del <0-7>         - clear slot   diskon - lift write protection\r\n"
    .ascii "  persist           - save task results to disk (survive reboot; needs diskon)\r\n"
    .ascii "  mem | uptime  - memory / runtime   dmesg - kernel event log\r\n"
    .ascii "  heap | alloc <n> | free <hex> - kernel heap (kmalloc/kfree)\r\n"
    .ascii "  color <1-f>   - color   beep - sound   lines - scroll test\r\n"
.ifndef MINIMAL
    .ascii "  invaders      - play Space Invaders (a/d or arrows, space fires, q quits)\r\n"
.endif
    .ascii "  clear | cls   - clear   reboot | halt | poweroff - restart / stop / ACPI off\r\n"
    .ascii "  echo <text>   - print   arrow-up - recall last input\r\n"
    .ascii "  banner <text> - print the text inside a box frame\r\n"
    .asciz "  kbd <de|us>   - keyboard layout (boot default: us)\r\n"

about_text:
    .ascii "TannX OS v2.87 - PM, multitasking, paging, userspace:\r\n"
    .ascii "  * every agent is its own THREAD with its own stack -\r\n"
    .ascii "    the timer interrupt shares the CPU (preemptive, round-robin)\r\n"
    .ascii "  * own GDT (flat model) + own IDT (256 gates)\r\n"
    .ascii "  * PIC remapped: IRQ0-15 -> INT 0x20-0x2F\r\n"
    .ascii "  * own paging (0-32 MB), page 0 unmapped = NULL protection;\r\n"
    .ascii "    page faults kill only the guilty thread, never the system\r\n"
    .ascii "  * agents run in RING 3: syscalls (INT 0x30) are their only\r\n"
    .ascii "    door - kernel memory, I/O and hlt/cli are off limits\r\n"
    .ascii "  * CPU exceptions 0-31 report their number instead of crashing\r\n"
    .ascii "  * all drivers homemade: VGA, keyboard, COM1, ATA disk, timer\r\n"
    .ascii "  * agents with skills pull tasks from the queue\r\n"
    .ascii "  The BIOS only loaded us - past the jump we are on our own.\r\n"
    .asciz "  made by Tannenbaum Media\r\n"

msg_unknown:    .asciz "Unknown command. 'help' lists all commands.\r\n"
msg_more:       .asciz "-- more (any key, q quits) --"
msg_more_clr:   .asciz "\r                              \r"
msg_alloc_usage:.asciz "Usage: alloc <bytes>\r\n"
msg_alloc1:     .asciz "alloc: "
msg_alloc2:     .asciz " bytes at 0x"
msg_heapfull:   .asciz "alloc: no room in the heap.\r\n"
msg_free_usage: .asciz "Usage: free <hexaddr>\r\n"
msg_free_ok:    .asciz "freed.\r\n"
msg_free_bad:   .asciz "ERROR: not a valid heap block (magic missing).\r\n"
msg_free_dbl:   .asciz "ERROR: double free detected - block was already free.\r\n"
msg_heap_hdr:   .asciz "Kernel heap (first-fit free list):\r\n"
msg_heap_at:    .asciz "  0x"
msg_heap_sz:    .asciz ": "
msg_heap_b:     .asciz " bytes, "
msg_heap_used:  .asciz "used"
msg_heap_fr:    .asciz "free"
msg_heap_corr:  .asciz "  CORRUPT - magic missing at 0x"
msg_banner_usage:.asciz "Usage: banner <text>\r\n"
msg_kbd_usage:  .asciz "Usage: kbd <de|us>\r\n"
msg_wish_usage: .asciz "Usage: wish <text>   (run 'diskon' first; 'wishes' lists all)\r\n"
msg_wish_ok:    .asciz "Wish stored on disk. The next LLM session will build it.\r\n"
msg_wish_full:  .asciz "Wish list full (8 slots) - the LLM has work to do. 'wishes' shows it.\r\n"
msg_wish_li:    .asciz "  wish ["
msg_wish_none:  .asciz "No pending wishes. Make one: wish <text>\r\n"
msg_snake_over: .asciz "GAME OVER - the wall (or you) won. Score: "
msg_snake_quit: .asciz "snake: quit. Score: "
msg_inv_win:   .asciz "*** YOU WIN! Earth is safe. ***\r\n"
msg_inv_over:  .asciz "GAME OVER - the invaders got you.\r\n"
msg_inv_quit:  .asciz "invaders: quit.\r\n"
msg_inv_score: .asciz "Aliens destroyed: "
msg_paused:    .asciz "= PAUSED =  [P] resume  [Q] quit"
msg_game_again:.asciz "\r\n   [SPACE] play again    [Q] quit\r\n"
msg_snake_title:.asciz "\r\n\r\n\r\n        S N A K E\r\n        =========\r\n\r\n"
msg_snake_help:.asciz "        Steer with W A S D or the arrow keys.\r\n        Eat the * food to grow longer.\r\n        Don't hit the wall or your own tail.\r\n        P pauses, Q quits.\r\n\r\n        [SPACE] start      [Q] quit\r\n"
msg_inv_title: .asciz "\r\n\r\n\r\n        S P A C E   I N V A D E R S\r\n        ===========================\r\n\r\n"
msg_inv_help:  .asciz "        Move with A / D or the arrow keys, SPACE fires.\r\n        Clear every alien, dodge the bombs.\r\n        Shoot the red UFO for a bonus, grab the & power-ups.\r\n        P pauses, Q quits.\r\n\r\n        [SPACE] start      [Q] quit\r\n"
msg_hud_score: .asciz "SCORE "
msg_hud_wave:  .asciz "WAVE "
msg_hud_lives: .asciz "LIVES "
msg_hud_len:   .asciz "LEN "
msg_kbd_de:     .asciz "Keyboard layout: German (QWERTZ). Umlauts have no ASCII - keys stay dead.\r\n"
msg_kbd_us:     .asciz "Keyboard layout: US.\r\n"
msg_top_hdr:    .asciz "top - live agents, 1 s refresh. 'q' quits.\r\n"
msg_top_sep:    .asciz "--- top ---\r\n"
msg_full:       .asciz "No free agent slots (max. 8).\r\n"
msg_agent_l:    .asciz "Agent ["
msg_spawn2:     .asciz "] '"
msg_spawn_t:    .asciz "' ("
msg_spawn3:     .asciz ") agent ready. Feed it work with 'task'.\r\n"
msg_spawn_usage:.asciz "Usage: spawn <math|scan|count|prime|gcd|fault|ask>\r\n"
msg_kill2:      .asciz "] stopped.\r\n"
msg_run_l:      .asciz "[run] ring-3 program started (kill it to stop).\r\n"
msg_kill_usage: .asciz "Usage: kill <0-7>\r\n"
msg_nosuch:     .asciz "No agent in that slot.\r\n"
msg_reap:       .asciz "reaped "
msg_reap2:      .asciz " idle agent(s); cleared finished tasks.\r\n"
msg_li1:        .asciz "  ["
msg_li2:        .asciz "] "
msg_li4:        .asciz "  completed: "
msg_sp_paren:   .asciz " ("
msg_paren_sp:   .asciz ") "
msg_sp:         .asciz " "
msg_n:          .asciz "n="
msg_at:         .asciz "@0x"
msg_arrow:      .asciz " -> "
msg_dep:        .asciz " <-t"
msg_res:        .asciz " = "
msg_calc_eq:    .asciz "= "
msg_calc_err:   .asciz "calc: bad expression (use + - * / and parentheses)\r\n"
msg_gfx_notxt:  .asciz "gfx: needs the framebuffer (no graphics on this boot)\r\n"
msg_tick:       .asciz "--- scheduler tick ---\r\n"
msg_noagents:   .asciz "No agents active. Start one with 'spawn math'.\r\n"
msg_notasks:    .asciz "No tasks. Create one, e.g. 'task math 1337 * 42'.\r\n"
msg_task_full:  .asciz "Task queue full (max. 8).\r\n"
msg_task_added: .asciz "Task ["
msg_task_added2:.asciz "] queued. A matching agent will grab it on its own.\r\n"
msg_task_usage: .asciz "Usage: task math <a> <op> <b> | scan <hex> | count <n> | prime <n> | gcd <a> <b>\r\n"
msg_saved:      .asciz "Saved - via our own ATA driver, no BIOS.\r\n"
msg_deleted:    .asciz "Slot cleared.\r\n"
msg_locked:     .ascii "Write protection active. 'diskon' enables save/del.\r\n"
                .asciz "CAUTION on real hardware: writes LBA 257-264 of the FIRST disk (only if it\r\ncarries the AGENTOS-MEDIUM marker at LBA 256; otherwise slots stay in RAM).\r\n"
msg_armed:      .asciz "Disk writes ARMED (LBA 257-264). Harmless in QEMU - lands in the image.\r\n"
marker_str:     .ascii "AGENTOS-MEDIUM"   # on-disk medium marker at LBA 256: a PROTOCOL
                                          #   CONSTANT (Makefile stamps it) - never rename
msg_ramfs:      .asciz "diskon: no TannX OS medium (no marker at LBA 256) - slots are RAM-backed.\r\nWrites land in RAM (lost on reboot); your disk is untouched. Persist: make usb-hybrid.\r\n"
msg_save_usage: .asciz "Usage: save <0-7> <text>\r\n"
msg_load_usage: .asciz "Usage: load <0-7>\r\n"
msg_del_usage:  .asciz "Usage: del <0-7>\r\n"
msg_slot_empty: .asciz "Slot is empty.\r\n"
msg_script_usage: .asciz "usage: script <slot 0-7>  (runs the slot text as commands)\r\n"
msg_sleep_usage:  .asciz "usage: sleep <ticks>  (18 ticks = 1 s, capped at 1080)\r\n"
msg_chain_abort:  .asciz "\r\n[chain aborted]\r\n"
msg_wait_abort:   .asciz "\r\n[remote abort: stuck program killed, chain dropped]\r\n"
msg_wait_timeout: .asciz "\r\n[wait: program stuck (no progress) - killed, autopilot recovers]\r\n"
msg_if_usage:     .asciz "usage: if <task|$|#> <=|!|<|>> <n|@task|$|#> <command>\r\n"
msg_repeat_usage: .asciz "usage: repeat <n>  (last line of a script - reruns its slot)\r\n"
msg_waittask_usage: .asciz "usage: waittask <task 0-7>  (block until the agent task is done)\r\n"
msg_waittask_to:  .asciz "\r\n[waittask: not done in time - result may be stale]\r\n"
msg_waitall_to:   .asciz "\r\n[waitall: tasks not done in time - results may be stale]\r\n"
msg_disp1:    .asciz "display: "
msg_disp_x:   .asciz " x "
msg_disp_sl:  .asciz ", "
msg_disp_pl:  .asciz " px/line, fb @0x"
msg_disp_kb:  .asciz " KB (32bpp)\r\n"
msg_disp_modes: .asciz "  modes:"
msg_disp_sp:  .asciz " "
msg_disp_xx:  .asciz "x"
msg_disp_none: .asciz "display: text mode (no linear framebuffer)\r\n"
msg_set:          .asciz "reg = "
msg_set_usage:    .asciz "usage: set|setb <n> | @<task> | +|-|*|/ <n>   ('$'=A, '#'=B)\r\n"
msg_ls_empty:   .asciz "- empty -"
msg_load1:      .asciz "Slot ["
msg_load2:      .asciz "]: "
msg_diskio:     .asciz "Disk error: no ATA drive reachable (AHCI mode? USB boot?).\r\n"
msg_time:       .asciz "Time (UTC): "
msg_date:       .asciz "Date: "
msg_colon:      .asciz ":"
msg_dot:        .asciz "."
msg_20:         .asciz "20"
msg_cpu:        .asciz "CPU: "
msg_cpu_lp:     .asciz "CPU logical processors: "
msg_cpu_smp:    .asciz "Threads (agents + shell) run preemptively on the boot core;\r\n'smp' shows the other cores woken at boot.\r\n"
msg_smp1:       .asciz "SMP: cores "
msg_smp2:       .asciz "  online "
msg_smp4:       .asciz "Try 'pbench' - the same prime-count on 1 core vs all cores.\r\n"
msg_smp5:       .asciz "thread-runs per core [id]count: "
msg_pb1:        .asciz "pbench: counting primes up to "
msg_pb2:        .asciz "  1 core:  primes="
msg_pb3:        .asciz "  ticks="
msg_pb4:        .asciz "  all cores: primes="
msg_selftest:   .asciz "self-test queued - CPU + RAM results go to dmesg.\r\n"
msg_cores:      .asciz "  logical CPUs "
msg_feat:       .asciz "  features:"
# CPU feature flags: {bit, name}, list ends with 0xFF. EDX (leaf 1) then ECX.
edx_tbl:
    .byte 23; .asciz "MMX"
    .byte 25; .asciz "SSE"
    .byte 26; .asciz "SSE2"
    .byte 28; .asciz "HTT"
    .byte 0xff
ecx_tbl:
    .byte 20; .asciz "SSE4.2"
    .byte 25; .asciz "AES"
    .byte 28; .asciz "AVX"
    .byte 31; .asciz "HV"
    .byte 0xff
msg_si_cpu:     .asciz "CPU:    "
msg_si_bios:    .asciz "BIOS:   "
msg_si_sys:     .asciz "System: "
msg_si_board:   .asciz "Board:  "
msg_si_ram:     .asciz "RAM:    "
msg_si_disk:    .asciz "Disk:   "
msg_si_gpu:     .asciz "GPU:    "
msg_si_nic:     .asciz "NIC:    "
msg_si_none:    .asciz "none"
msg_si_thr:     .asciz " ("
msg_si_thr2:    .asciz " threads)"
msg_ct1:        .asciz "CPU test (cputest [N] = N x 50M ALU iters):\r\n"
msg_ct_it:      .asciz "M iters, "
msg_ct_cyc:     .asciz "\r\n  "
msg_ct_cyc2:    .asciz " cycles (RDTSC), ~"
msg_ct_mhz:     .asciz " MHz, checksum 0x"
msg_ct_qmhz:    .asciz "? MHz (no timer), checksum 0x"
msg_ct_bw:      .asciz "  memory: "
msg_ct_bw2:     .asciz " MB/s read\r\n"
msg_ct_bwf:     .asciz "fast (<1 tick)\r\n"
msg_eht_ok:     .asciz "ehci device: "
msg_eht_cl:     .asciz " class "
msg_colon2:     .asciz ":"
msg_eht_none:   .asciz "ehcitest: no EHCI device found\r\n"
msg_eht_err:    .asciz "ehcitest: control transfer failed\r\n"
msg_hw_hdr:     .asciz "=== TannX OS hardware test ===\r\n"
msg_hw_done:    .asciz "=== hardware test complete ===\r\n"
msg_hw_cpu:     .asciz "CPU:    "
msg_hw_mi:      .asciz " Miter/s, "
msg_hw_mhz:     .asciz " MHz, "
msg_hw_stable:  .asciz "compute STABLE\r\n"
msg_hw_fault:   .asciz "compute FAULT!\r\n"
msg_hw_bw:      .asciz "cache/mem read bandwidth:\r\n"
msg_bw_l1:      .asciz "  16KB  (L1):  "
msg_bw_l2:      .asciz "  256KB (L2):  "
msg_bw_l3:      .asciz "  4MB   (L3):  "
msg_bw_ram:     .asciz "  16MB  (RAM): "
msg_hw_mbs:     .asciz " MB/s\r\n"
msg_hw_bwfast:  .asciz "fast\r\n"
msg_hw_ram:     .asciz "RAM:    testing "
msg_hw_rammb:   .asciz " MB  "
msg_hw_ramerr:  .asciz "  errors: "
msg_hw_rampass: .asciz "  PASS\r\n"
msg_hw_ramfail: .asciz "  FAIL\r\n"
logp_hw:        .asciz "hwtest: cpu "
logp_hw_mi:     .asciz " Miter/s "
logp_hw_mhz:    .asciz " MHz "
logp_hw_flt:    .asciz "FAULT "
logp_hw_stab:   .asciz "stable "
logp_hw_ram:    .asciz "ram "
logp_hw_mb:     .asciz "MB err "
logp_hw_bw:     .asciz " bw(MB/s) L1/L2/L3/RAM "
msg_rt1:        .asciz "RAM test (ramtest [MB]): 6 patterns + address + moving inversions\r\n"
msg_rt2:        .asciz "\r\nRAM test: "
msg_rt_mb:      .asciz " MB tested, errors: "
msg_rt_ok:      .asciz "  -> PASS\r\n"
msg_rt_bad:     .asciz "  -> FAIL (bad RAM!)\r\n"
msg_sm_health:  .asciz "SMART health: "
msg_sm_ok:      .asciz "OK\r\n"
msg_sm_fail:    .asciz "FAILING - back up now!\r\n"
msg_sm_none:    .asciz "SMART: no drive / not supported (AHCI mode?).\r\n"
msg_sm_temp:    .asciz "  Temperature:         "
msg_sm_c:       .asciz " C\r\n"
msg_sm_hours:   .asciz "  Power-on hours:      "
msg_sm_realloc: .asciz "  Reallocated sectors: "
msg_sm_pending: .asciz "  Pending sectors:     "
msg_dt1:        .asciz "Disk test: reading 4000 sectors (2 MB)\r\n"
msg_dt2:        .asciz "\r\n  2 MB read, errors: "
msg_dt3:        .asciz ", "
msg_dt_kbs:     .asciz " KB/s\r\n"
msg_dt_fast:    .asciz "<1 tick (very fast)\r\n"
msg_temp1:      .asciz "CPU temperature: "
msg_temp_c:     .asciz " C\r\n"
msg_temp_na:    .asciz "CPU temperature: not available (no Intel DTS / QEMU).\r\n"
msg_inbox0:     .asciz "inbox: empty (text sent to UDP :4713 shows up here).\r\n"
msg_inbox1:     .asciz "inbox: "
nd_pfx:         .asciz "DBG "
nd_l_cr:        .asciz "DBG CR="
nd_l_isr:       .asciz " ISR="
nd_l_rcr:       .asciz " RCR="
nd_l_phy:       .asciz " PHY="
nd_l_i:         .asciz " i="
nd_l_rxd:       .asciz "\r\nrxd"
nd_l_sp:        .asciz " "
nd_l_rx:        .asciz "  rx="
nd_l_hit:       .asciz " hit="
msg_nd_no:      .asciz "nicdbg: no RTL8168\r\n"
msg_si_dsz:     .asciz " ("
msg_si_dsz2:    .asciz ")"
msg_si_sp:      .asciz " "
msg_si_mb:      .asciz " MB"
msg_si_mbx:     .asciz " MB (approx, CMOS)\r\n"
msg_si_comma:   .asciz ", "
msg_si_at:      .asciz " @ "
msg_si_mhz:     .asciz " MT/s"
msg_si_nosmb:   .asciz "System: (no SMBIOS table found)\r\n"
msg_ddr2:       .asciz "DDR2"
msg_ddr3:       .asciz "DDR3"
msg_ddr4:       .asciz "DDR4"
msg_ddr_x:      .asciz "RAM"
empty_str:      .asciz ""
msg_model:      .asciz "Model: "
msg_dump_usage: .asciz "Usage: dump <hexaddr>   (e.g. dump 7c00, dump b8000)\r\n"
msg_colon_sp:   .asciz ": "
msg_bar:        .asciz " |"
msg_line:       .asciz "Line "
msg_up1:        .asciz "Uptime: "
msg_up2:        .asciz " ticks (~"
msg_up3:        .asciz " seconds)\r\n"
msg_mem1:       .asciz "Conventional memory: "
msg_mem2:       .asciz " KB, extended (>1MB): "
msg_mem3:       .asciz " KB\r\n"
msg_mem_e820:   .asciz "  usable (E820): "
msg_mem_heap:   .asciz "  kernel heap: "
msg_mem_mb:     .asciz " MB\r\n"
msg_mem_atp:    .asciz "  autopilot round "
msg_mem_mis2:   .asciz " mission "
msg_color_ok:   .asciz "Color set.\r\n"
msg_color_usage:.asciz "Usage: color <1-f>   (e.g. color b = cyan)\r\n"
msg_rnd:        .asciz "Random number: "
msg_beep:       .asciz "Beep! (in QEMU only audible with an audio option)\r\n"
msg_snd_none:   .asciz "AC97: no controller (QEMU: -audiodev none,id=ad0 -device AC97,audiodev=ad0)\r\n"
msg_snd_found:  .asciz "AC97: NAM 0x"
msg_snd_nabm:   .asciz " NABM 0x"
msg_snd_nordy:  .asciz "AC97: codec not ready\r\n"
msg_snd_play:   .asciz "AC97: playing 440 Hz, 1 s, 48 kHz 16-bit stereo ...\r\n"
msg_snd_prog:   .asciz "AC97: progress civ="
msg_snd_picb:   .asciz " picb="
msg_snd_done:   .asciz "AC97: done, sr=0x"
msg_auto_info:  .asciz "'auto' is deprecated and does nothing: agents always run in the background.\r\nEvery agent is its own thread; the timer shares the CPU.\r\n"
msg_gp1:        .asciz "\r\n*** PROTECTION FAULT (#GP) - privileged instruction/access from ring 3"
msg_exc_iso:    .asciz "\r\n*** FAULT (#DE/#UD/#OF/#BR) in ring 3 - agent killed"
msg_pf1:        .asciz "\r\n*** PAGE FAULT at 0x"
msg_pf_ag1:     .asciz " - agent ["
msg_pf_ag2:     .asciz "' shot down, task -> ERROR. System keeps running.\r\n"
msg_pf_sh:      .asciz " in the shell - caught, back to the prompt.\r\n"
msg_pp1:        .asciz " ("
msg_pp2:        .asciz "%)"
msg_pct:        .asciz "%"
msg_hello:      .asciz "Hello from ring 0! The agents send humble greetings from ring 3. :)\r\n"
msg_reboot:     .asciz "Rebooting...\r\n"
msg_exc:        .asciz "\r\n*** CPU EXCEPTION #"
msg_exc_thr:    .asciz " thread="
msg_exc2:       .asciz " - system halted ***\r\n"
msg_halt:       .asciz "System halted. You can close the VM now.\r\n"
msg_poweroff:   .asciz "ACPI power off...\r\n"

# --- 8x16 font for the framebuffer console -------------------
# ASCII 32-126, 16 bytes per glyph, MSB = left pixel. Extracted once
# from the Lat15-Fixed16 PSF console font (pure data, no compiler).
# The CP437 graphics the boot logo uses follow in font_extra.
font8x16:
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00   # ' '
    .byte 0x00,0x00,0x00,0x00,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x00,0x08,0x08,0x00,0x00   # '!'
    .byte 0x00,0x00,0x22,0x22,0x22,0x22,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00   # '"'
    .byte 0x00,0x00,0x00,0x00,0x12,0x12,0x12,0x7e,0x24,0x24,0x7e,0x48,0x48,0x48,0x00,0x00   # '#'
    .byte 0x00,0x00,0x00,0x00,0x08,0x3e,0x49,0x48,0x38,0x0e,0x09,0x49,0x3e,0x08,0x00,0x00   # '$'
    .byte 0x00,0x00,0x00,0x00,0x31,0x4a,0x4a,0x34,0x08,0x08,0x16,0x29,0x29,0x46,0x00,0x00   # '%'
    .byte 0x00,0x00,0x00,0x00,0x1c,0x22,0x22,0x14,0x18,0x29,0x45,0x42,0x46,0x39,0x00,0x00   # '&'
    .byte 0x00,0x00,0x08,0x08,0x08,0x08,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00   # "'"
    .byte 0x00,0x00,0x00,0x04,0x08,0x08,0x10,0x10,0x10,0x10,0x10,0x10,0x08,0x08,0x04,0x00   # '('
    .byte 0x00,0x00,0x00,0x20,0x10,0x10,0x08,0x08,0x08,0x08,0x08,0x08,0x10,0x10,0x20,0x00   # ')'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x08,0x49,0x2a,0x1c,0x2a,0x49,0x08,0x00,0x00,0x00   # '*'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x08,0x08,0x08,0x7f,0x08,0x08,0x08,0x00,0x00,0x00   # '+'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x08,0x08,0x10   # ','
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x3c,0x00,0x00,0x00,0x00,0x00,0x00   # '-'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00   # '.'
    .byte 0x00,0x00,0x00,0x00,0x02,0x02,0x04,0x08,0x08,0x10,0x10,0x20,0x40,0x40,0x00,0x00   # '/'
    .byte 0x00,0x00,0x00,0x00,0x18,0x24,0x42,0x46,0x4a,0x52,0x62,0x42,0x24,0x18,0x00,0x00   # '0'
    .byte 0x00,0x00,0x00,0x00,0x08,0x18,0x28,0x08,0x08,0x08,0x08,0x08,0x08,0x3e,0x00,0x00   # '1'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x02,0x0c,0x10,0x20,0x40,0x40,0x7e,0x00,0x00   # '2'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x02,0x1c,0x02,0x02,0x42,0x42,0x3c,0x00,0x00   # '3'
    .byte 0x00,0x00,0x00,0x00,0x04,0x0c,0x14,0x24,0x44,0x44,0x7e,0x04,0x04,0x04,0x00,0x00   # '4'
    .byte 0x00,0x00,0x00,0x00,0x7e,0x40,0x40,0x40,0x7c,0x02,0x02,0x02,0x42,0x3c,0x00,0x00   # '5'
    .byte 0x00,0x00,0x00,0x00,0x1c,0x20,0x40,0x40,0x7c,0x42,0x42,0x42,0x42,0x3c,0x00,0x00   # '6'
    .byte 0x00,0x00,0x00,0x00,0x7e,0x02,0x02,0x04,0x04,0x04,0x08,0x08,0x08,0x08,0x00,0x00   # '7'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x42,0x3c,0x42,0x42,0x42,0x42,0x3c,0x00,0x00   # '8'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x42,0x3e,0x02,0x02,0x02,0x04,0x38,0x00,0x00   # '9'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00   # ':'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x18,0x08,0x08,0x10,0x00   # ';'
    .byte 0x00,0x00,0x00,0x00,0x00,0x02,0x04,0x08,0x10,0x20,0x10,0x08,0x04,0x02,0x00,0x00   # '<'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x7e,0x00,0x00,0x00,0x7e,0x00,0x00,0x00,0x00   # '='
    .byte 0x00,0x00,0x00,0x00,0x00,0x40,0x20,0x10,0x08,0x04,0x08,0x10,0x20,0x40,0x00,0x00   # '>'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x02,0x04,0x08,0x08,0x00,0x08,0x08,0x00,0x00   # '?'
    .byte 0x00,0x00,0x00,0x00,0x1c,0x22,0x4a,0x56,0x52,0x52,0x52,0x4e,0x20,0x1e,0x00,0x00   # '@'
    .byte 0x00,0x00,0x00,0x00,0x18,0x24,0x24,0x42,0x42,0x7e,0x42,0x42,0x42,0x42,0x00,0x00   # 'A'
    .byte 0x00,0x00,0x00,0x00,0x7c,0x42,0x42,0x42,0x7c,0x42,0x42,0x42,0x42,0x7c,0x00,0x00   # 'B'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x40,0x40,0x40,0x40,0x42,0x42,0x3c,0x00,0x00   # 'C'
    .byte 0x00,0x00,0x00,0x00,0x78,0x44,0x42,0x42,0x42,0x42,0x42,0x42,0x44,0x78,0x00,0x00   # 'D'
    .byte 0x00,0x00,0x00,0x00,0x7e,0x40,0x40,0x40,0x7c,0x40,0x40,0x40,0x40,0x7e,0x00,0x00   # 'E'
    .byte 0x00,0x00,0x00,0x00,0x7e,0x40,0x40,0x40,0x7c,0x40,0x40,0x40,0x40,0x40,0x00,0x00   # 'F'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x40,0x40,0x4e,0x42,0x42,0x46,0x3a,0x00,0x00   # 'G'
    .byte 0x00,0x00,0x00,0x00,0x42,0x42,0x42,0x42,0x7e,0x42,0x42,0x42,0x42,0x42,0x00,0x00   # 'H'
    .byte 0x00,0x00,0x00,0x00,0x3e,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x3e,0x00,0x00   # 'I'
    .byte 0x00,0x00,0x00,0x00,0x1f,0x04,0x04,0x04,0x04,0x04,0x04,0x44,0x44,0x38,0x00,0x00   # 'J'
    .byte 0x00,0x00,0x00,0x00,0x42,0x44,0x48,0x50,0x60,0x60,0x50,0x48,0x44,0x42,0x00,0x00   # 'K'
    .byte 0x00,0x00,0x00,0x00,0x40,0x40,0x40,0x40,0x40,0x40,0x40,0x40,0x40,0x7e,0x00,0x00   # 'L'
    .byte 0x00,0x00,0x00,0x00,0x42,0x42,0x66,0x66,0x5a,0x5a,0x42,0x42,0x42,0x42,0x00,0x00   # 'M'
    .byte 0x00,0x00,0x00,0x00,0x42,0x62,0x62,0x52,0x52,0x4a,0x4a,0x46,0x46,0x42,0x00,0x00   # 'N'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x42,0x42,0x42,0x42,0x42,0x42,0x3c,0x00,0x00   # 'O'
    .byte 0x00,0x00,0x00,0x00,0x7c,0x42,0x42,0x42,0x7c,0x40,0x40,0x40,0x40,0x40,0x00,0x00   # 'P'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x42,0x42,0x42,0x42,0x5a,0x66,0x3c,0x03,0x00   # 'Q'
    .byte 0x00,0x00,0x00,0x00,0x7c,0x42,0x42,0x42,0x7c,0x48,0x44,0x44,0x42,0x42,0x00,0x00   # 'R'
    .byte 0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x40,0x30,0x0c,0x02,0x42,0x42,0x3c,0x00,0x00   # 'S'
    .byte 0x00,0x00,0x00,0x00,0x7f,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x00,0x00   # 'T'
    .byte 0x00,0x00,0x00,0x00,0x42,0x42,0x42,0x42,0x42,0x42,0x42,0x42,0x42,0x3c,0x00,0x00   # 'U'
    .byte 0x00,0x00,0x00,0x00,0x41,0x41,0x41,0x22,0x22,0x22,0x14,0x14,0x08,0x08,0x00,0x00   # 'V'
    .byte 0x00,0x00,0x00,0x00,0x42,0x42,0x42,0x42,0x5a,0x5a,0x66,0x66,0x42,0x42,0x00,0x00   # 'W'
    .byte 0x00,0x00,0x00,0x00,0x42,0x42,0x24,0x24,0x18,0x18,0x24,0x24,0x42,0x42,0x00,0x00   # 'X'
    .byte 0x00,0x00,0x00,0x00,0x41,0x41,0x22,0x22,0x14,0x08,0x08,0x08,0x08,0x08,0x00,0x00   # 'Y'
    .byte 0x00,0x00,0x00,0x00,0x7e,0x02,0x02,0x04,0x08,0x10,0x20,0x40,0x40,0x7e,0x00,0x00   # 'Z'
    .byte 0x00,0x00,0x00,0x0e,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x0e,0x00   # '['
    .byte 0x00,0x00,0x00,0x00,0x40,0x40,0x20,0x10,0x10,0x08,0x08,0x04,0x02,0x02,0x00,0x00   # '\\'
    .byte 0x00,0x00,0x00,0x70,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x70,0x00   # ']'
    .byte 0x00,0x00,0x18,0x24,0x42,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00   # '^'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x7f,0x00   # '_'
    .byte 0x00,0x20,0x10,0x08,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00   # '`'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x3c,0x42,0x02,0x3e,0x42,0x42,0x46,0x3a,0x00,0x00   # 'a'
    .byte 0x00,0x00,0x00,0x40,0x40,0x40,0x5c,0x62,0x42,0x42,0x42,0x42,0x62,0x5c,0x00,0x00   # 'b'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x3c,0x42,0x40,0x40,0x40,0x40,0x42,0x3c,0x00,0x00   # 'c'
    .byte 0x00,0x00,0x00,0x02,0x02,0x02,0x3a,0x46,0x42,0x42,0x42,0x42,0x46,0x3a,0x00,0x00   # 'd'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x7e,0x40,0x40,0x42,0x3c,0x00,0x00   # 'e'
    .byte 0x00,0x00,0x00,0x0c,0x10,0x10,0x10,0x7c,0x10,0x10,0x10,0x10,0x10,0x10,0x00,0x00   # 'f'
    .byte 0x00,0x00,0x00,0x00,0x00,0x02,0x3a,0x44,0x44,0x44,0x38,0x20,0x3c,0x42,0x42,0x3c   # 'g'
    .byte 0x00,0x00,0x00,0x40,0x40,0x40,0x5c,0x62,0x42,0x42,0x42,0x42,0x42,0x42,0x00,0x00   # 'h'
    .byte 0x00,0x00,0x00,0x08,0x08,0x00,0x18,0x08,0x08,0x08,0x08,0x08,0x08,0x3e,0x00,0x00   # 'i'
    .byte 0x00,0x00,0x00,0x04,0x04,0x00,0x0c,0x04,0x04,0x04,0x04,0x04,0x04,0x04,0x48,0x30   # 'j'
    .byte 0x00,0x00,0x00,0x40,0x40,0x40,0x44,0x48,0x50,0x60,0x50,0x48,0x44,0x42,0x00,0x00   # 'k'
    .byte 0x00,0x00,0x00,0x18,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x3e,0x00,0x00   # 'l'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x76,0x49,0x49,0x49,0x49,0x49,0x49,0x49,0x00,0x00   # 'm'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x5c,0x62,0x42,0x42,0x42,0x42,0x42,0x42,0x00,0x00   # 'n'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x3c,0x42,0x42,0x42,0x42,0x42,0x42,0x3c,0x00,0x00   # 'o'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x5c,0x62,0x42,0x42,0x42,0x42,0x62,0x5c,0x40,0x40   # 'p'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x3a,0x46,0x42,0x42,0x42,0x42,0x46,0x3a,0x02,0x02   # 'q'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x5c,0x62,0x42,0x40,0x40,0x40,0x40,0x40,0x00,0x00   # 'r'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x3c,0x42,0x40,0x30,0x0c,0x02,0x42,0x3c,0x00,0x00   # 's'
    .byte 0x00,0x00,0x00,0x00,0x10,0x10,0x10,0x7c,0x10,0x10,0x10,0x10,0x10,0x0c,0x00,0x00   # 't'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x42,0x42,0x42,0x42,0x42,0x42,0x46,0x3a,0x00,0x00   # 'u'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x42,0x42,0x42,0x24,0x24,0x24,0x18,0x18,0x00,0x00   # 'v'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x41,0x49,0x49,0x49,0x49,0x49,0x49,0x36,0x00,0x00   # 'w'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x42,0x42,0x24,0x18,0x18,0x24,0x42,0x42,0x00,0x00   # 'x'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x42,0x42,0x42,0x42,0x42,0x26,0x1a,0x02,0x02,0x3c   # 'y'
    .byte 0x00,0x00,0x00,0x00,0x00,0x00,0x7e,0x02,0x04,0x08,0x10,0x20,0x40,0x7e,0x00,0x00   # 'z'
    .byte 0x00,0x00,0x00,0x0c,0x10,0x10,0x08,0x08,0x10,0x20,0x10,0x08,0x08,0x10,0x10,0x0c   # '{'
    .byte 0x00,0x00,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08   # '|'
    .byte 0x00,0x00,0x00,0x30,0x08,0x08,0x10,0x10,0x08,0x04,0x08,0x10,0x10,0x08,0x08,0x30   # '}'
    .byte 0x00,0x00,0x00,0x31,0x49,0x46,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00   # '~'

    .include "logo/font-extra.inc"

# Desktop assets (RLE v2, logo/mkgui.py; index 0 transparent): the top-bar
#   brand (fir mark + wordmark on SURFACE2) and the fir silhouette, each for
#   UI scale 1 and 2. desk_layout picks the pair for the mode.
    .balign 4
brand_u1:
    .include "logo/brand-u1.inc"
    .balign 4
brand_u2:
    .include "logo/brand-u2.inc"
    .balign 4
fir_u1:
    .include "logo/fir-u1.inc"
    .balign 4
fir_u2:
    .include "logo/fir-u2.inc"

# Kernel budget: 256 sectors (.org 131072). The sentinel below
# sits in the LAST sector (vaddr ~0x27BF0): if a boot loads only the old 128
# sectors, that RAM is zero/garbage and `mem` won't print "KSENT256" - the
# headless proof (BIOS/UEFI/PXE all run the same kernel) that all 256 loaded.
__content_end:
    .org 131072 - 16
ksentinel:
    .asciz "KSENT256\r\n"
    .org 131072
