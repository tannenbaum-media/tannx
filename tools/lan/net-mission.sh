#!/usr/bin/env bash
# ============================================================
#  TannX OS remote MISSION. Broadcasts "MISSION <text>" to the
#  running OS on :4713, then listens on the normal return channel
#  (:4711) for the STATUS reply that confirms the new mission
#  telemetry. This is mission-control plumbing, not auth: it relies
#  on the trusted-LAN model documented in docs/ARCHITECTURE.md and
#  needs a kernel built with REMOTE_CTL=1.
#
#    ./net-mission.sh "new objective"          # default $AGENTOS_BCAST
#    ./net-mission.sh "new objective" 192.0.2.255
#
#  Kernel stores up to 47 ASCII bytes, same limit as SYS_SETMISSION.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
MISSION="${1:?usage: net-mission.sh \"<mission>\" [iface_bcast]}"
BCAST="${2:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
REQ=4713
REPLY=4711
python3 - "$MISSION" "$BCAST" "$REQ" "$REPLY" <<'PY2'
import socket, sys, time
mission, bcast, req, reply = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
wire = mission.encode("ascii", "replace")[:47]
if not wire:
    print("empty mission after ASCII conversion")
    sys.exit(2)
shown = wire.decode("ascii", "replace")
if shown != mission:
    print(f"mission will be stored as: {shown!r}")

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
payload = b"MISSION " + wire
for _ in range(3):
    tx.sendto(payload, (bcast, req))
print(f"sent MISSION to {bcast}:{req}, listening on :{reply} ...")

needle = "mis=" + shown
deadline = time.time() + 4
last_stat = None
while time.time() < deadline:
    try:
        data, addr = rx.recvfrom(2048)
    except socket.timeout:
        continue
    txt = data.decode("ascii", "replace")
    if txt.startswith("AgentOS") and "STAT" in txt:
        last_stat = f"  <- {addr[0]}: {txt}"
        print(last_stat)
        if needle in txt:
            sys.exit(0)

if last_stat:
    print(f"STATUS reply did not confirm {needle!r}")
else:
    print("no reply (is the PC up on this LAN? RX/TX needs the remote return channel)")
sys.exit(1)
PY2
