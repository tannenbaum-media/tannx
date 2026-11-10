#!/usr/bin/env bash
# ============================================================
#  TannX OS remote control (return channel).
#  Broadcasts a UDP command to the running OS on the LAN. The OS
#  has no IP, so we broadcast on :4713 - net_poll picks it up
#  regardless of address.
#
#    ./net-reboot.sh                       # reboot the netbooted PC
#    ./net-reboot.sh "any text"            # drop text into its 'inbox'
#    ./net-reboot.sh AGENTOS-REBOOT 10.0.0.255   # custom directed bcast
#
#  We send to the DIRECTED broadcast of the PC's subnet (default
#  $AGENTOS_BCAST, see lan-env.sh - the address that actually reaches
#  the test PC) AND to 255.255.255.255. The limited broadcast alone
#  can leave on the wrong interface on a multi-NIC host, so it is
#  only a fallback.
#
#  With PXE network-boot-first, the reboot makes the PC pull the
#  latest build - a hands-off update loop. Needs a kernel built with
#  REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
MSG="${1:-AGENTOS-REBOOT}"
BCAST="${2:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
PORT=4713
python3 - "$MSG" "$PORT" "$BCAST" <<'PY'
import socket, sys
msg, port, bcast = sys.argv[1].encode(), int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
# the directed broadcast first (reaches the PC's subnet reliably),
# then the limited broadcast as a fallback - UDP is lossy and the
# OS polls ~1x/sec, so send each a few times.
for dst in (bcast, "255.255.255.255"):
    for _ in range(3):
        s.sendto(msg, (dst, port))
    print(f"sent '{msg.decode()}' to {dst}:{port} (x3)")
PY
