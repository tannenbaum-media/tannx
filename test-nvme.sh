#!/usr/bin/env bash
# ============================================================
#  NVMe driver test. The `nvme` command runs a ring-3 C driver
#  (user/nvme.c): it finds an NVMe controller (PCI class 0x010802), maps
#  BAR0, brings the controller up (admin queue pair + enable), creates one
#  I/O queue pair, and writes+reads a 512-byte LBA to prove the path.
#
#  QEMU only (the bare-metal test PC has no NVMe; a modern x86 mini-PC does): a second drive
#  exposed as -device nvme, backed by a scratch file. We assert the serial
#  log AND - the end-to-end proof - that the pattern the OS wrote to LBA 0
#  actually landed in the host backing file (real DMA to storage).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

HAVE_FAT=1   # mkfs.fat + mtools + sgdisk -> a GPT-partitioned FAT NVMe disk
{ command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 \
  && command -v sgdisk >/dev/null 2>&1; } || HAVE_FAT=0

IMG="$(mktemp --suffix=.img)";  cp agentos32.img "$IMG"
NVME="$(mktemp --suffix=.nvme)"; dd if=/dev/zero of="$NVME" bs=1M count=24 status=none
NVMSG="hello from a FAT partition on NVMe"
if [ "$HAVE_FAT" = 1 ]; then
  FATP="$(mktemp --suffix=.fatp)"; dd if=/dev/zero of="$FATP" bs=1M count=16 status=none
  mkfs.fat -F 16 "$FATP" >/dev/null 2>&1
  printf '%s\n' "$NVMSG" > /tmp/aos_nvme_$$.txt
  mcopy -i "$FATP" /tmp/aos_nvme_$$.txt ::/NV.TXT
  rm -f /tmp/aos_nvme_$$.txt
  sgdisk -n 1:2048:+16M -t 1:0700 "$NVME" >/dev/null 2>&1
  dd if="$FATP" of="$NVME" bs=512 seek=2048 conv=notrunc status=none
  rm -f "$FATP"
fi
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"

# boot disk = the usual image; the NVMe SSD is extra hardware to drive.
# cache=writethrough so a completed write is in the file before we check it.
qemu-system-i386 -drive format=raw,file="$IMG" \
  -drive file="$NVME",if=none,id=nvm,format=raw,cache=writethrough \
  -device nvme,drive=nvm,serial=agentos01 \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
[ "$HAVE_FAT" = 1 ] && { printf 'nvme ls\r' >&3; sleep 3; printf 'nvme cat NV.TXT\r' >&3; sleep 3
                         printf 'diskon\r' >&3; sleep 1                       # WRITE a FAT16 file
                         printf 'save 6 nvme-fat-write-ok\r' >&3; sleep 1
                         printf 'nvme save NVO.TXT 6\r' >&3; sleep 3
                         printf 'nvme copy NV.TXT NVCOPY.TXT\r' >&3; sleep 4; }
printf 'nvme test\r' >&3; sleep 3        # destructive R/W (LAST - overwrites LBA 0)
printf 'halt\r' >&3; sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== NVMe driver checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

grep -aq "found controller" "$LOG" && a=1 || a=0
chk "$a" "the NVMe controller is found (PCI class 0x010802) + BAR0 mapped"

grep -aq "controller enabled (RDY)" "$LOG" && b=1 || b=0
chk "$b" "controller init handshake: admin queues + CC.EN -> CSTS.RDY"

grep -aq "I/O queue pair ready" "$LOG" && c=1 || c=0
chk "$c" "admin commands created the I/O completion + submission queues"

grep -aq "write+read LBA 0 verified" "$LOG" && d=1 || d=0
chk "$d" "I/O read after write returns the same 512 bytes (queue round-trip)"

# end-to-end proof: the pattern (buf[i] = i ^ 0x5a) the OS DMA'd to LBA 0 must
# be in the host backing file's first 512 bytes - real storage, not RAM echo.
RES="$(python3 - "$NVME" <<'PY'
import sys
try:
    d = open(sys.argv[1], "rb").read(512)
    ok = len(d) == 512 and all(d[i] == ((i ^ 0x5a) & 0xff) for i in range(512))
    print(f"lba0_match={int(ok)} first4={d[0]:02x},{d[1]:02x},{d[2]:02x},{d[3]:02x}")
except Exception as e:
    print("err", e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'lba0_match=1' && e=1 || e=0
chk "$e" "the written pattern landed in the host NVMe backing file (real DMA)"

if [ "$HAVE_FAT" = 1 ]; then
  grep -aq "FAT16 root directory" "$LOG" && f=1 || f=0
  chk "$f" "nvme ls mounts a FAT partition inside a GPT NVMe disk (shared fatfs)"
  grep -aq "$NVMSG" "$LOG" && g=1 || g=0
  chk "$g" "nvme cat reads a file off the GPT-partitioned NVMe disk"
  grep -aq "wrote slot 6" "$LOG" && w1=1 || w1=0
  chk "$w1" "nvme save reports it wrote a FAT16 file (fat_save over NVMe)"
  WROTE="$(mtype -i "$NVME@@1M" ::/NVO.TXT 2>/dev/null | tr -d '\r\n')"
  echo "  host reads ::/NVO.TXT = '$WROTE'"
  [ "$WROTE" = "nvme-fat-write-ok" ] && w2=1 || w2=0
  chk "$w2" "the host reads back the file TannX OS wrote to the NVMe disk"
  grep -aq "nvme: copied" "$LOG" && w3=1 || w3=0
  chk "$w3" "nvme copy reports success (file copy over NVMe)"
  CWROTE="$(mtype -i "$NVME@@1M" ::/NVCOPY.TXT 2>/dev/null | tr -d '\r\n')"
  echo "$CWROTE" | grep -q "$NVMSG" && w4=1 || w4=0
  chk "$w4" "the copied file NVCOPY.TXT has the source content (fat_copy over NVMe)"
else
  echo "SKIP : FAT checks (mkfs.fat/mtools/sgdisk not installed)"
fi

echo "--- nvme output ---"; sed 's/\r//g' "$LOG" | grep -i "nvme:" | head
rm -f "$LOG" "$NVME"

[ "$fail" = 0 ] && { echo "==== NVME OK ===="; exit 0; }
echo "==== NVME FAILED ===="; exit 1
