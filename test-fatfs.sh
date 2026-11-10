#!/usr/bin/env bash
# ============================================================
#  fatfs robustness test (audit finding 7): the shared read/write
#  FAT layer (user/fatfs.c) must survive a MALFORMED / MALICIOUS disk image
#  without a divide-by-zero crash. A prepared USB stick / VM disk is untrusted
#  input even on a trusted LAN.
#
#  A bare FAT16 VBR at LBA 0, corrupted so sectors/cluster (BPB byte 13) = 0.
#  The cluster math (f_maxcl at mount, `need` in fat_save) would divide by zero;
#  fat_mount must REJECT the image and the shell must live on. Proof: the box
#  answers a following `echo` and reports "no FAT filesystem" (clean refusal).
#
#  A POSITIVE CONTROL runs first on the *valid* image so "no FAT filesystem"
#  can't pass for the wrong reason (a disk that never mounted at all).
#
#  The cluster-chain cycle/range guards (fat_clus_ok + the f_maxcl step budget)
#  are covered by the multi-cluster read/write/copy paths in test-virtio-blk and
#  test-usb-fat: those walk the very same guarded loops and stay green, proving
#  the guards don't regress a valid chain.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
if ! command -v mkfs.fat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
  echo "SKIP : fatfs robustness (mkfs.fat/mtools not installed)"; exit 0
fi
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"

# ---- a valid bare FAT16 disk with one file (FAT16 needs >=16 MB) -----------
GOOD="$(mktemp --suffix=.blk)"; dd if=/dev/zero of="$GOOD" bs=1M count=16 status=none
mkfs.fat -F 16 "$GOOD" >/dev/null 2>&1 || { echo "mkfs.fat failed"; exit 1; }
printf 'fatfs-robustness-payload\n' > /tmp/aos_fat_$$.txt
mcopy -i "$GOOD" /tmp/aos_fat_$$.txt ::/GOOD.TXT
rm -f /tmp/aos_fat_$$.txt

# ---- a copy corrupted with sectors/cluster = 0 (BPB offset 13) -------------
BAD="$(mktemp --suffix=.blk)"; cp "$GOOD" "$BAD"
printf '\x00' | dd of="$BAD" bs=1 seek=13 count=1 conv=notrunc status=none

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"

run_disk() {   # $1 = disk image; one boot, appends to $LOG
  qemu-system-i386 -drive format=raw,file="$IMG" \
    -drive id=vd,file="$1",if=none,format=raw -device virtio-blk-pci,drive=vd \
    -nographic <"$FIFO" >>"$LOG" 2>/dev/null &
  QPID=$!
  exec 3>"$FIFO"
  sleep 4
  printf 'vblk ls\r'  >&3; sleep 2
  printf 'vblk cat GOOD.TXT\r' >&3; sleep 2
  printf 'echo fatfs-alive\r' >&3; sleep 2   # the survival proof
  printf 'halt\r' >&3; sleep 1
  exec 3>&- 2>/dev/null
  kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
}

echo "==== fatfs robustness checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

# --- positive control: the valid image mounts + reads --------------------
: > "$LOG"; run_disk "$GOOD"
GOODOUT="$(sed 's/\r//g' "$LOG")"
echo "$GOODOUT" | grep -q "FAT16 root directory" && g1=1 || g1=0
chk "$g1" "positive control: the valid FAT16 image mounts (vblk ls)"
echo "$GOODOUT" | grep -q "fatfs-robustness-payload" && g2=1 || g2=0
chk "$g2" "positive control: vblk cat reads the file off the valid image"

# --- the malformed image: sectors/cluster = 0 ----------------------------
: > "$LOG"; run_disk "$BAD"
BADOUT="$(sed 's/\r//g' "$LOG")"
echo "$BADOUT" | grep -q "no FAT filesystem" && b1=1 || b1=0
chk "$b1" "spc=0 image: fat_mount rejects it (no divide-by-zero)"
[ "$(echo "$BADOUT" | grep -c 'fatfs-alive')" -ge 1 ] && b2=1 || b2=0
chk "$b2" "the shell survives the malformed mount (echo answers)"

echo "--- fatfs output (malformed run) ---"; echo "$BADOUT" | grep -iE "vblk:|fat:|fatfs-alive" | head
rm -f "$FIFO" "$IMG" "$GOOD" "$BAD" "$LOG"

[ "$fail" = 0 ] && { echo "==== FATFS OK ===="; exit 0; }
echo "==== FATFS FAILED ===="; exit 1
