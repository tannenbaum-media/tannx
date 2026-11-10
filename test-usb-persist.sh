#!/usr/bin/env bash
# ============================================================
#  USB-backed persistence test. A diskless (PXE-booted) PC keeps its AgentFS
#  slots (the LLM-written scripts) in RAM, so a reboot wipes them. With a USB
#  stick, `usb backup` copies the 8 slots to the stick and `usb restore`
#  writes them back - local persistence, no dev-box proxy needed.
#
#  Headless proof of the round-trip: diskon, save a known string to slot 0,
#  `usb backup`, OVERWRITE slot 0 (simulate loss), `usb restore`, then `load
#  0` must show the ORIGINAL string - it came back off the USB stick.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)";   cp agentos32.img "$IMG"
STICK="$(mktemp --suffix=.usb)"; dd if=/dev/zero of="$STICK" bs=1M count=8 status=none
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"

run_stick() {   # $1 = stick image; drives one boot, appends to $LOG
  qemu-system-i386 -drive format=raw,file="$IMG" \
    -device qemu-xhci,id=xhci \
    -drive id=stick,file="$1",if=none,format=raw \
    -device usb-storage,bus=xhci.0,drive=stick \
    -nographic <"$FIFO" >>"$LOG" 2>/dev/null &
  QPID=$!
  exec 3>"$FIFO"
  sleep 4
}

# --- boot 1: the round-trip on a BLANK stick (backup allowed) --------------
: > "$LOG"; run_stick "$STICK"
printf 'diskon\r' >&3;                 sleep 1
printf 'save 0 PERSIST-USB-OK\r' >&3;  sleep 1
printf 'usb backup\r' >&3;             sleep 4
printf 'save 0 GONE-OVERWRITTEN\r' >&3; sleep 1
printf 'usb restore\r' >&3;            sleep 4
printf 'load 0\r' >&3;                 sleep 1
printf 'halt\r' >&3;                   sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
out="$(sed 's/\r//g' "$LOG")"

# --- boot 2: a FORMATTED stick - `usb backup` must REFUSE, `force` overrides
GUARDOUT=""
if command -v mkfs.fat >/dev/null 2>&1; then
  FATSTICK="$(mktemp --suffix=.usb)"; dd if=/dev/zero of="$FATSTICK" bs=1M count=8 status=none
  mkfs.fat -F 12 "$FATSTICK" >/dev/null 2>&1
  : > "$LOG"; run_stick "$FATSTICK"
  printf 'diskon\r' >&3;               sleep 1
  printf 'save 0 PERSIST-USB-OK\r' >&3; sleep 1
  printf 'usb backup\r' >&3;           sleep 3    # must be refused (FAT sig present)
  printf 'usb backup force\r' >&3;     sleep 4    # explicit override proceeds
  printf 'halt\r' >&3;                 sleep 1
  exec 3>&- 2>/dev/null
  kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
  GUARDOUT="$(sed 's/\r//g' "$LOG")"
  rm -f "$FATSTICK"
fi
rm -f "$FIFO" "$IMG" "$STICK"

echo "==== USB persistence checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

echo "$out" | grep -q "backed up 8 AgentFS slots to USB" && a=1 || a=0
chk "$a" "'usb backup' copies the 8 AgentFS slots onto the USB stick"

echo "$out" | grep -q "restored 8 AgentFS slots from USB" && b=1 || b=0
chk "$b" "'usb restore' writes the slots back from the stick (needs diskon)"

# the decisive one: slot 0 was overwritten with GONE-OVERWRITTEN, then restored;
# load 0 must show the ORIGINAL PERSIST-USB-OK -> it survived on the stick.
echo "$out" | grep -q "Slot \[0\]: PERSIST-USB-OK" && c=1 || c=0
chk "$c" "after restore, slot 0 holds the original (round-trip over the wipe)"

# --- the destructive-default guard (audit finding 7): a formatted stick is protected
if [ -n "$GUARDOUT" ]; then
  echo "$GUARDOUT" | grep -q "refusing 'usb backup'" && d=1 || d=0
  chk "$d" "'usb backup' REFUSES a formatted stick (audit finding 7: no raw LBA-0 clobber)"
  echo "$GUARDOUT" | grep -q "backed up 8 AgentFS slots to USB" && e=1 || e=0
  chk "$e" "'usb backup force' overrides the guard and writes anyway"
else
  echo "SKIP : backup-guard check (mkfs.fat not installed)"
fi

echo "--- output ---"; echo "$out" | grep -iE "backed up|restored|Slot \[0\]" | tail
[ -n "$GUARDOUT" ] && { echo "--- guard output ---"; echo "$GUARDOUT" | grep -iE "refusing|backed up"; }
rm -f "$LOG"

[ "$fail" = 0 ] && { echo "==== USB-PERSIST OK ===="; exit 0; }
echo "==== USB-PERSIST FAILED ===="; exit 1
