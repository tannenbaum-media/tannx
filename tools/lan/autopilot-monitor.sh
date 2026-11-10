#!/usr/bin/env bash
# ============================================================
#  TannX OS autopilot monitor - mission control for the self-flying OS.
#  A live dashboard for the autopilot running on the netbooted test PC:
#  it shows the box's telemetry (STATUS on :4713 -> :4711) and the rounds
#  the autopilot has asked the LLM for (from llm-proxy.py's log), and
#  lets you stop a wedged loop with one key (AGENTOS-ABORT on :4713 -
#  the abort recovery, no reboot). The companion to the self-healing:
#  now you can WATCH the OS fly itself, and step in if you want.
#
#    ./autopilot-monitor.sh [bcast] [proxy-log]
#      bcast      default $AGENTOS_BCAST (the test PC's subnet broadcast)
#      proxy-log  default /tmp/llm-proxy.log
#
#  Keys:  a = abort the autopilot   r = reboot the test PC   q = quit
#  Needs a kernel built with REMOTE_CTL=1; trusted LAN only.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
BCAST="${1:-}"
[ -n "$BCAST" ] || { lan_need_bcast; BCAST="$AGENTOS_BCAST"; }
PLOG="${2:-/tmp/llm-proxy.log}"

exec python3 - "$BCAST" "$PLOG" "$REPO_ROOT" <<'PY'
import socket, sys, time, os, select, termios, tty, re

bcast, plog, repo = sys.argv[1], sys.argv[2], sys.argv[3]

def status(timeout=1.2):
    """Send STATUS to :4713, read the telemetry reply on :4711."""
    try:
        rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        rx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        rx.bind(("0.0.0.0", 4711)); rx.settimeout(timeout)
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for d in (bcast, "255.255.255.255"):
            try: tx.sendto(b"STATUS", (d, 4713))
            except OSError: pass
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = rx.recvfrom(2048)
            except socket.timeout:
                break
            t = data.decode("latin1", "replace")
            if t.startswith("AgentOS") and "STAT" in t:
                rx.close(); tx.close(); return t.strip()
        rx.close(); tx.close()
    except OSError:
        pass
    return None

def send(msg, n=3):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for d in (bcast, "255.255.255.255"):
        for _ in range(n):
            try: s.sendto(msg, (d, 4713))
            except OSError: pass
    s.close()

def rounds():
    """The autopilot rounds asked, newest last, from the proxy log."""
    if not os.path.exists(plog): return None
    out = []
    try:
        for ln in open(plog, "r", errors="replace"):
            m = re.search(r"autopilot:\s*'(.*)'", ln)
            if m: out.append(m.group(1))
    except OSError:
        return None
    return out

def library():
    """The autopilot's persisted memory: count + named tools (the JSONL
    library llm-proxy.py keeps next to itself in the repository root)."""
    lib = os.environ.get("LLM_LIBRARY", os.path.join(repo, "autopilot-library.jsonl"))
    n, tools = 0, []
    try:
        import json
        for ln in open(lib, "r", errors="replace"):
            ln = ln.strip()
            if not ln: continue
            n += 1
            try:
                nm = json.loads(ln).get("name")
                if nm and nm not in tools: tools.append(nm)
            except ValueError:
                pass
    except OSError:
        return None
    return n, tools

def draw(msg=""):
    st = status()
    rs = rounds()
    sys.stdout.write("\x1b[2J\x1b[H")     # clear + home
    print("\x1b[36m  TannX OS Autopilot Monitor\x1b[0m  " + bcast)
    print("  " + "-"*56)
    if st:
        up = re.search(r"up=(\d+)s", st); a = re.search(r"a=([0-9a-fA-F]+)", st)
        ver = re.search(r"(v[0-9.]+)", st); atp = re.search(r"atp=(\d+)", st)
        mis = re.search(r"mis=(.*)$", st)         # the autopilot mission (trailing)
        # atp = rounds the test PC itself confirms; cross-checks the proxy log
        print(f"  box: \x1b[32m{ver.group(1) if ver else '?'}\x1b[0m  "
              f"up {up.group(1) if up else '?'}s   agents={a.group(1) if a else '?'}"
              f"   atp={atp.group(1) if atp else '?'}")
        m = (mis.group(1).strip() if mis else "")
        if m:
            print(f"       mission: \x1b[33m{m[:60]}\x1b[0m")
    else:
        print("  box: \x1b[31msilent\x1b[0m (off? busy? wrong subnet?)")
    print()
    if rs is None:
        print(f"  (no proxy log at {plog} - start {repo}/llm-proxy.py --bind 0.0.0.0)")
    elif not rs:
        print("  autopilot: no rounds yet")
    else:
        print(f"  autopilot: \x1b[33m{len(rs)} rounds\x1b[0m asked (newest last)")
        for i, m in enumerate(rs[-7:], start=max(1, len(rs)-6)):
            print(f"    {i:>3}: {m[:64]}")
    lib = library()
    if lib is not None:
        n, tools = lib
        ts = ("  tools: " + ", ".join(tools[:6])) if tools else ""
        print(f"  memory: \x1b[36m{n} programs\x1b[0m kept across reboots{ts}")
    print()
    if msg: print("  " + msg)
    print("  " + "-"*56)
    print("  \x1b[2m[a]\x1b[0m abort autopilot   \x1b[2m[r]\x1b[0m reboot test PC   \x1b[2m[q]\x1b[0m quit")
    sys.stdout.flush()

if not sys.stdin.isatty():        # piped / no terminal: one snapshot and out
    draw(); sys.exit(0)

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
msg = ""
try:
    tty.setcbreak(fd)
    last = 0
    while True:
        if time.time() - last > 2.5:
            draw(msg); msg = ""; last = time.time()
        if select.select([sys.stdin], [], [], 0.3)[0]:
            k = sys.stdin.read(1)
            if k in ("q", "\x03"): break
            if k == "a": send(b"AGENTOS-ABORT"); msg = "\x1b[33m-> sent AGENTOS-ABORT (stop the loop)\x1b[0m"; last = 0
            if k == "r": send(b"AGENTOS-REBOOT"); msg = "\x1b[33m-> sent AGENTOS-REBOOT\x1b[0m"; last = 0
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    sys.stdout.write("\x1b[0m\n")
PY
