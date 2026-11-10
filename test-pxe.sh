#!/usr/bin/env bash
# ============================================================
#  TannX OS PXE network-boot test
#  Proves the kernel boots over the network with NO disk attached:
#  QEMU's PXE ROM downloads pxe.img from QEMU's built-in TFTP and
#  jumps in; the stub falls through to Stage 2 and the shell comes
#  up on serial. This is the "no more stick juggling" loop, headless.
#  Usage: ./test-pxe.sh [pxe.img]
# ============================================================
set -u
IMG="${1:-pxe.img}"
[ -f "$IMG" ] || { echo "image not found: $IMG (run 'make pxe')"; exit 2; }
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }

TFTP="$(mktemp -d /tmp/agentos_pxe_XXXX)"
LOG="$(mktemp /tmp/agentos_pxe_XXXX.log)"
FIFO="$(mktemp -u /tmp/agentos_pxe_XXXX.in)"
cp "$IMG" "$TFTP/pxe.img"
mkfifo "$FIFO"

# -boot n: network boot. NO -drive: there is no disk at all.
qemu-system-i386 -boot n \
  -netdev user,id=n0,tftp="$TFTP",bootfile=pxe.img \
  -device rtl8139,netdev=n0 \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; rm -rf "$TFTP" "$FIFO"; }
trap cleanup EXIT

ok=1
for _ in $(seq 1 60); do
  if grep -aq "tannx>" "$LOG"; then ok=0; break; fi
  kill -0 "$QPID" 2>/dev/null || break
  sleep 1
done
if [ "$ok" -eq 0 ]; then
  sleep 1
  printf 'spawn math\r' >&3;      sleep 1
  printf 'task math 1337 * 42\r' >&3; sleep 3
  printf 'tasks\r' >&3;           sleep 1
  # Phase 2: the C userspace program rides in the image (no disk here);
  # pxe_blob_load staged it at 0x400000, so 'run' starts the real program.
  printf 'run\r' >&3;             sleep 2
  printf 'mem\r' >&3;             sleep 1    # v2.77: prove all 256 sectors loaded
  printf 'halt\r' >&3;            sleep 1
fi

echo
echo "==== Checks ($LOG) ===="
fail=0
check() { if grep -aq -- "$1" "$LOG"; then echo "OK   : $2"; else echo "MISS : $2"; fail=1; fi; }
check "network boot, kernel in RAM" "PXE stub runs (downloaded over the network)"
check "Welcome to TannX"          "kernel boots with no disk attached"
check "tannx>"                    "shell prompt over serial"
check "done = 56154"                "ring-3 agent computes after network boot"
check "hello from ring3 C"          "C userspace program runs from the PXE image (no disk)"
check "(M-JPEG)"                    "video clip rides in the PXE image (RAM disk, no disk)"
check "decoded frame 0 OK"         "jpeg.c decodes a JPEG frame on the diskless boot"
check "KSENT256"                    "all 256 kernel sectors loaded over PXE (v2.77 budget)"

if [ "$fail" -eq 0 ]; then
  echo "==== ALL TESTS PASSED ===="; exit 0
else
  echo "==== TESTS FAILED - inspect the log: $LOG ===="; exit 1
fi
