#!/usr/bin/env bash
# SMP smoke test: boot QEMU with multiple virtual CPUs, arm APs on demand,
# then prove ring-3 agent work still completes while AP scheduler counters move.
set -u
IMG=agentos32.img
LOG="$(mktemp /tmp/agentos_smp_XXXX.log)"
TMPIMG="$(mktemp /tmp/agentos_smp_XXXX.img)"
FIFO="$(mktemp -u /tmp/agentos_smp_XXXX.in)"

command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 2; }

cp "$IMG" "$TMPIMG"
mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$TMPIMG" -smp 4 -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QP=$!
exec 3>"$FIFO"

cleanup() {
  exec 3>&- 2>/dev/null
  kill "$QP" 2>/dev/null
  wait "$QP" 2>/dev/null
  rm -f "$TMPIMG" "$FIFO" "$LOG"
}
trap cleanup EXIT

send() { printf '%s\r' "$1" >&3; }

sleep 4
send 'smp';              sleep 1
send 'smpon';            sleep 4
send 'smp';              sleep 1
send 'spawn prime';      sleep 1
send 'spawn count';      sleep 1
send 'task prime 100';   sleep 1
send 'task count 100';   sleep 4
send 'tasks';            sleep 1
send 'smp';              sleep 1
send 'echo smp-survived'; sleep 1
send 'halt';             sleep 1
kill "$QP" 2>/dev/null
wait "$QP" 2>/dev/null

CLEAN="$(mktemp /tmp/agentos_smp_clean_XXXX.log)"
sed 's/\r//g' "$LOG" >"$CLEAN"

echo "==== SMP smoke checks ===="
fail=0
chk() { if grep -q "$1" "$CLEAN"; then echo "OK   : $2"; else echo "MISS : $2"; fail=1; fi; }
chk "SMP: cores 1  online 1" "SMP starts safe on the boot core before smpon"
chk "SMP armed - the other cores run agent threads now" "smpon wakes the APs on demand"
chk "SMP: cores 4  online 4" "QEMU -smp 4 reports four online cores after smpon"
chk "prime n=100 -> done = 541" "prime agent completes under SMP"
chk "count n=100 -> done = 5050" "count agent completes under SMP"
chk "smp-survived" "shell keeps responding after SMP agent work"

if grep -Eq 'thread-runs per core .*\[[1-3]\][1-9][0-9]*' "$CLEAN"; then
  echo "OK   : at least one AP ran scheduler work"
else
  echo "MISS : at least one AP ran scheduler work"
  fail=1
fi

echo "---- smp excerpts ----"
grep -E 'SMP:|thread-runs|prime n=100|count n=100|smp-survived' "$CLEAN" || true
rm -f "$CLEAN"

[ "$fail" = 0 ] && { echo "==== SMP OK ===="; exit 0; }
echo "==== SMP FAILED ===="; exit 1
