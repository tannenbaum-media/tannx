#!/usr/bin/env bash
# ============================================================
#  virtio-net test (VM track). virtio-net is the NIC
#  every cloud VM and hypervisor presents - the honest, testable answer to
#  "more NIC support" (the 2.5G chips need real hardware; QEMU has no model
#  for them, but it does emulate virtio-net). This drives the WHOLE stack
#  over it: bring-up (net_present=4), DHCP/ARP/TCP, an HTTP round-trip.
#
#  The kernel driver is legacy/transitional virtio (1af4:1000) over the I/O
#  BAR - split RX/TX virtqueues in fixed DMA RAM, the 10-byte virtio_net_hdr,
#  RX prefilled + replenished. QEMU: -device virtio-net-pci (romfile= so its
#  iPXE option ROM doesn't intercept the disk boot).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_vnet_XXXX.img)"; cp agentos32.img "$IMG"
PROXYLOG="$(mktemp /tmp/agentos_vnet_proxy_XXXX.log)"
. ./proxy-port.sh                # LLM_PROXY_PORT: 4080 / <n> / auto
python3 ./llm-proxy.py --mock --port "$PPORT" >"$PROXYLOG" 2>&1 &
PRXPID=$!
sleep 0.6
grep -q "listening" "$PROXYLOG" || { echo "proxy did not start"; cat "$PROXYLOG"; kill "$PRXPID" 2>/dev/null; exit 1; }

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$IMG" -boot order=c -nographic \
  -netdev "user,id=n0$PFWD" -device virtio-net-pci,netdev=n0,romfile= <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
sleep 5
send 'run net'                          # MAC + ARP/ICMP over virtio-net
sleep 5
send 'llm what is the wish loop'        # full TCP+HTTP round-trip over virtio-net
sleep 12
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" "$PRXPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== virtio-net output ===="
sed 's/\r//g' "$LOG" | grep -iE "MAC |llm:|MOCK|shell-lives" || echo "(no output)"
echo "==== checks ===="
fail=0
chk() { if grep -qiE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

chk "MAC 52:54:0"               "virtio-net is brought up (device-config MAC read)"
chk "llm: asking"              "the userspace TCP stack runs over virtio-net"
chk "AGENTOS-LLM-MOCK"         "an HTTP response round-trips (virtio-net TX + RX work)"
chk "You asked: what is the wish loop" "the request reached the proxy verbatim"
chk "shell-lives"             "the shell keeps responding afterwards"
if grep -q "prompt: 'what is the wish loop'" "$PROXYLOG"; then
  echo "OK   : the proxy received the request over virtio-net"
else
  echo "FAIL : the proxy received the request over virtio-net"; fail=1
fi

rm -f "$LOG" "$PROXYLOG"
[ "$fail" -eq 0 ] && { echo "==== VIRTIO-NET OK ===="; exit 0; }
echo "==== VIRTIO-NET FAILED ===="; exit 1
