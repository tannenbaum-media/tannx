#!/usr/bin/env bash
# ============================================================
#  Screenshot test ('run shot', user/shot.c). Boot 1: a FAT16 virtio-blk
#  disk - the BMP lands as SHOT0001.BMP and the host decodes it (header,
#  dimensions = framebuffer / scale, declared size). Boot 2: no disk - the
#  BMP streams to the mock proxy (POST /shot, a multi-MB upload over the
#  OS's own TCP stack) which writes it to AGENTOS_SHOT_DIR.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
{ command -v mkfs.fat >/dev/null 2>&1 && command -v mtype >/dev/null 2>&1; } || { echo "mkfs.fat/mtools missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
BLK="$(mktemp --suffix=.blk)"; dd if=/dev/zero of="$BLK" bs=1M count=16 status=none; mkfs.fat -F 16 "$BLK" >/dev/null
LOG="$(mktemp)"; LOG2="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; BMP="$(mktemp --suffix=.bmp)"
SHOTS="$(mktemp -d)"; PROXYLOG="$(mktemp)"; QPID=""; PRXPID=""
cleanup() { exec 3>&- 2>/dev/null; [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; [ -n "$PRXPID" ] && kill "$PRXPID" 2>/dev/null; wait 2>/dev/null; rm -rf "$FIFO" "$IMG" "$LOG" "$LOG2" "$BLK" "$BMP" "$SHOTS" "$PROXYLOG"; }
trap cleanup EXIT
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$2"; do sleep 0.5; t=$((t+1)); [ $t -ge "$3" ] && return 1; done; return 0; }

# ---- boot 1: FAT volume
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -net none \
  -drive id=vd,file="$BLK",if=none,format=raw -device virtio-blk-pci,drive=vd -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
send 'sysinfo'; sleep 1
send 'run shot';  waitfor 'shot: saved SHOT0001.BMP' "$LOG" 160
send 'run shot forest'; waitfor 'shot: saved FOREST.BMP' "$LOG" 160
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

# ---- boot 2: no disk -> proxy upload
. ./proxy-port.sh
AGENTOS_SHOT_DIR="$SHOTS" python3 ./llm-proxy.py --mock --port "$PPORT" >"$PROXYLOG" 2>&1 &
PRXPID=$!
sleep 0.6
rm -f "$FIFO"; mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -netdev "user,id=n0$PFWD" -device rtl8139,netdev=n0 \
  -nographic <"$FIFO" >"$LOG2" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
send 'run shot';  waitfor 'shot: sent' "$LOG2" 200
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

echo "==== shot output ===="; sed 's/\r//g' "$LOG" "$LOG2" | grep -a "shot:"
echo "==== checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
grep -aq 'shot: saved SHOT0001.BMP' "$LOG" && a=1 || a=0;  chk "$a" "run shot writes SHOT0001.BMP to the FAT volume"
grep -aq 'shot: saved FOREST.BMP' "$LOG" && a=1 || a=0;    chk "$a" "run shot <name> picks the name (FOREST.BMP)"
mtype -i "$BLK" ::/SHOT0001.BMP > "$BMP" 2>/dev/null
RES="$(python3 - "$BMP" "$LOG" <<'PY'
import sys,struct,re
try:
    d=open(sys.argv[1],'rb').read()
    log=open(sys.argv[2],'rb').read().decode('latin1')
    m=re.search(r'shot: captured (\d+)x(\d+) \((\d+) bytes\)',log)
    w,h,n=int(m.group(1)),int(m.group(2)),int(m.group(3))
    ok_hdr=d[:2]==b'BM' and struct.unpack('<I',d[2:6])[0]==len(d)==n
    bw,bh=struct.unpack('<ii',d[18:26]); bpp=struct.unpack('<H',d[28:30])[0]
    ok_dim=(bw,bh)==(w,h) and bpp==24
    # not blank: the console was on screen, so some pixels are bright
    px=d[54:]; bright=sum(1 for i in range(0,len(px)-3,3*97) if px[i]+px[i+1]+px[i+2]>300)
    print(f"len={len(d)} dim={bw}x{bh} bpp={bpp} bright={bright} hdr_ok={int(ok_hdr)} dim_ok={int(ok_dim)} content_ok={int(bright>20)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'hdr_ok=1' && a=1 || a=0;     chk "$a" "host decodes the BMP: header + file size match (mtools round-trip)"
echo "$RES" | grep -q 'dim_ok=1' && a=1 || a=0;     chk "$a" "dimensions = framebuffer / scale, 24 bpp"
echo "$RES" | grep -q 'content_ok=1' && a=1 || a=0; chk "$a" "the image has content (console pixels), not a blank frame"
grep -aq 'shot: sent .*the proxy saved' "$LOG2" && a=1 || a=0; chk "$a" "without a FAT volume the BMP streams to the proxy (POST /shot)"
ls "$SHOTS" | grep -qE 'tannx-.*\.(png|bmp)' && a=1 || a=0; chk "$a" "the proxy wrote the file into AGENTOS_SHOT_DIR"
[ "$fail" -eq 0 ] && { echo "==== SHOT OK ===="; exit 0; }
echo "==== SHOT FAILED ===="; sed 's/\r//g' "$LOG" "$LOG2" | tail -20; cat "$PROXYLOG"; exit 1
