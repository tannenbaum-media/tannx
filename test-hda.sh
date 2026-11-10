#!/usr/bin/env bash
# ============================================================
#  Intel HDA test. The driver lives in ring-3 C
#  (user/hda.c) over two kernel syscalls (PCI cfg + MMIO map). Boots
#  with QEMU's intel-hda + hda-output codec (audio sunk to 'none') and
#  checks: controller found, BAR mapped from ring 3, codec enumerated
#  (DAC + pin), and the stream DMA really moved (LPIB progress).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_hda_XXXX.img)"
cp agentos32.img "$IMG"

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$LOG"
}
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -nographic \
  -audiodev none,id=ad0 -device intel-hda -device hda-output,audiodev=ad0 \
  <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
sleep 4
send 'hda'
sleep 8
send 'echo still-alive'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
QPID=""

echo "==== hda output ===="
sed 's/\r//g' "$LOG" | grep -E "HDA|still-alive" || echo "(no HDA output)"
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "HDA: 8086:"                       "controller detected over SYS_PCI"
chk "HDA: BAR0 [0-9a-f]+ mapped"       "high MMIO BAR mapped into ring 3"
chk "HDA: codec [0-9a-f]+ cad [0-9] afg [0-9]+ dac [0-9]+ pin [0-9]+" "codec walked: AFG/DAC/pin found"
chk "HDA: playing 440"                 "stream programmed, DMA started"
chk "HDA: progress lpib=[1-9][0-9]+"   "link position advanced (DMA streams)"
chk "HDA: done"                        "stream completed and stopped"
chk "still-alive"                      "shell keeps responding afterwards"
[ "$fail" -eq 0 ] && echo "==== HDA OK ====" || { echo "==== HDA FAILED ===="; sed 's/\r//g' "$LOG" | tail -25; }
exit $fail
