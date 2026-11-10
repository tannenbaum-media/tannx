#!/bin/bash
# test-fetch.sh - the neofetch-style system card ('fetch' / 'run fetch',
#   user/fetch.c). Boots agentos32.img as a BIOS disk, grows one agent and
#   one finished task, then issues 'fetch' and checks over serial that the
#   card carries the facts it promises (OS/kernel version, CPU via cpuid,
#   E820 RAM via SYS_SYSINFO, display, agents/tasks from SYS_AGENTS, the
#   tagline). A screendump then proves the colour escapes reach the
#   framebuffer console: the teal palette entries (2/3 = the fir, 9 = the
#   accent labels) must be on screen - SYS_WRITE strips 0x01 <attr> from the
#   serial stream, so only pixels can show it. Finally the shell must answer
#   (the launcher waits for the card like 'wait', so the prompt follows it).
set -u
cd "$(dirname "$0")"
IMG="${1:-agentos32.img}"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu-system-i386 missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 2; }
TMPIMG=$(mktemp --suffix=.img); cp "$IMG" "$TMPIMG"
FIFO=$(mktemp -u); mkfifo "$FIFO"
LOG=$(mktemp); PPM=$(mktemp --suffix=.ppm)
MPORT=55577
FAILED=0
qemu-system-i386 -drive format=raw,file="$TMPIMG" -vga std \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -net none -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
cleanup() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; rm -f "$TMPIMG" "$FIFO" "$LOG" "$PPM"; }
trap cleanup EXIT
send() {  # send a line CHAR BY CHAR (whole lines lose bytes)
  local s="$1" i
  for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done
  printf '\r' >&3
}
check() {  # check <description> <fixed-string>
  local t=0
  while [ "$(grep -aFc -- "$2" "$LOG")" -lt 1 ]; do
    sleep 0.3; t=$((t + 1))
    if [ $t -ge 60 ]; then echo "FAIL : $1"; FAILED=1; return 1; fi
  done
  echo "OK   : $1"
}
for t in $(seq 1 60); do grep -aq "tannx> " "$LOG" && break; sleep 0.3; done
sleep 1
send "spawn prime"; sleep 0.5
send "task prime 100"
check "an agent finished a task before the card"       "prime done = 541"
sleep 1
send "fetch"
check "card header"                                      "agents@tannx"
check "OS line carries the TannX version"          "OS:       TannX OS v"
check "kernel line (version + GNU as + budget)"          "Kernel:   agentos32 v"
check "boot path detected (BIOS disk image)"             "Boot:     BIOS"
check "CPU brand string via cpuid in ring 3"             "CPU:      "
check "E820 RAM via SYS_SYSINFO"                         " MB usable"
check "display mode from SYS_FBINFO"                     "x32 framebuffer"
check "agents roster from SYS_AGENTS"                    "1 agent (prime)"
check "task counters from SYS_AGENTS"                    "1 done, 0 running, 0 waiting"
check "disk: the TannX medium marker was read"     "TannX medium"
check "the tagline"                                      "Plant a wish. The agents grow it."
sleep 1
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1
sleep 1
send "echo fetch-done"
check "shell answers after the card (launcher waited for it)" "fetch-done"
# pixels: the fir's teals (VGA 2/3 re-programmed to 0x2a6b60/0x6fc6b4) and the
# accent (9 = 0x2dd4bf) must be on the framebuffer console
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb')
    if f.readline().strip()!=b'P6': print("noppm"); sys.exit(0)
    w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    teal=acc=0
    for y in range(0,h,2):
        for x in range(0,w,2):
            o=(y*w+x)*3; r,g,b=d[o],d[o+1],d[o+2]
            if (r,g,b) in ((0x2a,0x6b,0x60),(0x6f,0xc6,0xb4)): teal+=1
            if (r,g,b)==(0x2d,0xd4,0xbf): acc+=1
    print("teal=%d acc=%d"%(teal,acc))
except Exception as e: print("err",e)
PY
)"
echo "  $RES"
TEAL=$(echo "$RES" | sed -n 's/.*teal=\([0-9]*\).*/\1/p'); ACC=$(echo "$RES" | sed -n 's/.*acc=\([0-9]*\).*/\1/p')
if [ "${TEAL:-0}" -gt 300 ]; then echo "OK   : the fir renders in the house teals (colour escapes via SYS_WRITE)"
else echo "FAIL : the fir renders in the house teals (colour escapes via SYS_WRITE)"; FAILED=1; fi
if [ "${ACC:-0}" -gt 100 ]; then echo "OK   : accent-coloured labels on the framebuffer console"
else echo "FAIL : accent-coloured labels on the framebuffer console"; FAILED=1; fi
echo "----"
if [ "$FAILED" -eq 0 ]; then echo "==== test-fetch PASSED ===="; exit 0
else echo "==== test-fetch FAILED ===="; echo "--- log ---"; cat "$LOG"; exit 1; fi
