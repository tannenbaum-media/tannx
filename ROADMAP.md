# TannX OS roadmap

Where the project stands and what is open. What TannX OS is and is not:
`MANIFESTO.md`. How it got here: `docs/HISTORY.md`.

## Done (the plumbing is complete)

Protected mode, paging with fault isolation, ring-3 agents behind one
syscall gate, preemptive multitasking, opt-in SMP, own drivers for VGA/
framebuffer, keyboard, mouse, COM1, ATA, AHCI/ATAPI, RTL8139/RTL8168/
e1000/virtio-net, AC97, EHCI HID; ring-3 drivers for NVMe, xHCI mass
storage, virtio-blk, virtio-gpu, Intel HDA; a shared FAT16/32 read+write
layer; a userspace TCP/IP stack with DHCP, DNS, HTTP client and an HTTP
server; the Dark Glass desktop compositor; the script engine with
registers, conditionals, loops and joins; the LLM loop (`llm`,
`llmscript`, `spawn ask`, `autopilot`, `offload`) through a host proxy
with LAN discovery; BIOS, UEFI, hybrid-stick and PXE boot; 35 headless
QEMU suites in `make test-all`.

## Open: the agent language and the LLM loop

- Multi-slot answers for long LLM output (a slot is 512 bytes today).
- A third register or a small register file - only if a real script
  needs it. The language stays small on purpose.
- Make the proxy's script contract and the kernel's command set one
  source of truth (today they are kept in sync by hand).

## Open: graphics

- Desktop: image blit into windows (the JPEG decoder exists), a small
  window/panel toolkit, draggable windows, a clickable and editable wish
  console bar.
- GOP best-mode `SetMode` in the UEFI loader (the mode list is already
  enumerated; switching modes changes the boot resolution and needs a
  real board to judge).
- virtio-gpu hardware cursor and multi-scanout presentation (QEMU
  exposes `max_outputs`, but the local probe still reports one active
  scanout; do not fake a multi-output test).
- virgl/3D is out of reach in the headless gate (no OpenGL in the test
  QEMU); nothing planned.

## Open: sound

- The ring-3 Intel HDA driver is QEMU-verified only; a real codec needs
  a cold-boot test on hardware.
- Route game sound effects and a `play <slot>` / tone command through
  whichever driver the machine has.

## Open: hardware breadth (needs silicon, not code)

- NVMe, xHCI mass storage, virtio and httpd have only run in QEMU.
- Modern NICs: Intel I225/I226 and Realtek RTL8125 have no QEMU model;
  a driver can only be written against a real card. The `nic_tbl` is
  data-driven, but a new chip is a new driver.
- SMP on real hardware: `smpon` is opt-in because a faulting application
  processor boot-loops the box. Needs a machine that can be power-cycled
  remotely.
- ACPI poweroff: the table walk finds PM1a_CNT and the S5 value, but the
  SLP_EN write did not engage in QEMU 8.2.2 and cannot be verified safely
  on a box you need to keep reachable.
- Firmware diversity: the hybrid stick's MBR-hosted ESP has been booted
  on OVMF and one real board; other UEFI firmware may insist on GPT.

## Open: security (see SECURITY.md)

- The remote-control channel (`REMOTE_CTL=1`) has no authentication. If
  it is ever to face anything but a trusted lab LAN it needs a shared
  secret or token in the protocol and in the `tools/lan` counterparts.
- The LLM proxy has no authentication either; it binds to 127.0.0.1 by
  default and should stay there unless the LAN is trusted.

## Open: housekeeping

- `agentos32.S` is one 16.8k-line file. Splitting it into `.include`
  modules (boot/mm/sched/net/usb/gui/games) is a maintainability job
  with no behaviour risk.
- Duplicated routines (PCI scans, MMIO mapping) could be consolidated.
- A deterministic driver for the games' score logic so score regressions
  are caught by the gate.

## Deliberately NOT planned

TLS/PKI, a browser, POSIX or multi-user semantics, arbitrary ELF program
loading, swap, broad filesystem support, a general driver zoo. Anything
on this list is built only on an explicit wish, and then it earns its
place in the gate or it does not ship.

## Larger ideas, not scheduled

- An ARM port ("TannX-ARM"): a separate fork - new ISA, no BIOS, MMIO
  instead of PCI. Extra large.
