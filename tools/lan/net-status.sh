#!/usr/bin/env bash
# ============================================================
#  TannX OS return channel - query the running OS
#  over the wire and print its reply. No more photographing the
#  screen: we send "STATUS" to :4713, the OS broadcasts a
#  telemetry line back to :4711, and we show it.
#
#    ./net-status.sh                 # ask the netbooted PC for status
#    ./net-status.sh [iface_bcast]   # default $AGENTOS_BCAST (lan-env.sh)
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
#
#  The OS polls RX ~1x/sec, so the reply lands within ~1-2 s.
#  Reply format: "AgentOS/32 vX.Y STAT up=<sec>s rx=<hex> hit=<hex> in=<hex>"
#    up  = uptime seconds        rx  = frames the RX ring delivered
#    hit = datagrams to :4713    in  = inbox has an unread message (01)
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
BCAST="${1:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
REQ=4713
REPLY=4711
python3 - "$BCAST" "$REQ" "$REPLY" <<'PY'
import socket, sys, time
bcast, req, reply = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])

# bind the listener FIRST so we don't miss a fast reply
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except OSError:
    pass
rx.bind(("", reply))
rx.settimeout(0.5)

tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):                       # UDP is lossy; ask a few times
    tx.sendto(b"STATUS", (bcast, req))
print(f"asked {bcast}:{req} for STATUS, listening on :{reply} ...")

deadline = time.time() + 4
while time.time() < deadline:
    try:
        data, addr = rx.recvfrom(2048)
    except socket.timeout:
        continue
    txt = data.decode("ascii", "replace")
    if "STAT" in txt and txt.startswith("AgentOS"):
        print(f"  <- {addr[0]}: {txt}")
        sys.exit(0)
print("no reply (is the PC up on this LAN? is the kernel built with REMOTE_CTL=1?)")
sys.exit(1)
PY
