# CLAUDE.md - TannX OS operating manual for coding agents

TannX OS (formerly AgentOS) is a bootable x86 OS: a 32-bit kernel in
pure GNU assembler (`agentos32.S`, AT&T syntax, no compiler), a UEFI
stage-0 in the same language (`agentos-uefi.S`), and a ring-3 userland in
freestanding C (`user/`). BIOS/UEFI only load us; after the jump every
driver is ours. The shell prompt is `tannx> `.

Read before changing anything: `docs/ARCHITECTURE.md` (memory map, ABI,
iron rules, pitfalls). Why things are the way they are: `docs/HISTORY.md`.
What is and is not in scope: `MANIFESTO.md`. Open work: `ROADMAP.md`.
Security model: `SECURITY.md`. Real hardware: `docs/BARE-METAL.md`.
The Claude Code wish loop: `docs/CLAUDE-CODE.md`.

## Guiding principle: everything prompt-based

TannX OS is an agent OS built by LLMs. What is missing (drivers,
software, commands) is not lamented but **wished for** in the running OS:

- `wish <text>` stores the wish on disk (LBA 265-272, magic 'AW', needs
  `diskon`). `make run32` boots `agentos32-live.img` for that: kernel,
  marker, ring-3 blob and video clip are refreshed on every start, while
  LBA 257-273 (AgentFS saves, wishes, persisted tasks) survives rebuilds.
  The UEFI path works the same way with `make run-uefi` / `uefi-live.img`.
- `netwish <text>` (and the desktop's wish field) broadcasts the wish over
  UDP :4711; `tools/lan/wishd.sh` or the local wish loop receive it.
- `sendwishes` frames the disk wishes on COM1 for `wish-bridge.sh`.
- `make wishes` harvests the disk slots of both live images.

There are two ways a wish gets built:

1. **Interactive session.** Standing order: first `make wishes`. Build
   every open wish - one commit per wish, all rules below apply. Then clear
   the slot (`./wishes.sh --clear <n>`) and log the wish in Part 3 of
   `docs/HISTORY.md` (date | wish | result). If a wish is too big for one
   session, say so in the log and leave a plan in `ROADMAP.md`.
2. **Headless wish loop** (`make wish-loop`, `tools/claude/build-wish.sh`).
   You are handed ONE wish in the prompt and you are already on a fresh
   branch `wish/<slug>`. Build only that wish. Do not harvest or clear
   slots (the loop does that), do not switch branches, rebase, reset or
   push. Your permissions are restricted to file tools inside the repo and
   Bash for `make`, `./test*.sh`, `chmod +x` on test scripts, read-only git and
   `git add`/`git commit` - one plain command per call (pipes, `&&`, heredocs
   are denied; create files with the Write tool).
   Anything else is denied, so do not try to work around it. After you
   finish, the hook re-runs `make test32` on your commits; red means your
   branch is not shipped.

## Building a wish (how to do it safely)

Pick the smallest home that fits, in this order:

1. **A ring-3 program** - preferred, no kernel change. Write
   `user/<name>.c` with `int <name>_main(void)` (or `(const char *arg)`),
   using only `user/libc.h` (print/printf, sys_getkey, framebuffer helpers,
   malloc, sys_read_sectors, sys_write_slot, net frames...). Register it
   in `user/appmain.c`: `main()` dispatches on the first three letters of
   the `run <arg>` text, so pick a name whose 3-letter prefix is free
   (taken: net llm off hda ask sna inv gui vgp nvm htt usb vbl mmc dfc).
   Add the source to `USER_SRCS`, a compile line and the object to the
   `ld` line of the `user.bin` rule in the Makefile. It then runs with
   `run <name>` at the `tannx>` prompt. Budget: `user.bin` must stay
   <= 65536 bytes (the build fails otherwise) and it is already ~61 KB -
   keep programs tiny, no tables you can compute, check
   `stat -c%s user.bin` after `make`.
2. **A shell script / AgentFS slot** - for wishes that are compositions of
   existing commands (`save <slot> <text>`, `script <slot>`).
3. **A new shell command in the kernel** (`agentos32.S`) - only when the
   wish needs kernel state or a ring-3 program cannot do it. Add the
   `cs_<name>` string, a `try_cmd` line in the dispatcher (longer words
   before their prefixes, e.g. `sendwishes` before `wish`), a `do_<name>`
   handler ending in `jmp shell`, and a line in the `help` text. Watch the
   kernel budget (iron rule 4). Kernel changes are the most likely to
   conflict with other work - keep them minimal.

Then:

- Add a headless test: copy the pattern of `test-run.sh` (boot a temp
  copy of `agentos32.img` with `-nographic`, type the command char by char
  into the serial FIFO, grep the output), add a `test-<name>:` target and
  its `.PHONY` entry to the Makefile. Not every wish can be tested in QEMU
  - then say so in the commit.
- Gate: `make test32` is mandatory, plus the suites for what you touched
  (`make test-run` for user/ programs, `make test-script`, `make test-gui`
  ...). `make test-all` (49 suites, ~30 minutes) is the release gate
  before merging into the main line. Never weaken, skip or delete a test.
- Commit with `git add <files>` (never `-A` or `.`), one commit per wish,
  English message: subject says what, body says why, plus "verified in
  QEMU only" (or also on hardware). Log the wish in `docs/HISTORY.md`
  Part 3 in the same commit.
- If the wish is impossible, unsafe (would weaken isolation, add an
  unauthenticated network control, write foreign disks) or too big: do not
  fake it. Commit a short plan in `ROADMAP.md` instead and say so.

## Commands

```
make                 # build agentos32.img (kernel + user.bin + video clip)
make run32           # interactive QEMU on the live image (Ctrl+A, X quits)
make live32          # only refresh agentos32-live.img (no QEMU)
make test32          # the core serial suite (test.sh) on the 32-bit image
make test-all        # THE RELEASE GATE: 49 headless suites
make test-<name>     # one suite while iterating (script, httpd, usb-fat, vgpu, tour, www, ...)
make debug32         # QEMU halted with a GDB stub on :1234 (docs/ARCHITECTURE.md, 9)
make minimal         # lean core build without the games, reports the footprint
make wishes          # harvest open wishes from both live images

make wish-loop       # local loop: wish in the VM -> Claude Code builds it -> reboot
make wish-dry-run    # print the exact claude command build-wish.sh would run
make test-wish-loop  # the loop end to end with a stub claude (headless, no model)

make uefi / run-uefi / test-uefi     # BOOTX64.EFI + uefi.img under OVMF
make hybrid / test-hybrid            # one image for BIOS and UEFI (in test-all)
make pxe / run-pxe / test-pxe        # diskless network boot over QEMU's TFTP
make usb-hybrid DEV=/dev/sdX         # write the stick (destructive, asks first)
make REMOTE_CTL=1                    # lab build WITH the unauthenticated UDP
                                     #   control channel - trusted LAN only

./llm-proxy.py --mock                # host proxy with canned answers (the tests)
ANTHROPIC_API_KEY=... ./llm-proxy.py # real answers; --bind 0.0.0.0 for a trusted LAN
./wishes.sh [--clear <n>] [image]    # list / clear wish slots in the live images
./wish-bridge.sh [dev]               # harvest wishes over a serial line (bare metal)
tools/claude/build-wish.sh "<wish>"  # build one wish with Claude Code on wish/<slug>
tools/claude/wish-loop.sh [--send "<line>"]  # the local loop / type into its VM
tools/lan/*.sh                       # PXE server, remote control, autopilot monitor,
                                     #   ship/wish-loop; env AGENTOS_IFACE,
                                     #   AGENTOS_TFTP_DIR, AGENTOS_BCAST
```

The suites take minutes (test32 ~3, test-all much longer). Run them in the
background and wait for them; do not run two QEMU suites that share a
fixed port at the same time. The LLM suites take the mock proxy's host port
from `LLM_PROXY_PORT` (`proxy-port.sh`; default 4080, `auto` = a free random
port, which `make test-all` sets), so they never collide on :4080.

## Where things live

- `agentos32.S` - the whole kernel: boot, shell dispatcher (`try_cmd`
  chain), `do_*` command handlers, drivers, scheduler, syscalls, messages
  and the `help` text near the end of the file.
- `user/` - ring-3 C: `appmain.c` (dispatcher), `libc.c/.h` (syscalls,
  printf, framebuffer), one file per program or driver; `user.ld` links it
  flat at the user base. Built into `user.bin` (LBA 300 of the image).
- `test*.sh` - the headless suites (serial FIFO + grep), wired in the
  Makefile; `test.sh` is the core suite behind `make test32`.
- `wishes.sh`, `wish-bridge.sh`, `tools/lan/wishd.sh` - wish harvesting
  (disk, serial, UDP). `tools/claude/` - the Claude Code wish loop.
- `llm-proxy.py` - the host proxy the OS's `llm`/`llmscript`/`autopilot`
  talk to. `docs/` - architecture, history, bare metal, Claude Code.

## Iron rules (details in docs/ARCHITECTURE.md, section 5)

1. The gate green, otherwise no commit (`make test-all` on the main line;
   at least `make test32` + the relevant suites on a wish branch).
2. Protected strings (test.sh greps them): banner word `TannX`,
   prompt `tannx> `, `msg_spawn3`, `msg_res`, `msg_load2`, the status
   names waiting/running/done/ERROR, print_tasks' result format, the #PF
   and heap messages. Change only together with test.sh.
3. ASCII only in OS strings. Code, comments, messages and documentation
   in English.
4. Kernel content < 131072 bytes; check the `KSENT256` sentinel. Raising
   the budget is a layout change, not a bump. `user.bin` <= 65536 bytes.
5. Page 0 stays unmapped. Never set CR0.WP. Exactly one DPL-3 gate (0x30).
6. One change = one commit; subject says what, body says why. State
   whether it was verified in QEMU only or also on hardware.

## How to work

- Every feature gets a headless check: a `test-<name>.sh` that drives
  the OS over its serial console and greps the result, plus a Makefile
  target (and a line in `test-all` when it belongs to the gate). Storage:
  prove the bytes land in the host backing file (mtools/curl). Graphics:
  screendumps. Sound: DMA progress counters.
- Agents never write tables or the screen; they use syscalls. New
  syscalls go through the existing gate, take validated buffers
  (`sc_chkbuf`) and are documented in the ABI table.
- Hardware you cannot run is untested. Say so in the commit and in the
  docs. Do not deploy to, reboot, or write a disk on a machine you were
  not asked to touch.
- Keep the kernel comments useful for the next session: they are the
  co-author's notes, not decoration.
- Before leaving: `make wishes` is empty or logged (interactive sessions),
  `git status` is clean, the gate was green on the committed tree.
