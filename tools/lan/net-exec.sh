#!/usr/bin/env bash
# ============================================================
#  net-exec.sh - run ANY shell command on a live TannX OS over UDP and
#  print its console output here (so an LLM session can drive the test
#  PC's tests itself). Kernel side: "EXEC <cmd>" on :4713 stages the command
#  through the ';' chain machinery; the captured console output is
#  broadcast back to :4711 (same return channel as STATUS) as
#  "AGENTOS-OUT <text>" chunks followed by "AGENTOS-END".
#
#  Usage: ./net-exec.sh "<command[; command...]>" [waitsecs] [bcast]
#         ./net-exec.sh "smpon"
#         ./net-exec.sh "spawn prime; task prime 100; sleep 45; tasks" 12
#  bcast defaults to $AGENTOS_BCAST (see lan-env.sh). Needs a kernel built
#  with REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
CMD="${1:?usage: net-exec.sh \"<command>\" [waitsecs] [bcast-addr]}"
WAIT="${2:-12}"
BCAST="${3:-${AGENTOS_BCAST:-}}"

exec python3 - "$CMD" "$WAIT" "$BCAST" <<'PY'
import socket, sys, time
cmd, wait, bcast = sys.argv[1], float(sys.argv[2]), sys.argv[3]

# listen for the reply on :4711 (the kernel broadcasts OUT there, like STATUS)
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
rx.bind(("0.0.0.0", 4711))
rx.settimeout(0.5)

tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
# the LAN's directed broadcast first (reaches the test PC's subnet
# reliably), then the limited broadcast as a fallback
dests = [bcast] if bcast else []
dests.append("255.255.255.255")
payload = ("EXEC " + cmd).encode("ascii", "replace")
for d in dests:
    for _ in range(2):
        try: tx.sendto(payload, (d, 4713))
        except OSError: pass

deadline = time.time() + wait
got = False
while time.time() < deadline:
    try:
        d, a = rx.recvfrom(2048)
    except socket.timeout:
        continue
    if d.startswith(b"AGENTOS-END"):
        got = True
        break
    if d.startswith(b"AGENTOS-OUT "):
        got = True
        sys.stdout.write(d[12:].decode("ascii", "replace"))
        sys.stdout.flush()
sys.exit(0 if got else 1)
PY
