#!/usr/bin/env bash
# ============================================================
#  Userspace TCP/IP + HTTP stack test (net.c, Ring 3).
#  Flashes net.bin at LBA 300 of a copy of agentos32.img, boots it under
#  QEMU user-net (slirp), runs a throwaway HTTP server on the host, then
#  drives 'run' over serial and checks the net program reached the host:
#  ARP reply, ICMP reply, and the HTTP body it fetched.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

# net is folded into the default program now; 'run net' selects it.
IMG="$(mktemp /tmp/agentos_net_XXXX.img)"
cp agentos32.img "$IMG"

WWW="$(mktemp -d)"
MARK="HELLO-FROM-AGENTOS-NET-42"
printf '%s\n' "$MARK" > "$WWW/index.html"
( cd "$WWW" && exec python3 -m http.server 8080 --bind 0.0.0.0 ) >/dev/null 2>&1 &
SRVPID=$!
sleep 0.6

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$IMG" -nographic \
  -netdev user,id=n0 -device rtl8139,netdev=n0 <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
sleep 4
send 'run net'
sleep 10
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" "$SRVPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"; rm -rf "$WWW"

echo "==== net program output ===="
sed 's/\r//g' "$LOG" | grep -iE "net:|MAC |DHCP|DNS|IP |ARP|ping|HTTP|Example Domain|$MARK|bytes\)|TCP:" || echo "(no net output)"
echo "==== checks ===="
fail=0
chk() { if grep -qiE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "DHCP .*IP " "DHCP obtains a lease"
chk "ARP .*at .*:" "ARP resolves the gateway MAC"
chk "ping .*\.\.\. reply" "ICMP echo reply from the gateway"
chk "$MARK"        "HTTP GET fetched the host page body"
if grep -qi "Example Domain" "$LOG"; then echo "OK   : DNS + real-internet HTTP GET (example.com)"; else echo "INFO : no internet in this env - skipped the example.com fetch"; fi
[ "$fail" -eq 0 ] && echo "==== NET STACK OK ====" || echo "==== NET STACK FAILED ===="
rm -f "$LOG"
exit $fail
