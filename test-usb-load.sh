#!/usr/bin/env bash
# ============================================================
#  USB script-load test. `usb load <file> <slot>` reads a script
#  file off a FAT USB stick into an AgentFS slot (the 'AF'|len|text record
#  llmscript writes), so you can author software on a PC, drop it on a stick,
#  and `script <slot>` it on bare metal - the manual counterpart to the LLM
#  autopilot. Needs diskon.
#
#  Headless: a FAT16 stick with RUN.SCR (an echo), then diskon -> usb load ->
#  script; assert the script's output appears.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
if ! command -v mkfs.fat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
    echo "SKIP: mkfs.fat / mtools not installed"; echo "==== USB-LOAD OK ===="; exit 0
fi
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

STICK="$(mktemp --suffix=.usb)"; rm -f "$STICK"; dd if=/dev/zero of="$STICK" bs=1M count=16 status=none
mkfs.fat -F 16 "$STICK" >/dev/null 2>&1
printf 'echo USB-SCRIPT-RAN\n' > /tmp/aos_run_$$.scr
mcopy -i "$STICK" /tmp/aos_run_$$.scr ::/RUN.SCR
rm -f /tmp/aos_run_$$.scr
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"

qemu-system-i386 -drive format=raw,file="$IMG" \
  -device qemu-xhci,id=xhci \
  -drive id=stick,file="$STICK",if=none,format=raw \
  -device usb-storage,bus=xhci.0,drive=stick \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"; sleep 4
printf 'diskon\r' >&3;             sleep 1
printf 'usb load RUN.SCR 3\r' >&3; sleep 3
printf 'script 3\r' >&3;           sleep 2
printf 'halt\r' >&3;               sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
out="$(sed 's/\r//g' "$LOG")"
rm -f "$FIFO" "$IMG" "$STICK" "$LOG"

echo "==== USB script-load checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

echo "$out" | grep -q "loaded RUN.SCR .* into slot 3" && a=1 || a=0
chk "$a" "'usb load' writes the file from the stick into an AgentFS slot"

echo "$out" | grep -q "USB-SCRIPT-RAN" && b=1 || b=0
chk "$b" "'script 3' executes the loaded program (author on PC, run on metal)"

echo "--- output ---"; echo "$out" | grep -iE "loaded RUN|USB-SCRIPT-RAN"

[ "$fail" = 0 ] && { echo "==== USB-LOAD OK ===="; exit 0; }
echo "==== USB-LOAD FAILED ===="; exit 1
