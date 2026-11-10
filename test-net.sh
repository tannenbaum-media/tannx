#!/usr/bin/env bash
# ============================================================
#  TannX OS network test
#  Boots with each supported NIC, fires 'netwish', dumps all NIC
#  traffic to a pcap and checks the UDP broadcast went out intact.
#  Also checks the PCI probe reports an unknown card's ID.
#  Usage: ./test-net.sh [image]   (default: agentos32.img)
# ============================================================
set -u
IMG="${1:-agentos32.img}"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 2; }
command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump missing"; exit 2; }

fail=0
check() { if eval "$2"; then echo "OK   : $1"; else echo "MISS : $1"; fail=1; fi; }

# run_nic <qemu-device> <expected-driver-banner>
run_nic() {
  local dev="$1" banner="$2"
  local pcap log tmp
  pcap="$(mktemp /tmp/agentos_net_XXXX.pcap)"
  log="$(mktemp /tmp/agentos_net_XXXX.log)"
  tmp="$(mktemp /tmp/agentos_net_XXXX.img)"
  cp "$IMG" "$tmp"
  { sleep 3; printf 'net\r'; sleep 1
    printf 'netwish hello from the wire\r'; sleep 2
    printf 'halt\r'; sleep 1; } | \
    timeout --foreground 18 qemu-system-i386 -drive format=raw,file="$tmp" \
      -netdev user,id=n0,restrict=on -device "$dev",netdev=n0 \
      -object filter-dump,id=d0,netdev=n0,file="$pcap" \
      -nographic >"$log" 2>/dev/null || true
  echo "-- $dev --"
  check "$dev: NIC up, banner '$banner'"      "grep -aq '$banner' '$log'"
  check "$dev: netwish reports a broadcast"   "grep -aq 'Wish broadcast' '$log'"
  local dump verb
  dump="$(tcpdump -r "$pcap" -nnA 2>/dev/null)"
  check "$dev: UDP to 255.255.255.255:4711"   "echo \"\$dump\" | grep -q '255.255.255.255.4711'"
  check "$dev: payload carries AGENTOS-WISH"  "echo \"\$dump\" | grep -q 'AGENTOS-WISH: hello from the wire'"
  verb="$(tcpdump -r "$pcap" -nnv 2>/dev/null)"
  check "$dev: IP header checksum valid"      "! echo \"\$verb\" | grep -q 'bad cksum'"
  rm -f "$pcap" "$log" "$tmp"
}

# probe_nic <qemu-device> <expected vendor:device>
probe_nic() {
  local dev="$1" id="$2" log tmp
  log="$(mktemp /tmp/agentos_net_XXXX.log)"
  tmp="$(mktemp /tmp/agentos_net_XXXX.img)"
  cp "$IMG" "$tmp"
  { sleep 3; printf 'net\r'; sleep 2; printf 'halt\r'; sleep 1; } | \
    timeout --foreground 14 qemu-system-i386 -drive format=raw,file="$tmp" \
      -netdev user,id=n0,restrict=on -device "$dev",netdev=n0 -nographic >"$log" 2>/dev/null || true
  echo "-- probe $dev --"
  check "probe reports unknown card $id"      "grep -aq 'vendor:device $id' '$log'"
  rm -f "$log" "$tmp"
}

echo "==== Network checks ===="
run_nic rtl8139 "NIC up (RTL8139)"
run_nic e1000   "NIC up (e1000)"
run_nic e1000e  "NIC up (e1000)"   # H2: 82574L (8086:10d3) driven by the e1000 path
probe_nic pcnet 1022:2000          # an unsupported card still reports its ID

if [ "$fail" -eq 0 ]; then
  echo "==== ALL TESTS PASSED ===="; exit 0
else
  echo "==== TESTS FAILED ===="; exit 1
fi
