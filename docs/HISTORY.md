# AgentOS development history (v0.1 to v2.x)

Notes kept during development in 2026. The kernel and the userland were
written by LLM coding sessions directed and tested by the project owner;
these notes record the WHY behind the decisions of each version, in the
order they were made. The current operating manual is `CLAUDE.md`, the
architecture reference is `docs/ARCHITECTURE.md`.
TannX OS was formerly AgentForest OS (and before that AgentOS).

Part 1 is the original operating manual of the 16-bit real-mode kernel
(v0.1 to v0.7). It is kept verbatim as a historical document: that kernel
is no longer built, but the conventions, register contracts and pitfalls
written down here carried over into the 32-bit kernel. Part 2 is the
per-version log. Part 3 is the log of the wish loop.

## Part 1: the original 16-bit operating manual (v0.1 to v0.7, historical)


### Project

AgentOS is a self-contained, bootable 16-bit operating system (x86 Real
Mode) in pure GNU assembler (AT&T syntax). There is **no** libc, no
Linux, no DOS underneath -- only BIOS interrupts and the bare CPU.
The entire code lives in **one file: `agentos.S`** (Stage 1 + Stage 2).

### Build & Test

```bash
make            # builds agentos.img (needs only binutils: as, ld, objcopy)
make run        # starts the image in QEMU
make clean
```

- There are no automated tests. After every change: `make run`
  and manually run through the affected commands in the shell
  (at minimum: boot, `help`, the changed command, `spawn` + `tick`).
- The build error `Error: attempt to move .org backwards` means: the
  image has grown past the size limit -> see "Size limit" below.

### Memory layout

| Address        | Contents                                            |
|----------------|-----------------------------------------------------|
| `0x0000-0x03FF`| Interrupt Vector Table (IVT); our timer hook sits at `0x70` (= vector `0x1C` x 4) |
| `0x7C00`       | Stage 1 (boot sector, 512 bytes, ends with `0xAA55`) |
| `0x7E00`       | Stage 2 (kernel), loaded by Stage 1 via `INT 13h`   |
| `< 0x7C00`     | Stack (grows downward from `0x7C00`)                 |

All segments (CS, DS, ES, SS) are **0**. Addresses are therefore always
"real" offsets -- no segment juggling needed.

### Code conventions (important!)

- **AT&T syntax, `.code16`**, assembled with the system `as`
  (x86_64 binutils -- works because the linker resolves absolute
  16-bit relocations; that is why all addresses must stay < 0x10000).
- **Everything stays in `.text`**, including data/strings. Do not create
  `.data`/`.bss` sections -- the linker script and the flat binary expect
  a single section in file order.
- **ASCII only in strings.** No umlauts/special characters (UTF-8 turns
  into garbage in VGA text mode). Transliterate anything non-ASCII.
  Line break is always `\r\n`.
- 32-bit instructions (`movl`, `divl`, `incl`, `%eax` ...) are allowed in
  Real Mode (operand-size prefix), memory addressing stays 16-bit
  (only BX/BP/SI/DI combinations, no scaled index).
- Use unique, named labels per routine (`sp_loop`,
  `tc_no` ...), no ambiguous numeric labels spanning routines.

### Register contracts of the helper routines

| Routine        | Input              | Clobbers                   | Preserves |
|----------------|--------------------|----------------------------|--------|
| `putc`         | AL = character     | AH                         | BX, all others |
| `puts`         | SI = string (0-term)| AX, SI                    | BX, DI |
| `crlf`         | --                  | AX                         | rest   |
| `readline`     | --                  | AX, DI; fills `linebuf`    | BX     |
| `print_dec32`  | EAX = number       | nothing (saves everything) | everything |
| `try_cmd`      | DI = command string| AX, SI, DI; sets `arg_ptr` | Carry=0 on match |
| `slot_ptr`     | BX = agent index   | DI = table entry           | BX     |
| `name_ptr`     | BX = agent index   | SI = name                  | BX     |

Command handlers may use registers freely and **always** end with
`jmp shell` (exceptions: `reboot`, `halt`).

### Adding a new shell command (standard recipe)

1. Create the command string in the data area: `cs_foo: .asciz "foo"`
2. Add it to the dispatch chain in `shell`:
   ```asm
   mov $cs_foo, %di
   call try_cmd
   jnc do_foo
   ```
3. Write the handler (arguments are available from `arg_ptr` as a 0-terminated string):
   ```asm
   do_foo:
       ...
       jmp shell
   ```
4. Add an entry to `help_text`. `make run`, test.

### Size limit

- Stage 1 must fit in 510 bytes (`.org 510` enforces that).
- Stage 1 + Stage 2 together may have at most **8704 bytes** (17 sectors)
  -- enforced by `.org 8704` at the end of the file.
- When space runs out: increase `.org 8704` **and** adjust the sector
  count in the `INT 13h` read in Stage 1 (`mov $0x0210, %ax` -> AL =
  sector count). Caution: a single read only fits the
  sectors 2-18 of track 0/head 0 (= max. AL=17). Beyond that the
  loading must be rebuilt across multiple reads (next head/track).

### Agent subsystem (v0.5: real task system)

- `agents_tbl`: 8 entries of **8 bytes** each:
  `used(1) | type(1) | status(1) | task-index(1) | done(2) | progress(1) | free(1)`
  - type = capability: 0=math, 1=scan, 2=count (names in `type_names`)
  - status: 0=idle, 1=busy (names in `astate_names`)
  - task-index: running task (0xFF = none), progress: remaining ticks
  - `slot_ptr` uses `shl $3`
- `tasks_tbl`: 8 entries of **16 bytes** each:
  `used(1) | type(1) | status(1) | agent(1) | a(2) | b(2) | op(1) | free(3) | result(4)`
  - status: 0=waiting, 1=running, 2=done (names in `tstate_names`)
  - `task_ptr` uses `shl $4`
- `scheduler_step` (BIOS-free, ISR-safe):
  Phase 1 assigns waiting tasks to idle agents of a matching type
  (`find_idle_agent`), sets progress=3. Phase 2 counts down progress for busy
  agents; at 0 -> `run_task` (computes the result per type), task
  "done", agent "idle", done++.
- `run_task`: math = `a op b` (+,-,*,/, 32-bit); scan = sum of the 16
  bytes from address `a` (segment 0); count = sum 1..a.
- `tick`/`run` calls `scheduler_step` once (under the `sched_busy` lock).
  `auto` lets the timer ISR call it once per second -- the ISR skips
  if `sched_busy` is set (no reentrancy damage).
- `parse_type`/`starts_with`: recognize math|scan|count at the start of a word
  and advance SI past the word (for `spawn <type>` and `task <type> ...`).

### Debugging

- QEMU with GDB: `qemu-system-i386 -drive format=raw,if=floppy,file=agentos.img -s -S`,
  then `gdb -ex 'target remote :1234' -ex 'set architecture i8086'`,
  breakpoint e.g. `b *0x7e00`. (Real-mode disassembly in GDB is
  finicky -- often `objdump -b binary -m i386 -M addr16,data16 -D agentos.img` is enough.)
- For "does not boot": first check the boot signature
  (`od -A d -t x1 -j 508 -N 4 agentos.img` -> must show `55 aa`),
  then look at the disassembly of the first bytes.

### What you should NOT do

- Do not introduce any C files, no libc, no external dependencies.
- Do not switch to `nasm` (it is not installed here; GNU as is enough).
- No protected-mode rewrite "on the side" -- that is a separate,
  planned project and breaks all of the BIOS I/O.
- Do not assume that BIOS interrupts preserve registers -- when in doubt,
  save them beforehand.
- Never write `agentos.img` to a device without being asked; only run
  `make usb` when the user has explicitly confirmed the target device.

---

## Part 2: version notes

### New in v0.2

#### Status line (line 0)

- **Line 0 is reserved** for the status line and is drawn every second
  by the timer ISR via `draw_status` directly into VGA memory
  (`B800:0000`, attribute `0x70`). Normal output begins
  from line 1 (`cls` sets the cursor accordingly).
- After every change to the agent table or `auto_flag` in
  mainline code, call `call draw_status` (the handlers for spawn/kill/
  auto already do this), so the display is immediately correct.
- Known cosmetic flaw: BIOS teletype scrolling briefly pushes text
  below the line, until the next refresh -- fixed by the
  custom VGA driver in Phase 2 of the phase plan.

#### Rules for interrupt service routines

- Save ALL registers used -- including the full 32-bit
  registers (`push %eax` etc.), DS, ES. Mainline code uses 32-bit ops!
- Set DS to 0 at the start, `cld` before string instructions.
- **Do not call BIOS interrupts from an ISR** (not reentrant).
  Output in ISRs only via direct VGA writes.
- Keep it short: the per-second work (status line, autorun) only runs
  on every 18th tick (`stat_cnt`).

#### New helper routines / variables

| Routine/Var    | Purpose                                              |
|----------------|------------------------------------------------------|
| `draw_status`  | redraw the status line completely; saves all registers itself, callable from ISR and mainline |
| `vga_puts`     | string from SI to ES:DI as character+attr `0x70` (stosw) |
| `vga_dec`      | EAX decimal to ES:DI (attr `0x70`); saves registers |
| `cur_attr`     | current color attribute for `cls`/`color` (default `0x0A`) |
| `auto_flag`    | 1 = autorun: ISR advances agents once per second    |
| `stat_cnt`     | tick counter 18->0 for the per-second work of the ISR |
| `histbuf`      | last input line (up-arrow history in `readline`)    |
| `rnd_seed`     | LCG state for `rnd`                                  |

#### beep / hardware I/O

`do_beep` is the reference for direct hardware programming:
PIT channel 2 (ports `0x43`/`0x42`), speaker gate port `0x61`,
waiting via `hlt` + tick comparison. Use the same pattern for future
drivers (Phase 2/3).

---

### New in v0.3

#### Custom VGA text driver (Phase 2 done)

- `putc` now writes **directly to 0xB8000** (character + `cur_attr`),
  advances the hardware cursor via the CRTC ports 0x3D4/0x3D5, and
  scrolls itself. **No more BIOS INT 10h in the kernel.** (Stage 1 still
  uses its own `puts16` via BIOS -- that is fine.)
- New cursor variables `cur_x` (0..79) and `cur_y` (1..24). Line 0
  remains reserved for the status line; `scroll_up` only moves
  lines 1..24 and leaves line 0 alone.
- New helper routines: `pc_pos` (offset = (cur_y*80+cur_x)*2),
  `scroll_up` (lines up, clear the bottom one), `move_cursor`
  (set hardware cursor). All save their registers themselves.
- Important for future changes: `putc` expects DS=0 (true throughout
  the entire mainline code). `scroll_up` reads `cur_attr` BEFORE it switches DS to
  0xB800 -- keep this pattern in similar code.
- Reentrancy: the timer ISR/`draw_status` write only line 0, `putc`
  only lines 1..24 -- so they do not disturb each other, even when the timer
  fires in the middle of output.

#### Next step

Phase 3 (custom keyboard driver via IRQ1/port 0x60) -- see the phase plan.
After that, `int $0x16` is removed from `readline` and both input AND output
belong entirely to us.

### New in v0.5 -- agents are the core

The calculator command `calc` from the interim state has been **removed**.
Computation is now what a **math agent** can do -- no longer a
standalone command. That fits the name "AgentOS".

#### New/changed commands
- `spawn <type>` -- start an agent with a capability: `math`, `scan`, `count`.
- `task math <a> <op> <b>` / `task scan <hex>` / `task count <n>` -- put a task
  into the queue.
- `tasks` / `queue` -- all tasks with type, input, status and result.
- `agents` / `ps` -- agents with type, idle/busy and number of completed tasks.
- `tick` / `run` -- one scheduler step, followed by queue output.
- `auto` -- scheduler runs in the timer interrupt (1x/s).
- `kill <0-7>` -- terminate an agent; a running task falls back to "waiting".

#### Remaining system commands
`date`/`time` (RTC/CMOS), `dump <hex>` (hexdump), `cpuid`, `mem`, `uptime`,
`color`, `beep`, `lines`, `clear`/`cls`, `echo`, `reboot`/`halt`. These are
close to the OS/hardware and are kept as tools.

#### Important implementation details (for future changes)
- **Register contracts in the scheduler:** `find_idle_agent` receives BX, returns
  the agent pointer in SI + `agent_found_id`. In `scheduler_step`, DI is always
  the task pointer, SI the agent pointer -- both address via DS=0.
- `run_task` does `pusha`/`popa` internally; the upper 32-bit halves may be
  destroyed in it (the ISR saves the full 32-bit registers on the outside).
- **Keep status texts compact!** The status line (`stat_txt1/2/_t/3`) together
  with numbers must not exceed 80 columns, otherwise it overflows into
  line 1. Currently ~58 characters -- enough headroom, but measure when extending.
- Reentrancy: `sched_busy` protects the tables when the ISR fires
  while `tick` is in the middle of `scheduler_step`.

#### Size
7437 / 8704 bytes (Stage 1 + Stage 2). ~1.2 KB headroom.

#### Next step
Phase 3 (custom keyboard driver, IRQ1/port 0x60) OR Phase 5
(mini file system on disk sectors) -- see the phase plan.

### New in v0.6 -- custom drivers for keyboard & disk

Guiding principle from now on: **"What is not there, we build ourselves."** The BIOS
is now used only for bootstrapping (Stage 1 loads the kernel via
INT 13h, a one-time setting of video mode 3 at start, INT 19h as a
reboot fallback). During operation: all custom drivers.

#### Boot change (IMPORTANT)
- The image is now a **hard disk image**. Start with:
  `qemu-system-i386 -drive format=raw,file=agentos.img` (NO more `if=floppy`!)
- Stage 1 loads **48 kernel sectors** via INT 13h **AH=42h** (LBA-DAP,
  label `dap`). Size limit now `.org 25088` (49 sectors).

#### Custom keyboard driver (Phase 3 done)
- `kbd_isr` hangs on **IVT 9 (IRQ1)**, reads port 0x60, translates
  scancode set 1 -> ASCII via `kbmap`/`kbmap_sh` (US layout, as before
  via the BIOS), manages shift and the E0 prefix, places words
  (AH=scancode, AL=ASCII) into the 16-entry ring buffer `kbuf`
  (`kb_head`/`kb_tail`). At the end **EOI to port 0x20** -- mandatory!
- `kgetch` replaces INT 16h: same return value (AL=ASCII, AH=scancode),
  sleeps via `hlt` until the next interrupt. `readline` now calls
  `kgetch` -- otherwise unchanged (up-arrow event: AH=0x48, AL=0).
- Keypad special cases: `*` (0x37), `-` (0x4A), `+` (0x4E), `/` (E0 35)
  return the operator characters -- handy for `task math` on
  non-US layouts.
- Caution: there is NO MORE BIOS keyboard buffer. Never add
  `int $0x16` again -- it would hang forever.

#### Custom ATA disk driver + AgentFS (Phase 5 done)
- PIO, LBA28, Primary Master, **polling** (in `ata_init` nIEN is
  set -> no disk IRQs). Ports 0x1F0-0x1F7, 0x3F6.
- Routines: `ata_read` (AX=LBA, DI=buffer), `ata_write` (AX=LBA,
  SI=buffer), both CF=1 on error; `ata_wait_rdy`/`ata_wait_drq`
  with timeout (also detect 0xFF = no drive).
- **AgentFS**: 8 slots on LBA 100-107, format `'A' 'F' | length | text`.
  Commands `save <0-7> <text>`, `load <0-7>`, `ls`, `del <0-7>`.
- **Write-protect latch:** `save`/`del` refuse until `diskon`
  has been run (`fs_armed`). Reason: on real hardware the driver writes
  to the FIRST disk at the primary port -- on a machine with
  data that would be dangerous. In QEMU everything lands in the image (and
  survives reboots, until `make` rebuilds the image).
- AHCI note: on real hardware the legacy ports only work
  if SATA is set to **IDE/Compatibility** in the BIOS. Otherwise you get a clean
  "disk error" (timeout).
- Never call ATA from the ISR (long poll loops + reentrancy) --
  that is why there is deliberately no disk task type for agents.

#### Further BIOS removals
- `cls`: now fills lines 1-24 directly in 0xB8000 (previously INT 10h scroll).
- `mem`: reads CMOS 0x15/0x16 instead of INT 12h.
- `reboot`: 8042 reset pulse (`out 0x64, 0xFE`), INT 19h only as a fallback.

#### Size
9710 / 25088 bytes -- plenty of headroom for Phase 6/7.

### v0.6.1 -- bugfix: booting from floppy possible again

v0.6 had switched Stage 1 to INT 13h/AH=42h (LBA) -- only hard disk
boots can do that. In VMware (image as floppy) or QEMU with
`if=floppy` the boot ended in "Disk error! System halted."
(looks like a hang, is a hlt loop).

Fix: Stage 1 checks the boot drive (DL from the BIOS). DL < 0x80 -> floppy
-> CHS read in 3 chunks without crossing track boundaries (17+18+13 = 48
sectors, targets 0x7E00/0xA000/0xC400, `read_chs` with 3 retries).
DL >= 0x80 -> hard disk -> LBA-DAP as before.

Note to self for next time: **never make boot paths exclusive** -- DL
decides, offer both ways. AgentFS still needs an
ATA drive at the primary port; on a floppy boot without a disk you get a clean
"disk error: no ATA drive reachable" (timeout, no hang).

### New in v0.7 -- serial console + automated tests

Phase 6 done: AgentOS now has a **custom UART driver** for
COM1 (16550, ports 0x3F8-0x3FD) -- input AND output, IRQ-driven,
no BIOS.

#### Output
- `putc` calls `serial_putc` as the very first thing -- EVERY screen character
  also goes over COM1 (115200 baud, 8N1). The status line still uses
  `vga_puts` directly and is deliberately NOT mirrored
  (otherwise it would flood the serial log every second).
- `serial_putc` has a timeout and detects 0xFF (no UART
  installed) -- so it never hangs, even on hardware without a COM port.

#### Input
- `com1_isr` on **IVT 0x0C (IRQ4)**; `serial_init` unmasks IRQ4 at the
  PIC (bit 4 of port 0x21) and sets **OUT2** in the MCR (without OUT2
  no IRQ gets through on real hardware!). IER = 0x01 (receive IRQ only).
- The handler fetches ALL pending bytes in a loop (LSR bit 0)
  and translates: CR/LF -> Enter, DEL/BS -> Backspace, `ESC [ A` -> up
  arrow (3-state machine in `esc_state`), printable characters directly.
- The keyboard and COM1 ISR share the buffer via **`push_key`**
  (AX event in, discards on a full buffer, expects DS=0). The
  ring buffer `kbuf` was enlarged to **64 entries**: QEMU delivers
  piped input as a burst, 16 entries would overflow on a whole
  line. `readline`/`kgetch` are unchanged -- they do not know
  where the characters come from.

#### Automated tests
- `./test.sh [image]` (or `make test`): boots headless
  (`qemu -nographic`), feeds a command sequence over COM1,
  checks the log for banner, prompt, agent results (56154, 5050)
  and AgentFS roundtrip. Runs on a COPY of the image.
- Adding new checks: extend the commands in `feed()`, add a
  `check "<pattern>" "<description>"` below.
- Interactive serial: `qemu-system-i386 -drive format=raw,file=agentos.img -nographic`
  (to quit: **Ctrl+A, then X**).

#### Size
10133 / 25088 bytes.

#### Roadmap status
Phases 1-6 done. Remaining: Phase 7 (Protected Mode, separate branch).

### New in v0.8 -- AgentOS/32: Protected Mode (Phase 7)

Second, complete kernel: `agentos32.S` (32-bit Protected Mode).
The 16-bit kernel `agentos.S` (v0.7) remains unchanged alongside
it. Both share commands and output texts -- **one `test.sh`
tests both**: `./test.sh agentos32.img` or `make test32`.

#### Structure
- Stage 1: identical dual loader (CHS for floppy, LBA for HDD).
- Real-mode prologue (`stage2`): video mode 3 via INT 10h (the LAST
  BIOS call), A20 via port 0x92, `cli`, `lgdtl`, CR0.PE,
  `ljmp $0x08, $pm_entry`.
- GDT: null + code (0x08) + data (0x10), flat 0..4 GB
  (0x00CF9A...FFFF / 0x00CF92...FFFF).
- IDT: 256 gates, built at runtime at **0x500** (free RAM,
  saves 2 KB of image). `set_gate`: EBX=vector, EAX=handler.
- Vectors 0-31 -> EXC stubs (macro), report "CPU EXCEPTION #n" via
  `puts` (so it is also visible over serial!) and halt.
  0x20=timer, 0x21=keyboard, 0x24=COM1, rest -> `default_int`.

#### Pitfalls that are navigated around here
- **PIC remap is mandatory**: without it IRQ0-7 collide with the
  CPU exceptions. ICW sequence with io_wait (port 0x80); masks:
  master 0xEC (only IRQ0,1,4 free), slave 0xFF.
- **EOI** to port 0x20 (master); we do not use slave IRQs.
- After the jump **never BIOS again**: any int $0x10/0x13/0x16
  would be an exception in PM.
- Timeout loops: 16-bit `xor %cx,%cx`+`loop` = 65536 rounds,
  in 32-bit that would be 4 billion! That is why everywhere uses an explicit
  `mov $0x10000, %ecx`.
- `rep insw/outsw` need the 66 prefix in 32-bit mode for
  word transfers -- gas does that automatically (check: `66 f3 6d`).
- Pointer tables (`agent_names`, `type_names`, `tstate_names`, ...)
  are now `.long` with `(,%reg,4)` indexing; `arg_ptr` is `.long`.
- VGA flat: 0xB8000 is simply an address, no ES juggling.
  `dump b8000` now works directly.
- ISRs: only `pushal`/`popal` + `cld`; the segment registers are never touched
  again after initialization.
- Reboot: 8042 pulse, fallback `lidt` (limit 0) + `int $3`
  -> triple fault -> reset.

#### Verified (via disassembly -- no QEMU in the sandbox)
Mode switch byte-exact (lgdtl / 0F 20 C0 / or $1 / 0F 22 C0 /
EA..08 00), GDT descriptors, gdtr/idtr, set_gate address computation
(`lea 0x500(,%ebx,8)`), PIC ICWs + masks, EXC stubs (`6A nn`),
66-prefixed string I/O, kbmap bytes, boot signature, 4x iret.
Size: 12151 / 25088 bytes. The first real boot is up to the user.

#### Roadmap
Phases 1-7: all done. The original roadmap is thereby complete.

### New in v0.9 -- real preemptive multitasking (Phase 8, bonus)

The agents are no longer a table simulation: **every agent is a
real thread** with its own 4 KB stack. The timer interrupt preempts
the CPU and distributes it round-robin. The shell is thread 0 and stays
usable while agents compute.

#### Thread model
- `cur_thread` (byte), `tcb_state` (9 bytes: 1=runnable, shell always 1),
  `tcb_esp` (9 longs). Thread ID = agent slot + 1.
- Stacks: 0x21000 + TID*0x1000 (i.e. 0x22000...0x29000), 4 KB of free
  RAM each -- costs no image byte. The shell keeps 0x9F000.
- **Context switch in the timer ISR**: `pushal` puts all registers onto the
  stack of the interrupted thread -> save ESP into `tcb_esp[cur]` -> find the next
  thread with state==1 -> load its ESP -> EOI -> `popal`+`iret`
  resume ITS world. No thread notices anything.
- **Synthetic frame** (spawn): pre-fill the stack as if the
  thread had just been interrupted by the timer -- from the top: EFLAGS=0x202
  (IF=1, otherwise the thread runs forever with cli!), CS=0x08,
  EIP=agent_main, then 8 popal registers (EBX position = agent slot;
  the ESP position is a placeholder, popal ignores it).
  `tcb_state` is set as the VERY LAST thing -- before that the
  scheduler must not see the half-finished frame.

#### agent_main (contract)
- Takes the slot from EBX -> EBP. NEVER outputs text itself (only the
  shell prints; threads write silently into the tables).
- Task search+claim under `cli` (otherwise two threads claim the same
  task). No task -> `sti; hlt` = voluntarily yield the CPU.
- Visible work: 4 %/tick via the progress byte (agents_tbl+6),
  ~25 ticks ~ 1.4 s per task -- CPU-independent, because tick-clocked.
  Then `run_task` (unchanged), task done, done++.

#### Synchronization
- `putc` is atomic (`pushfl; cli ... popal; popfl`): the outputs of multiple
  contexts do not get chopped up. IF is only off for ~us there -- the COM1 FIFO
  (16 bytes ~ 1.4 ms of buffer) does not overflow.
- `kill <n>` = `tcb_state[n+1]=0` (descheduled; the victim is guaranteed
  suspended at the time of the call, since the shell is currently running) + task reset as
  before.
- Removed: scheduler_step, find_idle_agent, auto_flag, sched_busy.
  `tick` = snapshot, `auto` = info text -- the commands remain for
  test.sh compatibility; all grepped texts are unchanged.
- `tasks` shows "(NN%)" for running tasks, `ps` shows "NN%" for busy;
  the status line shows "Threads:N" instead of auto.

#### test.sh
Unchanged green for BOTH kernels: results now appear on
their own (~1.4 s after `task ...`), long before the tick/tasks commands
check with their sleeps.

#### Verified (disassembly)
ESP save/load `89/8b 24 9d <tcb_esp>`, frame trio 0x202/0x08/agent_main,
agent_main scan against tasks_tbl/agents_tbl, putc pushfl/cli, 12490 bytes.
As always: it has never booted here.

### New in v1.0 -- paging + fault isolation (Phase 9, bonus)

AgentOS/32 now has its own memory management -- and uses it for
what distinguishes a real OS: **A memory fault kills only
the culprit, never the system.**

#### Paging layout
- Page Directory at 0x30000, 8 page tables at 0x31000-0x38FFF.
- Identity mapping 0-32 MB in 4 KB pages (no PSE needed, runs
  on everything from the 486 up). **Page 0 is intentionally unmapped** = NULL protection.
- WARNING: that is why the **IDT had to move from 0x500 to 0x2F000** -- it
  lay in the middle of page 0; unmapped would mean: every interrupt -> #PF ->
  triple fault. Whoever tweaks the memory layout: page 0 is off-limits.
- Addresses >= 32 MB are unmapped -> `dump 2000000` triggers a (cleanly
  caught) page fault.

#### #PF handler (vector 14, own gate instead of EXC stub)
- Reads CR2 (the faulting address) and decides based on `cur_thread`:
  - **Agent** (!=0): message with slot+name, task -> status 3 = ERROR
    (new in tstate_names), agent slot freed, `tcb_state[cur]=0`,
    load the next runnable thread, `popal`+`iret`. The other
    threads notice nothing.
  - **Shell** (0): message, then `mov shell_safe_esp,%esp; sti;
    jmp shell`. The anchor is set at the start of each shell round --
    a longjmp in assembler.
- The **error code pushed by the CPU is never cleaned up** -- we
  never return to the offender, both paths replace ESP completely.
- Assumption (documented): ISRs and kernel paths are fault-free; only
  user input (dump address, task scan <addr>) reaches wild
  addresses. A #PF *inside* an ISR would lose its EOI.

#### Demos
- `dump 0` -> "PAGE FAULT at 0x00000000 ... in the shell -- caught".
- `task scan 0` -> agent claims, works ~1.4 s, dereferences NULL ->
  "Agent [n] 'name' shot down, task -> ERROR. System keeps
  running." `tasks` shows the ERROR status, `agents` the freed slot.

#### test.sh
Unchanged, still green for both kernels -- paging is transparent for all
the verified flows.

#### Verified (disassembly)
CR3/CR0.PG sequence, `movl $0,0x31000` (NULL page), idtr->0x2F000,
set_gate->0x2F000, #PF gate (vector 14 -> pf_handler), CR2 read,
kill path end `mov tcb_esp(,%ebx,4),%esp; popal; iret`,
shell path `mov shell_safe_esp,%esp`. Size: 13214 / 25088 bytes.

### New in v1.1 -- Ring 3: agents in userspace (Phase 10)

Full privilege separation: **agents run in Ring 3.** Kernel memory
is only readable for them, I/O and privileged instructions (hlt/cli/in/out) are
forbidden. The only door back: the syscall gate **INT 0x30** -- the
only gate with DPL 3 (`set_gate3`, type byte 0xEE).

#### Building blocks
- **GDT**: +user code 0x18 (0xFA), +user data 0x20 (0xF2), +TSS slot
  0x28 (limit now 47). `tss_init` fills the TSS descriptor at
  runtime (base split!), SS0=0x10, IO bitmap base=0x68 (= "no
  I/O for Ring 3"), `ltr`.
- **Two stacks per agent**: user 0x21000+TID*0x1000, **kernel
  0x41000+TID*0x1000**. On every Ring 3->0 transition the CPU loads
  SS0:ESP0 from the TSS -- `thread_resume` therefore sets ESP0 before
  every switch to a Ring 3 thread to the top of its kernel stack.
  This works because the kernel stack of a thread running in Ring 3 is
  empty by construction.
- **The spawn frame** now lies on the KERNEL stack and has 13 dwords:
  ...registers, EIP, CS=0x1B, EFLAGS=0x202, ESP=user stack, SS=0x23.
  `iret` thereby automatically descends into Ring 3.
- **Paging**: PDEs with the U bit; kernel image pages 7-0xD U=1/W=0
  (readable for agents -- they read ticks and their task fields directly),
  user stacks U=1/W=1, everything else supervisor-only. Ring 0 still writes
  the "read-only" pages, because **CR0.WP=0** remains. Never set WP,
  otherwise the kernel stalls.
- **Syscalls** (EAX=number, EBX=arg, return via the saved EAX slot
  `28(%esp)` in the pushal frame): 0=yield (kernel does sti;hlt),
  1=claim, 2=progress, 3=finish. Interrupt gate => IF=0 => claim/finish
  atomic without explicit cli.
- **#GP (13)** now goes into fault isolation like #PF (gp_handler ->
  pf_common): privileged instructions from Ring 3 cost the agent.
- agent_main computes entirely in Ring 3 (run_task is gone); `task
  scan <addr>` reads the address in Ring 3 -- kernel/device pages
  (e.g. b8000, 2f000, 30000) kill the agent via #PF.

#### Demos
`task scan b8000` -> agent dies at VGA memory (supervisor-only).
`task scan 7c00` -> allowed (the image is readable), returns the checksum.
`dump 0` / `task scan 0` as before. The shell (Ring 0) may still do everything.

#### Verified (disassembly)
GDT bytes FA/F2 + limit 0x2F, tss_init patch sequence + SS0/IO map,
frame values 0x23/0x202/0x1B, thread_resume->tss+4, exactly 1x DPL-3 gate,
5x int $0x30, the EAX slot trick, U-bit loops (0x31007/0x7005/0x21007).
Size: 13935 / 25088. test.sh expected unchanged green (the flows are
identical, only the execution level of the agents is new).

### v1.9-v1.11 - real hardware: the segment-nulling triple fault

Building blind on QEMU for so long, the first boot on the real test PC
(a Haswell desktop) surfaced a
textbook bug QEMU had hidden all along. Symptom: `spawn math` flashed
an error for a tenth of a second, then the machine rebooted unprompted.

A reboot means a TRIPLE fault. But exc_common is supposed to halt with
"CPU EXCEPTION #n" - so the reporting path itself was faulting on a
trashed stack before the message was readable. First move was therefore
diagnostic, not a fix: the 32 exception stubs now pass the vector in
EAX (no push), and exc_common switches to a dedicated panic stack
(0x1D000) and reloads DS/ES before printing - so even with a junk ESP
it FREEZES with the number and the culprit thread instead of rebooting.
Verified with a throwaway int3 build.

The root cause: before the first spawn only the ring-0 shell runs, so
the timer never does a privilege switch. The first spawn makes the
timer iret into ring 3 for the first time - and a real CPU NULLs any
of DS/ES/FS/GS that still holds a DPL-0 selector on a return to lower
privilege (a privilege-leak guard, Intel SDM). The kernel ran with
0x10 (DPL 0), so the agent woke with NULL data segments; its first
memory access - or any ISR firing from ring 3 - #GP'd, and the storm
cascaded to a triple fault. QEMU does not implement the nulling, so it
NEVER showed up in any of our suites.

Fix (v1.10), in thread_resume: load the target ring's data segments
before the iret. Ring-3 threads get the user data segs (0x23, DPL 3),
which iret leaves intact; ring-0 threads get 0x10. Both are base-0
4 GB, so kernel code still reaches all memory through either and QEMU
behaviour is identical - all suites stayed green. The lesson for the
log: "works in QEMU" is not "works on silicon", and the gap is widest
exactly at privilege transitions.

Also this stretch: e1000 NIC driver + a PCI Ethernet probe so an
unknown card reports its own vendor:device (v1.9); a help/about pager
because 40 lines do not fit 24 rows (v1.10); and PXE network boot so
the dev loop no longer needs the stick at all (v1.11).

### v1.52-v1.57 - AHCI: a storage driver written blind, verified over the wire

The test PC's chipset exposes its SATA ports only through AHCI (no legacy
IDE mode), so the kernel's ATA PIO driver was blind there. A full AHCI
block driver followed: the HBA's ABAR mapped as a 4 MB uncached page,
IDENTIFY + READ DMA EXT + WRITE DMA EXT with one command slot and one
PRDT, polled, every wait loop bounded so a sick controller cannot hang
the boot. Shell commands `ahci` (detect + IDENTIFY), `aread <lba>`,
`awrite <lba> <pattern>` (explicit and manual only - writing a real disk
is destructive) and a boot probe that logs the HBA to dmesg (PI bitmap,
per-port SSTS/SIG, then IDENTIFY and an LBA-0 read), so a headless box
self-reports its disk over the UDP log channel.

The driver was developed against QEMU's ICH9 AHCI (test-ahci.sh: the
written sector survives a QEMU restart) and then read back from the real
machine without a screen or keyboard: PI=0x10 (only port 4 wired), SSTS
0x113 (link up), SIG 0xEB140101 - an ATAPI optical drive, not the HDD
(the HDD had been unplugged on purpose so that automatic writes could do
no harm). That drove v1.55-v1.57: ATAPI signatures accepted, IDENTIFY
PACKET DEVICE reads the model string, and ATA PACKET carries READ
CAPACITY(10) and READ(10) so `cdread <lba>` hexdumps a 2048-byte block.
Both were confirmed on the hardware blind over UDP: the model string of
the real DVD writer, then "atapi-cap: no media" from a real SCSI
round-trip. Lesson: a driver that reports its own registers over the
wire can be brought up on hardware you cannot see.

### v1.92-v1.95 - the USB keyboard echo bug: one clobbered register

The EHCI HID driver saw every key: the `usb-kbd:` diagnostic broadcast
showed real keycodes, hid2ascii and push_key looked right, yet nothing
echoed on the real machine. The cause was not in the keyboard path at
all: the periodic poll (`ehci_hid_poll`, called from the idle loop) ran
`arm_qh`, which clobbered EDI - and EDI was `readline`'s line-buffer
pointer. Every key reached the buffer, and the shell silently dropped it.
The fix is one `pushal`/`popal` pair around the poll. Two more lessons
from the same night: enumerating a second device failed because the hub
requests still used the previous port's queue-head characteristics
(restore the hub control QH before each port), and the auto-start of the
USB stack was deliberately left off at boot because enabling it disabled
the BIOS-emulated keyboard before the fix had been confirmed on hardware.
Rule carried forward: a routine called from the idle loop must preserve
every register, because it interrupts arbitrary shell code.

### v2.41-v2.47 - the wish loop goes live, then literal

One session, 2026-06-11, working from the standing order: empty wish
queue, so the work came from the previous commit's "known limitation"
and the roadmap's execution order.

**v2.41 tbl_lock.** v2.40's documented SMP race: sys_claim/sys_finish
relied on IF=0 for atomicity, which only holds per core - two same-type
agents claiming on two cores could double-assign a task. One spinlock
(the sched_lock xchg primitive) around claim's scan-and-take and
finish's table mutation, released before the slow notification path.
Deadlock-free because the lock is only ever held with interrupts off.

**v2.42-v2.43 the wish loop gets a phone, and the box a voice.** 1d:
`llm <text>` -> ring-3 HTTP POST through our own TCP stack to
llm-proxy.py on the dev box (TLS stays off the bare metal, as the
MANIFESTO demands). 2a: an AC97 driver small enough for the budget -
PCI detect, codec bring-up, 440 Hz over a 2-entry BDL, DMA progress
readable from CIV/PICB so the headless gate can assert sound without
hearing it.

**v2.44 the agents language.** `script <slot>` feeds an AgentFS slot
through the v2.19 ';'-chain machinery - every shell command was already
a statement, we just needed a way to store and replay them. `sleep`
paces, ESC aborts (a slot whose last line calls itself is a loop, so
the user needs an exit). Lesson: a typed ';' is consumed by the chainer
before `save` ever sees it, hence commas as the typed separator.

**v2.45-v2.46 the motto becomes literal.** The proxy grew a backend
registry (@claude = a local CLI backend; @api = the Claude API;
@openai = any OpenAI-compatible endpoint; @ollama = local models) with
per-request routing from the OS prompt. Then llmscript: the model
answers with NOTHING but AgentOS commands (the /script system prompt is
the contract), the answer lands in an AgentFS slot via SYS_WRITE_SLOT -
the single, diskon-guarded, slots-only ring-3 disk-write door - and
`script <slot>` executes it. Live-verified: "find the 100th prime and
celebrate with a beep" -> the model wrote the six lines, the OS
computed 541 and beeped.

**v2.47 the harvest was blind.** Writing the SYS_WRITE_SLOT guard forced
a hard look at the disk layout - and v1.78's +157 move (kernel to 128
sectors) had left three host-side spots on the old numbers: wishes.sh
harvested LBA 108 (kernel writes 265 - 'make wishes' read mid-kernel
bytes for ~70 versions), run32 refreshed only 100 of 128 kernel sectors
(every live boot ran a franken-kernel), and the live image had no
medium marker at all (diskon refused, wish could not persist). All
three healed; the proof is a wish typed in the live image surfacing in
'make wishes'. Lesson for the log: a layout move must grep the HOST
scripts too, not just the kernel - QEMU suites all passed because they
use fresh images and the OS-internal paths agreed with themselves.

### v2.60 - the autopilot needed a disk it did not have

**D4.** llmscript/
script/autopilot persist through SYS_WRITE_SLOT, which is diskon-gated,
and diskon REFUSED on the PXE-booted test PC: a diskless box has no
AGENTOS-MEDIUM marker, and the only real disk (GRUB/Ubuntu) is a foreign
medium diskon must protect. So the whole agent-language loop - the
AgentOS thesis - could not run on the actual hardware. The fix keeps the
data-protection guarantee intact: diskon now arms RAM-backed slots
(fs_ram=1, SLOT_RAM at 0x136000, 17x512 B for LBA 257-273) instead of
refusing; ata_read/ata_write reroute just the slot LBAs to that RAM when
fs_ram is set, and everything else (the LBA 256 marker, boot reads, the
ring-3 blob) still hits the disk. Writes are volatile - lost on reboot -
but the foreign disk is NEVER written, which is exactly the promise the
old refusal made. Live-proven end to end on the test PC: diskon -> "slots are
RAM-backed", then a real model (reached through the LAN-discovered proxy) wrote
a spawn/task/sleep/tasks/echo script into RAM slot 7 and the OS executed
it (count 1..100 = 5050). test-d4.sh (in test-all, 17 suites) wipes the
marker, then asserts diskon arms RAM-backed, save/load round-trips in
RAM, and the on-disk sector stays zero. Lesson: a protective refusal
that blocks the headline feature is a design smell - find the path that
keeps the protection AND unblocks the feature (here: never touch the
disk, but do not refuse - redirect to RAM).

## Part 3: the wish log

What was wished for in a running AgentOS with `wish <text>` and what the
LLM sessions built from it (harvested with `make wishes`, cleared with
`./wishes.sh --clear <n>`). The in-OS wish log is short: most later work
came from the roadmap and from the previous version's documented
limitations rather than from wishes typed into the running system.

| Date | Wish | Result |
|------|------|--------|
| 2026-06-06 | UEFI boot support | Hand-written PE32+ (`agentos-uefi.S`, no compiler) loads kernel32.bin from the ESP, ExitBootServices, long-mode to protected-mode descent; the full shell runs under OVMF, ring-3 agents compute. Kernel bug found on the way: firmware hands over CR0.WP=1, which made the kernel's U=1/W=0 trick fault recursively; paging_init now forces WP=0. v1.5 added the framebuffer console (own 8x16 font into the GOP framebuffer; the framebuffer lies outside the identity map, so it is mapped with 4 MB pages via CR4.PSE). |
| 2026-06-07 | (follow-up: make the wish loop work on bare metal) | Hybrid stick (BIOS + UEFI from one image) boots real hardware; the AGENTOS-MEDIUM marker protects foreign disks (diskon refuses without it); wish harvesting over COM1 (wish-bridge), an RTL8139 driver in pure assembler, and `netwish` over UDP broadcast. With that, `wish` works on a diskless real machine too. |
| 2026-06-08 | build me space invaders (arrived via netwish from the test PC, the first wish through the acknowledged return channel) | v1.31: full Space Invaders as the `invaders` command - 32 aliens marching as a block, bombs, one bullet, win/lose, a/d + space + q, built on the snake VGA/shadow/framebuffer machinery. Prerequisites fixed in the same session: RTL8168 receive (acknowledge the ISR each poll, v1.28), the symmetric STATUS/ACK return channel (v1.29) and acknowledged netwish with retry (v1.30). |
