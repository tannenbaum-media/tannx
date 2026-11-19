# TannX OS v2.88 - input and idle fixes

A maintenance release with input, idle and screen fixes found while running TannX in the
browser (v86, https://tannx.dev/try/). All of them affect QEMU and real
hardware as well.

## Downloads

| File | Boots on | How |
|---|---|---|
| `tannx-v2.88-usb-hybrid.img` | BIOS **and** UEFI PCs, QEMU | write raw to a USB stick (`dd`, balenaEtcher, Rufus in DD mode) |
| `tannx-v2.88-bios.img` | BIOS PCs, QEMU | `qemu-system-i386 -drive format=raw,file=tannx-v2.88-bios.img -vga std -m 512` |
| `tannx-v2.88-uefi.img` | UEFI only, QEMU + OVMF | `qemu-system-x86_64 -bios OVMF.fd -drive format=raw,file=tannx-v2.88-uefi.img` |

Check the download with `sha256sum -c SHA256SUMS`.

## Fixes

- **A stale key no longer ends the next program.** Every key typed at the
  shell also went into the ring-3 key ring, and nothing emptied it. A `q`
  that closed the `help` pager (or an Esc at the prompt) made the next
  `invaders`, `snake`, `forest` or `run tour` quit on the spot. The ring
  now starts empty when a program starts from the shell.
- **Arrow keys steer the games.** The kernel always delivered the arrows
  to ring 3, but snake and invaders only listened to WASD / A-D. Snake
  now steers with all four arrows and invaders moves with Left/Right
  (Space still fires). The file manager, the text browser and the tour
  take the arrows too (up/down scroll, right/left = next/back).
- **The games own the screen.** snake and invaders took the keyboard but
  not the framebuffer, so the kernel kept painting its status line, the
  desktop panel values and the mouse pointer over the board. They now
  grab it like the other full-screen apps. Invaders' pause banner reads
  PAUSE again instead of TAUSE.
- **An idle prompt idles again.** With a PS/2 mouse the idle loop
  busy-polled the 8042, because IRQ12 never fires on one test PC. That
  was a full host core at a bare prompt in QEMU and v86 (~95 %). The
  kernel now checks at boot whether IRQ12 fires and only busy-polls when
  it does not, when EHCI USB HID is active, or while a ring-3 device
  driver (the sound apps, vgpu, nvme, xhci) runs. Measured at an idle
  prompt: QEMU 100 % -> 2 %, v86 ~95 % -> 3 %; with the forest running,
  QEMU 100 % -> ~20 %, v86 ~65 % -> 19 %.
- **No status-line leftovers on the desktop.** Starting `gui` could
  leave part of the kernel status line on the Dark Glass top area (seen
  under v86, where drawing is slow). The status line was drawn after the
  new program could already run. It is now drawn before.

Verified in QEMU (the 49-suite gate) and in v86. The IRQ12 check could not
be run on the PS/2-emulating test PC for this release; machines whose
IRQ12 does not fire fall back to the old polling.

---

# TannX OS v2.87 - first public release

TannX OS is a bootable x86 operating system written in GNU assembler (kernel)
and freestanding C (ring-3 userland), grown wish by wish by LLM coding
sessions. Plant a wish. The agents grow it.

## Downloads

| File | Boots on | How |
|---|---|---|
| `tannx-v2.87-usb-hybrid.img` | BIOS **and** UEFI PCs, QEMU | write raw to a USB stick (`dd`, balenaEtcher, Rufus in DD mode) |
| `tannx-v2.87-bios.img` | BIOS PCs, QEMU | `qemu-system-i386 -drive format=raw,file=tannx-v2.87-bios.img -vga std -m 512` |
| `tannx-v2.87-uefi.img` | UEFI only, QEMU + OVMF | `qemu-system-x86_64 -bios OVMF.fd -drive format=raw,file=tannx-v2.87-uefi.img` |

Check the download with `sha256sum -c SHA256SUMS`.

## Highlights

- Kernel in one GNU-assembler file: paging, ring 3, preemptive multitasking, opt-in SMP.
- Agents as first-class citizens: typed ring-3 workers, task queue, the `forest` view.
- The wish loop: `wish <text>` at the prompt, a Claude Code session builds it, the
  49-suite headless QEMU gate decides.
- Desktop compositor, guided tour (`run tour`), text browser, file manager, editor,
  monitor, recorder, synthesizer, screenshots, Chromecast app.
- Boots via BIOS, UEFI and PXE; verified on a Haswell desktop and on a dual-socket
  Xeon Gold server (UEFI).

## Known limitations

- Lab OS with a trusted-LAN model: no TLS, no authentication. Read SECURITY.md.
- On real hardware input currently needs PS/2 or EHCI USB; xHCI-only machines have
  no keyboard yet.
- LLM features need the host proxy (`llm-proxy.py`) - see README.

Licensed GPL-3.0-or-later. "TannX" and the fir-tree logo are trademarks of
Tannenbaum Media and not covered by the license.
