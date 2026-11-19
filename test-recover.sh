#!/usr/bin/env bash
# ============================================================
#  Getting back out (v2.89). Regression checks for the ways a visitor of
#  the browser demo got stuck or left with a broken screen in v2.88:
#   - the help pager: 'q' returns to the prompt, every time (10 rounds)
#   - 'waittask' on a task nobody serves: a key typed first no longer
#     hides the abort key behind it (Ctrl+C here, Escape on PS/2)
#   - 'disktest' never reads past the end of the disk (IDENTIFY bound),
#     and the disk still answers afterwards (diskon finds the marker)
#   - under the Dark Glass compositor ('gui'): a full-screen program that
#     quits gets a fresh prompt, and the kernel's 'gfx' demo leaves no
#     circles behind (screendump of the bottom row = wallpaper again)
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
PGFX="$(mktemp --suffix=.ppm)"; PAFT="$(mktemp --suffix=.ppm)"
MPORT=55581
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$LOG" "$PGFX" "$PAFT"
}
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -vga std -net none \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
dump() { printf "screendump %s\n" "$1" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1; }

sleep 4
for i in 1 2 3 4 5 6 7 8 9 10; do        # pager: help, then q at the first pause
  send 'help'; sleep 1.2; printf 'q' >&3; sleep 0.5
done
send 'echo pager-rounds-done'; sleep 1
send 'task math 2 * 3'; sleep 1          # no math agent: nobody serves it
send 'waittask 0'; sleep 1
printf 'q' >&3; sleep 0.5                # a stray key first ...
printf '\003' >&3; sleep 1               # ... then the abort key
send 'echo waittask-left'; sleep 1
send 'disktest'; sleep 6
send 'diskon'; sleep 1
send 'gui'; sleep 3
send 'snake'; sleep 4
printf 'q' >&3; sleep 3                  # quit snake under the compositor
send 'echo after-snake'; sleep 1
send 'gfx'; sleep 3
dump "$PGFX"
printf 'x' >&3; sleep 4                  # any key ends gfx; gui repaints
dump "$PAFT"
send 'halt'; sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

# bright gfx pixels left on the bottom screen row (the starburst ends there
# every 40 px), sampled where Dark Glass shows plain wallpaper
bottom_bright() { python3 - "$1" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb'); f.readline(); w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    n=0
    for y in (h-1, h-2):
        for x in range(0, w//4, 40):
            o=(y*w+x)*3
            if max(d[o],d[o+1],d[o+2]) > 140: n+=1
    print(n)
except Exception: print(-1)
PY
}
B_GFX="$(bottom_bright "$PGFX")"; B_AFT="$(bottom_bright "$PAFT")"
OUT="$(tr -d '\r' < "$LOG")"
RAW="$(cat "$LOG")"
echo "==== recover checks (bright bottom-row samples: gfx=$B_GFX after=$B_AFT) ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
n="$(printf '%s' "$RAW" | python3 -c 'import sys; s=sys.stdin.read(); print(s.count("q quits) --\r                              \rtannx> "))')"
[ "$n" -ge 10 ] && a=1 || a=0
chk "$a" "help pager: q returns to the prompt in all 10 rounds ($n)"
echo "$OUT" | grep -q 'waittask-left' && echo "$OUT" | grep -q 'aborted' && b=1 || b=0
chk "$b" "waittask on an unserved task: Ctrl+C behind a stray key aborts it"
echo "$OUT" | grep -q 'reading 2880 sectors' && echo "$OUT" | grep -q '1440 KB read, errors: 0' && c=1 || c=0
chk "$c" "disktest stays inside the 1.44 MB disk (IDENTIFY bound, no errors)"
echo "$OUT" | sed -n '/1440 KB read/,$p' | grep -q 'Disk writes ARMED' && d=1 || d=0
chk "$d" "after disktest the disk still answers (diskon finds the marker)"
printf '%s' "$RAW" | python3 -c 'import sys,re; s=sys.stdin.read(); sys.exit(0 if re.search(r"snake: quit\. Score: \d+\r\n\r\ntannx> ", s) else 1)' && e=1 || e=0
chk "$e" "under gui a quit full-screen program gets a fresh prompt"
[ "$B_GFX" -gt 3 ] && [ "$B_AFT" = 0 ] && f=1 || f=0
chk "$f" "under gui the gfx demo is repainted away after its key"
[ "$fail" = 0 ] && { echo "==== RECOVER OK ===="; exit 0; }
echo "==== RECOVER FAILED ===="; echo "$OUT" | tail -30 | sed 's/^/  /'; exit 1
