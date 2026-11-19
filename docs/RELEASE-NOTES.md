# TannX OS v2.89 - getting back out

A maintenance release with the open points from a QA pass of the browser
demo (v86, https://tannx.dev/try/) and from filming v2.88 on a real
server. Most of them were ways to get stuck or to be left with a broken
screen; all of them affect QEMU and real hardware as well.

## Downloads

| File | Boots on | How |
|---|---|---|
| `tannx-v2.89-usb-hybrid.img` | BIOS **and** UEFI PCs, QEMU | write raw to a USB stick (`dd`, balenaEtcher, Rufus in DD mode) |
| `tannx-v2.89-bios.img` | BIOS PCs, QEMU | `qemu-system-i386 -drive format=raw,file=tannx-v2.89-bios.img -vga std -m 512` |
| `tannx-v2.89-uefi.img` | UEFI only, QEMU + OVMF | `qemu-system-x86_64 -bios OVMF.fd -drive format=raw,file=tannx-v2.89-uefi.img` |

Check the download with `sha256sum -c SHA256SUMS`.

## Fixes

- **A server boots in seconds, not in 80.** On a Supermicro X11DPi
  (UEFI, Intel C620 SATA) the screen stayed black for ~80 s after the
  loader. The boot's AHCI self-check sent a CD-ROM command to the SATA
  disk; the disk refused it, the controller stopped, and the next read
  waited out a very long timeout. The self-check no longer does that,
  the AHCI driver restarts the port after any error, and the boot-time
  read gives up after about a second. Loader to desktop: 80 s -> 2 s.
- **disktest no longer breaks the disk.** It read a fixed 2 MB, past the
  end of the 1.44 MB demo disk, and the emulated drive then refused
  every later read until a reboot (`diskon`, `wishes`, and every program
  start: `llm`, `llmscript`, `offload`, `hda`, `spawn ask` only printed
  "hello from ring3"). It now reads at most the disk's size, and the
  disk driver resets the channel after a failed command. Without a
  network card those commands say "llm: no NIC / no link" again.
- **Escape gets you out of a wait.** `waittask`, `waitall` and `wait`
  only looked at the oldest key typed, so a `q` pressed first hid the
  Escape behind it and a `waittask` on a task nobody serves could not
  be left. Escape or Ctrl+C now works wherever it sits.
- **Dark Glass comes back clean.** After `run tour`, `forest`, the games
  or `gfx` quit under `gui`, the desktop is fully repainted and the
  shell prints a fresh prompt. Before, parts of the program's last frame
  could stay, `gfx` stayed on screen for good, and the prompt only came
  with the next Enter. Without `gui`, `gfx` now restores the desktop
  instead of leaving its circles as the background.
- **No more bright dashes at the top.** In graphics modes the console's
  old text-mode memory is mapped into the framebuffer by some emulators
  and graphics cards; the status line showed up there as small dashes in
  every full-screen app and in the Dark Glass bar. That memory is now
  plain RAM in graphics modes.
- **Snake uses the whole screen**, with tall cells like invaders, instead
  of a thin strip in the middle.
- **Clearer `mem` and `sysinfo`.** `mem` says "autopilot round 0 (no
  mission yet)" and labels its last-sector check instead of printing two
  lines that looked like garbage; `sysinfo` reports the same RAM as
  `mem` (E820) instead of the 64 MB CMOS estimate.
- **The help pager.** A key that arrived just before the idle loop went
  to sleep could wait for the next timer tick (up to 55 ms). The loop now
  re-checks with interrupts off before it halts.
- **Release images carry the video clip again.** The release build did
  not install the Python imaging library, so v2.88's images shipped
  without the demo clip for `run video`.

Verified in QEMU (the gate, now 50 suites with the new `test-recover`),
in v86, and the boot-time fix on the Supermicro server. The other fixes
were not run on real hardware.

---

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
