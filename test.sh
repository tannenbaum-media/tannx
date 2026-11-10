#!/usr/bin/env bash
# ============================================================
#  TannX OS smoke test
#  Boots the image headless in QEMU and drives it entirely
#  over the serial console (COM1). Then checks the log.
#  Usage: ./test.sh [path/to/agentos.img]
#
#  Feeding is FEEDBACK-DRIVEN: the kernel echoes every received
#  char, so each command waits for its own echo line
#  ("tannx> <cmd>") and is retried if chars got dropped (serial
#  RX bytes can get lost while ISRs run - observed as 'dikon',
#  'loa 0', 'alt').
# ============================================================
set -u
IMG="${1:-agentos.img}"
LOG="$(mktemp /tmp/agentos_test_XXXX.log)"
TMPIMG="$(mktemp /tmp/agentos_test_XXXX.img)"
FIFO="$(mktemp -u /tmp/agentos_test_XXXX.in)"

# 32-bit image (agentos32*/hybrid*)? Then additionally check the ring-3 +
# paging protection paths. The non-32 branch dates from the retired
# German-speaking 16-bit kernel and is kept only for the image-name switch.
IS32=0
case "$(basename "$IMG")" in *32*|*hybrid*) IS32=1 ;; esac
TO=60; [ "$IS32" -eq 1 ] && TO=150; TO=${TEST_TIMEOUT:-$TO}   # global watchdog (TEST_TIMEOUT overrides, e.g. slow CI runners) (seconds; grew with the
                                     # added mmcheck/display/modulo feed steps)
SPAWN_PAT="math)-Agent bereit"
[ "$IS32" -eq 1 ] && SPAWN_PAT="math) agent ready"

command -v qemu-system-i386 >/dev/null 2>&1 || {
  echo "qemu-system-i386 missing (sudo apt install qemu-system-x86)"; exit 2; }
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 2; }

cp "$IMG" "$TMPIMG"   # test run leaves the original untouched
mkfifo "$FIFO"

qemu-system-i386 -drive format=raw,file="$TMPIMG" \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"        # keep the serial input open for the whole run
trap '' PIPE         # if the watchdog kills QEMU, fail the checks instead of dying on SIGPIPE

cleanup() {
  exec 3>&- 2>/dev/null
  kill "$QPID" 2>/dev/null
  rm -f "$TMPIMG" "$FIFO"
}
trap cleanup EXIT

send() {  # send a line CHAR BY CHAR (whole lines lose bytes even more)
  local s="$1" i
  for ((i = 0; i < ${#s}; i++)); do
    printf '%s' "${s:$i:1}" >&3
    sleep 0.02
  done
  printf '\r' >&3
}

declare -A SENT       # how often each command was issued successfully
sendw() {  # send <cmd> and wait until its echo count confirms receipt
  local cmd="$1" need t=0
  SENT["$cmd"]=$(( ${SENT["$cmd"]:-0} + 1 ))
  need=${SENT["$cmd"]}
  send "$cmd"
  # fixed-string grep: commands contain regex chars ('*'); the echoed
  # line ends in \r, which doubles as our end-of-command anchor
  while [ "$(grep -aFc -- "tannx> $cmd"$'\r' "$LOG")" -lt "$need" ]; do
    sleep 0.3; t=$((t+1))
    if [ $t -eq 10 ] || [ $t -eq 25 ]; then
      printf '\r' >&3            # flush a possibly half-received line
      sleep 0.3                  # (executes harmless garbage), retry
      send "$cmd"
    fi
    if [ $t -ge 40 ]; then
      echo "WARN : no echo for '$cmd' - continuing" >&2
      return 1
    fi
  done
}

feed() {
  sleep 3                                   # wait for boot + banner
  sendw 'spawn math';                       sleep 1
  sendw 'task math 1337 * 42';              sleep 1
  sendw 'calc 12345 % 1000';                sleep 1   # modulo in the calculator -> 345 (unique)
  # INT_MIN / -1 overflows idiv -> #DE (not divide-by-zero): must be guarded,
  # not fault. Returns the wrapped INT_MIN; the shell must stay alive after.
  sendw 'calc 2147483648 / -1';             sleep 1   # -> -2147483648, no fault
  sendw 'echo calc-idivguard-ok';           sleep 1
  sendw 'task math 100 % 7';                sleep 2   # modulo in the math agent -> 2
  sendw 'tick';                             sleep 1
  sendw 'tick';                             sleep 1
  sendw 'tick';                             sleep 1
  sendw 'tasks';                            sleep 1
  sendw 'spawn count';                      sleep 1
  sendw 'task count 100';                   sleep 1
  sendw 'auto';                             sleep 5
  sendw 'tasks';                            sleep 1
  sendw 'auto';                             sleep 1   # deprecated no-op, must not break the chain
  # again - while the ISR scheduler runs (IF=0) even more RX bytes get
  # lost. In the 32-bit kernel 'auto' only prints an info text.
  sendw 'diskon';                           sleep 1
  sendw 'save 0 serial self-test';          sleep 1
  sendw 'load 0';                           sleep 2
  if [ "$IS32" -eq 1 ]; then
    # Protection paths: ring-3 agent reads VGA (0xB8000)
    # -> #PF, only the agent dies (task -> ERROR), the system lives on.
    sendw 'spawn scan';                     sleep 1
    sendw 'task scan b8000';                sleep 4
    sendw 'tasks';                          sleep 1
    sendw 'echo still-alive';               sleep 1
    sendw 'spawn fault';                    sleep 1
    sendw 'task fault';                     sleep 4
    sendw 'tasks';                          sleep 1
    sendw 'echo fault-isolated';            sleep 1
    # LINEMAX is 254 - a >62-char typed line must arrive
    # complete (the old cap silently truncated it after 62 chars)
    sendw 'echo longline-0123456789012345678901234567890123456789012345678901234567890123456789-END';  sleep 1
    # Heap: alloc/free/heap, double-free detection. The
    # addresses are deterministic: the first block sits at 0x4000010 (heap relocated to high RAM).
    sendw 'alloc 100';                      sleep 1
    sendw 'alloc 200';                      sleep 1
    sendw 'free 4000010';                     sleep 1
    sendw 'heap';                           sleep 1
    sendw 'free 4000010';                     sleep 1
    # Isolation: sys_mmiomap must REFUSE the kernel heap (relocated to
    # 64 MB) so untrusted ring-3 code can't alias it; device BARs above RAM still map.
    # AFTER the heap test - 'run' touches the kernel heap, so keep that test pristine.
    sendw 'run mmcheck';                    sleep 2
    # A ring-3 syscall entered with DF=1 must NOT run its rep
    # movs/stos backwards into kernel RAM - syscall_isr does `cld`. The
    # probe sets DF, calls sys_setmission, reads it back: mission round-trips.
    sendw 'run dfcheck';                     sleep 2
    sendw 'echo df-survived';               sleep 1
    # Task type prime: 100th prime = 541
    sendw 'spawn prime';                    sleep 1
    sendw 'task prime 100';                 sleep 3
    sendw 'tasks';                          sleep 1
    sendw 'spawn gcd';                      sleep 1
    sendw 'task gcd 48 18';                 sleep 2
    sendw 'tasks';                          sleep 1
    # The smoke path has now filled all 8 task slots; reap before the next
    # queueing check. The result strings above stay in the log for assertions.
    sendw 'reap';                           sleep 1
    sendw 'spawn count';                    sleep 1
    # 32-bit task arg: 'count 70000' must use the FULL value, not
    # wrap at 16 bits (70000 & 0xffff = 4464 -> the old sum was 9965880).
    sendw 'task count 70000';               sleep 2
    sendw 'tasks';                          sleep 1
    # top: let it run 2 s, q quits without enter.
    # No echo-wait here: top takes over the console.
    send 'top';                             sleep 2
    printf 'q' >&3;                         sleep 1
    sendw 'echo top-done';                  sleep 1
    # banner (extra): box frame around the text
    sendw 'banner agentos';                 sleep 1
    # kbd (extra): layout switch reports; the scancode path itself was
    # proven via QEMU monitor sendkey (y/z swap) - serial input
    # bypasses the keyboard map, so that part cannot be tested here
    sendw 'kbd de';                         sleep 1
    sendw 'kbd us';                         sleep 1
    # snake easter egg: title screen auto-starts (~3 s) into play, then q
    # quits the running game ("snake: quit. Score:"); shell must survive.
    sendw 'snake';                          sleep 4
    printf 'q' >&3;                         sleep 1
    # wish loop (the TannX OS idea): store + list; diskon is already
    # armed from the AgentFS section above
    sendw 'wish play mp3 files';            sleep 1
    sendw 'wishes';                         sleep 1
    sendw 'sendwishes';                     sleep 1   # 8.1: serial harvest
    sendw 'sysinfo';                        sleep 1   # hw detection (CPU/SMBIOS/RAM)
    sendw 'display';                        sleep 1   # framebuffer geometry
  fi
  sendw 'mem';                              sleep 1   # prove all 256 sectors loaded
  send 'halt';                              sleep 1
}

( sleep "$TO"; kill "$QPID" 2>/dev/null ) &  # watchdog
WPID=$!
feed
kill "$QPID" 2>/dev/null                     # halt only stops the CPU,
kill "$WPID" 2>/dev/null                     # QEMU keeps running
wait "$QPID" 2>/dev/null

# --- 8.0 negative path: WITHOUT the medium marker, diskon must refuse
NEGLOG=""
if [ "$IS32" -eq 1 ]; then
  NEGIMG="$(mktemp /tmp/agentos_test_XXXX.negimg)"
  NEGLOG="$(mktemp /tmp/agentos_test_XXXX.neglog)"
  cp "$IMG" "$NEGIMG"
  dd if=/dev/zero of="$NEGIMG" bs=512 seek=256 count=1 conv=notrunc status=none
  { sleep 3; printf 'diskon\r'; sleep 1; printf 'halt\r'; sleep 1; } | \
    timeout --foreground 15 qemu-system-i386 \
      -drive format=raw,file="$NEGIMG" -nographic >"$NEGLOG" 2>/dev/null || true
  rm -f "$NEGIMG"
fi

echo
echo "==== Checks ($LOG) ===="
fail=0
check() {  # check <pattern> <description>
  if grep -q "$1" "$LOG"; then
    echo "OK   : $2"
  else
    echo "MISS : $2   (pattern: $1)"
    fail=1
  fi
}
check "TannX"          "system boots, banner arrives via COM1"
check "tannx>"             "shell prompt appears"
check "$SPAWN_PAT"           "spawn math"
check "= 56154"              "math agent computes 1337*42 (tick)"
check "math 100 % 7 -> done = 2" "math agent computes modulo (100 % 7 = 2)"
check "= 345"                "calc computes modulo (12345 % 1000 = 345)"
check "= -2147483648"        "calc guards INT_MIN / -1 (idiv overflow, no #DE)"
check "calc-idivguard-ok"    "shell survives the INT_MIN / -1 calc"
check "KSENT256"             "all 256 kernel sectors loaded (kernel budget)"
check "= 5050"               "count agent sums 1..100 (auto/ISR)"
check "]: serial self-test"  "AgentFS: save+load via our own ATA driver"
if [ "$IS32" -eq 1 ]; then
  # note: the kernel prints hex in LOWERCASE (phex_nib: add $0x57)
  check "PAGE FAULT at 0x000b8000" "protection: scan b8000 faults at the real address"
  check "shot down"                "MMU shoots down only the agent, not the system"
  check "scan @0x.*-> ERROR"       "tasks shows the scan task as ERROR"
  check "still-alive"              "shell keeps responding after the page fault"
  check "FAULT (#DE/#UD/#OF/#BR) in ring 3" "exception isolation: #UD in a ring-3 agent is caught"
  check "fault  -> ERROR"          "tasks shows the fault task as ERROR"
  check "fault-isolated"           "shell keeps responding after the #UD agent fault"
  check "longline-0123456789012345678901234567890123456789012345678901234567890123456789-END" "LINEMAX: a >62-char line survives readline + the chainer"
  check "mmcheck: kernel-heap map REFUSED" "isolation: sys_mmiomap refuses the kernel heap"
  check "dfcheck: DF=1 setmission r=0 mission='DFPROBE'" "isolation: syscall_isr cld neutralizes ring-3 DF"
  check "df-survived"              "shell keeps responding after the DF=1 syscall probe"
  check "display: [0-9]* x [0-9]*" "display: reports the framebuffer geometry"
  check "alloc: 100 bytes at 0x04000010" "kmalloc: first block at the arena start"
  check "0x04000000: 112 bytes, free"    "kfree frees, heap walks the list"
  check "0x04000080: 208 bytes, used"    "kmalloc splits, neighbour block stays used"
  check "double free detected"           "double free is detected and reported"
  check "prime n=100 -> done = 541"      "prime agent finds the 100th prime (ring 3)"
  check "gcd 48 18 -> done = 6"          "gcd agent computes the greatest common divisor"
  check "count n=70000 -> done = 2450035000" "task arg is full 32-bit (count 70000, no 16-bit wrap)"
  if [ "$(grep -ac -- '--- top ---' "$LOG")" -ge 2 ]; then
    echo "OK   : top refreshes repeatedly (1 s pace via ticks)"
  else
    echo "MISS : top refreshes repeatedly   (pattern: 2x '--- top ---')"
    fail=1
  fi
  check "top-done"                       "q quits top, shell responds again"
  check "| agentos |"                    "banner draws the box frame"
  check "Keyboard layout: German"        "kbd de switches the layout"
  check "Keyboard layout: US"            "kbd us switches back"
  check "snake: quit. Score:"            "snake easter egg starts and quits cleanly"
  check "Wish stored on disk"            "wish writes its slot via the ATA driver"
  check "]: play mp3 files"              "wishes lists the pending wish"
  # D4: on an unmarked (foreign/diskless) disk, diskon no longer refuses -
  # it arms RAM-backed slots (volatile) and never writes the foreign disk.
  if grep -aq "RAM-backed" "$NEGLOG" && ! grep -aq "writes ARMED" "$NEGLOG"; then
    echo "OK   : diskon arms RAM-backed slots on an unmarked disk (D4, disk untouched)"
  else
    echo "MISS : diskon arms RAM-backed slots on an unmarked disk (D4, disk untouched)"
    fail=1
  fi
  # 8.1: sendwishes frames the wishes machine-readably for the bridge
  if grep -aqz "<<AGENTOS-WISHES.*WISH:play mp3 files.*AGENTOS-END" "$LOG"; then
    echo "OK   : sendwishes beams a framed wish block over COM1"
  else
    echo "MISS : sendwishes beams a framed wish block over COM1"
    fail=1
  fi
  # hardware detection: CPU via cpuid, System via SMBIOS, RAM summed
  check "CPU:    GenuineIntel"           "sysinfo reads the CPU via cpuid"
  check "System: QEMU"                   "sysinfo reads the board via SMBIOS/DMI"
  check "RAM:    [0-9]"                   "sysinfo reports installed RAM"
  check "Disk:   QEMU HARDDISK"           "sysinfo identifies the ATA disk (model + size)"
  check "GPU:    1234:1111"               "sysinfo detects the display controller (pci_find_class)"
  check "NIC:    8086:100e"               "sysinfo detects the network controller (pci_find_class)"
fi

if [ "$fail" -eq 0 ]; then
  echo "==== ALL TESTS PASSED ===="
  exit 0
else
  echo "==== TESTS FAILED - inspect the log: $LOG ===="
  exit 1
fi
