#!/usr/bin/env bash
# ============================================================
#  RAM-backed slots. On a diskless PXE boot (the bare-metal test PC) or a foreign
#  internal disk there is no AGENTOS-MEDIUM marker, so 'diskon' used to
#  REFUSE - which blocked llmscript/script/autopilot on real hardware.
#  Now diskon arms RAM-backed slots instead: writes land in a kernel RAM
#  region (volatile), and the foreign disk is NEVER touched. This test
#  wipes the marker (= a foreign disk), then proves:
#    1. diskon reports RAM-backed (no longer "Refusing to arm")
#    2. save/load round-trips through the RAM slot
#    3. the on-disk slot sector stays zero (disk untouched)
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_d4_XXXX.img)"
cp agentos32.img "$IMG"
# Simulate a foreign / diskless box: erase the AGENTOS-MEDIUM marker at LBA 256
dd if=/dev/zero of="$IMG" bs=512 seek=256 count=1 conv=notrunc status=none
# and make sure slot 5 (LBA 262) starts zeroed, so a stray disk write would show
dd if=/dev/zero of="$IMG" bs=512 seek=262 count=1 conv=notrunc status=none

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$LOG"
}
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }

sleep 4
send 'diskon'                       # foreign disk -> must arm RAM-backed, not refuse
sleep 1
send 'save 5 hello-d4-ram'          # write to RAM slot 5 (LBA 262)
sleep 1
send 'load 5'                       # read it back from RAM
sleep 2
send 'echo shell-lives'
sleep 1
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
QPID=""

OUT="$(tr -d '\r' < "$LOG")"
# Read back the on-disk slot sector: must still be all-zero (write went to RAM)
DISKHEX="$(dd if="$IMG" bs=512 skip=262 count=1 2>/dev/null | tr -d '\0' | head -c 32)"

echo "==== d4 console ===="
echo "$OUT" | grep -iE 'ram-backed|refus|hello-d4|shell-lives' | sed 's/^/  /'
echo "==== checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

echo "$OUT" | grep -qi 'RAM-backed'        && a=1 || a=0; chk "$a" "diskon arms RAM-backed slots (no medium)"
echo "$OUT" | grep -qi 'Refusing to arm'   && b=0 || b=1; chk "$b" "diskon does NOT refuse anymore"
echo "$OUT" | grep -q  'hello-d4-ram'      && c=1 || c=0; chk "$c" "save/load round-trips through the RAM slot"
echo "$OUT" | grep -q  'shell-lives'       && d=1 || d=0; chk "$d" "shell still alive after RAM I/O"
[ -z "$DISKHEX" ]                          && e=1 || e=0; chk "$e" "on-disk slot sector stays zero (disk untouched)"

echo "==== D4 OK ====" && [ "$fail" = 0 ] && exit 0
echo "==== D4 FAILED ===="; exit 1
