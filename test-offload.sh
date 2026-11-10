#!/usr/bin/env bash
# ============================================================
#  Compute-offload test (llm-proxy.py /compute + user/net.c
#  offload_main). Starts the proxy on the host, boots agentos32.img under
#  QEMU user-net (slirp), types 'offload <job>' at the shell and checks the
#  computed result came back through the OS's own TCP stack. /compute runs
#  no LLM backend, so it is deterministic and needs no API key (--mock just
#  guarantees the proxy starts without one).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_off_XXXX.img)"
cp agentos32.img "$IMG"

PROXYLOG="$(mktemp /tmp/agentos_off_proxy_XXXX.log)"
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
send 'offload'                   # no job -> usage line, program exits clean
sleep 3
send 'offload sum 100'           # trivial deterministic job: 1..100 = 5050
sleep 6
send 'offload mandel 16'         # the GPU-style kernel: 16x16 Mandelbrot count = 51
sleep 8
send 'offload primes 100'        # prime sieve: 25 primes <= 100
sleep 6
send 'offload fib 30'            # big-int Fibonacci: fib 30 = 832040
sleep 6
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" "$PRXPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== offload output ===="
sed 's/\r//g' "$LOG" | grep -iE "offload|sum 1|mandel|in-set|usage|shell-lives" || echo "(no offload output)"
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "usage: offload"             "bare 'offload' prints usage and returns"
chk "offload: sending"           "offload client starts the request"
chk "sum 1\.\.100 = 5050"        "sum job computed and returned through the OS TCP stack"
chk "mandel 16x16 = 51 in-set"   "Mandelbrot offload job computed (the GPU-style kernel)"
chk "primes <= 100 = 25"         "prime-sieve offload job computed (25 primes <= 100)"
chk "fib 30 = 832040"            "big-int Fibonacci offload job computed (fib 30)"
chk "shell-lives"                "shell keeps responding afterwards"
if grep -q "compute: 'mandel 16'" "$PROXYLOG"; then
  echo "OK   : proxy logged the compute job"
else
  echo "FAIL : proxy logged the compute job"; fail=1
fi
[ "$fail" -eq 0 ] && echo "==== OFFLOAD OK ====" || { echo "==== OFFLOAD FAILED ===="; sed 's/\r//g' "$LOG" | tail -30; cat "$PROXYLOG"; }
rm -f "$LOG" "$PROXYLOG"
exit $fail
