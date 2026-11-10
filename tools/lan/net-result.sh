#!/usr/bin/env bash
# ============================================================
#  TannX OS result channel - pull agent results
#  over the wire. Sends "RESULTS" to the OS on :4713; the OS
#  broadcasts every finished/errored task's result back to
#  :4711. (The OS ALSO auto-pushes a "DONE ..." line to :4711
#  the moment an agent finishes - run ./wishd.sh-style listen,
#  or just this, to see them.)
#
#    ./net-result.sh                 # ask the netbooted PC for results
#    ./net-result.sh [iface_bcast]   # default $AGENTOS_BCAST (lan-env.sh)
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
#
#  Reply: "AgentOS/32 v1.x RSLT t<i>=<dec> ..."   (t<i>=ERR on fault)
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
BCAST="${1:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
python3 - "$BCAST" <<'PY'
import socket, sys, time
bcast = sys.argv[1]
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except OSError: pass
rx.bind(("", 4711))
rx.settimeout(0.5)
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(3):
    tx.sendto(b"RESULTS", (bcast, 4713))
print(f"asked {bcast}:4713 for RESULTS, listening on :4711 ...")
deadline = time.time() + 4
while time.time() < deadline:
    try:
        data, addr = rx.recvfrom(2048)
    except socket.timeout:
        continue
    txt = data.decode("ascii", "replace")
    if txt.startswith("AgentOS") and ("RSLT" in txt or "DONE" in txt):
        print(f"  <- {addr[0]}: {txt}")
        sys.exit(0)
print("no reply (no finished tasks yet, or PC not up / TX down)")
sys.exit(1)
PY
