#!/usr/bin/env bash
# ============================================================
#  llmscript test - end to end: the LLM writes a script INTO
#  the running OS and the OS executes it. Mock proxy (deterministic
#  canned script), QEMU slirp. Checks the whole chain:
#    llmscript without diskon -> the SYS_WRITE_SLOT guard refuses;
#    diskon + llmscript 5 ... -> answer arrives, slot 5 persisted;
#    load 5 -> the script text is really on disk;
#    script 5 -> it RUNS: count agent computes 5050, echo proves the end.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_lls_XXXX.img)"
cp agentos32.img "$IMG"

PROXYLOG="$(mktemp /tmp/agentos_lls_proxy_XXXX.log)"
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
send 'llmscript 5 count to 100'   # no diskon yet -> guard must refuse
sleep 8
send 'diskon'
sleep 1
send 'llmscript 5 count to 100'
sleep 8
send 'load 5'
sleep 2
send 'script 5'
sleep 10                          # spawn+compute+sleep 40 ticks+echo
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" "$PRXPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== llmscript output ===="
sed 's/\r//g' "$LOG" | grep -E "llmscript|REFUSED|llm-made-this|5050|shell-lives" | head -14
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "slot write REFUSED"          "SYS_WRITE_SLOT guard refuses without diskon"
chk "the LLM wrote:"              "answer captured from the proxy"
chk "saved to slot 5"             "script persisted into the AgentFS slot"
chk "\]: spawn count"             "load 5 reads the script back from disk"
chk "= 5050"                      "script 5 EXECUTED: count agent computed 5050"
chk "llm-made-this"               "the LLM-written echo line ran last"
chk "shell-lives"                 "shell keeps responding afterwards"
if grep -q "script: 'count to 100'" "$PROXYLOG"; then
  echo "OK   : proxy served /script mode"
else
  echo "FAIL : proxy served /script mode"; fail=1
fi
[ "$fail" -eq 0 ] && echo "==== LLMSCRIPT OK ====" || { echo "==== LLMSCRIPT FAILED ===="; sed 's/\r//g' "$LOG" | tail -40; cat "$PROXYLOG"; }
rm -f "$LOG" "$PROXYLOG"
exit $fail
