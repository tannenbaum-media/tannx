#!/usr/bin/env bash
# ============================================================
#  TannX OS UEFI smoke test
#  Boots uefi.img headless under OVMF: stage 0 loads the real
#  kernel from the ESP, leaves boot services, drops from long
#  mode to protected mode - and the full TannX OS shell must
#  answer over serial, agents included.
#  Usage: ./test-uefi.sh [path/to/uefi.img]
# ============================================================
set -u
IMG="${1:-uefi.img}"
FW="/usr/share/ovmf/OVMF.fd"
LOG="$(mktemp /tmp/agentos_uefi_XXXX.log)"
FIFO="$(mktemp -u /tmp/agentos_uefi_XXXX.in)"

[ -f "$IMG" ] || { echo "image not found: $IMG (run 'make uefi')"; exit 2; }
[ -f "$FW" ]  || { echo "OVMF firmware missing (sudo apt install ovmf)"; exit 2; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || {
  echo "qemu-system-x86_64 missing"; exit 2; }

KVM=""
[ -w /dev/kvm ] && KVM="-enable-kvm"
mkfifo "$FIFO"

PPM="$(mktemp /tmp/agentos_uefi_XXXX.ppm)"
MPORT=45459

qemu-system-x86_64 $KVM -bios "$FW" \
  -drive format=raw,file="$IMG" \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait \
  -net none -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"

cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; rm -f "$FIFO"; }
trap cleanup EXIT

# OVMF needs a while; wait for the shell prompt instead of guessing
ok=1
for _ in $(seq 1 60); do
  if grep -aq "tannx>" "$LOG"; then ok=0; break; fi
  kill -0 "$QPID" 2>/dev/null || break
  sleep 1
done

if [ "$ok" -eq 0 ]; then
  sleep 1
  printf 'echo uefi-alive\r' >&3;   sleep 2
  printf 'spawn math\r' >&3;        sleep 1
  printf 'task math 6 * 7\r' >&3;   sleep 3
  printf 'tasks\r' >&3;             sleep 2
  # grab the framebuffer BEFORE halt - 6.4 renders the console into
  # the GOP framebuffer, so the screen must be far from black
  printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1
  sleep 1
  printf 'display\r' >&3;           sleep 2   # report the GOP framebuffer geometry
  printf 'mem\r' >&3;               sleep 1   # v2.77: prove all 256 sectors loaded
  printf 'halt\r' >&3;              sleep 1
fi

echo
echo "==== Checks ($LOG) ===="
fail=0
check() {
  if grep -aq -- "$1" "$LOG"; then
    echo "OK   : $2"
  else
    echo "MISS : $2   (pattern: $1)"
    fail=1
  fi
}
check "TannX OS UEFI stage 0"      "OVMF runs the hand-built PE32+ stub"
check "kernel32.bin loaded"       "stub reads the kernel from the ESP"
check "ABCDE"                     "descent markers: EBS, copy, GDT, compat, protected"
check "Welcome to TannX OS"     "kernel boots after the long->protected drop"
check "tannx>"                  "shell prompt over serial"
check "uefi-alive"                "shell answers"
check "-> done = 42"              "ring-3 agent computes under UEFI boot"
check "KSENT256"                  "all 256 kernel sectors loaded under UEFI (v2.77 budget)"
check "display: [0-9]* x [0-9]*"  "display: reports the GOP framebuffer geometry"
check "modes: [0-9]"              "display lists the enumerated GOP modes (read-only)"
# framebuffer console (6.4): count non-black bytes in the screendump.
# A truly black screen is ~0 non-null bytes (just the PPM header); a
# rendered screen is tens of thousands. Threshold well clear of both,
# and independent of the palette (the v1.14 blue title bar lights fewer
# colour channels than the old grey one did).
if [ -s "$PPM" ] && [ "$(tr -d '\0' < "$PPM" | wc -c)" -gt 8000 ]; then
  echo "OK   : framebuffer console renders (screendump is not black)"
else
  echo "MISS : framebuffer console renders (screendump is not black)"
  fail=1
fi
rm -f "$PPM"

if [ "$fail" -eq 0 ]; then
  echo "==== ALL TESTS PASSED ===="
  exit 0
else
  echo "==== TESTS FAILED - inspect the log: $LOG ===="
  exit 1
fi
