#!/usr/bin/env bash
# ============================================================
#  Text browser test ('run www <url>', user/www.c + proxy_ext.py /fetch).
#  Mock proxy on the host (a fixed page with 3 links, no Internet), the OS
#  fetches it over its own TCP stack, follows link 2 by number, goes back,
#  quits. Host side: GET /fetch?url= works for curl, and the SSRF guard
#  refuses loopback / private / non-http targets.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
PROXYLOG="$(mktemp)"; LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PPM="$(mktemp --suffix=.ppm)"
MPORT=$((55900 + RANDOM % 300)); QPID=""; PRXPID=""
cleanup() { exec 3>&- 2>/dev/null; [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; [ -n "$PRXPID" ] && kill "$PRXPID" 2>/dev/null; wait 2>/dev/null; rm -f "$FIFO" "$IMG" "$LOG" "$PPM" "$PROXYLOG"; }
trap cleanup EXIT
. ./proxy-port.sh                # LLM_PROXY_PORT: 4080 / <n> / auto
python3 ./llm-proxy.py --mock --port "$PPORT" >"$PROXYLOG" 2>&1 &
PRXPID=$!
sleep 0.6
grep -q "listening" "$PROXYLOG" || { echo "proxy did not start"; cat "$PROXYLOG"; exit 1; }
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
echo "==== host-side /fetch ===="
curl -s "http://127.0.0.1:$PPORT/fetch?url=http://example.com/" | grep -q "TITLE: TannX mock page" && a=1 || a=0
chk "$a" "GET /fetch?url= answers the mock page (curl)"
G="$(python3 - <<'PY'
import proxy_ext as p
bad=0
for u in ["http://127.0.0.1/","http://localhost/x","http://10.1.2.3/","http://192.168.1.1/","http://169.254.169.254/","ftp://example.com/","file:///etc/passwd"]:
    try: p.check_url(u); bad+=1; print("ALLOWED", u)
    except p.SSRFError: pass
    except Exception as e: print("other", u, e)
print("refused_all=%d" % int(bad==0))
PY
)"
echo "  $G" | tail -1
echo "$G" | grep -q "refused_all=1" && a=1 || a=0
chk "$a" "SSRF guard refuses loopback / RFC1918 / link-local / non-http URLs"

qemu-system-i386 -drive format=raw,file="$IMG" -vga std -monitor telnet:127.0.0.1:$MPORT,server,nowait \
  -netdev "user,id=n0$PFWD" -device rtl8139,netdev=n0 -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while [ "$(grep -ac -- "$1" "$LOG")" -lt "${3:-1}" ]; do sleep 0.5; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
send 'run www http://example.com/start'
waitfor 'www: title TannX mock page' 40
sleep 2
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf '2' >&3; sleep 0.3; printf '\r' >&3            # follow link [2]
waitfor 'www: fetching http://mock.test/manifesto' 30
waitfor 'www: title TannX mock page' 30 2
printf 'h' >&3                                        # back
waitfor 'www: fetching http://example.com/start' 30 2
sleep 14                                              # behind a guestfwd a fetch lingers ~12 s
printf 'q' >&3; waitfor 'www: quit' 60
send 'echo shell-lives'; sleep 2
send 'halt'; sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

echo "==== www output ===="
sed 's/\r//g' "$LOG" | grep -a "www:" | head -20
echo "==== checks ===="
g() { grep -aqE -- "$1" "$LOG" && echo 1 || echo 0; }
chk "$(g 'www: fetching http://example.com/start')"   "run www <url> starts a fetch through the proxy"
chk "$(g 'www: 10 lines, 3 links')"                    "the page arrived and was wrapped: 10 lines, 3 links"
chk "$(g 'www: title TannX mock page')"          "the title line was parsed"
chk "$(g 'www: fetching http://mock.test/manifesto')"  "typing 2 + Enter follows link [2]"
[ "$(grep -ac 'www: fetching http://example.com/start' "$LOG")" -ge 2 ] && a=1 || a=0
chk "$a"                                               "h goes back to the previous page"
chk "$(g 'www: quit')"                                 "q quits the browser"
chk "$(g 'shell-lives')"                               "shell lives afterwards"
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb'); assert f.readline().strip()==b'P6'
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    bg=px(4,h//2); bg_ok=abs(bg[0]-10)<=6 and abs(bg[1]-22)<=6 and abs(bg[2]-20)<=6
    acc=ink=0
    for y in range(0,h,3):
        for x in range(0,w,3):
            r,g,b=px(x,y)
            if g>180 and b>150 and r<100: acc+=1
            if r>180 and g>180 and b>180: ink+=1
    print(f"bg_ok={int(bg_ok)} acc_ok={int(acc>100)} ink_ok={int(ink>200)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'bg_ok=1' && a=1 || a=0;  chk "$a" "screendump: brand background"
echo "$RES" | grep -q 'ink_ok=1' && a=1 || a=0; chk "$a" "screendump: page text rendered"
[ "$fail" -eq 0 ] && { echo "==== WWW OK ===="; exit 0; }
echo "==== WWW FAILED ===="; sed 's/\r//g' "$LOG" | tail -20; cat "$PROXYLOG"; exit 1
