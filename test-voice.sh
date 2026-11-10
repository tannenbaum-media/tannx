#!/usr/bin/env bash
# ============================================================
#  Voice wish test: 'run voice' records through the HDA capture path,
#  POSTs a 16 kHz WAV to llm-proxy.py's /stt over the OS's ring-3 TCP
#  stack and stages "wish <transcript>" in slot 7; `script 7` plants it
#  through the real `wish` command. The proxy runs in --mock mode (a fixed
#  transcript, no speech model needed); the mic is the test signal (QEMU's
#  'none' audiodev is silence). Also checks /stt from the host directly:
#  the mock answer, and the clear error for a too-small body.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
PROXYLOG="$(mktemp)"
# a private host port: slirp forwards the guest's 10.0.2.2:4080 to it (one nc
# per connection), so two gates on one box - or a stray proxy on 4080 - cannot
# collide. slirp refuses a guestfwd on its own host alias, so the alias moves
# to 10.0.2.4 (10.0.2.3 is the DNS alias) and 10.0.2.2 becomes forwardable.
PORT=$((42000 + RANDOM % 2000))
python3 ./llm-proxy.py --mock --port $PORT >"$PROXYLOG" 2>&1 &
PRXPID=$!
sleep 0.6
grep -q "listening" "$PROXYLOG" || { echo "proxy did not start"; cat "$PROXYLOG"; kill "$PRXPID" 2>/dev/null; exit 1; }
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  kill "$PRXPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$LOG" "$PROXYLOG"
}
trap cleanup EXIT

# host side first: /stt with a tiny silent WAV -> the mock transcript; a
# 3-byte body -> a clear STT error (not an LLM answer)
TINY="$(python3 -c "import struct,sys; d=b'\0'*3200; sys.stdout.buffer.write(b'RIFF'+struct.pack('<I',36+len(d))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,16000,32000,2,16)+b'data'+struct.pack('<I',len(d))+d)" | curl -s --data-binary @- -H 'Content-Type: application/octet-stream' http://127.0.0.1:$PORT/stt | tr -d '\r')"
BAD="$(printf 'abc' | curl -s --data-binary @- http://127.0.0.1:$PORT/stt | tr -d '\r')"

qemu-system-i386 -drive format=raw,file="$IMG" -nographic \
  -audiodev none,id=a0 -device intel-hda -device hda-duplex,audiodev=a0 \
  -netdev user,id=n0,host=10.0.2.4,guestfwd=tcp:10.0.2.2:4080-cmd:"nc 127.0.0.1 $PORT" \
  -device rtl8139,netdev=n0 \
  <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
sleep 4
send 'diskon'
sleep 1
send 'run voice 2 test; wait; script 7'      # record 2 s, transcribe, plant - one line
sleep 22
send 'wishes'
sleep 2
send 'echo still-alive'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

echo "==== voice output ===="
sed 's/\r//g' "$LOG" | grep -E "voice:|audio:|Wish|wish \[|still-alive" || echo "(no voice output)"
echo "  host /stt tiny wav -> '$TINY'"
echo "  host /stt 3 bytes  -> '$BAD'"
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "voice: listening for 2 s \(test signal\)"       "voice starts capturing"
chk "voice: captured 32000 samples \([0-9]+ chunks, in-lpib [1-9][0-9]*, peak [1-9][0-9]{3,}\), sending 64044 bytes" \
                                                     "2 s captured + decimated to 16 kHz mono (input DMA ran, non-silent)"
chk "voice: transcript: build a tetris game with a high score table" "the 64 KB WAV reached /stt over the ring-3 TCP stack; transcript came back"
chk "voice: staged in slot 7"                        "transcript staged as 'wish ...' in AgentFS slot 7"
chk "wish \[[0-9]\]: build a tetris game with a high score table" "script 7 planted it through the real wish command: 'wishes' lists it from the wish slot on disk"
chk "still-alive"                                    "shell keeps responding afterwards"
grep -q "stt: 64044 bytes of audio" "$PROXYLOG" && echo "OK   : proxy logged the WAV upload (64044 bytes)" || { echo "FAIL : proxy upload log"; fail=1; }
[ "$TINY" = "build a tetris game with a high score table" ] && echo "OK   : host /stt mock transcript" || { echo "FAIL : host /stt mock"; fail=1; }
case "$BAD" in *"STT error"*) echo "OK   : host /stt rejects a non-WAV body with a clear STT error";; *) echo "FAIL : /stt error path"; fail=1;; esac
[ "$fail" -eq 0 ] && echo "==== VOICE OK ====" || { echo "==== VOICE FAILED ===="; sed 's/\r//g' "$LOG" | tail -30; cat "$PROXYLOG"; }
exit $fail
