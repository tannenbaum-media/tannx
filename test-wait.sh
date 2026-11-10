#!/usr/bin/env bash
# ============================================================
#  Wait self-heal test. A model-written program that never exits under
#  'wait' wedged the autopilot in the field. Now 'wait' kills a program that
#  goes WAIT_BUDGET (~30 s) with NO sys_progress heartbeat - it's stuck - and
#  drops the chain, so the autopilot recovers WITHOUT a human or a reboot. A
#  legit slow LLM call heartbeats via recv_tcp, so it never trips this.
#  Here we wedge with `gui; wait` (the compositor never heartbeats) and confirm
#  the wait self-heals after ~30 s and the shell answers again.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$LOG"
}
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }

sleep 4
send 'gui'                       # a ring-3 program that never exits / heartbeats
sleep 2
send 'wait'                      # blocks on it - the wedge
sleep 2
send 'echo wait-self-healed'     # queued; runs only once the wait gives up
sleep 35                         # WAIT_BUDGET ~30 s, then the timeout fires
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

OUT="$(tr -d '\r' < "$LOG")"
echo "==== wait self-heal console (tail) ===="
echo "$OUT" | tail -6 | sed 's/^/  /'
echo "==== checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
echo "$OUT" | grep -q 'program stuck' && a=1 || a=0
chk "$a" "'wait' self-heals: a no-heartbeat program is killed after the budget"
echo "$OUT" | grep -q 'wait-self-healed' && b=1 || b=0
chk "$b" "the shell answers again - the autopilot recovers, no reboot"
[ "$fail" = 0 ] && { echo "==== WAIT OK ===="; exit 0; }
echo "==== WAIT FAILED ===="; exit 1
