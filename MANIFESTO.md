# TannX OS -- what it is, and what it is not

A one-page line in the sand. When a feature is proposed, it
is measured against this. The point of TannX OS is to stay small enough to
understand whole, with the **agent** as the first-class citizen.

## What TannX OS IS

- A **bare-metal x86 operating system in pure GNU assembler** (AT&T, no
  compiler) -- one 32-bit kernel (`agentos32.S`). BIOS *and* UEFI boot, a
  hybrid USB stick, and PXE network boot, all from the same image.
- An **Agent OS**: agents are real ring-3 threads with privilege
  separation, typed capabilities, and a clean lifecycle (spawn / claim /
  progress / finish / kill / reap). They form **pipelines** (one agent's
  result feeds the next), report **results over the wire**, are **fault-
  isolated** (#PF/#GP kill only the guilty agent) and **watchdog-bounded**
  (a runaway is killed, the box never stalls).
- **Self-hosting over the LAN**: the OS has a UDP telemetry channel, a
  userspace TCP/HTTP path, and acknowledged `netwish`. The dev box serves
  LLM/compute requests and harvests wishes; with the `REMOTE_CTL=1` lab
  build it can also remote-reboot the box, query STATUS and RESULTS and set
  missions. PXE turns that into a hands-off update loop: build -> deploy ->
  reboot -> confirm (`tools/lan/ship.sh`), no stick, no getting up.
- **Built by LLMs through the wish loop**: what is missing is not lamented
  but *wished for* in the running OS; an LLM session builds it next.
- **Honest and tested**: `make test-all` (49 suites) green or no commit;
  bare-metal claims are verified on real hardware (a Haswell desktop), never
  assumed.
  QEMU now also gates an explicit `-smp 4` smoke path.
- **Minimal by construction**: a `make minimal` core drops the extras
  (games today; benchmarks/sensors next) for the lean build.

## What TannX OS is NOT (out of scope, by design)

- **Not an Internet OS.** There is no TLS, browser, package manager, user
  accounts, or hostile-network security boundary. TCP/HTTP/DHCP/DNS exist
  only as small, testable appliance paths for the trusted lab LAN
  (`SECURITY.md`).
- **Not SMP-first.** The safe boot path is single-core; APs are woken only
  by explicit `smpon`, and SMP is kept to agent-thread scheduling with a
  QEMU `-smp 4` smoke gate plus later real-hardware checks.
- **Not POSIX, not a desktop, not a general driver zoo.** USB mass storage,
  AHCI/ATAPI, virtio block/net/GPU, NVMe, audio, and the Dark Glass GUI exist
  because they earned their place in the gate; arbitrary ELF loading, swap,
  filesystems beyond the small FAT appliance path, and broad device support are
  still out of scope.
- **Not a general-purpose OS.** It runs agents. That is the job.

Anything on the "is not" list is built only on an explicit wish -- and then
it earns its place or it does not ship. Roadmap and trade-offs: `ROADMAP.md`.
