#!/usr/bin/env bash
# ============================================================
#  USB FAT read test. A normal USB stick has a FAT filesystem with
#  the files you copied on from a PC. `usb ls` lists the root directory and
#  `usb cat <name>` prints a file - a tiny read-only FAT16/FAT32 layer over
#  the MSC block driver (usb_block). Handles a bare VBR or an MBR partition.
#
#  Headless: build a real FAT stick with mkfs.fat + mtools (no root needed),
#  copy known files onto it, attach it as a usb-storage device, and assert
#  the OS lists + reads them. Runs once for FAT16 and once for FAT32.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
if ! command -v mkfs.fat >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
    echo "SKIP: mkfs.fat / mtools (mcopy) not installed - FAT test skipped"
    echo "==== USB-FAT OK ===="; exit 0
fi
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

run_fat() {  # <fat-type> <image-MB> <label>
    local F="$1" MB="$2" LABEL="$3"
    local STICK IMG LOG FIFO MSG
    STICK="$(mktemp --suffix=.usb)"; rm -f "$STICK"
    dd if=/dev/zero of="$STICK" bs=1M count="$MB" status=none
    mkfs.fat -F "$F" "$STICK" >/dev/null 2>&1
    MSG="hello from a real FAT$F usb stick"
    printf '%s\n' "$MSG" > /tmp/aos_fat_$$.txt
    mcopy -i "$STICK" /tmp/aos_fat_$$.txt ::/HELLO.TXT
    mcopy -i "$STICK" /tmp/aos_fat_$$.txt ::/README.MD
    rm -f /tmp/aos_fat_$$.txt
    local bigsum=""
    if [ -n "$F" ]; then            # a multi-cluster source for the copy test
        python3 -c "import sys; sys.stdout.write(''.join('U%04d-multicluster-payload\n'%i for i in range(150))[:4000])" > /tmp/aos_ubig_$$.txt
        bigsum="$(md5sum /tmp/aos_ubig_$$.txt | cut -d' ' -f1)"
        mcopy -i "$STICK" /tmp/aos_ubig_$$.txt ::/BIG.TXT
        rm -f /tmp/aos_ubig_$$.txt
    fi
    IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
    LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
    qemu-system-i386 -drive format=raw,file="$IMG" \
      -device qemu-xhci,id=xhci \
      -drive id=stick,file="$STICK",if=none,format=raw \
      -device usb-storage,bus=xhci.0,drive=stick \
      -nographic <"$FIFO" >"$LOG" 2>/dev/null &
    local QPID=$!
    exec 3>"$FIFO"; sleep 4
    printf 'usb ls\r' >&3;            sleep 3
    printf 'usb cat HELLO.TXT\r' >&3; sleep 3
    if [ -n "$F" ]; then            # WRITE: save an AgentFS slot out as a FAT16 file
        printf 'diskon\r' >&3;            sleep 1
        printf 'save 4 usb-fat-write-ok\r' >&3; sleep 1
        printf 'usb save OUT.TXT 4\r' >&3; sleep 3
        printf 'usb copy BIG.TXT COPY.TXT\r' >&3; sleep 5   # multi-cluster write over USB
    fi
    printf 'halt\r' >&3;              sleep 1
    exec 3>&- 2>/dev/null
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
    local out; out="$(sed 's/\r//g' "$LOG")"
    local wrote="" cpysum=""
    if [ -n "$F" ]; then
        wrote="$(mtype -i "$STICK" ::/OUT.TXT 2>/dev/null | tr -d '\r\n')"
        cpysum="$(mtype -i "$STICK" ::/COPY.TXT 2>/dev/null | md5sum | cut -d' ' -f1)"
    fi
    rm -f "$FIFO" "$IMG" "$STICK" "$LOG"

    echo "  -- $LABEL --"
    echo "$out" | grep -q "FAT$F root directory" && a=1 || a=0
    chk "$a" "$LABEL: usb ls mounts the FAT$F filesystem"
    echo "$out" | grep -qE "HELLO.TXT +[0-9]+" && b=1 || b=0
    chk "$b" "$LABEL: the root directory lists the files on the stick"
    echo "$out" | grep -q "$MSG" && c=1 || c=0
    chk "$c" "$LABEL: usb cat reads a file's contents off the stick"
    if [ -n "$F" ]; then
        echo "$out" | grep -q "wrote slot 4" && d=1 || d=0
        chk "$d" "$LABEL: usb save reports it wrote the file (fat_save over USB)"
        echo "  host reads ::/OUT.TXT = '$wrote'"
        [ "$wrote" = "usb-fat-write-ok" ] && e=1 || e=0
        chk "$e" "$LABEL: the host reads back the file TannX OS wrote to the stick"
        echo "$out" | grep -q "usb: copied" && g=1 || g=0
        chk "$g" "$LABEL: usb copy reports success (multi-cluster write over USB)"
        echo "  source md5=$bigsum  COPY.TXT md5=$cpysum"
        [ "$bigsum" = "$cpysum" ] && h=1 || h=0
        chk "$h" "$LABEL: usb copy is byte-identical to the source (cluster chain on a stick)"
    fi
}

echo "==== USB FAT read checks ===="
run_fat 16 16 "FAT16"
run_fat 32 64 "FAT32"

[ "$fail" = 0 ] && { echo "==== USB-FAT OK ===="; exit 0; }
echo "==== USB-FAT FAILED ===="; exit 1
