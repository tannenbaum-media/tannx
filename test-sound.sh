#!/usr/bin/env bash
# ============================================================
#  AC97 sound test. Boots agentos32.img with QEMU's AC97
#  device (audio sunk to 'none' - headless), runs the 'sound' command and
#  checks the driver detected the controller, the codec came ready, and
#  the PCM-out bus master actually consumed samples (CIV/PICB progress).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_snd_XXXX.img)"
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
  -audiodev none,id=ad0 -device AC97,audiodev=ad0 <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
sleep 4
send 'sound'
sleep 6
send 'echo still-alive'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
QPID=""

echo "==== sound output ===="
sed 's/\r//g' "$LOG" | grep -E "AC97|still-alive" || echo "(no AC97 output)"
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "AC97: NAM 0x[0-9A-Fa-f]+ NABM 0x[0-9A-Fa-f]+" "controller detected, BARs read"
chk "AC97: playing 440"                            "codec ready, playback started"
chk "picb=[1-9][0-9]*"                            "bus master consumed samples (PICB advanced)"
chk "AC97: done, sr=0x"                            "playback ran to the last valid entry"
chk "still-alive"                                  "shell keeps responding afterwards"
[ "$fail" -eq 0 ] && echo "==== AC97 OK ====" || { echo "==== AC97 FAILED ===="; sed 's/\r//g' "$LOG" | tail -25; }
exit $fail
