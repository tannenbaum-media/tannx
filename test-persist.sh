#!/usr/bin/env bash
# ============================================================
#  Autopilot persistence test. A diskless (PXE-booted) PC loses its
#  RAM-backed AgentFS slots on every reboot, so the LLM-written software
#  evaporates. The llm-proxy is the OS's long-term memory: it archives
#  every autopilot script it generates to a library file, and when a fresh
#  session starts (a long gap = a reboot) it re-seeds the system prompt
#  from that library so the loop builds ON its past work.
#
#  This is a HOST-side test (no QEMU): drive the proxy's /script endpoint
#  directly, kill+restart it to simulate a reboot, and prove the library
#  grew + the second session re-seeded from it. Uses --mock (no API key).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }

PORT=4096
LIB="$(mktemp -u --suffix=.jsonl)"
LOGA="$(mktemp)"; LOGB="$(mktemp)"
rm -f "$LIB"

post() {  # POST a /script body to the proxy, discard the reply
  python3 - "$1" <<'PY'
import urllib.request, sys
try:
    urllib.request.urlopen(
        urllib.request.Request("http://127.0.0.1:4096/script", data=sys.argv[1].encode()),
        timeout=5).read()
except Exception as e:
    print("post error:", e, file=sys.stderr)
PY
}
postr() {  # POST and PRINT the reply (for the re-run check)
  python3 - "$1" <<'PY'
import urllib.request, sys
try:
    print(urllib.request.urlopen(
        urllib.request.Request("http://127.0.0.1:4096/script", data=sys.argv[1].encode()),
        timeout=5).read().decode("utf-8","replace"))
except Exception as e:
    print("post error:", e, file=sys.stderr)
PY
}

# --- session 1: a fresh box flies a few autopilot rounds -------------
#   The --mock backend returns one canned script every round, so to a fresh
#   proxy these 3 rounds look identical; the stall breaker would fire on
#   the 3rd. Persistence and the breaker are orthogonal - disable the breaker
#   here (LLM_STALL_LIMIT high) so this test stays about archiving + re-seed.
#   The breaker has its own test (test-stall.sh).
LLM_STALL_LIMIT=99 LLM_SESSION_GAP=120 python3 ./llm-proxy.py --mock --port "$PORT" --library "$LIB" >"$LOGA" 2>&1 &
PA=$!
sleep 1.2
post "autopilot tool:adder build an adder tool"
post "autopilot count the primes under 50"
post "autopilot play a short melody"
sleep 0.4
kill "$PA" 2>/dev/null; wait "$PA" 2>/dev/null

ENTRIES=$(grep -c . "$LIB" 2>/dev/null || echo 0)

# --- session 2: the box "reboots" - a fresh proxy with the SAME library.
#     Its first autopilot request must re-seed from the 3 archived programs.
python3 ./llm-proxy.py --mock --port "$PORT" --library "$LIB" >"$LOGB" 2>&1 &
PB=$!
sleep 1.2
post "autopilot continue exploring"
# the autopilot RE-RUNS a tool it built earlier (executable library)
RERUN="$(postr "autopilot rerun:adder")"
sleep 0.4
kill "$PB" 2>/dev/null; wait "$PB" 2>/dev/null

echo "==== autopilot persistence checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

{ [ "$ENTRIES" -ge 3 ] 2>/dev/null && a=1 || a=0; }
chk "$a" "session 1 archived every autopilot program ($ENTRIES in the library)"

grep -q '"name": "adder"' "$LIB" && b=1 || b=0
chk "$b" "a 'tool:<name>' mission files the program under that name"

grep -q '"mission": "count the primes under 50"' "$LIB" && c=1 || c=0
chk "$c" "the mission text is recorded with the program"

grep -q "autopilot memory:.*3 programs" "$LOGB" && d=1 || d=0
chk "$d" "session 2 proxy loads the persisted library at startup"

grep -q "NEW SESSION - seeded from 3 memories" "$LOGB" && e=1 || e=0
chk "$e" "session 2 re-seeds the loop from memory (builds on past work)"

grep -q "tools: \['adder'\]" "$LOGB" && f=1 || f=0
chk "$f" "the named tool is carried into the new session's seed"

grep -q "RE-RUN saved tool 'adder'" "$LOGB" && g=1 || g=0
chk "$g" "'rerun:<name>' executes a saved tool from the library (not the LLM)"

# the re-run reply must be a runnable script that keeps the loop alive
RR="$(printf '%s' "$RERUN" | tr -d '\r')"
{ echo "$RR" | grep -q "spawn count" && echo "$RR" | grep -q "script 7"; } && h=1 || h=0
chk "$h" "the re-run serves the saved program + a fresh autopilot tail"

rm -f "$LIB" "$LOGA" "$LOGB"
[ "$fail" = 0 ] && { echo "==== PERSIST OK ===="; exit 0; }
echo "==== PERSIST FAILED ===="; exit 1
