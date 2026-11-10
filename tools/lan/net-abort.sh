#!/usr/bin/env bash
# ============================================================
#  TannX OS remote ABORT (autopilot self-healing).
#  Broadcasts "AGENTOS-ABORT" to the running OS on :4713. The kernel's
#  do_wait / sh_chain check the flag and break out of a wedged chain,
#  'wait' or autopilot loop - killing the stuck program and dropping the
#  chain WITHOUT a reboot. This is the recovery that needed a power-cycle
#  in the field when a model-written program never exited under 'wait'.
#
#    ./net-abort.sh                 # stop a wedged autopilot/chain on the test PC
#    ./net-abort.sh 192.0.2.255     # custom directed broadcast (default $AGENTOS_BCAST)
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
BCAST="${1:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
PORT=4713
python3 - "$PORT" "$BCAST" <<'PY'
import socket, sys
port, bcast = int(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for dst in (bcast, "255.255.255.255"):
    for _ in range(3):
        s.sendto(b"AGENTOS-ABORT", (dst, port))
    print(f"sent 'AGENTOS-ABORT' to {dst}:{port} (x3)")
PY
