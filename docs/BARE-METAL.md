# TannX OS on bare metal

How to boot TannX OS on a real PC, how to get wishes and telemetry back
out of it, and what to watch out for. Everything in `make test-all` runs
in QEMU; this page is the part the gate cannot cover.

All network addresses below are placeholders from the RFC 5737
documentation ranges. Replace them with your own lab network.

## 0. Safety first: your disk

TannX OS has its own ATA/AHCI drivers and CAN write to the first internal
disk. Two guards exist, and you should know both:

- **The medium marker.** `diskon` (which arms every write path: save,
  del, wish, llmscript, autopilot, persist) reads LBA 256 and looks for
  the string `AGENTOS-MEDIUM`. Images built by `make` and sticks written
  by `make usb-hybrid` carry it. On a machine whose first disk is NOT an
  TannX OS medium (a PXE-booted box with a Linux disk, for example), diskon
  does not refuse but arms **RAM-backed slots**: writes land in RAM, are
  lost on reboot, and the foreign disk is never touched.
- **`ahcibless`** (needs `confirm`) deliberately stamps the marker onto a
  SATA disk to dedicate it to TannX OS persistence. Only run it on a disk
  you are willing to lose. `awrite` writes one AHCI sector and is likewise
  explicit and destructive.
- `smpon` is opt-in: a faulting application processor boot-loops a real
  machine, so the kernel never wakes the other cores by itself.

## 1. The hybrid USB stick (BIOS and UEFI from one image)

```
make hybrid                    # hybrid.img: boot sector + MBR with one type-EF
                               # partition; the kernel sits twice (raw from
                               # sector 1 for BIOS, kernel32.bin on the ESP for UEFI)
lsblk                          # find the stick - the next step overwrites it
make usb-hybrid DEV=/dev/sdX   # dd the image, asks for confirmation
```

Boot the PC from the stick. Old firmware runs the boot sector (Stage 1
loads the kernel with two 128-sector LBA reads). UEFI firmware ignores
the code, finds the type-EF partition, mounts the FAT ESP and runs
`\EFI\BOOT\BOOTX64.EFI`. Both land in the same kernel; the UEFI path
renders the console into the GOP framebuffer, the BIOS path uses VGA text
mode or the VBE framebuffer for the desktop.

Notes from real boards:
- Some BIOSes refuse to boot a USB-HDD without the active flag; the
  partition entry has it set (0x80). The CHS fields are 0xFF dummies
  (everything lives in LBA land); a firmware that insists on plausible
  CHS values would need them filled in.
- The UEFI specification allows an ESP on an MBR disk, but some firmware
  only looks for GPT. OVMF and the project's test PC accept the MBR
  ESP. If yours does not, the fallback is a GPT hybrid (protective MBR
  with boot code + GPT), which is not built today.
- Secure Boot must be off; the loader is not signed.
- The UEFI stub prints descent markers on COM1 (ExitBootServices, copy,
  GDT, compat, protected). If the machine stops after the firmware
  banner, those markers tell you how far it got. Server boards route
  the BMC's Serial-over-LAN to COM2 (0x2F8): the stub and the kernel
  mirror the console there too, the stub adds its handover state and
  the firmware memory map, and the kernel prints one letter per init
  stage (a..z) plus colour stripes in the GOP framebuffer before paging.
- Verified on a Supermicro X11DPi-NT (2x Xeon Gold, 32 GB, AMI UEFI):
  the firmware loads the stub ABOVE 4 GB, so the 32-bit descent runs
  from a low copy; a 64-bit xHCI BAR above 4 GB is skipped; boards
  without an 8042 (port 0x64 reads 0xFF) get no PS/2 mouse.
- `make usb-uefi DEV=/dev/sdX` writes a UEFI-only stick (`uefi.img`),
  `make usb32 DEV=/dev/sdX` a BIOS-only one (`agentos32.img`). The hybrid
  stick supersedes both.

## 2. PXE: the no-stick loop

A PXE-capable NIC's option ROM downloads `pxe.img` over TFTP at boot and
the firmware does the transfer, so TannX OS needs no NIC driver to boot
this way. Rebuild on the dev box + reboot the target = new version, no
re-flashing.

```
make pxe                       # pxe.img = pxe_stage1 stub + flat kernel
make test-pxe                  # headless proof over QEMU's built-in TFTP
make run-pxe                   # the same in a window
```

For real hardware you need a DHCP/TFTP server on the lab LAN. The
simplest is dnsmasq in proxy-DHCP mode: it does not hand out addresses
(your router still does), it only adds the "boot this file from here"
options for PXE clients. The proxy range must be the real local subnet
(dnsmasq rejects 0.0.0.0,proxy):

```
sudo apt install dnsmasq
mkdir -p /srv/tftp-agentos && cp pxe.img /srv/tftp-agentos/
sudo dnsmasq --conf-file=/dev/null --port=0 \
  --interface=enp3s0 --bind-interfaces \
  --dhcp-range=192.0.2.0,proxy --dhcp-boot=pxe.img \
  --pxe-service=x86PC,"TannX OS network boot",pxe.img \
  --enable-tftp --tftp-root=/srv/tftp-agentos
```

`tools/lan/pxe-server.sh {start|stop|status|deploy}` wraps that line. It
and the other lab scripts are configured through environment variables:

```
AGENTOS_IFACE=enp3s0           # the LAN interface facing the target
AGENTOS_TFTP_DIR=/srv/tftp-agentos
AGENTOS_BCAST=192.0.2.255      # broadcast address of the lab LAN
```

Then on the target: firmware boot menu -> Network/PXE boot. Serve this
only on an isolated or lab LAN. If you let dnsmasq hand out addresses
(a non-proxy `--dhcp-range`), you have a second DHCP server on the wire.

A diskless PXE box has no TannX OS medium, so `diskon` arms RAM-backed
slots: llmscript, script and the autopilot work, but nothing persists
across reboots. `usb backup` / `usb restore` can copy the eight AgentFS
slots to and from a FAT stick over the ring-3 xHCI driver.

## 3. Getting data back out: wishes, status, logs

The OS mirrors every console character to COM1 (115200 8N1) and accepts
input from it, so a serial cable is the most robust wire:

- **Serial bridge**: a null-modem cable (or a USB-TTL adapter on a COM
  header) to the dev box. `wish-bridge.sh [dev]` listens on the serial
  device, logs everything and collects `WISH:` lines (the OS emits them
  with `sendwishes`) into the wish queue. `wish-bridge.sh --send "cmd"`
  types a command into the real machine the same way test.sh types into
  QEMU - the whole test harness works over one cable.
- **UDP telemetry (default build)**: `wish`/`netwish` broadcast
  `AGENTOS-WISH: <text>` to UDP port 4711 and the OS pushes agent results
  and status lines there as well. `tools/lan/wishd.sh` collects the
  wishes on the dev box. The LLM client discovers the proxy by
  broadcasting `AGENTOS-PROXY?` to port 4080 and adopts whoever answers.
- **Remote control (`make REMOTE_CTL=1` only)**: the kernel listens on
  UDP port 4713 for EXEC, REBOOT, ABORT, MISSION, STATUS, RESULTS, DMESG,
  RUNPROG and SELFTEST and answers on 4711. `tools/lan/net-exec.sh`,
  `net-status.sh`, `net-reboot.sh`, `net-abort.sh`, `net-mission.sh`,
  `net-dmesg.sh`, `net-result.sh`, `net-run.sh`, `net-selftest.sh` are the
  host-side helpers; `tools/lan/autopilot-monitor.sh` is a live dashboard
  for the autopilot loop, `tools/lan/ship.sh` deploys a build to the TFTP
  directory and reboots the target, `tools/lan/wish-loop.sh` closes the
  wish -> build -> deploy -> reboot circle, and `tools/lan/test-hw.sh`
  runs a hardware-in-the-loop suite over the same channel. None of this
  is authenticated. Build it only for a trusted lab LAN; see SECURITY.md.

A box running the compositor is sluggish to react to control packets;
send the reboot a few times if the first one is swallowed.

## 4. What has been verified on hardware

On one Haswell desktop (Intel Lynx Point chipset, RTL8168 NIC, integrated
HD Graphics), used as the project's test PC:

- BIOS boot from the hybrid stick, UEFI boot, and PXE boot.
- The RTL8168 driver (receive wedge diagnosed and fixed blind over UDP),
  E820 memory sizing, cpuid/SMBIOS readouts.
- The segment-nulling triple fault on the first ring-3 switch, which
  QEMU never shows (see docs/HISTORY.md).
- AHCI: IDENTIFY, ATAPI IDENTIFY PACKET and SCSI READ CAPACITY against
  the real DVD drive, all over the wire.
- EHCI USB keyboard and mouse, the framebuffer console at native
  resolution with adaptive font scaling, and the desktop compositor on
  the firmware framebuffer.
- The LLM loop: a PXE-booted, diskless box asked a real model through
  the LAN proxy, received a script into a RAM-backed slot and executed
  it (autopilot).

QEMU-only so far (no suitable hardware was available): NVMe, xHCI mass
storage, virtio-blk/net/gpu, Intel HDA audio on a real codec (playback,
and the microphone/line-in capture path of `run rec` / `run voice` - a
real codec may route the mic through a mixer widget the connection walk
does not select; see user/audio.c), httpd on
hardware, SMP on hardware (`smpon` has been tried and the kernel was made
opt-in because of it), ACPI poweroff. Treat these as untested on metal.

### A microphone under QEMU

The gate runs with `-audiodev none` (silence in, nothing out). To use a
real microphone and speakers with the recorder, the synthesizer and the
voice wish, give QEMU a host audio backend and the duplex codec:

```bash
qemu-system-i386 -drive format=raw,file=agentos32-live.img \
  -audiodev pa,id=a0 -device intel-hda -device hda-duplex,audiodev=a0 \
  -netdev user,id=n0 -device rtl8139,netdev=n0
```

`pa` (PulseAudio/PipeWire-pulse), `alsa`, `pipewire` or `sdl` all work;
`hda-micro` instead of `hda-duplex` presents the pins as speaker + mic.
For the voice wish start `./llm-proxy.py` with `faster_whisper` installed
(or `STT_URL` pointing at an STT service), then in the OS:
`diskon; run voice; wait; script 7`.

## 5. Hardware wish list

What would widen the verified set: a modern mini-PC with NVMe, xHCI and
2.5G Intel NICs (I225/I226 - QEMU has no model, so a driver can only be
written against silicon), a Realtek RTL8125 card (a different descriptor
model from the RTL8168), a few USB sticks of different makes for the
mass-storage quirks, and a USB-TTL serial adapter for the pre-network
boot phase.
