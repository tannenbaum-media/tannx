#!/usr/bin/env bash
# ============================================================
#  M-JPEG player robustness test (v2.86 regression). The video player decodes
#  an UNTRUSTED on-disk M-JPEG clip. A degenerate frame - SOI (FF D8) straight
#  to SOS (FF DA) with a component count of 0 and no SOF - decodes to a 0x0
#  image; the player then computed `fb->w / w` with w==0 -> #DE, killing the
#  ring-3 video program. The decoder (user/jpeg.c) must reject such a frame
#  (no SOF, ncomp=0) and the player must handle it gracefully ("JPEG decode
#  failed") and keep the shell alive.
#
#  We craft a clip at the video LBA (1024): a valid M-JPEG header pointing at a
#  single 7-byte degenerate frame, boot, `run` (the video player), and assert
#  no #DE / agent-shootdown and a live shell afterwards.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"

# --- craft the malicious clip in place ---------------------------------------
# header @ LBA 1024: {magic "MJPG"=0x47504A4D, count=1, w=64, h=64, fps=8} then
# a frame table at +20: entry0 = (sect_off=0, size=7).
# frame @ LBA 1025: FF D8 FF DA 00 03 00  (SOI, SOS len=3 ncomp=0, degenerate)
python3 - "$IMG" <<'PY'
import struct, sys
f = open(sys.argv[1], "r+b")
LBA = 1024
f.seek(LBA * 512)
# count = 0x10000 exercises BOTH v2.86 fixes: the frame-table index clamp
# (61 max) and the degenerate-frame #DE guard (frame 0 below).
hdr = struct.pack("<5I", 0x47504A4D, 0x10000, 64, 64, 8) # magic,count,w,h,fps
hdr += struct.pack("<2I", 0, 7)                          # frame table: (off=0, size=7)
hdr += b"\x00" * (512 - len(hdr))
f.write(hdr)
f.seek((LBA + 1) * 512)
frame = bytes([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x03, 0x00])  # SOI + SOS ncomp=0
frame += b"\x00" * (512 - len(frame))
f.write(frame)
f.close()
print("crafted degenerate M-JPEG clip at LBA 1024/1025")
PY

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$IMG" -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
for t in $(seq 1 50); do grep -aq "tannx> " "$LOG" && break; sleep 0.3; done
sleep 1
# run the video player, give it a moment to hit the degenerate frame, then quit
# it and prove the shell still answers
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
send "run"; sleep 3
send "kill 0"; sleep 1
send "echo video-fuzz-survived"; sleep 1
send "halt"; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
out="$(sed 's/\r//g' "$LOG")"
rm -f "$IMG" "$LOG" "$FIFO"

echo "==== M-JPEG fuzz checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

# the clip was found + attempted (proves the player actually ran our clip)
echo "$out" | grep -q "(M-JPEG)" && a=1 || a=0
chk "$a" "the player picked up the crafted M-JPEG clip"
# the untrusted frame count (0x10000) is clamped to the 61-entry table capacity,
# not walked past hdr[] (Finding 2). The player prints the clamped count.
echo "$out" | grep -q "61 JPEG frames" && cl=1 || cl=0
chk "$cl" "the frame count is clamped to 61 (no OOB frame-table walk, v2.86)"
# the degenerate frame is rejected gracefully, NOT decoded to 0x0
echo "$out" | grep -q "JPEG decode failed" && b=1 || b=0
chk "$b" "the degenerate frame is rejected (no 0x0 decode)"
# NO divide-by-zero / ring-3 fault from the video program
if echo "$out" | grep -qiE "FAULT \(#DE|PAGE FAULT|agent killed"; then df=1; else df=0; fi
chk "$([ $df = 0 ] && echo 1 || echo 0)" "no #DE / fault on the degenerate frame (v2.86)"
# the shell survived
echo "$out" | grep -q "video-fuzz-survived" && s=1 || s=0
chk "$s" "the shell keeps responding after the malicious clip"

echo "--- video output ---"; echo "$out" | grep -iE "video\]|JPEG|FAULT|killed" | head
[ "$fail" = 0 ] && { echo "==== VIDEO-FUZZ OK ===="; exit 0; }
echo "==== VIDEO-FUZZ FAILED ===="; exit 1
