#!/usr/bin/env bash
# ============================================================
#  USB mass-storage test. The `usb` command runs a ring-3 C
#  driver (user/xhci.c): it brings up the xHCI controller (TRB command +
#  event rings + DCBAA in user RAM), enumerates the device (Enable Slot /
#  Address Device / Get Device + Config Descriptors), Configure Endpoint +
#  SET_CONFIGURATION for the two bulk endpoints, then speaks MSC Bulk-Only
#  Transport + SCSI: INQUIRY, READ CAPACITY, WRITE(10) + READ(10).
#
#  QEMU: -device qemu-xhci + a usb-storage device (VID 46f4, "QEMU
#  HARDDISK"). Asserts the serial log AND - the end-to-end proof - that the
#  pattern the OS wrote to LBA 0 actually landed in the host backing file.
#  xHCI enumeration in the kernel wedged the box at boot, so this is ring-3
#  and on-demand, never at boot.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)";   cp agentos32.img "$IMG"
STICK="$(mktemp --suffix=.usb)"; dd if=/dev/zero of="$STICK" bs=1M count=8 status=none
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"

qemu-system-i386 -drive format=raw,file="$IMG" \
  -device qemu-xhci,id=xhci \
  -drive id=stick,file="$STICK",if=none,format=raw \
  -device usb-storage,bus=xhci.0,drive=stick \
  -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
printf 'usb test\r' >&3; sleep 4
printf 'halt\r' >&3; sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== USB mass-storage checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

grep -aq "found controller" "$LOG" && a=1 || a=0
chk "$a" "the xHCI controller is found (PCI class 0x0C0330) + BAR0 mapped"

grep -aq "device on port" "$LOG" && b=1 || b=0
chk "$b" "a connected port is reset; Enable Slot/Address Device enumerate it"

grep -aq "USB device 46f4:1" "$LOG" && c=1 || c=0
chk "$c" "Get Device Descriptor over EP0 (the usb-storage VID:PID)"

grep -aq "MSC endpoints configured" "$LOG" && d=1 || d=0
chk "$d" "config descriptor parsed; Configure Endpoint + SET_CONFIGURATION"

grep -aq "INQUIRY 'QEMU" "$LOG" && e=1 || e=0
chk "$e" "SCSI INQUIRY over Bulk-Only Transport (CBW -> data -> CSW)"

grep -aqE "capacity [0-9]+ blocks" "$LOG" && f=1 || f=0
chk "$f" "SCSI READ CAPACITY returns the medium geometry"

grep -aq "write+read LBA 0 verified" "$LOG" && g=1 || g=0
chk "$g" "SCSI WRITE(10) + READ(10) round-trips a 512-byte block"

# end-to-end: the pattern (i ^ 0x3c) the OS wrote must be in the host file.
RES="$(python3 - "$STICK" <<'PY'
import sys
try:
    d = open(sys.argv[1], "rb").read(512)
    ok = len(d) == 512 and all(d[i] == ((i ^ 0x3c) & 0xff) for i in range(512))
    print(f"lba0_match={int(ok)} first4={d[0]:02x},{d[1]:02x},{d[2]:02x},{d[3]:02x}")
except Exception as e:
    print("err", e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'lba0_match=1' && h=1 || h=0
chk "$h" "the written block landed in the host USB backing file (real DMA)"

echo "--- usb output ---"; sed 's/\r//g' "$LOG" | grep -i "xhci:" | head
rm -f "$LOG" "$STICK"

[ "$fail" = 0 ] && { echo "==== USB OK ===="; exit 0; }
echo "==== USB FAILED ===="; exit 1
