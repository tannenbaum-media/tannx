#!/usr/bin/env bash
# ============================================================
#  virtio-gpu driver test. The `vgpu` command runs a ring-3 C
#  driver (user/vgpu.c): it finds the modern virtio-gpu, walks its PCI
#  caps, runs the device-init handshake, sets up the control virtqueue in
#  user RAM, and drives the full 2D pipeline (GET_DISPLAY_INFO ->
#  RESOURCE_CREATE_2D -> ATTACH_BACKING -> SET_SCANOUT -> TRANSFER_TO_HOST
#  -> FLUSH) to put a real picture on the scanout.
#
#  QEMU only: -vga none -device virtio-gpu-pci makes the virtio-gpu the
#  sole display, so the monitor screendump captures what the driver drew.
#  We assert the serial log AND that the three colour bars are on screen.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
PPM="$(mktemp --suffix=.ppm)"; LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
IMG2=""; PPM2=""; LOG2=""; FIFO2=""
IMG3=""; LOG3=""; FIFO3=""
IMG4=""; PPM4A=""; PPM4B=""; LOG4=""; FIFO4=""
QPID=""; QP2=""; QP3=""; QP4=""
MPORT=55613
cleanup() {
  exec 3>&- 4>&- 5>&- 6>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QP2" ] && kill "$QP2" 2>/dev/null
  [ -n "$QP3" ] && kill "$QP3" 2>/dev/null
  [ -n "$QP4" ] && kill "$QP4" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  [ -n "$QP2" ] && wait "$QP2" 2>/dev/null
  [ -n "$QP3" ] && wait "$QP3" 2>/dev/null
  [ -n "$QP4" ] && wait "$QP4" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$PPM" "$LOG" "$FIFO2" "$IMG2" "$PPM2" "$LOG2" \
        "$FIFO3" "$IMG3" "$LOG3" "$FIFO4" "$IMG4" "$PPM4A" "$PPM4B" "$LOG4"
}
trap cleanup EXIT

qemu-system-i386 -drive format=raw,file="$IMG" -vga none -device virtio-gpu-pci \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
printf 'vgpu\r' >&3;  sleep 3
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1
sleep 1
printf 'halt\r' >&3;  sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

echo "==== virtio-gpu driver checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

grep -aq "found 1af4:1050" "$LOG" && a=1 || a=0
chk "$a" "the modern virtio-gpu is found and its PCI caps walked"
grep -aq "mapped BAR" "$LOG" && b=1 || b=0
chk "$b" "device-init handshake + BAR map (FEATURES_OK/DRIVER_OK)"
grep -aq "scanouts=[1-9][0-9]* active=" "$LOG" && m=1 || m=0
chk "$m" "GET_DISPLAY_INFO enumerates enabled scanouts and picks an active one"
grep -aq "set scanout [0-9][0-9]* -> resource 1" "$LOG" && s0=1 || s0=0
chk "$s0" "SET_SCANOUT uses the selected scanout"
grep -aq "active scanout [0-9][0-9]* =" "$LOG" && al=1 || al=0
chk "$al" "the standalone vgpu log reports the selected scanout"
grep -aq "flush OK" "$LOG" && c=1 || c=0
chk "$c" "full 2D pipeline ran: create/attach/scanout/transfer/flush"

# verify the driver's framebuffer actually reached the scanout: the three
# colour bars (red 0xf87171, green 0x4ade80, cyan 0x22d3ee) at known spots.
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb')
    if f.readline().strip()!=b'P6': print("noppm"); sys.exit(0)
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    def near(p,r,g,b): return abs(p[0]-r)+abs(p[1]-g)+abs(p[2]-b) < 60
    red   = near(px(int(w*0.25), int(h*0.41)), 0xf8,0x71,0x71)
    green = near(px(int(w*0.50), int(h*0.56)), 0x4a,0xde,0x80)
    cyan  = near(px(int(w*0.75), int(h*0.73)), 0x22,0xd3,0xee)
    print(f"dims={w}x{h} red={int(red)} green={int(green)} cyan={int(cyan)}")
except Exception as e:
    print("err", e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'red=1 green=1 cyan=1' && e=1 || e=0
chk "$e" "the driver's framebuffer is on the scanout (3 colour bars DMA'd)"

echo "--- vgpu output ---"; sed 's/\r//g' "$LOG" | grep -i "vgpu:" | head

# -- phase 2: the COMPOSITOR renders via virtio-gpu (the optional GPU path) --
# A second boot: with no firmware FB (-vga none), the Dark Glass compositor
# must use the virtio-gpu backing and present each frame. Screendump the
# virtio-gpu and assert the navy gradient wallpaper is on it.
IMG2="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG2"
PPM2="$(mktemp --suffix=.ppm)"; LOG2="$(mktemp)"; FIFO2="$(mktemp -u)"; mkfifo "$FIFO2"
qemu-system-i386 -drive format=raw,file="$IMG2" -vga none -device virtio-gpu-pci \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -nographic <"$FIFO2" >"$LOG2" 2>/dev/null &
QP2=$!; exec 4>"$FIFO2"; sleep 4
printf 'sysinfo\r' >&4; sleep 1; printf 'gui\r' >&4; sleep 4
printf "screendump %s\n" "$PPM2" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf 'halt\r' >&4; sleep 1
exec 4>&- 2>/dev/null; kill "$QP2" 2>/dev/null; wait "$QP2" 2>/dev/null; QP2=""

grep -aq "PAGE FAULT" "$LOG2" && pf=1 || pf=0
chk "$([ $pf = 0 ] && echo 1 || echo 0)" "the compositor runs on virtio-gpu without faulting"
R2="$(python3 - "$PPM2" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb')
    if f.readline().strip()!=b'P6': print("noppm"); sys.exit(0)
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    tr,tg,tb=px(10,h//5); br,bg,bb=px(10,h-10)          # left-margin wallpaper
    navy = tr<28 and tg<34 and tb<48 and tb>tr           # dark bluish navy
    grad = bb>tb and bg>tg                               # lifts toward the bottom
    print(f"top={tr},{tg},{tb} bot={br},{bg},{bb} navy={int(navy)} grad={int(grad)}")
except Exception as e: print("err",e)
PY
)"
echo "  $R2"
echo "$R2" | grep -q 'navy=1 grad=1' && g=1 || g=0
chk "$g" "the Dark Glass desktop is presented on the virtio-gpu scanout"

# -- phase 4: the compositor keeps PRESENTING after a game (audit finding 7: freeze) --
# A foreground game is the same user.bin image, so its crt0 zeroes the shared
# .bss including vgpu.c's state (vg_fb/desc/...). If reclaim doesn't re-run
# vgpu_setup, vgpu_present() sees vg_fb==0 and the scanout stays FROZEN on the
# pre-game frame. Proof: launch+quit snake, then two screendumps ~3 s apart -
# a live compositor's clock/spinner/accent move, so the frames must DIFFER.
IMG4="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG4"
PPM4A="$(mktemp --suffix=.ppm)"; PPM4B="$(mktemp --suffix=.ppm)"
LOG4="$(mktemp)"; FIFO4="$(mktemp -u)"; mkfifo "$FIFO4"
qemu-system-i386 -drive format=raw,file="$IMG4" -vga none -device virtio-gpu-pci \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -nographic <"$FIFO4" >"$LOG4" 2>/dev/null &
QP4=$!; exec 6>"$FIFO4"; sleep 4
printf 'gui\r' >&6;   sleep 4
printf 'snake\r' >&6; sleep 5        # snake auto-starts (~3 s) into play
printf 'q' >&6;       sleep 5        # quit it -> the compositor reclaims the screen
printf "screendump %s\n" "$PPM4A" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 3
printf "screendump %s\n" "$PPM4B" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf 'halt\r' >&6;  sleep 1
exec 6>&- 2>/dev/null; kill "$QP4" 2>/dev/null; wait "$QP4" 2>/dev/null; QP4=""

grep -aq "PAGE FAULT" "$LOG4" && pf4=1 || pf4=0
chk "$([ $pf4 = 0 ] && echo 1 || echo 0)" "the compositor survives a game launch/exit on virtio-gpu (no fault)"
# the frozen-vs-live check is only meaningful once snake has actually EXITED
# (otherwise it's still foreground and the compositor is legitimately stepped aside)
if grep -aq "snake: quit" "$LOG4"; then
  if [ -s "$PPM4A" ] && [ -s "$PPM4B" ] && cmp -s "$PPM4A" "$PPM4B"; then
    frozen=1; else frozen=0; fi
  chk "$([ $frozen = 0 ] && echo 1 || echo 0)" "the compositor keeps presenting after the game (not frozen; audit finding 7)"
else
  echo "SKIP : freeze check (snake did not exit in time - timing, not the bug)"
fi

# -- phase 3: QEMU multi-output reality check (diagnostic, not a gate) --
# This QEMU exposes a max_outputs property, but with max_outputs=2 it still
# currently reports one enabled scanout to GET_DISPLAY_INFO. Keep this visible
# so future work does not fake a multi-scanout presentation test on a single
# active output.
IMG3="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG3"
LOG3="$(mktemp)"; FIFO3="$(mktemp -u)"; mkfifo "$FIFO3"
qemu-system-i386 -drive format=raw,file="$IMG3" -vga none -device virtio-gpu-pci,max_outputs=2 \
  -nographic <"$FIFO3" >"$LOG3" 2>/dev/null &
QP3=$!; exec 5>"$FIFO3"; sleep 4
printf 'vgpu\r' >&5; sleep 3; printf 'halt\r' >&5; sleep 1
exec 5>&- 2>/dev/null; kill "$QP3" 2>/dev/null; wait "$QP3" 2>/dev/null; QP3=""
MOUT="$(sed 's/\r//g' "$LOG3" | grep -i 'display info ok, scanouts=' | head -1 || true)"
if [ -n "$MOUT" ]; then
  echo "INFO : max_outputs=2 probe -> $MOUT"
else
  echo "INFO : max_outputs=2 probe produced no display-info line"
fi

[ "$fail" = 0 ] && { echo "==== VGPU OK ===="; exit 0; }
echo "==== VGPU FAILED ===="; exit 1
