#!/usr/bin/env bash
# ============================================================
#  Mission telemetry test. The free-running autopilot
#  runs 'llmscript 7 autopilot <mission>' each round; the kernel captures
#  that mission text (capture_mission) and exposes it as the autopilot's
#  current round + mission - over the wire in STATUS (mis=<text>, for
#  tools/lan/autopilot-monitor.sh) and locally in the `mem` command.
#
#  Verified purely over the SERIAL console (deterministic): type the
#  llmscript (capture_mission runs at dispatch, before the network call,
#  so no proxy is needed), then `mem`, and read back the mission.
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
MISSION="find-primes-under-200"

qemu-system-i386 -drive format=raw,file="$IMG" -nographic -net none <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
# round 0: mem before any autopilot round - mission empty
printf 'mem\r' >&3;                              sleep 1
# capture a mission. llmscript launches a ring-3 net program that will fail
# without a proxy, but capture_mission already ran at command dispatch.
printf 'llmscript 7 autopilot %s\r' "$MISSION" >&3; sleep 2
printf 'kill 0\r' >&3;                           sleep 1
printf 'mem\r' >&3;                              sleep 1
printf 'halt\r' >&3;                             sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

echo "==== mission telemetry checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

# the second `mem` (after the llmscript) must show the captured mission
grep -aq "autopilot round" "$LOG" && a=1 || a=0
chk "$a" "mem reports the autopilot round + mission line"

grep -aq "mission $MISSION" "$LOG" && b=1 || b=0
chk "$b" "capture_mission copied the mission text after 'autopilot '"

[ "$fail" = 0 ] && { echo "==== MISSION OK ===="; exit 0; }
echo "==== MISSION FAILED ===="; exit 1
