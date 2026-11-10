#!/usr/bin/env bash
# ============================================================
#  Remote abort test (autopilot self-healing). A model-written program
#  that never exits under 'wait' wedged the autopilot in the field and
#  needed a power-cycle. Now "AGENTOS-ABORT" on :4713 breaks do_wait/
#  sh_chain out of it - killing the stuck program and dropping the chain,
#  no reboot. Headless via the L2 tap: we wedge the box with `gui; wait`
#  (the compositor never exits), inject AGENTOS-ABORT, and confirm the
#  shell comes back (the abort message + a command answers afterwards).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32-dev.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

exec python3 - <<'PY'
import subprocess, time, tempfile, shutil, os, sys
sys.path.insert(0, ".")
from l2tap import L2, build_udp_bcast

L_PORT, H_PORT = 24131, 24130
img = tempfile.mktemp(suffix=".img"); shutil.copy("agentos32-dev.img", img)
fifo = tempfile.mktemp(); os.mkfifo(fifo)
tap = L2(H_PORT, L_PORT)
log = "/tmp/test_abort.log"
q = subprocess.Popen(
    ["qemu-system-i386", "-drive", f"format=raw,file={img}", "-vga", "std", "-nographic",
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
send("gui")                 # launch the compositor (a ring-3 program, never exits)
time.sleep(2)
send("wait")                # blocks forever on it - this is the wedge
time.sleep(2)
send("echo recovered-after-abort")   # queued; only runs once the wait aborts
time.sleep(1)
# inject AGENTOS-ABORT to :4713 (the L2 tap delivers the first guest-bound datagram)
tap.inject(build_udp_bcast(b"AGENTOS-ABORT", 4713, sport=4713, src_ip="192.0.2.77"))
time.sleep(4)
q.kill(); q.wait()
out = open(log).read().replace("\r", "")
tap.close(); w.close(); os.remove(img); os.remove(fifo)

print("==== abort console (tail) ====")
for l in out.splitlines()[-12:]:
    print("  " + l)
print("==== checks ====")
fail = 0
def chk(c, m):
    global fail
    print(("OK   : " if c else "FAIL : ") + m); fail = fail or (0 if c else 1)

chk("remote abort" in out, "AGENTOS-ABORT breaks 'wait' out of the stuck program")
chk("recovered-after-abort" in out, "the shell answers again - no reboot needed")
print("==== ABORT OK ====" if not fail else "==== ABORT FAILED ====")
sys.exit(1 if fail else 0)
PY
