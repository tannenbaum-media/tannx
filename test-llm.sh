#!/usr/bin/env bash
# ============================================================
#  LLM wish-loop test (llm-proxy.py + user/net.c llm_main).
#  Starts the proxy in MOCK mode on the host (no API key needed), boots
#  agentos32.img under QEMU user-net (slirp), types 'llm <question>' at
#  the shell and checks the canned answer came back through the OS's own
#  TCP stack and got printed on the console.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_llm_XXXX.img)"
cp agentos32.img "$IMG"

PROXYLOG="$(mktemp /tmp/agentos_llm_proxy_XXXX.log)"
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
send 'llm'                       # no prompt -> usage line, program exits clean
sleep 3
send 'llm what is the wish loop'
sleep 14
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" "$PRXPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== llm output ===="
sed 's/\r//g' "$LOG" | grep -iE "llm|MOCK|usage|shell-lives" || echo "(no llm output)"
echo "==== checks ===="
fail=0
chk() { if grep -qiE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "usage: llm"                 "bare 'llm' prints usage and returns"
chk "llm: asking"                "llm client starts the request"
chk "AGENTOS-LLM-MOCK"           "answer body arrived through the OS TCP stack"
chk "You asked: what is the wish loop" "the prompt reached the proxy verbatim"
chk "shell-lives"                "shell keeps responding afterwards"
if grep -q "prompt: 'what is the wish loop'" "$PROXYLOG"; then
  echo "OK   : proxy logged the prompt"
else
  echo "FAIL : proxy logged the prompt"; fail=1
fi
[ "$fail" -eq 0 ] && echo "==== LLM LOOP OK ====" || { echo "==== LLM LOOP FAILED ===="; sed 's/\r//g' "$LOG" | tail -30; cat "$PROXYLOG"; }
rm -f "$LOG" "$PROXYLOG"
exit $fail
