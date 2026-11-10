#!/usr/bin/env bash
# ============================================================
#  Remote EHCI/USB enumeration trigger. Sends "EHCITEST"+<ctrl><port>
#  to the test PC on :4713; it runs ehci_run from its idle loop and
#  BROADCASTS the result (ehci-dn / usb-hid / ehci-dbg lines) to :4711.
#  We listen and print whatever comes back - no keyboard at the test PC.
#    ./net-ehcitest.sh <ctrl> <port> [bcast]   # bcast default $AGENTOS_BCAST
#  e.g. ./net-ehcitest.sh 1 6        # controller 1, downstream port 6
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
CTRL="${1:-0}"; PORT="${2:-0}"; BCAST="${3:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
echo "[ehcitest] trigger ctrl=$CTRL port=$PORT on $BCAST:4713, listening on :4711 (32s)"
python3 -c "
import socket,sys,time
ctrl,port=int('$CTRL'),int('$PORT')
r=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
r.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
r.bind(('',4711)); r.settimeout(32)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
pkt=b'EHCITEST'+bytes([ctrl,port])
for _ in range(3): s.sendto(pkt,('$BCAST',4713))
t=time.time(); seen=set()
while time.time()-t<32:
    try:
        d,a=r.recvfrom(2048); txt=d.decode('latin1','replace').strip()
        if ('ehci' in txt or 'usb' in txt) and txt not in seen:
            seen.add(txt); print('  <-',txt)
    except socket.timeout: break
if not seen: print('  (nothing - box may have wedged before broadcasting)')
"
