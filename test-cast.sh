#!/usr/bin/env bash
# ============================================================
#  Chromecast test ('run cast', user/cast.c + proxy_ext.py /cast/*). The
#  mock proxy simulates a "Living Room TV": one-shot 'run cast play <url>'
#  from the shell, then the app: pause, volume, stop, quit. Screendump of
#  the now-playing card.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
PROXYLOG="$(mktemp)"; LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PPM="$(mktemp --suffix=.ppm)"
MPORT=$((56500 + RANDOM % 300)); QPID=""; PRXPID=""
cleanup() { exec 3>&- 2>/dev/null; [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; [ -n "$PRXPID" ] && kill "$PRXPID" 2>/dev/null; wait 2>/dev/null; rm -f "$FIFO" "$IMG" "$LOG" "$PPM" "$PROXYLOG"; }
trap cleanup EXIT
. ./proxy-port.sh                # LLM_PROXY_PORT: 4080 / <n> / auto
python3 ./llm-proxy.py --mock --port "$PPORT" >"$PROXYLOG" 2>&1 &
PRXPID=$!
sleep 0.6
grep -q "listening" "$PROXYLOG" || { echo "proxy did not start"; cat "$PROXYLOG"; exit 1; }
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -monitor telnet:127.0.0.1:$MPORT,server,nowait \
  -netdev "user,id=n0$PFWD" -device rtl8139,netdev=n0 -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$LOG"; do sleep 0.5; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
send 'run cast play https://youtu.be/dQw4w9WgXcQ';  waitfor 'title=YouTube video dQw4w9WgXcQ' 40
sleep 1
send 'run cast';     waitfor 'cast: devices 1' 40
sleep 3
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
# each op lingers up to ~6 s behind a guestfwd (see proxy_post); keys queue in the ring
printf ' ' >&3;      waitfor 'cast: ok paused' 60
printf '+' >&3;      waitfor 'cast: ok volume' 60
printf 's' >&3;      waitfor 'cast: ok stopped' 60
sleep 3; printf 'q' >&3;  waitfor 'cast: quit' 60
send 'echo shell-lives'; sleep 2
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
echo "==== cast output ===="; sed 's/\r//g' "$LOG" | grep -aE "cast:|^ok |state=|title=" | head -20
echo "==== checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
g() { grep -aqE -- "$1" "$LOG" && echo 1 || echo 0; }
chk "$(g 'cast: device Living Room TV')"              "one-shot: the proxy's device list reached the OS (mock Living Room TV)"
chk "$(g 'title=YouTube video dQw4w9WgXcQ')"           "one-shot: 'run cast play <youtube url>' plays via the YouTube receiver (mock)"
chk "$(g 'state=PLAYING')"                             "one-shot: status PLAYING printed"
chk "$(g 'cast: devices 1')"                           "app: device discovery"
chk "$(g 'cast: ok paused')"                           "app: space pauses"
chk "$(g 'cast: ok volume')"                           "app: + raises the volume"
chk "$(g 'cast: ok stopped')"                          "app: s stops"
chk "$(g 'cast: quit')"                                "app: q quits"
chk "$(g 'shell-lives')"                               "shell lives afterwards"
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb'); assert f.readline().strip()==b'P6'
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    bg=px(2,h//2); bg_ok=abs(bg[0]-10)<=6 and abs(bg[1]-22)<=6 and abs(bg[2]-20)<=6
    acc=sum(1 for y in range(0,h,3) for x in range(0,w,3) if (lambda r,g,b: g>180 and b>150 and r<100)(*px(x,y)))
    print(f"bg_ok={int(bg_ok)} acc_ok={int(acc>100)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'bg_ok=1' && a=1 || a=0;  chk "$a" "screendump: brand background"
echo "$RES" | grep -q 'acc_ok=1' && a=1 || a=0; chk "$a" "screendump: now-playing card with the teal progress/state"
[ "$fail" -eq 0 ] && { echo "==== CAST OK ===="; exit 0; }
echo "==== CAST FAILED ===="; sed 's/\r//g' "$LOG" | tail -20; cat "$PROXYLOG"; exit 1
