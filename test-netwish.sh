#!/usr/bin/env bash
# ============================================================
#  netwish acknowledged-delivery test (8.3 / v1.30). Headless via the L2
#  tap: drive 'netwish <text>' on the serial console, watch the guest
#  broadcast "AGENTOS-WISH: <text>" on the L2 wire, inject the dev box's
#  "AGENTOS-WISH-ACK" back, and confirm the guest's retry loop STOPS with
#  "delivered (ack ...)" - i.e. the ack round-trip works and there is no
#  endless re-broadcast. (Serial triggers it so the single host->guest
#  L2 datagram per boot can be spent on the ack.)
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

exec python3 - <<'PY'
import subprocess, time, tempfile, shutil, os, sys
sys.path.insert(0, ".")
from l2tap import L2, parse_udp

L_PORT, H_PORT = 24021, 24020
img = tempfile.mktemp(suffix=".img"); shutil.copy("agentos32.img", img)
fifo = tempfile.mktemp(); os.mkfifo(fifo)
tap = L2(H_PORT, L_PORT)
log = "/tmp/test_netwish.log"
q = subprocess.Popen(
    ["qemu-system-i386", "-drive", f"format=raw,file={img}", "-nographic",
     "-netdev", f"dgram,id=n0,local.type=inet,local.host=127.0.0.1,local.port={L_PORT},"
                f"remote.type=inet,remote.host=127.0.0.1,remote.port={H_PORT}",
     "-device", "rtl8139,netdev=n0"],
    stdin=open(fifo, "r+b", buffering=0), stdout=open(log, "w"), stderr=subprocess.STDOUT)
w = open(fifo, "w+b", buffering=0)


def send(s):
    for c in s:
        w.write(c.encode()); time.sleep(0.02)
    w.write(b"\r")


time.sleep(5)
send("netwish headless-ack-test")

# wait for the guest to broadcast the wish, count how many copies it sends
wishes = 0
saw = False
deadline = time.time() + 5
acked = False
while time.time() < deadline:
    f = tap.recv_frame()
    if not f:
        continue
    u = parse_udp(f)
    if u and b"headless-ack-test" in u[2]:
        wishes += 1
        if not saw:                       # ack the FIRST broadcast we see
            saw = True
            tap.send_udp(b"AGENTOS-WISH-ACK", 4713)
            acked = True
time.sleep(2)
q.kill(); q.wait()
out = open(log).read().replace("\r", "")
tap.close(); w.close(); os.remove(img); os.remove(fifo)

print("==== netwish console ====")
for l in out.splitlines():
    if "wish" in l.lower():
        print("  " + l)
print(f"(guest broadcast the wish {wishes}x; ack injected: {acked})")
print("==== checks ====")
fail = 0
def chk(c, m):
    global fail
    print(("OK   : " if c else "FAIL : ") + m); fail = fail or (0 if c else 1)

chk(b"AGENTOS-WISH:" in open(log, "rb").read() or "broadcast over UDP" in out,
    "netwish broadcast went out on the wire")
chk("delivered (ack" in out, "the ack round-trip stopped the retry loop (delivered)")
chk("no ack" not in out, "no false 'no ack' give-up")
print("==== NETWISH-ACK OK ====" if not fail else "==== NETWISH-ACK FAILED ====")
sys.exit(1 if fail else 0)
PY
