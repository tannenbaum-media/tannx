#!/usr/bin/env bash
# ============================================================
#  File manager test ('run files', user/files.c): a FAT16 virtio-blk disk
#  with three files; the app lists them with sizes + free space, opens one
#  in the viewer, deletes one after the y/n confirmation. The host checks
#  the deletion really landed in the backing file (mtools).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
{ command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; } || { echo "mkfs.fat/mtools missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
BLK="$(mktemp --suffix=.blk)"; dd if=/dev/zero of="$BLK" bs=1M count=16 status=none; mkfs.fat -F 16 "$BLK" >/dev/null
T="$(mktemp -d)"
printf 'Hello from the FAT volume.\nTannX OS lists, views and deletes files here.\n' > "$T/readme.txt"
python3 -c "print(''.join('line %d of the notes\n' % i for i in range(80)))" > "$T/notes.md"
head -c 3000 /dev/urandom > "$T/blob.bin"
mcopy -i "$BLK" "$T/readme.txt" ::/README.TXT; mcopy -i "$BLK" "$T/notes.md" ::/NOTES.MD; mcopy -i "$BLK" "$T/blob.bin" ::/BLOB.BIN
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PPM="$(mktemp --suffix=.ppm)"
MPORT=$((56200 + RANDOM % 300)); QPID=""
cleanup() { exec 3>&- 2>/dev/null; [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; [ -n "$QPID" ] && wait "$QPID" 2>/dev/null; rm -rf "$FIFO" "$IMG" "$LOG" "$PPM" "$BLK" "$T"; }
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -net none -monitor telnet:127.0.0.1:$MPORT,server,nowait \
  -drive id=vd,file="$BLK",if=none,format=raw -device virtio-blk-pci,drive=vd -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$LOG"; do sleep 0.5; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
send 'run files';     waitfor 'files: FAT16 on virtio-blk' 40
sleep 2
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf 'j' >&3; sleep 0.5; printf '\r' >&3;  waitfor 'files: open NOTES.MD' 20   # viewer
sleep 1; printf ' ' >&3; sleep 0.5; printf 'q' >&3; sleep 1                     # page, back
printf 'j' >&3; sleep 0.5; printf 'd' >&3; sleep 0.5; printf 'n' >&3; sleep 1   # delete? no
printf 'd' >&3; sleep 0.5; printf 'y' >&3;   waitfor 'files: deleted BLOB.BIN' 20
sleep 1; printf 'q' >&3;  waitfor 'files: quit' 20
send 'echo shell-lives'; sleep 2
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
echo "==== files output ===="; sed 's/\r//g' "$LOG" | grep -a "files:" | head
echo "==== checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
g() { grep -aqE -- "$1" "$LOG" && echo 1 || echo 0; }
chk "$(g 'files: FAT16 on virtio-blk, 3 entries, [0-9]+ KB free of [0-9]+ KB')" "mounts the FAT volume: 3 entries, free/total space"
chk "$(g 'files: open NOTES.MD \(16[0-9][0-9] bytes\)')"  "Enter opens the selected text file in the viewer"
chk "$(g 'files: deleted BLOB.BIN')"                      "d + y deletes the file (n before it did not)"
chk "$(g 'files: quit')"                                  "q quits"
chk "$(g 'shell-lives')"                                  "shell lives afterwards"
L="$(mdir -i "$BLK" ::/ 2>/dev/null)"
echo "$L" | grep -q "BLOB" && a=0 || a=1;   chk "$a" "host: BLOB.BIN is gone from the backing file (mtools)"
echo "$L" | grep -q "README" && a=1 || a=0; chk "$a" "host: README.TXT and NOTES.MD survived"
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb'); assert f.readline().strip()==b'P6'
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    bg=px(2,h//2); bg_ok=abs(bg[0]-10)<=6 and abs(bg[1]-22)<=6 and abs(bg[2]-20)<=6
    ink=sum(1 for y in range(0,h,3) for x in range(0,w,3) if min(px(x,y))>170)
    print(f"bg_ok={int(bg_ok)} ink_ok={int(ink>150)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'bg_ok=1' && a=1 || a=0;  chk "$a" "screendump: brand background"
echo "$RES" | grep -q 'ink_ok=1' && a=1 || a=0; chk "$a" "screendump: list text rendered"
[ "$fail" -eq 0 ] && { echo "==== FILES OK ===="; exit 0; }
echo "==== FILES FAILED ===="; sed 's/\r//g' "$LOG" | tail -20; exit 1
