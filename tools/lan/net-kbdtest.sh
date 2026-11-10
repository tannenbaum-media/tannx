#!/usr/bin/env bash
# ============================================================
#  USB keyboard echo debug. Arms the test PC's keyboard QH
#  (EHCITEST ctrl=1 port=2), then LISTENS on :4711 for a long
#  window while you type at the test PC. Prints the keyboard diag:
#    usb-kbd:  <raw report>  p=<kbd_pushes>  ht=<head>/<tail>
#    usb-key a=<ascii>  ht=<head>/<tail>        (translated key)
#  Tells us in one window whether translation + push_key fire.
#    ./net-kbdtest.sh [seconds] [ctrl] [port] [bcast]   # bcast default $AGENTOS_BCAST
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
SECS="${1:-75}"; CTRL="${2:-1}"; PORT="${3:-2}"; BCAST="${4:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
echo "[kbdtest] arming kbd QH ctrl=$CTRL port=$PORT on $BCAST:4713; listening :4711 for ${SECS}s"
echo "[kbdtest] >>> when you see 'usb-kbd-ep' come back, TYPE on the test PC keyboard <<<"
python3 -c "
import socket,sys,time
ctrl,port,secs=int('$CTRL'),int('$PORT'),int('$SECS')
r=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
r.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
r.bind(('',4711)); r.settimeout(1.0)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
pkt=b'EHCITEST'+bytes([ctrl,port])
for _ in range(3): s.sendto(pkt,('$BCAST',4713))
t=time.time(); n=0
while time.time()-t<secs:
    try:
        d,a=r.recvfrom(2048); txt=d.decode('latin1','replace').rstrip()
        if 'usb' in txt or 'ehci' in txt:
            n+=1; print('  <-',txt,flush=True)
    except socket.timeout: continue
print(f'[kbdtest] done, {n} lines')
"
