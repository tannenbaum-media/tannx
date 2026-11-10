#!/usr/bin/env bash
# ============================================================
#  TannX OS remote dmesg - read the kernel log over
#  the wire. Sends "DMESG" to the OS on :4713; the OS broadcasts
#  the most recent ~200 bytes of its event log back to :4711.
#  (The full log stays on the serial/screen `dmesg` command.)
#
#    ./net-dmesg.sh                 # ask the netbooted PC for its log
#    ./net-dmesg.sh [iface_bcast]   # default $AGENTOS_BCAST (lan-env.sh)
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
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
    tx.sendto(b"DMESG", (bcast, 4713))
print(f"asked {bcast}:4713 for DMESG, listening on :4711 ...")
deadline = time.time() + 4
while time.time() < deadline:
    try:
        data, addr = rx.recvfrom(2048)
    except socket.timeout:
        continue
    txt = data.decode("ascii", "replace")
    if txt.startswith("AgentOS") and "DMSG" in txt:
        print(f"--- {addr[0]} kernel log ---")
        print(txt.split("DMSG", 1)[1].lstrip("\r\n"))
        sys.exit(0)
print("no reply (PC not up / TX down)")
sys.exit(1)
PY
