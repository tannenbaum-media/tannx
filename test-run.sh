#!/bin/bash
# test-run.sh - ABI v2 / C-userspace proof (Phase 1).
#   Boots agentos32.img as a BIOS hard disk (the blob rides at LBA 300),
#   issues 'run' over the serial console, and checks that the gcc-built
#   ring-3 C program reached COM1 with its banner. Then 'kill 0' and a
#   follow-up command confirm the shell survived the ring-3 program.
#   Pure serial, headless - same mechanism as test.sh.
set -u
IMG="${1:-agentos32.img}"
TMPIMG=$(mktemp /tmp/agentos_run.XXXX.img)
FIFO=$(mktemp -u /tmp/agentos_run.XXXX.fifo)
LOG=$(mktemp /tmp/agentos_run.XXXX.log)
FAILED=0

command -v qemu-system-i386 >/dev/null 2>&1 || {
  echo "qemu-system-i386 missing (sudo apt install qemu-system-x86)"; exit 2; }
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 2; }

cp "$IMG" "$TMPIMG"
mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$TMPIMG" \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; rm -f "$TMPIMG" "$FIFO" "$LOG"; }
trap cleanup EXIT

send() {  # send a line CHAR BY CHAR (whole lines lose bytes)
  local s="$1" i
  for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done
  printf '\r' >&3
}
check() {  # check <description> <fixed-string>
  local t=0
  while [ "$(grep -aFc -- "$2" "$LOG")" -lt 1 ]; do
    sleep 0.3; t=$((t + 1))
    if [ $t -ge 40 ]; then echo "FAIL : $1"; FAILED=1; return 1; fi
  done
  echo "OK   : $1"
}

# wait for the shell prompt
for t in $(seq 1 50); do grep -aq "tannx> " "$LOG" && break; sleep 0.3; done
sleep 1

send "run"
check "C program prints its banner over serial (SYS_WRITE)" "hello from ring3 C"
check "C program read the framebuffer info (SYS_FBINFO)"    "framebuffer "
check "C program finds the M-JPEG clip on disk (SYS_READ_SECTORS)" "(M-JPEG)"
check "C program decodes a JPEG frame in ring 3 (jpeg.c)"          "decoded frame 0 OK"

sleep 1
send "kill 0"
check "kill stops the ring-3 program"                       "] stopped."

# shell still alive after running + killing a ring-3 program? 'agents'
# was never issued before, so its output only appears if it ran now -
# and "No agents active" also proves the slot was freed by kill.
send "agents"
check "shell keeps responding after the ring-3 program"     "No agents active"

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "==== test-run PASSED ===="; exit 0
else echo "==== test-run FAILED ===="; echo "--- log ---"; cat "$LOG"; exit 1; fi
