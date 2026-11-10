#!/usr/bin/env bash
# ============================================================
#  HTTP server test. Until now TannX OS's TCP
#  stack was an outbound client (SYN -> SYN-ACK). The `httpd` command makes
#  it a SERVER: passive open (answer an inbound SYN with SYN-ACK), read the
#  request, and serve it - so the box can be QUERIED, not just query.
#
#  Headless: QEMU slirp with hostfwd forwards a host port to the guest's
#  :80; we curl it from the host and assert the responses. GET /status ->
#  live agent/task JSON; GET / -> a plain-text banner. Also answers ARP so
#  slirp/clients can resolve the guest before connecting.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
HP=18080   # host port -> guest :80

# a virtio-blk data disk (GPT + FAT16) with a file to serve over HTTP
HAVE_FAT=1
{ command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1 \
  && command -v sgdisk >/dev/null 2>&1; } || HAVE_FAT=0
FMSG="TannX OS served this from its disk over HTTP"
DISK="$(mktemp --suffix=.blk)"; dd if=/dev/zero of="$DISK" bs=1M count=24 status=none
BLKARGS=""
if [ "$HAVE_FAT" = 1 ]; then
  FATP="$(mktemp --suffix=.fatp)"; dd if=/dev/zero of="$FATP" bs=1M count=16 status=none
  mkfs.fat -F 16 "$FATP" >/dev/null 2>&1
  printf '%s\n' "$FMSG" > /tmp/aos_httpd_$$.htm
  mcopy -i "$FATP" /tmp/aos_httpd_$$.htm ::/INDEX.HTM
  rm -f /tmp/aos_httpd_$$.htm
  sgdisk -n 1:2048:+16M -t 1:0700 "$DISK" >/dev/null 2>&1
  dd if="$FATP" of="$DISK" bs=512 seek=2048 conv=notrunc status=none
  rm -f "$FATP"
  BLKARGS="-drive id=vd,file=$DISK,if=none,format=raw -device virtio-blk-pci,drive=vd"
fi

qemu-system-i386 -drive format=raw,file="$IMG" -boot order=c \
  -netdev user,id=n0,hostfwd=tcp::$HP-:80 -device rtl8139,netdev=n0 \
  $BLKARGS \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 5
printf 'httpd\r' >&3
sleep 3

# curl the guest (retry: httpd may still be binding right after launch)
STATUS=""; ROOT=""
for try in 1 2 3 4 5; do
  STATUS="$(curl -s --max-time 5 http://127.0.0.1:$HP/status 2>/dev/null)"
  [ -n "$STATUS" ] && break
  sleep 1
done
ROOT="$(curl -s --max-time 5 http://127.0.0.1:$HP/ 2>/dev/null)"
# a second /status proves the server loops (serves more than one connection)
STATUS2="$(curl -s --max-time 5 http://127.0.0.1:$HP/status 2>/dev/null)"
MISSION="remote mission alpha"
MCODE="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST --data-binary "$MISSION" http://127.0.0.1:$HP/mission 2>/dev/null)"
MSTATUS="$(curl -s --max-time 5 http://127.0.0.1:$HP/status 2>/dev/null)"
LONGMISSION="abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuv"
MLONG="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST --data-binary "$LONGMISSION" http://127.0.0.1:$HP/mission 2>/dev/null)"
# GET /file/<name> off the virtio-blk FAT disk + a 404 for a missing file
FILE=""; F404=""; UPCODE=""; UPBACK=""; RECODE=""; REBACK=""; BIGCODE=""; BADCODE=""; PATHCODE=""
if [ "$HAVE_FAT" = 1 ]; then
  FILE="$(curl -s --max-time 8 http://127.0.0.1:$HP/file/INDEX.HTM 2>/dev/null)"
  F404="$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' http://127.0.0.1:$HP/file/NOPE.TXT 2>/dev/null)"
  # POST /file/<name> upload, then GET it back: a full round-trip through fat_save
  UPCODE="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST --data-binary 'uploaded-over-http-roundtrip' http://127.0.0.1:$HP/file/UP.TXT 2>/dev/null)"
  sleep 1
  UPBACK="$(curl -s --max-time 8 http://127.0.0.1:$HP/file/UP.TXT 2>/dev/null)"
  RECODE="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST --data-binary 'replaced' http://127.0.0.1:$HP/file/UP.TXT 2>/dev/null)"
  sleep 1
  REBACK="$(curl -s --max-time 8 http://127.0.0.1:$HP/file/UP.TXT 2>/dev/null)"
  # audit finding 6: a data-less TCP connect (portscan/health-check) must NOT replay the
  # previous POST and overwrite UP.TXT with 0 bytes. Open + immediately close.
  exec 9<>/dev/tcp/127.0.0.1/$HP 2>/dev/null && exec 9>&- 2>/dev/null
  sleep 1
  STALEBACK="$(curl -s --max-time 8 http://127.0.0.1:$HP/file/UP.TXT 2>/dev/null)"
  BIGBODY="$(head -c 5000 /dev/zero | tr '\0' x)"
  BIGCODE="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST --data-binary "$BIGBODY" http://127.0.0.1:$HP/file/BIG.TXT 2>/dev/null)"
  BADCODE="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST --data-binary 'bad-name' http://127.0.0.1:$HP/file/ 2>/dev/null)"
  PATHCODE="$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' -X POST --data-binary 'bad-path' http://127.0.0.1:$HP/file/BAD/NAME.TXT 2>/dev/null)"
  # audit finding 7: a bogus 12-digit Content-Length must not overflow the parser
  # into a negative value (which would defeat the size guards). Raw request, tiny
  # body; the saturating parse clamps it high -> the too_large path answers 413.
  OVFCODE="$(python3 - "$HP" <<'PY'
import socket, sys
try:
    s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
    s.sendall(b"POST /file/OVF.TXT HTTP/1.0\r\nHost: x\r\n"
              b"Content-Length: 999999999999\r\nConnection: close\r\n\r\nhi")
    buf = b""
    while True:
        try: chunk = s.recv(256)
        except Exception: break
        if not chunk: break
        buf += chunk
    try: s.shutdown(socket.SHUT_RDWR)
    except Exception: pass
    s.close()
    parts = buf.decode("latin1", "replace").split()
    print(parts[1] if len(parts) > 1 else "none")
except Exception:
    print("none")
PY
)"
  sleep 1
  # and the server is still alive after it
  OVFALIVE="$(curl -s --max-time 6 http://127.0.0.1:$HP/status 2>/dev/null)"
fi

printf 'halt\r' >&3; sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG" "$DISK"

echo "==== HTTP server checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
echo "  /status -> $STATUS"
echo "  /       -> $ROOT"

grep -aq "listening on :80" "$LOG" && a=1 || a=0
chk "$a" "the server brings up the NIC and listens on :80 (passive open)"

echo "$STATUS" | grep -q '"os":"TannX"' && b=1 || b=0
chk "$b" "GET /status completes the 3-way handshake and returns JSON"

{ echo "$STATUS" | grep -q '"agents":' && echo "$STATUS" | grep -q '"tasks":'; } && c=1 || c=0
chk "$c" "the JSON carries the live SYS_AGENTS snapshot (agents/tasks counts)"

# the appliance reports its display geometry over HTTP too (sys_fbinfo)
echo "$STATUS" | grep -qE '"w":[0-9]+,"h":[0-9]+' && cf=1 || cf=0
chk "$cf" "the JSON carries the framebuffer geometry (w/h from sys_fbinfo)"

# ...and its autopilot-loop telemetry (sys_atp: round count + mission)
echo "$STATUS" | grep -qE '"atp":[0-9]+,"mission":"' && cg=1 || cg=0
chk "$cg" "the JSON carries the autopilot telemetry (atp round + mission)"

echo "$ROOT" | grep -q "fetch('/status')" && d=1 || d=0
chk "$d" "GET / serves the HTML dashboard (polls /status via JS)"

echo "$STATUS2" | grep -q '"os":"TannX"' && e=1 || e=0
chk "$e" "the server loops - a second request is served too"

echo "  POST /mission -> HTTP $MCODE ; /status mission -> $MSTATUS"
[ "$MCODE" = "204" ] && m1=1 || m1=0
chk "$m1" "POST /mission accepts a remote mission update"
echo "$MSTATUS" | grep -q '"mission":"remote mission alpha"' && m2=1 || m2=0
chk "$m2" "GET /status reports the mission set over HTTP"
echo "  oversized POST /mission -> HTTP $MLONG"
[ "$MLONG" = "400" ] && m3=1 || m3=0
chk "$m3" "POST /mission rejects missions longer than the telemetry field"

if [ "$HAVE_FAT" = 1 ]; then
  echo "  /file/INDEX.HTM -> $FILE"
  echo "$FILE" | grep -q "$FMSG" && f=1 || f=0
  chk "$f" "GET /file/<name> serves a file off the virtio-blk disk (httpd+fatfs)"
  [ "$F404" = "404" ] && g=1 || g=0
  chk "$g" "GET /file/<missing> returns 404 (HTTP $F404)"
  # upload round-trip: POST wrote UP.TXT to the disk, GET reads it back
  echo "  POST /file/UP.TXT -> HTTP $UPCODE ; GET back -> '$UPBACK'"
  [ "$UPCODE" = "201" ] && u1=1 || u1=0
  chk "$u1" "POST /file/<name> accepts an upload (HTTP 201, fat_save to the disk)"
  [ "$UPBACK" = "uploaded-over-http-roundtrip" ] && u2=1 || u2=0
  chk "$u2" "the uploaded file round-trips: GET returns exactly what was POSTed"
  echo "  overwrite POST /file/UP.TXT -> HTTP $RECODE ; GET back -> '$REBACK'"
  [ "$RECODE" = "201" ] && u2a=1 || u2a=0
  chk "$u2a" "POST /file/<name> overwrites an existing FAT file"
  [ "$REBACK" = "replaced" ] && u2b=1 || u2b=0
  chk "$u2b" "the overwritten file reads back with the replacement body"
  echo "  after empty connect, GET /file/UP.TXT -> '$STALEBACK'"
  [ "$STALEBACK" = "replaced" ] && u2c=1 || u2c=0
  chk "$u2c" "a data-less connect does NOT replay the last POST (audit finding 6: file intact)"
  echo "  oversized POST /file/BIG.TXT -> HTTP $BIGCODE"
  [ "$BIGCODE" = "413" ] && u3=1 || u3=0
  chk "$u3" "oversized POST /file/<name> is rejected instead of silently truncating"
  echo "  bad POST /file/ -> HTTP $BADCODE"
  [ "$BADCODE" = "400" ] && u4=1 || u4=0
  chk "$u4" "POST /file/ with an empty FAT name is rejected"
  echo "  bad POST /file/BAD/NAME.TXT -> HTTP $PATHCODE"
  [ "$PATHCODE" = "400" ] && u5=1 || u5=0
  chk "$u5" "POST /file/<bad path> maps invalid FAT names to HTTP 400"
  echo "  overflow Content-Length POST -> HTTP $OVFCODE"
  [ "$OVFCODE" = "413" ] && u6=1 || u6=0
  chk "$u6" "a 12-digit Content-Length saturates to 413, no int overflow (audit finding 7)"
  echo "$OVFALIVE" | grep -q '"os":"TannX"' && u7=1 || u7=0
  chk "$u7" "the server survives the overflow request (still serves /status)"
else
  echo "SKIP : /file checks (mkfs.fat/mtools/sgdisk not installed)"
fi

echo "--- httpd output ---"; sed 's/\r//g' "$LOG" | grep -i "httpd:" | head
rm -f "$LOG"

[ "$fail" = 0 ] && { echo "==== HTTPD OK ===="; exit 0; }
echo "==== HTTPD FAILED ===="; exit 1
