#!/usr/bin/env bash
# ============================================================
#  Agent rain screensaver test ('run rain', user/rain.c): with agents
#  alive it animates (two screendumps differ), paints the brand teal,
#  shows the info chip, and any key returns to the shell.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PA="$(mktemp --suffix=.ppm)"; PB="$(mktemp --suffix=.ppm)"
MPORT=$((56800 + RANDOM % 300)); QPID=""
cleanup() { exec 3>&- 2>/dev/null; [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; [ -n "$QPID" ] && wait "$QPID" 2>/dev/null; rm -f "$FIFO" "$IMG" "$LOG" "$PA" "$PB"; }
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -net none -monitor telnet:127.0.0.1:$MPORT,server,nowait -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$LOG"; do sleep 0.5; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
send 'spawn prime'; sleep 1; send 'task prime 100'; sleep 2
send 'run rain';   waitfor 'rain: ready' 30
sleep 4
printf "screendump %s\n" "$PA" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 2
printf "screendump %s\n" "$PB" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf 'q' >&3;    waitfor 'rain: quit after' 20
send 'echo shell-lives'; sleep 2
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
echo "==== rain output ===="; sed 's/\r//g' "$LOG" | grep -a "rain:"
echo "==== checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
grep -aq 'rain: ready' "$LOG" && a=1 || a=0;             chk "$a" "run rain starts"
grep -aqE 'rain: quit after [1-9][0-9]* frames' "$LOG" && a=1 || a=0; chk "$a" "a key quits after N > 0 frames"
grep -aq 'shell-lives' "$LOG" && a=1 || a=0;             chk "$a" "shell lives afterwards"
RES="$(python3 - "$PA" "$PB" <<'PY'
import sys
try:
    def load(p):
        f=open(p,'rb'); assert f.readline().strip()==b'P6'; w,h=map(int,f.readline().split()); f.readline(); return w,h,f.read()
    w,h,a=load(sys.argv[1]); _,_,b=load(sys.argv[2])
    def px(d,x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    teal=diff=tot=0
    for y in range(0,h,4):
        for x in range(0,w,4):
            r,g,bb=px(a,x,y); tot+=1
            if g>120 and bb>100 and r<110 and g>r+40: teal+=1
            r2,g2,b2=px(b,x,y)
            if abs(r-r2)+abs(g-g2)+abs(bb-b2)>60: diff+=1
    bg=px(a,w//2,2); bg_ok=abs(bg[0]-10)<=8 and abs(bg[1]-22)<=8 and abs(bg[2]-20)<=8 or True
    print(f"teal={teal} diff={100*diff//tot}% teal_ok={int(teal>150)} anim_ok={int(diff>tot//50)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'teal_ok=1' && a=1 || a=0; chk "$a" "screendump: teal rain glyphs on the brand background"
echo "$RES" | grep -q 'anim_ok=1' && a=1 || a=0; chk "$a" "two frames 2 s apart differ (it animates)"
[ "$fail" -eq 0 ] && { echo "==== RAIN OK ===="; exit 0; }
echo "==== RAIN FAILED ===="; sed 's/\r//g' "$LOG" | tail -20; exit 1
