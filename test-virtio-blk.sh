#!/usr/bin/env bash
# ============================================================
#  virtio-blk test (cloud/VM disk). With virtio-net (the VM NIC) already in,
#  virtio-blk is the VM disk - together they make TannX OS a first-class
#  VM/cloud guest. The `vblk` command runs a ring-3 modern-virtio driver
#  (user/vblk.c, the vgpu.c MMIO pattern): cap-walk, handshake, one request
#  virtqueue, the block protocol (header/data/status chain). It reads a FAT
#  filesystem off the disk via the shared FAT layer (fatfs.c) - `vblk ls` /
#  `vblk cat` - and `vblk test` verifies raw R/W.
#
#  QEMU: -device virtio-blk-pci,drive=.. (1af4:1001). The disk is a real
#  FAT16 image (mkfs.fat+mtools) with a known file.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
HAVE_FAT=1   # need mkfs.fat + mtools + sgdisk to build a GPT-partitioned FAT disk
{ command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 \
  && command -v sgdisk >/dev/null 2>&1; } || HAVE_FAT=0
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
BLK="$(mktemp --suffix=.blk)"; dd if=/dev/zero of="$BLK" bs=1M count=24 status=none
MSG="hello from a GPT-partitioned virtio-blk disk"
if [ "$HAVE_FAT" = 1 ]; then
  # a real-world disk: a GPT with one FAT16 partition (like an NVMe / VM disk)
  FATP="$(mktemp --suffix=.fatp)"; dd if=/dev/zero of="$FATP" bs=1M count=16 status=none
  mkfs.fat -F 16 "$FATP" >/dev/null 2>&1
  printf '%s\n' "$MSG" > /tmp/aos_vblk_$$.txt
  mcopy -i "$FATP" /tmp/aos_vblk_$$.txt ::/VBLK.TXT
  SUBMSG="file in a subdirectory works"
  printf '%s\n' "$SUBMSG" > /tmp/aos_vsub_$$.txt
  mmd -i "$FATP" ::/DOCS
  mcopy -i "$FATP" /tmp/aos_vsub_$$.txt ::/DOCS/DEEP.TXT
  # a multi-cluster source (~4 KB > one 2 KB cluster) to exercise the chain
  BIGSRC="/tmp/aos_vbig_$$.txt"
  python3 -c "import sys; sys.stdout.write(''.join('L%04d-multicluster-payload\n'%i for i in range(150))[:4000])" > "$BIGSRC"
  BIGSUM="$(md5sum "$BIGSRC" | cut -d' ' -f1)"
  mcopy -i "$FATP" "$BIGSRC" ::/BIG.TXT
  rm -f /tmp/aos_vblk_$$.txt /tmp/aos_vsub_$$.txt
  sgdisk -n 1:2048:+16M -t 1:0700 "$BLK" >/dev/null 2>&1   # GPT partition @ sector 2048
  dd if="$FATP" of="$BLK" bs=512 seek=2048 conv=notrunc status=none
  rm -f "$FATP"
fi
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"

qemu-system-i386 -drive format=raw,file="$IMG" \
  -drive id=vd,file="$BLK",if=none,format=raw -device virtio-blk-pci,drive=vd \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
[ "$HAVE_FAT" = 1 ] && { printf 'vblk ls\r' >&3; sleep 3; printf 'vblk cat VBLK.TXT\r' >&3; sleep 3
                        printf 'vblk cat DOCS/DEEP.TXT\r' >&3; sleep 3
                        # WRITE: save an AgentFS slot out as a FAT16 file (fat_save)
                        printf 'diskon\r' >&3; sleep 1
                        printf 'save 5 written-by-agentos\r' >&3; sleep 1
                        printf 'vblk save AOS.TXT 5\r' >&3; sleep 3
                        printf 'vblk copy BIG.TXT COPY.TXT\r' >&3; sleep 4; }
printf 'vblk test\r' >&3; sleep 3        # destructive R/W (LAST - overwrites sector 0)
printf 'halt\r' >&3; sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
out="$(sed 's/\r//g' "$LOG")"
rm -f "$FIFO" "$IMG"

echo "==== virtio-blk checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

echo "$out" | grep -q "found 10011af4" && a=1 || a=0
chk "$a" "the virtio-blk device is found (1af4:1001) + caps walked + BAR mapped"
echo "$out" | grep -qE "capacity [0-9]+ sectors" && b=1 || b=0
chk "$b" "device config read: the disk capacity"
echo "$out" | grep -q "write+read sector 0 verified" && c=1 || c=0
chk "$c" "the request virtqueue round-trips a write then a read (vblk test)"

RES="$(python3 - "$BLK" <<'PY'
import sys
try:
    d = open(sys.argv[1], "rb").read(512)
    ok = len(d) == 512 and all(d[i] == ((i ^ 0x69) & 0xff) for i in range(512))
    print(f"sec0_match={int(ok)}")
except Exception as e:
    print("err", e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'sec0_match=1' && d=1 || d=0
chk "$d" "the written sector landed in the host backing file (real DMA)"

if [ "$HAVE_FAT" = 1 ]; then
  echo "$out" | grep -q "FAT16 root directory" && e=1 || e=0
  chk "$e" "vblk ls mounts a FAT partition inside a GPT disk (shared fatfs + GPT)"
  echo "$out" | grep -q "$MSG" && f=1 || f=0
  chk "$f" "vblk cat reads a file off the GPT-partitioned VM disk"
  echo "$out" | grep -q "file in a subdirectory works" && h=1 || h=0
  chk "$h" "vblk cat DOCS/DEEP.TXT navigates a subdirectory (FAT path resolver)"
  # WRITE: the OS created AOS.TXT in the FAT partition (at 1M in the GPT disk);
  # the host reads it back (vblk test only clobbers sector 0, not the partition)
  echo "$out" | grep -q "wrote slot 5" && w1=1 || w1=0
  chk "$w1" "vblk save reports it wrote the slot to a FAT16 file (fat_save)"
  WROTE="$(mtype -i "$BLK@@1M" ::/AOS.TXT 2>/dev/null | tr -d '\r\n')"
  echo "  host reads ::/AOS.TXT = '$WROTE'"
  [ "$WROTE" = "written-by-agentos" ] && w2=1 || w2=0
  chk "$w2" "the host filesystem reads back the file TannX OS wrote (real FAT write)"
  # multi-cluster: the OS copied a ~4 KB file (> one cluster) into a cluster chain
  echo "$out" | grep -q "copied" && w3=1 || w3=0
  chk "$w3" "vblk copy reports success (multi-cluster write)"
  mtype -i "$BLK@@1M" ::/COPY.TXT > /tmp/aos_vcpy_$$.txt 2>/dev/null
  CPYSUM="$(md5sum /tmp/aos_vcpy_$$.txt | cut -d' ' -f1)"
  echo "  source md5=$BIGSUM  copy md5=$CPYSUM"
  [ "$BIGSUM" = "$CPYSUM" ] && w4=1 || w4=0
  chk "$w4" "the multi-cluster copy is byte-identical to the source (cluster chain)"
  rm -f /tmp/aos_vbig_$$.txt /tmp/aos_vcpy_$$.txt
else
  echo "SKIP : FAT checks (mkfs.fat/mtools not installed)"
fi

echo "--- vblk output ---"; echo "$out" | grep -iE "vblk:|fat:" | head
rm -f "$LOG" "$BLK"

[ "$fail" = 0 ] && { echo "==== VIRTIO-BLK OK ===="; exit 0; }
echo "==== VIRTIO-BLK FAILED ===="; exit 1
