#!/usr/bin/env python3
# stream-view.py - turn Claude Code's `--output-format stream-json` into a
# readable one-line-per-step console view for build-wish.sh. Reads stdin,
# writes stdout; lines that are not JSON pass through unchanged.
import json
import sys


def short(s, n=160):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n - 3] + "..."


def tool_line(block):
    name = block.get("name", "?")
    inp = block.get("input") or {}
    arg = (inp.get("command") or inp.get("file_path") or inp.get("pattern")
           or inp.get("path") or inp.get("description") or "")
    return f"  -> {name} {short(arg, 140)}".rstrip()


def main():
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            print(line, flush=True)
            continue
        if not isinstance(ev, dict):
            continue
        t = ev.get("type")
        if t == "system" and ev.get("subtype") == "init":
            print(f"  [claude] session {ev.get('session_id', '?')}  "
                  f"model {ev.get('model', '?')}  "
                  f"permissions {ev.get('permissionMode', '?')}", flush=True)
        elif t == "assistant":
            for b in (ev.get("message") or {}).get("content") or []:
                if b.get("type") == "text" and b.get("text", "").strip():
                    print(f"  claude: {short(b['text'])}", flush=True)
                elif b.get("type") == "tool_use":
                    print(tool_line(b), flush=True)
        elif t == "user":
            for b in (ev.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                    c = b.get("content")
                    if isinstance(c, list):
                        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
                    print(f"     ! {short(c, 140)}", flush=True)
        elif t == "result":
            cost = ev.get("total_cost_usd")
            print(f"  [claude] done: {ev.get('subtype', '?')}, "
                  f"{ev.get('num_turns', '?')} turns"
                  + (f", ${cost:.2f}" if isinstance(cost, (int, float)) else "")
                  + (" (ERROR)" if ev.get("is_error") else ""), flush=True)
            if ev.get("result"):
                print("  --- summary ---", flush=True)
                for l in str(ev["result"]).splitlines():
                    print("  " + l, flush=True)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
