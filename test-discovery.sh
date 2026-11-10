#!/usr/bin/env bash
# ============================================================
#  Proxy discovery test. On a real LAN TannX OS has no idea what
#  IP the host / llm-proxy.py is on, so 'llm' broadcasts
#  "AGENTOS-PROXY?" and adopts the IP+MAC of whoever answers
#  "AGENTOS-PROXY!". Headless via the L2 tap: serial triggers 'llm',
#  we watch the guest's PROXY? broadcast, inject a PROXY! reply from a
#  chosen IP, and confirm the guest reports "llm: proxy at <that IP>".
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

exec python3 - <<'PY'
import subprocess, time, tempfile, shutil, os, sys
sys.path.insert(0, ".")
from l2tap import L2, parse_udp, build_udp_bcast

L_PORT, H_PORT = 24121, 24120
PROXY_IP = "192.0.2.77"          # RFC 5737 test address
img = tempfile.mktemp(suffix=".img"); shutil.copy("agentos32.img", img)
fifo = tempfile.mktemp(); os.mkfifo(fifo)
tap = L2(H_PORT, L_PORT)
log = "/tmp/test_discovery.log"
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
send("llm hi")

saw = False
deadline = time.time() + 12
while time.time() < deadline and not saw:
    f = tap.recv_frame()
    if not f:
        continue
    u = parse_udp(f)
    if u and u[2].startswith(b"AGENTOS-PROXY?"):
        saw = True
        tap.inject(build_udp_bcast(b"AGENTOS-PROXY!", 0x0ff0, sport=0x0ff0, src_ip=PROXY_IP))
time.sleep(2)
q.kill(); q.wait()
out = open(log).read().replace("\r", "")
tap.close(); w.close(); os.remove(img); os.remove(fifo)

print("==== discovery console ====")
for l in out.splitlines():
    if "proxy" in l.lower() or "llm:" in l.lower():
        print("  " + l)
print("==== checks ====")
fail = 0
def chk(c, m):
    global fail
    print(("OK   : " if c else "FAIL : ") + m); fail = fail or (0 if c else 1)

chk(saw, "guest broadcasts AGENTOS-PROXY? when llm starts")
chk(f"proxy at {PROXY_IP}" in out, f"guest adopts the answering proxy ({PROXY_IP})")
print("==== DISCOVERY OK ====" if not fail else "==== DISCOVERY FAILED ====")
sys.exit(1 if fail else 0)
PY
