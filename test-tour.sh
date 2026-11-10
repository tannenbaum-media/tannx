#!/usr/bin/env bash
# ============================================================
#  Guided tour test ('run tour', user/tour.c). The tour is the first thing
#  the README tells a new user to run, so it must work headless: it owns
#  the keyboard + framebuffer (SYS_FGRAB), drives REAL shell commands
#  through SYS_SHELL and reads their output back through SYS_CONSOLE.
#  We step through it over serial, check the kernel's own echo of the
#  injected commands and the agents' results, and screendump a step card
#  (brand background, accent, text ink, and NO kernel status bar painted
#  over it - the FB grab must silence the kernel's drawing).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PPM="$(mktemp --suffix=.ppm)"
MPORT=$((55600 + RANDOM % 300)); QPID=""
cleanup() { exec 3>&- 2>/dev/null; [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; [ -n "$QPID" ] && wait "$QPID" 2>/dev/null; rm -f "$FIFO" "$IMG" "$LOG" "$PPM"; }
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -net none \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$LOG"; do sleep 0.5; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
send 'run tour';            waitfor 'tour: ready' 30
sleep 2
printf 'n' >&3;             waitfor 'tour: step 1 ran' 40      # spawn prime, live
printf 'n' >&3;             waitfor 'tour: step 2 ran' 60      # task prime 100 + tasks
sleep 1
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf 'n' >&3;             waitfor 'tour: step 3 ran' 60      # spawn scan + task scan b8000
printf 'b' >&3;             waitfor 'tour: step 2$' 20 || true  # back works
sleep 4
printf 'q' >&3;             waitfor 'tour: done' 20
sleep 1
send 'echo shell-lives';    sleep 2
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

echo "==== tour output ===="
sed 's/\r//g' "$LOG" | grep -aE "tour:|tannx> (spawn|task|tasks|clear)|agent ready|prime done|PAGE FAULT|shell-lives" | head -30
echo "==== checks ===="
fail=0
chk() { if grep -aqE -- "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "tour: ready"                       "the tour starts (framebuffer + keyboard grab)"
chk "(tannx> |^)spawn prime"           "SYS_SHELL typed 'spawn prime' into the real shell (kernel echo)"
chk "\(prime\) agent ready"             "the shell executed it: a prime agent came up"
chk "prime done = 541"                  "'task prime 100' ran live and the agent found 541"
chk "PAGE FAULT at 0x000b8000"          "the isolation step killed the scan agent, not the OS"
chk "tour: step 3 ran"                  "the tour read the fault back and moved on"
chk "tour: done"                        "q leaves the tour"
chk "shell-lives"                       "the shell is back afterwards (keyboard released)"
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb'); assert f.readline().strip()==b'P6'
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    bg=px(4,h//2); bg_ok=abs(bg[0]-10)<=6 and abs(bg[1]-22)<=6 and abs(bg[2]-20)<=6
    acc=ink=blue=0
    for y in range(0,h,3):
        for x in range(0,w,3):
            r,g,b=px(x,y)
            if g>180 and b>150 and r<100: acc+=1          # brand teal accent
            if r>180 and g>180 and b>180: ink+=1          # white-ish text
            if b>120 and r<40 and g<40: blue+=1           # the kernel's VGA-blue status bar
    print(f"bg={bg} acc={acc} ink={ink} blue={blue} bg_ok={int(bg_ok)} acc_ok={int(acc>150)} ink_ok={int(ink>200)} clean_ok={int(blue<50)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'bg_ok=1' && a=1 || a=0;    chk2() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk2 "$a" "screendump: brand background #0A1614"
echo "$RES" | grep -q 'acc_ok=1' && a=1 || a=0;   chk2 "$a" "screendump: teal accent elements"
echo "$RES" | grep -q 'ink_ok=1' && a=1 || a=0;   chk2 "$a" "screendump: card text rendered"
echo "$RES" | grep -q 'clean_ok=1' && a=1 || a=0; chk2 "$a" "screendump: kernel status bar NOT painted over the app (FB grab)"
[ "$fail" -eq 0 ] && { echo "==== TOUR OK ===="; exit 0; }
echo "==== TOUR FAILED ===="; sed 's/\r//g' "$LOG" | tail -30; exit 1
