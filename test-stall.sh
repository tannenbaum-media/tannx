#!/usr/bin/env bash
# ============================================================
#  Autopilot stall-breaker test. A free-running autopilot
#  can get stuck rotating on ONE plan - a wedged model, or a backend that
#  keeps echoing the same script - and then it hammers the OS and the API
#  every few seconds doing the same nothing. The llm-proxy watches the
#  scripts it hands back: when the SAME plan comes round STALL_LIMIT times,
#  it breaks the rut with a cool-down (a long sleep that throttles the loop
#  + a forced-variety next mission) INSTEAD of rotating on it - and it keeps
#  the loop alive rather than killing it.
#
#  HOST-side test (no QEMU): --mock returns one canned script every round,
#  so to a fresh proxy every round looks identical - exactly the stall we
#  want to provoke. Drive /script directly and prove the break fires on the
#  Nth round, not before, that the cool-down keeps the loop flying, and that
#  the throttle is NOT archived as if it were real work.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }

PORT=4098
LIB="$(mktemp -u --suffix=.jsonl)"; rm -f "$LIB"
LOG="$(mktemp)"

postr() {  # POST a /script body to the proxy and PRINT the reply
  python3 - "$1" <<'PY'
import urllib.request, sys
try:
    print(urllib.request.urlopen(
        urllib.request.Request("http://127.0.0.1:4098/script", data=sys.argv[1].encode()),
        timeout=5).read().decode("utf-8", "replace"))
except Exception as e:
    print("post error:", e, file=sys.stderr)
PY
}

# STALL_LIMIT=3: the 3rd identical round breaks. SESSION_GAP high so the
# repeated rounds all count as ONE session (a fresh session would re-seed,
# not stall).
LLM_STALL_LIMIT=3 LLM_SESSION_GAP=600 \
  python3 ./llm-proxy.py --mock --port "$PORT" --library "$LIB" >"$LOG" 2>&1 &
PP=$!
sleep 1.2
R1="$(postr 'autopilot continue' | tr -d '\r')"
R2="$(postr 'autopilot continue' | tr -d '\r')"
R3="$(postr 'autopilot continue' | tr -d '\r')"   # <- expect the cool-down break
R4="$(postr 'autopilot continue' | tr -d '\r')"   # <- loop must keep flying after
sleep 0.3
ENTRIES=$(grep -c . "$LIB" 2>/dev/null || echo 0)
kill "$PP" 2>/dev/null; wait "$PP" 2>/dev/null

echo "==== autopilot stall-breaker checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

# rounds 1 and 2 are the normal canned plan, NOT a premature break
{ echo "$R1" | grep -q "autopilot-alive" && ! echo "$R1" | grep -q "cooling down"; } && a=1 || a=0
chk "$a" "round 1 runs the normal plan (no premature break)"

{ echo "$R2" | grep -q "autopilot-alive" && ! echo "$R2" | grep -q "cooling down"; } && b=1 || b=0
chk "$b" "round 2 still runs the normal plan"

# round 3: the same plan a 3rd time -> the proxy breaks the rut
echo "$R3" | grep -q "cooling down" && c=1 || c=0
chk "$c" "round 3 (same plan x3) returns the cool-down break"

echo "$R3" | grep -q "sleep 180" && d=1 || d=0
chk "$d" "the cool-down throttles the loop (a long sleep)"

echo "$R3" | grep -q "do something completely different" && e=1 || e=0
chk "$e" "the cool-down forces a different next mission"

# the break must NOT kill autonomy: the cool-down re-arms the loop
{ echo "$R3" | grep -q "^llmscript 7 autopilot" && echo "$R3" | grep -q "^script 7$"; } && f=1 || f=0
chk "$f" "the cool-down keeps the loop alive (re-arms llmscript/wait/script 7)"

grep -q "STALL break - same plan x3" "$LOG" && g=1 || g=0
chk "$g" "the proxy logs the stall break for the operator"

# round 4 proves the loop survived the break - back to the normal plan
{ echo "$R4" | grep -q "autopilot-alive" && ! echo "$R4" | grep -q "cooling down"; } && h=1 || h=0
chk "$h" "round 4 flies again after the break (loop not killed)"

# the cool-down is a throttle, not the OS's work: only the 2 real rounds
# (1 and 2; round 3 broke, round 4 is post-break) were archived as programs.
# R1,R2 archived; R3 cool-down NOT archived; R4 archived -> 3 entries.
{ [ "$ENTRIES" = 3 ] 2>/dev/null && i=1 || i=0; }
chk "$i" "the cool-down is not archived as built software ($ENTRIES real rounds)"

rm -f "$LIB" "$LOG"
[ "$fail" = 0 ] && { echo "==== STALL OK ===="; exit 0; }
echo "==== STALL FAILED ===="; exit 1
