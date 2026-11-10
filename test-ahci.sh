#!/usr/bin/env bash
# ============================================================
#  TannX OS AHCI driver test
#  QEMU's default machine has no AHCI, so we attach an ich9 AHCI
#  controller (-device ahci) plus a scratch SATA disk and drive the
#  full block path over serial:
#    - lspci sees the SATA/AHCI controller
#    - ahci   detects + IDENTIFYs the disk (model, sector count)
#    - awrite writes a pattern to a sector
#    - aread  reads it back (round-trip)
#  This is the only automatic test of the AHCI path; on the bare-metal test PC
#  the proof is the boot 'ahci:' dmesg line over the wire.
#  Usage: ./test-ahci.sh [hybrid.img]
# ============================================================
set -u
IMG="${1:-hybrid.img}"
[ -f "$IMG" ] || { echo "image not found: $IMG (run 'make hybrid.img')"; exit 2; }
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }

SATA="$(mktemp /tmp/agentos_sata_XXXX.img)"
LOG="$(mktemp /tmp/agentos_ahci_XXXX.log)"
FIFO="$(mktemp -u /tmp/agentos_ahci_XXXX.in)"
# 8 MB scratch disk, zeroed (the test writes its own pattern)
dd if=/dev/zero of="$SATA" bs=1024 count=8192 status=none
mkfifo "$FIFO"

qemu-system-i386 \
  -drive file="$IMG",format=raw,if=ide \
  -device ahci,id=ahci0 \
  -drive if=none,id=sata0,file="$SATA",format=raw \
  -device ide-hd,drive=sata0,bus=ahci0.0 \
  -nographic -serial mon:stdio -no-reboot <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; rm -f "$SATA" "$FIFO" "$LOG"; }
trap cleanup EXIT

ok=1
for _ in $(seq 1 30); do
  if grep -aq "tannx>" "$LOG"; then ok=0; break; fi
  kill -0 "$QPID" 2>/dev/null || break
  sleep 1
done
if [ "$ok" -eq 0 ]; then
  sleep 1
  printf 'lspci\r'  >&3;             sleep 1
  printf 'ahci\r'   >&3;             sleep 2
  printf 'awrite 9 cafe1234\r' >&3;  sleep 2
  printf 'aread 9\r' >&3;            sleep 2
  printf 'ahcibless\r' >&3;          sleep 1
  printf 'ahcibless confirm\r' >&3;  sleep 2
  printf 'spawn math\r' >&3;         sleep 1
  printf 'task math 111 * 3\r' >&3;  sleep 2
  printf 'persist\r' >&3;            sleep 2
  printf 'dmesg\r'  >&3;             sleep 2
  printf 'halt\r'   >&3;             sleep 1
fi

# strip ANSI so greps are reliable
CLEAN="$(mktemp /tmp/agentos_ahci_clean_XXXX.log)"
sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" > "$CLEAN"

echo
echo "==== AHCI checks ($CLEAN) ===="
fail=0
check() { if grep -aq -- "$1" "$CLEAN"; then echo "OK   : $2"; else echo "MISS : $2"; fail=1; fi; }
check "(SATA/AHCI)"                 "lspci sees the SATA/AHCI controller"
check "ahci: PI "                   "boot probe logs the HBA port state to dmesg"
check "QEMU HARDDISK"               "ahci IDENTIFY returns the disk model"
check "sectors 16384"               "ahci IDENTIFY returns the sector count (8 MB)"
check "ahci-rd: lba0 "              "boot probe read LBA0 over AHCI"
check "awrite: sector written"      "awrite issues WRITE DMA EXT"
check "34 12 fe ca 34 12 fe ca"     "aread reads back the written pattern (round-trip)"
check "Re-run as: ahcibless confirm" "ahcibless refuses without the confirm token (blessing guard)"
check "dedicated to TannX OS"        "ahcibless confirm writes the TannX OS marker to the SATA disk"
check "task results written to disk" "persist saves the task table to the blessed AHCI disk"
rm -f "$CLEAN"

# release the first QEMU's write-lock on $IMG before the second run
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
# with QEMU gone, the marker write is flushed: it must really be on the medium
if [ "$(dd if="$SATA" bs=1 skip=$((256*512)) count=14 status=none 2>/dev/null)" = "AGENTOS-MEDIUM" ]; then
  echo "OK   : the AGENTOS-MEDIUM marker reached LBA 256 of the disk"
else
  echo "MISS : the AGENTOS-MEDIUM marker reached LBA 256 of the disk"; fail=1
fi
rm -f "$SATA" "$FIFO"
trap - EXIT

# --- second run: an ATAPI device (optical) on the AHCI bus. The test PC's real
#     port-4 device is ATAPI, so this is the path that matters on that box:
#     pstart must accept the 0xEB140101 signature, IDENTIFY PACKET (0xA1) must
#     return the model, and the boot log must label it ATAPI (not a HDD). ---
CD="$(mktemp /tmp/agentos_cd_XXXX.raw)"
LOG2="$(mktemp /tmp/agentos_ahci2_XXXX.log)"
FIFO2="$(mktemp -u /tmp/agentos_ahci2_XXXX.in)"
# 2 MB raw "disc" with a recognizable first block (for the cdread round-trip)
dd if=/dev/zero of="$CD" bs=2048 count=1024 status=none
printf 'AGENTOS-CD-BLOCK-0' | dd of="$CD" bs=1 conv=notrunc status=none
mkfifo "$FIFO2"
qemu-system-i386 \
  -drive file="$IMG",format=raw,if=ide \
  -device ahci,id=ahci0 \
  -drive if=none,id=cd0,file="$CD",format=raw,media=cdrom \
  -device ide-cd,drive=cd0,bus=ahci0.0 \
  -nographic -serial mon:stdio -no-reboot <"$FIFO2" >"$LOG2" 2>/dev/null &
QPID2=$!
exec 4>"$FIFO2"
cleanup2() { exec 4>&- 2>/dev/null; kill "$QPID2" 2>/dev/null; rm -f "$CD" "$FIFO2" "$LOG2"; }
trap cleanup2 EXIT
ok2=1
for _ in $(seq 1 30); do
  if grep -aq "tannx>" "$LOG2"; then ok2=0; break; fi
  kill -0 "$QPID2" 2>/dev/null || break
  sleep 1
done
if [ "$ok2" -eq 0 ]; then
  sleep 1
  printf 'ahci\r'   >&4; sleep 2
  printf 'cdread 0\r' >&4; sleep 2
  printf 'dmesg\r'  >&4; sleep 2
  printf 'halt\r'   >&4; sleep 1
fi
CLEAN2="$(mktemp /tmp/agentos_ahci2_clean_XXXX.log)"
sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG2" > "$CLEAN2"
echo
echo "==== ATAPI checks ($CLEAN2) ===="
check2() { if grep -aq -- "$1" "$CLEAN2"; then echo "OK   : $2"; else echo "MISS : $2"; fail=1; fi; }
check2 "eb140101"                  "boot probe sees the ATAPI signature on a port"
check2 "QEMU DVD-ROM"              "IDENTIFY PACKET (0xA1) returns the optical drive model"
check2 "ATAPI (optical"            "ahci command labels the device ATAPI, not a HDD"
check2 "1024 blocks"               "READ CAPACITY(10) returns the disc size (2 MB)"
check2 "41 47 45 4e 54 4f 53"      "cdread reads the block via SCSI READ(10) (AGENTOS marker)"
rm -f "$CLEAN2"

if [ "$fail" -eq 0 ]; then
  echo "==== ALL TESTS PASSED ===="; exit 0
else
  echo "==== TESTS FAILED - inspect the log ===="; exit 1
fi
