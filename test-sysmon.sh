#!/usr/bin/env bash
# ============================================================
#  'run sysmon' - the live system monitor (user/sysmon.c). Agents get work,
#  the monitor starts, prints its periodic telemetry line over serial, a
#  screendump proves the dashboard is on the framebuffer (accent header,
#  panel surfaces, table text, graph bars), 'q' quits and the shell lives.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; PPM="$(mktemp --suffix=.ppm)"
MPORT=55593
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -nographic \
  -netdev user,id=n0 -device rtl8139,netdev=n0 \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; rm -f "$FIFO" "$IMG" "$PPM" "$LOG"; }
trap cleanup EXIT
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
waitfor() { local t=0; while ! grep -aq -- "$1" "$LOG"; do sleep 0.3; t=$((t+1)); [ $t -ge "$2" ] && return 1; done; return 0; }
sleep 4
send 'spawn prime'; sleep 0.5
send 'spawn math'; sleep 0.5
send 'task math 1337 * 42'; sleep 0.5
send 'task prime 65000'; sleep 0.3
send 'task prime 64000'; sleep 0.3
send 'run sysmon'
waitfor "sysmon: ready" 60
waitfor "sysmon: up=" 60
sleep 6
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf 'q' >&3
waitfor "sysmon: quit" 20
send 'echo shell-lives'; sleep 2
send 'halt'; sleep 1

echo "==== sysmon output ===="
sed 's/\r//g' "$LOG" | grep -aE "sysmon:|shell-lives|done =" || echo "(no output)"
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb')
    if f.readline().strip()!=b'P6': print("noppm"); sys.exit(0)
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y):
        o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    teal=lambda c: abs(c[0]-0x2d)<20 and abs(c[1]-0xd4)<20 and abs(c[2]-0xbf)<20
    surf=lambda c: abs(c[0]-0x12)<6 and abs(c[1]-0x28)<6 and abs(c[2]-0x23)<6
    top=sum(1 for x in range(0,w,8) if teal(px(x,0)))
    panels=sum(1 for y in range(h//8,h//2,6) for x in range(0,w,6) if surf(px(x,y)))
    # table text: primary (E6F2EE) or muted (7FA399) glyph pixels in the agents panel
    ink=sum(1 for y in range(h//5,h//2,2) for x in range(0,w//2,2) if px(x,y)[1]>150 and px(x,y)[0]>100)
    # graph bars: teal (any brightness - older bars are dimmed) or amber/red columns
    def barpx(c):
        r,g,b=c
        return (g>r+30 and b>r+20 and g>55)
    bars=sum(1 for y in range(h*3//5,h-h//10,3) for x in range(w//2,w,3) if barpx(px(x,y)))
    print(f"w={w} h={h} top={top} panels={panels} ink={ink} bars={bars} top_ok={int(top>w//16)} panels_ok={int(panels>400)} ink_ok={int(ink>60)} bars_ok={int(bars>10)}")
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
echo "==== checks ===="
fail=0
chk() { if grep -qaE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "sysmon: ready"                                   "monitor starts"
chk "sysmon: up=[0-9]+s agents=[2-9] share=[0-9]+% (working|parked) rx=" "telemetry line: uptime, agent roster (SYS_AGENTS), cpu share, rx"
chk "sysmon: quit"                                    "q quits"
chk "shell-lives"                                     "shell answers afterwards (keyboard released)"
chk "prime done = "                                   "the agents kept working underneath"
for k in top panels ink bars; do
  if echo "$RES" | grep -q "${k}_ok=1"; then echo "OK   : screendump $k"; else echo "FAIL : screendump $k"; fail=1; fi
done
[ "$fail" -eq 0 ] && { echo "==== SYSMON OK ===="; exit 0; }
echo "==== SYSMON FAILED ===="; sed 's/\r//g' "$LOG" | tail -30; exit 1
