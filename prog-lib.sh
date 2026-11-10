#!/usr/bin/env bash
# ============================================================
#  prog-lib.sh - inspect the autopilot's long-term memory.
#  The llm-proxy archives every program the free-running autopilot writes
#  into a JSONL library; this shows what the OS has built over time - the
#  capability it accumulated across reboots that a diskless PC itself
#  cannot keep.
#
#    ./prog-lib.sh                 # summary: named tools + recent programs
#    ./prog-lib.sh -v              # verbose: full script text of each entry
#    ./prog-lib.sh <name>          # show the program(s) filed under <name>
#    LLM_LIBRARY=/path ./prog-lib.sh
# ============================================================
set -u
cd "$(dirname "$0")"
LIB="${LLM_LIBRARY:-$PWD/autopilot-library.jsonl}"
[ -f "$LIB" ] || { echo "no library yet at $LIB (the autopilot has not run, or used a different --library)"; exit 0; }

exec python3 - "$LIB" "${1:-}" <<'PY'
import json, sys, time
path, arg = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
recs = []
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            try: recs.append(json.loads(line))
            except ValueError: pass

def when(ts):
    try: return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))
    except Exception: return "?"

if arg and arg not in ("-v", "--verbose"):
    hits = [r for r in recs if r.get("name") == arg]
    if not hits:
        print(f"no program named '{arg}' in the library"); sys.exit(0)
    for r in hits:
        print(f"=== {arg}  ({when(r.get('ts',0))}) ===\n{r.get('script','')}\n")
    sys.exit(0)

verbose = arg in ("-v", "--verbose")
print(f"autopilot library: {len(recs)} programs  ({path})")
tools = {}
for r in recs:
    n = r.get("name")
    if n: tools[n] = r
if tools:
    print(f"\nnamed tools ({len(tools)}):")
    for n, r in tools.items():
        print(f"  - {n:<16} {r.get('mission','')[:50]}")
print(f"\nrecent programs (newest last):")
for r in recs[-12:]:
    tag = f"[{r['name']}] " if r.get("name") else ""
    print(f"  {when(r.get('ts',0))}  {tag}{r.get('mission','')[:60]}")
    if verbose:
        for ln in r.get("script", "").splitlines():
            print(f"        | {ln}")
PY
