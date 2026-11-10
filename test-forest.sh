#!/bin/bash
# test-forest.sh - the live agent forest ('forest' / 'run forest',
#   user/forest.c). Boots agentos32.img, spawns two agents, finishes one
#   task and starts a long one, then launches 'forest' and screendumps the
#   framebuffer: the night-sky gradient, the aurora, the fir bodies and the
#   accent glow of the working agent's crown must be on screen, and the
#   scene must still be animating (two dumps differ). 'q' must quit back to
#   the shell, the kernel must repaint the desktop (the dump after the quit
#   differs from the forest), and the shell must answer.
set -u
cd "$(dirname "$0")"
IMG="${1:-agentos32.img}"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu-system-i386 missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 2; }
TMPIMG=$(mktemp --suffix=.img); cp "$IMG" "$TMPIMG"
FIFO=$(mktemp -u); mkfifo "$FIFO"
LOG=$(mktemp); PA=$(mktemp --suffix=.ppm); PB=$(mktemp --suffix=.ppm); PC=$(mktemp --suffix=.ppm)
MPORT=55578
FAILED=0
qemu-system-i386 -drive format=raw,file="$TMPIMG" -vga std \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -net none -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; rm -f "$TMPIMG" "$FIFO" "$LOG" "$PA" "$PB" "$PC"; }
trap cleanup EXIT
send() {
  local s="$1" i
  for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done
  printf '\r' >&3
}
check() {
  local t=0
  while [ "$(grep -aFc -- "$2" "$LOG")" -lt 1 ]; do
    sleep 0.3; t=$((t + 1))
    if [ $t -ge 100 ]; then echo "FAIL : $1"; FAILED=1; return 1; fi
  done
  echo "OK   : $1"
}
dump() { printf "screendump %s\n" "$1" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1; }
for t in $(seq 1 60); do grep -aq "tannx> " "$LOG" && break; sleep 0.3; done
sleep 1
send "spawn prime"; sleep 0.5
send "spawn math"; sleep 0.5
send "task math 6 * 7"
check "a finished task grows a tree"                      "math done = 42"
send "task prime 150000"; sleep 0.5                        # long: a seed in flight + a glowing crown
send "forest"
check "forest launches in ring 3 and reports the scene"   "forest: ready "
check "it counted the agents"                             ", 2 agents, 1 tasks done"
sleep 8                                                    # the full first frame + a few dirty-rect frames (TCG)
dump "$PA"
sleep 3
dump "$PB"
printf 'q' >&3
check "q quits the forest with its frame statistics"      "forest: quit after "
sleep 3
dump "$PC"
send "echo forest-done"
check "shell answers after the forest exits"              "forest-done"

RES="$(python3 - "$PA" "$PB" "$PC" <<'PY'
import sys
def load(p):
    f=open(p,'rb'); assert f.readline().strip()==b'P6'
    w,h=map(int,f.readline().split()); f.readline(); return w,h,f.read()
try:
    w,h,a=load(sys.argv[1]); _,_,b=load(sys.argv[2]); _,_,c=load(sys.argv[3])
    def px(d,x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    r,g,bl=px(a,w//2,4); sky_ok = r<20 and g<24 and bl<30          # night sky at the top
    gy=h*80//100
    r,g,bl=px(a,w//2,gy+h//40); ground_ok = g>r and g>bl and g<60 and r<40   # dark green ground
    aur=body=glow=0
    for y in range(h//10, gy, 4):
        for x in range(0,w,4):
            r,g,bl=px(a,x,y)
            if y < h*45//100 and g>80 and g>r+40 and bl>r: aur+=1        # aurora light
            if (r,g,bl)==(0x2a,0x6b,0x60) or (r,g,bl)==(0x6f,0xc6,0xb4): body+=1   # fir body / lit edge
            if g>190 and bl>170 and r<120: glow+=1                       # accent glow
    diff=tot=0
    for y in range(0,h,7):
        for x in range(0,w,7):
            tot+=1; o=(y*w+x)*3
            if abs(a[o]-b[o])+abs(a[o+1]-b[o+1])+abs(a[o+2]-b[o+2])>24: diff+=1
    anim = diff
    diff2=0
    for y in range(0,h,7):
        for x in range(0,w,7):
            o=(y*w+x)*3
            if abs(a[o]-c[o])+abs(a[o+1]-c[o+1])+abs(a[o+2]-c[o+2])>40: diff2+=1
    back = 100*diff2//max(tot,1)
    print("sky_ok=%d ground_ok=%d aur=%d body=%d glow=%d anim=%d back=%d"%(sky_ok,ground_ok,aur,body,glow,anim,back))
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
val() { echo "$RES" | sed -n "s/.*$1=\([0-9]*\).*/\1/p"; }
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; FAILED=1; fi; }
[ "$(val sky_ok)" = 1 ] && s=1 || s=0;            chk "$s" "night-sky gradient at the top"
[ "$(val ground_ok)" = 1 ] && s=1 || s=0;         chk "$s" "dark green ground below the horizon"
[ "${AUR:=$(val aur)}" -gt 400 ] 2>/dev/null && s=1 || s=0;   chk "$s" "aurora curtains light the sky ($AUR px)"
[ "${BODY:=$(val body)}" -gt 150 ] 2>/dev/null && s=1 || s=0; chk "$s" "fir trees in the house teal ($BODY px)"
[ "${GLOW:=$(val glow)}" -gt 20 ] 2>/dev/null && s=1 || s=0;  chk "$s" "the working agent's crown glows ($GLOW px)"
[ "${ANIM:=$(val anim)}" -gt 40 ] 2>/dev/null && s=1 || s=0;  chk "$s" "the scene animates between two dumps ($ANIM samples changed)"
# the Workspace desktop (concept C) is itself a dark fir-green scene, so
#   only ~30% of the samples differ from the forest night - 15% still
#   separates "repainted" from "forest left on screen" (~0%).
[ "${BACK:=$(val back)}" -gt 15 ] 2>/dev/null && s=1 || s=0;  chk "$s" "the desktop is repainted after the quit (${BACK}% changed)"
echo "----"
if [ "$FAILED" -eq 0 ]; then echo "==== test-forest PASSED ===="; exit 0
else echo "==== test-forest FAILED ===="; echo "--- log ---"; grep -av "^ *$" "$LOG" | tail -40; exit 1; fi
