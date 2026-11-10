#!/usr/bin/env bash
# ============================================================
#  HDA capture + recorder test. QEMU's intel-hda with the hda-duplex codec
#  (line-out + line-in; audio sunk to 'none', which still clocks the input
#  DMA at the real rate but delivers silence) and a FAT16 virtio-blk disk.
#  'run rec test' swaps the silent mic for the engine's deterministic test
#  signal and prints diagnostics. Checks: the codec's capture path (ADC +
#  input pin) is found, the INPUT stream's LPIB advances (real DMA), the
#  recording holds non-silent samples, playback streams through the output
#  descriptor, and REC.WAV lands on the host-side disk image as a valid
#  48 kHz mono WAV with the recorded samples in it (mtools + python).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
HAVE_FAT=1
{ command -v mkfs.fat >/dev/null 2>&1 && command -v mtype >/dev/null 2>&1; } || HAVE_FAT=0
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
BLK="$(mktemp --suffix=.blk)"; dd if=/dev/zero of="$BLK" bs=1M count=16 status=none
[ "$HAVE_FAT" = 1 ] && mkfs.fat -F 16 "$BLK" >/dev/null 2>&1
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"; WAV="$(mktemp --suffix=.wav)"
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$BLK" "$LOG" "$WAV"
}
trap cleanup EXIT
qemu-system-i386 -drive format=raw,file="$IMG" -nographic \
  -audiodev none,id=a0 -device intel-hda -device hda-duplex,audiodev=a0 \
  -drive id=vd,file="$BLK",if=none,format=raw -device virtio-blk-pci,drive=vd \
  <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
printf 'run rec test\r' >&3; sleep 4        # capture running, ~1/s diagnostics
printf 'r' >&3; sleep 3                      # record ~3 s of the test signal
printf 'r' >&3; sleep 1                      # stop
printf 'p' >&3; sleep 5                      # play it back (3 s + lead)
printf 's' >&3; sleep 5                      # save REC.WAV to the virtio-blk FAT
printf 'q' >&3; sleep 2
printf '\r' >&3; sleep 1                     # the keys also typed into the shell line: flush it
printf 'echo still-alive\r' >&3; sleep 2
printf 'halt\r' >&3; sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

echo "==== rec output ===="
sed 's/\r//g' "$LOG" | grep -E "audio:|rec:|still-alive" || echo "(no rec output)"
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "audio: codec [0-9a-f]+ cad [0-9] afg [0-9]+ dac [0-9]+ out-pin [0-9]+ adc [1-9][0-9]* in-pin [1-9][0-9]*" "codec walked: DAC/out-pin AND ADC/in-pin (capture path) found"
chk "rec: capture running \(adc [1-9]"               "input stream programmed and started"
chk "rec: t=[0-9]+ in-lpib=[1-9][0-9]* chunks=[1-9][0-9]*" "input DMA position advances (LPIB) and chunks arrive"
chk "rec: recording"                                 "R starts a take"
chk "rec: stopped, [1-9][0-9]{4,} frames, peak [1-9][0-9]{3,}" "take holds >= 10k frames of NON-silent samples"
chk "rec: playing"                                   "P starts playback through the output ring"
chk "rec: playback done, out-lpib=[1-9]"             "output DMA streamed the take (LPIB advanced)"
chk "rec: quit \(recorded [1-9][0-9]*.*overruns 0"   "clean quit (Q), no capture overruns"
chk "still-alive"                                    "shell keeps responding afterwards"
if [ "$HAVE_FAT" = 1 ]; then
  chk "rec: saved REC.WAV \([1-9][0-9]* bytes\)"     "S wrote REC.WAV through the FAT layer"
  mtype -i "$BLK" ::/REC.WAV > "$WAV" 2>/dev/null
  RES="$(python3 - "$WAV" <<'PY'
import sys, struct
try:
    d = open(sys.argv[1], "rb").read()
    ok_hdr = d[:4] == b"RIFF" and d[8:16] == b"WAVEfmt " and d[36:40] == b"data"
    fmt, ch, rate, _, _, bps = struct.unpack_from("<HHIIHH", d, 20)
    n = struct.unpack_from("<I", d, 40)[0]
    pcm = struct.unpack_from("<%dh" % (min(n, len(d) - 44) // 2), d, 44)
    peak = max(abs(s) for s in pcm) if pcm else 0
    print(f"hdr={int(ok_hdr)} fmt={fmt} ch={ch} rate={rate} bits={bps} data={n} file={len(d)} peak={peak} "
          f"len_ok={int(len(d) == 44 + n and n >= 20000)} sig_ok={int(peak > 4000)}")
except Exception as e:
    print("err", e)
PY
)"
  echo "  host reads ::/REC.WAV: $RES"
  echo "$RES" | grep -q "hdr=1 fmt=1 ch=1 rate=48000 bits=16" && a=1 || a=0
  [ "$a" = 1 ] && echo "OK   : WAV header: PCM 48 kHz mono 16-bit" || { echo "FAIL : WAV header"; fail=1; }
  echo "$RES" | grep -q "len_ok=1" && b=1 || b=0
  [ "$b" = 1 ] && echo "OK   : WAV data length matches the file (real FAT write)" || { echo "FAIL : WAV length"; fail=1; }
  echo "$RES" | grep -q "sig_ok=1" && c=1 || c=0
  [ "$c" = 1 ] && echo "OK   : the WAV holds the captured signal (non-silent)" || { echo "FAIL : WAV silent"; fail=1; }
else
  echo "SKIP : mkfs.fat/mtools missing - WAV round-trip not checked"
fi
[ "$fail" -eq 0 ] && echo "==== REC OK ====" || { echo "==== REC FAILED ===="; sed 's/\r//g' "$LOG" | tail -25; }
exit $fail
