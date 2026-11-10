#!/usr/bin/env bash
# ============================================================
#  Remote-exec test - headless via the L2 tap.
#  l2tap.py + QEMU '-netdev dgram' give a raw-Ethernet link to the guest
#  NIC, so we inject an "EXEC <cmd>" frame and read back the guest's
#  "AGENTOS-OUT"/"AGENTOS-END" broadcast reply - the SAME return channel
#  the bare-metal test PC speaks, no real LAN needed. (QEMU's UDP netdev only delivers
#  the first host->guest datagram per boot, so the test packs everything
#  into ONE ';'-chained EXEC - which is exactly how a real test run is
#  driven anyway.)
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32-dev.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

exec python3 - <<'PY'
import subprocess, time, tempfile, shutil, os, sys
sys.path.insert(0, ".")
from l2tap import L2, parse_udp

PORTS = [(23981, 23980), (23983, 23982), (23985, 23984), (23987, 23986)]


def run_exec(cmd, extra_dev, wait):
    """Boot QEMU (one fresh boot - the dgram netdev delivers only the
    first host->guest datagram), inject ONE EXEC, return its OUT text +
    whether AGENTOS-END arrived."""
    L_PORT, H_PORT = PORTS.pop(0)
    img = tempfile.mktemp(suffix=".img"); shutil.copy("agentos32-dev.img", img)
    tap = L2(H_PORT, L_PORT)
    args = ["qemu-system-i386", "-drive", f"format=raw,file={img}", "-nographic"] + extra_dev + [
        "-netdev", f"dgram,id=n0,local.type=inet,local.host=127.0.0.1,local.port={L_PORT},"
                   f"remote.type=inet,remote.host=127.0.0.1,remote.port={H_PORT}",
        "-device", "rtl8139,netdev=n0"]
    q = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                         stdout=open("/tmp/test_remote.log", "w"), stderr=subprocess.STDOUT)
    time.sleep(6)
    out, done = [], False
    for _ in range(3):
        tap.send_udp(b"EXEC " + cmd, 4713); time.sleep(0.1)
    deadline = time.time() + wait
    while time.time() < deadline and not done:
        f = tap.recv_frame()
        if not f:
            continue
        u = parse_udp(f)
        if not u:
            continue
        if u[2].startswith(b"AGENTOS-END"):
            done = True
        elif u[2].startswith(b"AGENTOS-OUT "):
            out.append(u[2][12:])
    q.kill(); q.wait(); tap.close(); os.remove(img)
    return b"".join(out), done


def status_probe(payload=b"STATUS"):
    """A fresh boot whose ONE host->guest datagram is a telemetry request
    (the dgram netdev delivers only the first), so we read back the STATUS line."""
    L_PORT, H_PORT = PORTS.pop(0)
    img = tempfile.mktemp(suffix=".img"); shutil.copy("agentos32-dev.img", img)
    tap = L2(H_PORT, L_PORT)
    args = ["qemu-system-i386", "-drive", f"format=raw,file={img}", "-nographic",
        "-netdev", f"dgram,id=n0,local.type=inet,local.host=127.0.0.1,local.port={L_PORT},"
                   f"remote.type=inet,remote.host=127.0.0.1,remote.port={H_PORT}",
        "-device", "rtl8139,netdev=n0"]
    q = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                         stdout=open("/tmp/test_remote_st.log", "w"), stderr=subprocess.STDOUT)
    time.sleep(6)
    status = b""
    for _ in range(3):
        tap.send_udp(payload, 4713); time.sleep(0.1)
    deadline = time.time() + 6
    while time.time() < deadline and not status:
        f = tap.recv_frame()
        if not f:
            continue
        u = parse_udp(f)
        if u and u[2].startswith(b"AgentOS/32") and b"up=" in u[2]:
            status = u[2]
    q.kill(); q.wait(); tap.close(); os.remove(img)
    return status


fail = 0
def chk(cond, label):
    global fail
    print(("OK   : " if cond else "FAIL : ") + label)
    if not cond:
        fail = 1

# 1) a synchronous chain: echoes + an agent pipeline
o, done = run_exec(b"echo REMOTE-OK; spawn prime; task prime 100; sleep 45; tasks; echo CHAIN-END", [], 14)
print("==== chain output ====\n" + o.decode("ascii", "replace").strip() + "\n==== checks ====")
chk(done, "the EXEC reply terminated with AGENTOS-END")
chk(b"REMOTE-OK" in o, "echo output round-trips over the L2 wire")
chk(b"= 541" in o, "agent pipeline ran (prime 100 = 541) and streamed back")
chk(b"CHAIN-END" in o, "the whole ';' chain ran to its last statement")

# 1b) the STATUS telemetry line carries the autopilot round counter
status = status_probe()
print("==== STATUS line ====\n" + status.decode("ascii", "replace").strip())
chk(b"atp=" in status, "STATUS exposes the autopilot round counter (telemetry)")

mission_status = status_probe(b"MISSION wire mission")
print("==== MISSION line ====\n" + mission_status.decode("ascii", "replace").strip())
chk(b"mis=wire mission" in mission_status, "MISSION updates the remote STATUS mission field")

# 2) a BACKGROUND ring-3 program (hda): its output comes after the chain
#    ends - the capture must hold until the program exits (prog-exit flush).
o, done = run_exec(b"hda", ["-audiodev", "none,id=ad0", "-device", "intel-hda",
                            "-device", "hda-output,audiodev=ad0"], 16)
print("==== hda-over-exec output ====\n" + o.decode("ascii", "replace").strip() + "\n==== checks ====")
chk(b"codec" in o and b"HDA: done" in o,
    "background prog (hda) output is captured and returned over the wire")

print("==== REMOTE-EXEC OK ====" if fail == 0 else "==== REMOTE-EXEC FAILED ====")
sys.exit(fail)
PY
