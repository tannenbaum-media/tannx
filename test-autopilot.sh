#!/usr/bin/env bash
# ============================================================
#  Autopilot test (v2.49). Mock proxy: an 'autopilot ...' llmscript
#  prompt returns a canned script that ends with the continuation tail
#  (llmscript 7 autopilot continue; wait; script 7) - so the OS loops:
#  ask the LLM, run the script, ask again. The test checks at least two
#  full iterations happened, then stops the loop with Ctrl+C over the
#  serial console and verifies the shell is back.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_atp_XXXX.img)"
cp agentos32.img "$IMG"

PROXYLOG="$(mktemp /tmp/agentos_atp_proxy_XXXX.log)"
. ./proxy-port.sh                # LLM_PROXY_PORT: 4080 / <n> / auto
python3 ./llm-proxy.py --mock --port "$PPORT" >"$PROXYLOG" 2>&1 &
PRXPID=$!
sleep 0.6
grep -q "listening" "$PROXYLOG" || { echo "proxy did not start"; cat "$PROXYLOG"; kill "$PRXPID" 2>/dev/null; exit 1; }

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$IMG" -nographic \
  -netdev "user,id=n0$PFWD" -device rtl8139,netdev=n0 <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
sleep 4
send 'diskon'
sleep 1
send 'autopilot explore the system'
# each round: llmscript fetch + count pipeline + sleep 40 ticks. One fetch
# prints one 'saved to slot 7' - wait until the SECOND fetch completed
# (i.e. the continuation request round-tripped), then Ctrl+C stops the loop.
for i in $(seq 1 60); do
  [ "$(grep -ac "saved to slot 7" "$LOG")" -ge 2 ] && break
  sleep 1
done
printf '\x03' >&3                  # Ctrl+C - serial chain abort
sleep 4
printf '\x03' >&3                  # once more in case round N was mid-fetch
sleep 3
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" "$PRXPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

ROUNDS=$(grep -ac "saved to slot 7" "$LOG")
echo "==== autopilot output (rounds: $ROUNDS) ===="
sed 's/\r//g' "$LOG" | grep -E "autopilot|alive|aborted|5050|shell-lives" | head -14
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "saved to slot 7"        "round 1: the LLM script landed in slot 7"
[ "$ROUNDS" -ge 2 ] && echo "OK   : the loop self-perpetuated ($ROUNDS rounds)" \
                    || { echo "FAIL : the loop self-perpetuated"; fail=1; }
chk "= 5050"                 "the autopilot's work actually ran (count agent)"
chk "chain aborted"          "Ctrl+C stopped the loop"
chk "shell-lives"            "shell back at the prompt afterwards"
if grep -q "autopilot: 'autopilot continue'" "$PROXYLOG"; then
  echo "OK   : proxy saw the continuation request"
else
  echo "FAIL : proxy saw the continuation request"; fail=1
fi
[ "$fail" -eq 0 ] && echo "==== AUTOPILOT OK ====" || { echo "==== AUTOPILOT FAILED ===="; sed 's/\r//g' "$LOG" | tail -40; cat "$PROXYLOG"; }
rm -f "$LOG" "$PROXYLOG"
exit $fail
