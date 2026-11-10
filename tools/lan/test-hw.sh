#!/usr/bin/env bash
# ============================================================
#  TannX OS hardware-in-the-loop test.
#  Drives the netbooted bare-metal test PC over UDP like a test
#  suite - it exercises the exact RTL8168 RX/TX + return-channel
#  path that QEMU CANNOT emulate (no 8168 there). This is the only
#  automated test for that path; run it against the real box.
#
#    ./test-hw.sh            # ship the current build, then test the PC
#    ./test-hw.sh --no-ship  # test the running PC as-is (no rebuild/reboot)
#    AGENTOS_BCAST=192.0.2.255 ./test-hw.sh
#
#  Needs the test PC powered and PXE-booting on a trusted LAN, and a
#  kernel built with REMOTE_CTL=1. NOT part of `make test-all` (that
#  stays QEMU-only / CI-able).
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
lan_need_bcast
BCAST="$AGENTOS_BCAST"
VER="$(grep '^nh_rep_pfx:' "$REPO_ROOT/agentos32.S" | grep -oE 'v[0-9]+\.[0-9]+')"

if [ "${1:-}" != "--no-ship" ]; then
  echo "[hw] shipping $VER to the test PC (build -> deploy -> reboot) ..."
  "$HERE/ship.sh" || { echo "[hw] ship failed - is the test PC up and PXE-booting?"; exit 1; }
  echo
fi

python3 - "$BCAST" "$VER" <<'PY'
import socket, sys, time, re
bcast, ver = sys.argv[1], sys.argv[2]

rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except OSError: pass
rx.bind(("", 4711)); rx.settimeout(0.5)
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

def query(req, needle, tries=6):
    for _ in range(tries):
        tx.sendto(req, (bcast, 4713))
        end = time.time() + 1.5
        while time.time() < end:
            try: data, _ = rx.recvfrom(2048)
            except socket.timeout: continue
            s = data.decode("ascii", "replace")
            if s.startswith("AgentOS") and needle in s:
                return s
    return None

fail = 0
def check(name, cond, detail=""):
    global fail
    print(("OK   : " if cond else "FAIL : ") + name + (("   " + detail) if detail else ""))
    if not cond: fail += 1

print("==== HW-in-the-loop checks (test PC over UDP) ====")
st = query(b"STATUS", "STAT")
check(f"test PC answers STATUS as {ver}", st is not None and ver in (st or ""), (st or "(no reply)").strip())

up = rxc = hit = None
if st:
    m = re.search(r"up=(\d+)s rx=([0-9a-fA-F]+) hit=([0-9a-fA-F]+)", st)
    if m: up, rxc, hit = int(m.group(1)), int(m.group(2), 16), int(m.group(3), 16)
check("fresh boot (uptime < 90s)", up is not None and up < 90, f"up={up}s")
check("RTL8168 RX is draining (rx>0)", rxc is not None and rxc > 0, f"rx={rxc}")

before = hit or 0
for i in range(20):
    tx.sendto(b"PING-HWTEST-%02d" % i, (bcast, 4713)); time.sleep(0.05)
time.sleep(2)
st2 = query(b"STATUS", "STAT")
hit2 = None
if st2:
    m = re.search(r"hit=([0-9a-fA-F]+)", st2)
    if m: hit2 = int(m.group(1), 16)
check("RX delivers our :4713 datagrams (hit climbs)",
      hit2 is not None and hit2 > before, f"{before} -> {hit2}")

dm = query(b"DMESG", "DMSG")
check("DMESG returns the kernel log", dm is not None and "boot" in (dm or ""),
      (dm or "").replace("\r\n", " | ")[:90])

rs = query(b"RESULTS", "RSLT")
check("RESULTS channel answers", rs is not None)

print()
if fail == 0:
    print("==== HW-IN-THE-LOOP: ALL TESTS PASSED ====")
    sys.exit(0)
print(f"==== HW-IN-THE-LOOP: {fail} TEST(S) FAILED ====")
sys.exit(1)
PY
