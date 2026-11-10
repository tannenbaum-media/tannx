#!/usr/bin/env bash
# ============================================================
#  LLM agent test (v2.53). 'spawn ask' launches the ring-3 askd daemon
#  (agent typ 5 on the real claim/finish ABI); 'task ask <slot>' makes
#  it read the slot's text, ask the (mock) proxy and write the answer
#  back into the slot. Checks the full cycle including the finish
#  notification, the answer really persisted on disk, and the failure
#  path for an empty slot (result 0).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_ask_XXXX.img)"
cp agentos32.img "$IMG"

PROXYLOG="$(mktemp /tmp/agentos_ask_proxy_XXXX.log)"
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
send 'save 2 what is agentos'
sleep 1
send 'spawn ask'
sleep 4                          # daemon: DHCP/ARP bring-up
send 'task ask 2'
for i in $(seq 1 30); do         # claim + mock ask + slot write + finish
  grep -aq "ask done = [1-9]" "$LOG" && break
  sleep 1
done
send 'load 2'
sleep 2
send 'task ask 6'                # empty slot -> clean failure, result 0
sleep 6
send 'agents'
sleep 2
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" "$PRXPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== askd output ===="
sed 's/\r//g' "$LOG" | grep -E "askd|ask done|MOCK|shell-lives" | head -12
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "askd: LLM agent online"          "spawn ask launches the daemon"
chk "ask done = [1-9][0-9]+"          "agent claimed, asked, finished (len > 0)"
chk "\]: AGENTOS-LLM-MOCK"            "the answer is really IN the slot (load 2)"
chk "You asked: what is agentos"      "the slot text reached the LLM verbatim"
chk "askd: empty/bad slot"            "empty slot fails cleanly"
chk "ask done = 0"                    "failure finishes with result 0"
chk "\(ask\)"                         "agents lists the ask agent type"
chk "shell-lives"                     "shell keeps responding afterwards"
[ "$fail" -eq 0 ] && echo "==== ASKD OK ====" || { echo "==== ASKD FAILED ===="; sed 's/\r//g' "$LOG" | tail -40; cat "$PROXYLOG"; }
rm -f "$LOG" "$PROXYLOG"
exit $fail
