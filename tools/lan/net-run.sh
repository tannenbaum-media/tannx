#!/usr/bin/env bash
# ============================================================
#  TannX OS remote 'run'. Sends "RUNPROG" to the test PC on :4713;
#  the OS launches the ring-3 C userspace program from its idle
#  loop (same path as the shell 'run' command) - no keyboard
#  needed. Use this to start the program on the network-booted
#  test PC and watch it on its screen.
#
#  The program prints "[video] ..." over COM1; if you have the
#  serial bridge attached (./wish-bridge.sh) you'll see those
#  lines. On the framebuffer: the rectangle demo on a diskless
#  PXE boot, or the decoded video if a clip is on a disk.
#
#    ./net-run.sh            # launch the program on the test PC
#    ./net-run.sh [bcast]    # default $AGENTOS_BCAST (lan-env.sh)
#  Stop it again with a remote reboot, or 'kill <n>' at the test PC.
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
BCAST="${1:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
echo "[run] triggering RUNPROG on $BCAST:4713 ..."
python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
for _ in range(3): s.sendto(b'RUNPROG',('$BCAST',4713))
"
echo "[run] sent. The ring-3 program should start on the test PC (look at its screen)."
echo "[run] STATUS to confirm the box is alive:"
sleep 1
"$HERE/net-status.sh" "$BCAST" 2>/dev/null || true
