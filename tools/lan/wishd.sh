#!/usr/bin/env bash
# ============================================================
#  TannX OS wish daemon - the LAN end of the wire.
#  Listens for the UDP broadcasts the kernel's 'netwish' sends
#  (255.255.255.255:4711, payload "AGENTOS-WISH: <text>") and
#  appends each new wish to the queue the LLM reads.
#
#  Usage: ./wishd.sh                 listen forever (Ctrl-C quits)
#         AGENTOS_PORT=4711 ./wishd.sh
#         AGENTOS_BCAST=192.0.2.255 ./wishd.sh   # LAN broadcast for the acks
#         AGENTOS_WISH_QUEUE=/path/wish-queue.txt ./wishd.sh
#
#  Counterpart to wish-bridge.sh (serial). Same queue file, so
#  'make wishes' / the LLM sees wishes no matter which wire they
#  arrived on - serial cable or network. Trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
PORT="${AGENTOS_PORT:-4711}"
QUEUE="${AGENTOS_WISH_QUEUE:-wish-queue.txt}"

echo "wishd listening on UDP :$PORT - Ctrl-C to stop. Queue: $QUEUE"

exec python3 - "$PORT" "$QUEUE" "${AGENTOS_BCAST:-}" <<'PY'
import socket, sys, os
port, queue, lan_bcast = int(sys.argv[1]), sys.argv[2], sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
except OSError:
    pass
s.bind(("", port))
prefix = "AGENTOS-WISH: "

# ACK socket: the OS broadcasts wishes blind and retries until it hears
# back, so confirm every wish we receive on the OS's listen port (:4713).
# The OS has no IP -> we must broadcast the ack. 255.255.255.255 can pick
# the wrong NIC on a multi-homed box, so also hit the LAN's directed
# broadcast (AGENTOS_BCAST, derived from the default route if unset).
ackport = 4713
ack = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ack.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
acktargets = {"255.255.255.255"}
if lan_bcast:
    acktargets.add(lan_bcast)
def send_ack():
    for b in acktargets:
        try: ack.sendto(b"AGENTOS-WISH-ACK", (b, ackport))
        except OSError: pass

while True:
    data, addr = s.recvfrom(2048)
    try:
        msg = data.decode("ascii", "replace").rstrip("\x00").strip()
    except Exception:
        continue
    if not msg.startswith(prefix):
        continue
    text = msg[len(prefix):].strip()
    if not text:
        continue
    send_ack()                       # tell the OS we got it (stops its retries)
    seen = set()
    if os.path.exists(queue):
        with open(queue) as f:
            seen = {l.strip() for l in f}
    if text not in seen:
        with open(queue, "a") as f:
            f.write(text + "\n")
        print(f"[wishd] + {text}   (from {addr[0]}, acked)", flush=True)
    else:
        print(f"[wishd] (dup) {text}   (acked)", flush=True)
PY
