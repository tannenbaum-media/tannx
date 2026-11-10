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
