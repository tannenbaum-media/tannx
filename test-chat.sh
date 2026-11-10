#!/usr/bin/env bash
# ============================================================
#  'run chat' - the full-screen LLM chat (user/chat.c). Mock proxy on the
#  host, QEMU slirp; a prompt is typed INTO the chat over serial, the canned
#  answer must come back through the OS's TCP stack and be echoed on the
#  serial console; a screendump proves the bubbles are on the framebuffer
#  (teal user bubble right, dark agent bubble left, the accent header line);
#  ESC ESC quits and the shell still answers (SYS_KBGRAB released).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_chat_XXXX.img)"; cp agentos32.img "$IMG"
PROXYLOG="$(mktemp /tmp/agentos_chat_proxy_XXXX.log)"
. ./proxy-port.sh                # LLM_PROXY_PORT: 4080 / <n> / auto
python3 ./llm-proxy.py --mock --port "$PPORT" >"$PROXYLOG" 2>&1 &
PRXPID=$!
sleep 0.6
grep -q "listening" "$PROXYLOG" || { echo "proxy did not start"; cat "$PROXYLOG"; kill "$PRXPID" 2>/dev/null; exit 1; }

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PPM="$(mktemp --suffix=.ppm)"
MPORT=55591
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -nographic \
  -netdev "user,id=n0$PFWD" -device rtl8139,netdev=n0 \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" "$PRXPID" 2>/dev/null; wait "$QPID" 2>/dev/null; rm -f "$FIFO" "$IMG" "$PPM" "$LOG" "$PROXYLOG"; }
trap cleanup EXIT
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$LOG"; do sleep 0.3; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
send 'run chat'
waitfor "chat: ready" 60
send 'what is the wish loop'           # typed INTO the chat (fg_prog routes keys to the ring-3 key ring)
waitfor "chat: ai>" 80
sleep 2
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf '\x1b\x1b' >&3                  # ESC ESC = a lone Escape over serial -> quit
sleep 2
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1

echo "==== chat output ===="
sed 's/\r//g' "$LOG" | grep -aE "chat:|shell-lives" || echo "(no chat output)"
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb')
    if f.readline().strip()!=b'P6': print("noppm"); sys.exit(0)
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y):
        o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    teal=lambda c: abs(c[0]-0x2d)<20 and abs(c[1]-0xd4)<20 and abs(c[2]-0xbf)<20
    surf2=lambda c: abs(c[0]-0x18)<8 and abs(c[1]-0x35)<8 and abs(c[2]-0x30)<8
    # accent line along the very top of the header
    top=sum(1 for x in range(0,w,8) if teal(px(x,0)))
    # user bubble: teal area in the right half of the message area
    # (one exchange: the bubbles sit just above the input box near the bottom)
    ub=sum(1 for y in range(h//5,h-h//12,4) for x in range(w//2,w,4) if teal(px(x,y)))
    # agent bubble: raised surface in the left half
    ab=sum(1 for y in range(h//5,h-h//12,4) for x in range(0,w//2,4) if surf2(px(x,y)))
    # light text pixels inside the message area (the answer)
    ink=sum(1 for y in range(h//5,h-h//12,4) for x in range(0,w//2,4) if px(x,y)[1]>200 and px(x,y)[0]>200)
    print(f"w={w} h={h} top={top} ub={ub} ab={ab} ink={ink} top_ok={int(top>w//16)} ub_ok={int(ub>40)} ab_ok={int(ab>60)} ink_ok={int(ink>30)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "==== checks ===="
fail=0
chk() { if grep -qaE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "chat: ready \(proxy: connected\)"       "chat starts and brings the network up"
chk "chat: you> what is the wish loop"       "the typed line went to the chat, not the shell (SYS_KBGRAB)"
chk "chat: ai> AGENTOS-LLM-MOCK"             "the answer came back through the OS TCP stack"
chk "You asked: what is the wish loop"       "the prompt reached the proxy verbatim"
chk "chat: quit"                             "ESC ESC quits the chat"
chk "shell-lives"                            "shell answers again afterwards (keyboard released)"
grep -q "prompt: 'what is the wish loop'" "$PROXYLOG" && echo "OK   : proxy logged the prompt" || { echo "FAIL : proxy logged the prompt"; fail=1; }
for k in top ub ab ink; do
  if echo "$RES" | grep -q "${k}_ok=1"; then echo "OK   : screendump $k"; else echo "FAIL : screendump $k"; fail=1; fi
done
if grep -qa "^what is the wish loop" "$LOG" || grep -qa "Unknown command: what" "$LOG"; then echo "FAIL : the chat line leaked into the shell"; fail=1; else echo "OK   : nothing leaked into the shell line editor"; fi
[ "$fail" -eq 0 ] && { echo "==== CHAT OK ===="; exit 0; }
echo "==== CHAT FAILED ===="; sed 's/\r//g' "$LOG" | tail -30; cat "$PROXYLOG"; exit 1
