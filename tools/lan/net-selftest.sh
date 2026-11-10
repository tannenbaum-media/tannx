#!/usr/bin/env bash
# ============================================================
#  TannX OS remote self-test. Sends "SELFTEST" to the test PC on
#  :4713; the OS runs a CPU benchmark + a RAM test from its
#  idle loop and logs the results to dmesg. We wait, then pull
#  the kernel log (net-dmesg) and show the cpu-bench / ram-test
#  lines. Full self-debugging of the hardware tests over the wire.
#
#    ./net-selftest.sh            # run + read the test PC's results
#    ./net-selftest.sh [bcast]    # default $AGENTOS_BCAST (lan-env.sh)
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
BCAST="${1:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
echo "[selftest] triggering SELFTEST on $BCAST:4713 ..."
python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
for _ in range(3): s.sendto(b'SELFTEST',('$BCAST',4713))
"
echo "[selftest] running (CPU + RAM)... waiting ~8s, then reading dmesg"
sleep 8
"$HERE/net-dmesg.sh" "$BCAST"
