#!/usr/bin/env bash
# ============================================================
#  'run edit <file>' - the full-screen editor (user/edit.c). Two storages:
#   1. a FAT16 volume on a virtio-blk disk: a NEW file is typed over serial
#      (arrows/Home via the ESC-[ decoder, Tab, Enter), Ctrl+S saves it,
#      Ctrl+Q quits - and mtools on the HOST reads the bytes back out of the
#      backing file (the storage proof the project demands).
#   2. an AgentFS slot ('edit slot5', needs diskon): the text saved there
#      runs as a script with 'script 5'.
#  A screendump checks the editor chrome is on the framebuffer.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
{ command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 && command -v sgdisk >/dev/null 2>&1; } \
  || { echo "mkfs.fat/mtools/sgdisk missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
BLK="$(mktemp --suffix=.blk)"; dd if=/dev/zero of="$BLK" bs=1M count=24 status=none
FATP="$(mktemp --suffix=.fatp)"; dd if=/dev/zero of="$FATP" bs=1M count=16 status=none
mkfs.fat -F 16 "$FATP" >/dev/null 2>&1
sgdisk -n 1:2048:+16M -t 1:0700 "$BLK" >/dev/null 2>&1      # GPT, one FAT16 partition @ 2048
dd if="$FATP" of="$BLK" bs=512 seek=2048 conv=notrunc status=none
rm -f "$FATP"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PPM="$(mktemp --suffix=.ppm)"; OUT="$(mktemp)"
MPORT=55592
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -nographic \
  -drive id=vd,file="$BLK",if=none,format=raw -device virtio-blk-pci,drive=vd \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; rm -f "$FIFO" "$IMG" "$BLK" "$PPM" "$LOG" "$OUT"; }
trap cleanup EXIT
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
type_() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.03; done; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$LOG"; do sleep 0.3; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
# --- 1. FAT file on virtio-blk ---
send 'run edit HELLO.TXT'
waitfor "edit: new file HELLO.TXT" 60
sleep 1
type_ 'hello from the editor'; printf '\r' >&3
type_ 'line two'; printf '\r' >&3
printf '\t' >&3; type_ 'indented'                 # Tab -> 4 spaces
printf '\x1b[A' >&3; sleep 0.1                    # Up    (ESC [ A)
printf '\x1b[1~' >&3; sleep 0.1                   # Home  (ESC [ 1 ~)
type_ '> '                                        # insert at the head of "line two"
printf '\x1b[B' >&3; sleep 0.1                    # Down
printf '\x1b[F' >&3; sleep 0.1                    # End
type_ ' end'
sleep 1
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf '\x13' >&3                                 # Ctrl+S
waitfor "edit: saved" 40
printf '\x11' >&3                                 # Ctrl+Q
waitfor "edit: quit" 20
# --- 2. AgentFS slot ---
sleep 1
send 'diskon'; sleep 1
send 'run edit slot5'
waitfor "edit: new file slot5" 60
sleep 1
type_ 'echo edited-in-slot'
printf '\x13' >&3; sleep 1
printf '\x11' >&3; sleep 2
send 'script 5'; sleep 3
send 'echo shell-lives'; sleep 2
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

# host-side proof: read the file back with mtools (partition @ 2048*512)
mcopy -i "$BLK@@1048576" ::/HELLO.TXT "$OUT" 2>/dev/null
echo "==== HELLO.TXT read back on the host ===="; cat "$OUT" 2>/dev/null || echo "(missing)"
EXPECT="$(printf 'hello from the editor\n> line two\n    indented end')"
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb')
    if f.readline().strip()!=b'P6': print("noppm"); sys.exit(0)
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y):
        o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    teal=lambda c: abs(c[0]-0x2d)<20 and abs(c[1]-0xd4)<20 and abs(c[2]-0xbf)<20
    top=sum(1 for x in range(0,w,8) if teal(px(x,0)))                       # accent line
    ink=sum(1 for y in range(h//20,h//4,2) for x in range(0,w//2,2) if px(x,y)[1]>200)  # text rows
    cur=sum(1 for y in range(h//20,h//4,2) for x in range(0,w//2,2) if teal(px(x,y)))  # cursor block
    bg=px(w//2,h//2); bg_ok = bg[0]<20 and bg[1]<40 and bg[2]<40 and bg[1]>bg[0]
    print(f"w={w} h={h} top={top} ink={ink} cur={cur} top_ok={int(top>w//16)} ink_ok={int(ink>80)} cur_ok={int(cur>8)} bg_ok={int(bg_ok)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "==== checks ===="
fail=0
chk() { if grep -qaE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "edit: new file HELLO.TXT via virtio-blk"  "editor opens a new file on the virtio-blk FAT volume"
chk "edit: saved [0-9]+ bytes -> HELLO.TXT \(virtio-blk\)" "Ctrl+S writes the file (fat_save)"
chk "edit: quit"                               "Ctrl+Q quits"
if [ "$(cat "$OUT" 2>/dev/null)" = "$EXPECT" ]; then echo "OK   : host mtools reads back exactly what was typed (arrows/Home/End/Tab applied)"
else echo "FAIL : host read-back differs"; fail=1; fi
chk "edit: no FAT volume - using AgentFS slot 5|edit: new file slot5 via slot" "slot mode: 'edit slot5'"
chk "edit: saved [0-9]+ bytes -> slot5 \(slot\)" "Ctrl+S writes the AgentFS slot (SYS_WRITE_SLOT)"
chk "edited-in-slot"                           "'script 5' runs the text the editor saved"
chk "shell-lives"                              "shell answers afterwards"
for k in top ink cur bg; do
  if echo "$RES" | grep -q "${k}_ok=1"; then echo "OK   : screendump $k"; else echo "FAIL : screendump $k"; fail=1; fi
done
[ "$fail" -eq 0 ] && { echo "==== EDIT OK ===="; exit 0; }
echo "==== EDIT FAILED ===="; sed 's/\r//g' "$LOG" | tail -40; exit 1
