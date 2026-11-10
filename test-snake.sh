#!/bin/bash
# test-snake.sh - the ring-3 snake game (snake moved out of the kernel
#   into userspace C, 'run snake'). Boots agentos32.img as a BIOS disk (the
#   blob rides at LBA 300), issues 'run snake', steers with WASD and quits
#   with 'q'. Pure serial, headless - same mechanism as test-run.sh. The
#   framebuffer rendering is verified visually by a human on real hardware
#   (project convention); here we prove the game launches, takes input, and
#   exits cleanly leaving the shell alive.
set -u
IMG="${1:-agentos32.img}"
TMPIMG=$(mktemp /tmp/agentos_snake.XXXX.img)
FIFO=$(mktemp -u /tmp/agentos_snake.XXXX.fifo)
LOG=$(mktemp /tmp/agentos_snake.XXXX.log)
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
key() { printf '%s' "$1" >&3; }      # a single raw keypress (no CR)
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

# launch via the 'snake' command (the launcher path: run_start + fg_prog input
# routing). fg_prog keeps the steering/quit keys out of the shell command line.
send "snake"
check "snake launches in ring 3 and announces itself"  "snake: ready"

# the title auto-starts after ~3 s; steer a little with WASD, then quit with q
sleep 4
for c in d d s s a a w w; do key "$c"; sleep 0.2; done
key "q"
check "q quits the game cleanly with a final score line"  "snake: quit. Score:"

# SLOT REUSE (regression guard): launch a SECOND program. It reuses the freed
# thread slot - if creation doesn't reset tcb_running the run-queue scan skips
# it forever and only one ring-3 program ever runs per boot (the v2.34 bug).
sleep 1
send "invaders"
check "a second program reuses the freed slot and runs"  "invaders: ready"
sleep 4
for c in a a d d; do key "$c"; sleep 0.2; done
key "q"
check "the second program also quits cleanly"  "invaders: quit. Score:"

# the shell must survive both ring-3 programs that ran and exited
sleep 1
send "echo snake-done"
check "shell keeps responding after the programs exit"  "snake-done"

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "==== test-snake PASSED ===="; exit 0
else echo "==== test-snake FAILED ===="; echo "--- log ---"; cat "$LOG"; exit 1; fi
