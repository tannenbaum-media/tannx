#!/usr/bin/env bash
# ============================================================
#  Synthesizer + system-sound test. 'run synth test' auto-plays the demo
#  score (notes, a chord, waveform changes) and prints diagnostics; the
#  gate cannot hear, so it asserts the OUTPUT ring streams (LPIB), the mix
#  is non-silent (peak), the ring never underruns, notes/waveforms cycle,
#  and ESC quits cleanly. Then `beep` must route through the HDA codec
#  when a controller is present (ring-3 'run beep'), and a `make CHIME=1`
#  kernel must play the boot chime by itself.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
LOG="$(mktemp)"; LOG2="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$LOG" "$LOG2"
}
trap cleanup EXIT
boot() {   # $1 = image, $2 = log
  qemu-system-i386 -drive format=raw,file="$1" -nographic \
    -audiodev none,id=a0 -device intel-hda -device hda-duplex,audiodev=a0 \
    <"$FIFO" >"$2" 2>/dev/null &
  QPID=$!
  exec 3>"$FIFO"
  sleep 4
}
stop() { exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""; }

boot "$IMG" "$LOG"
printf 'run synth test\r' >&3; sleep 8       # the demo score: arpeggio, chord, TAB -> square/saw
printf 'Q' >&3; sleep 2                      # shift-Q quits (a lone ESC is held by the serial ISR)
printf '\r' >&3; sleep 1                     # the Q also sits in the shell line: flush it
printf 'beep\r' >&3; sleep 3                 # HDA present -> ring-3 beep
printf 'echo still-alive\r' >&3; sleep 2
printf 'halt\r' >&3; sleep 1
stop

# boot chime: a CHIME=1 kernel launches 'run chime' at boot (no keys typed)
make CHIME=1 agentos32.img >/dev/null 2>&1 && cp agentos32.img "$IMG" && CH=1 || CH=0
make agentos32.img >/dev/null 2>&1          # restore the default kernel for the next suite
if [ "$CH" = 1 ]; then
  boot "$IMG" "$LOG2"
  sleep 3
  printf 'echo chime-shell-ok\r' >&3; sleep 2
  printf 'halt\r' >&3; sleep 1
  stop
fi

echo "==== synth output ===="
sed 's/\r//g' "$LOG" | grep -E "synth:|Beep|still-alive" | head -40 || echo "(no synth output)"
[ "$CH" = 1 ] && { echo "==== chime boot ===="; sed 's/\r//g' "$LOG2" | grep -E "chime|run\]|shell-ok"; }
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$2"; then echo "OK   : $3"; else echo "FAIL : $3"; fail=1; fi; }
chk "synth: ready \(8 voices"                        "$LOG" "synthesizer starts on the HDA output path"
chk "synth: note C4 on, SINE KEYS"                   "$LOG" "demo score plays notes (C4, sine)"
chk "synth: note [A-G]#?[0-9] on, SQUARE"            "$LOG" "waveform cycles (TAB -> square)"
chk "synth: note [A-G]#?[0-9] on, SAW"               "$LOG" "waveform cycles again (saw)"
chk "synth: t=[0-9]+ out-lpib=[1-9][0-9]* chunks=[1-9][0-9]{2,} peak=[1-9][0-9]{3,}" "$LOG" "output DMA streams (LPIB), >=100 chunks mixed, non-silent peak"
UND="$(sed 's/\r//g' "$LOG" | grep -oE "underruns [0-9]+\)" | grep -oE "[0-9]+" | tail -1)"
echo "  underruns at quit: ${UND:-?}"
if [ -n "${UND:-}" ] && [ "$UND" -le 2 ]; then echo "OK   : Q quits; the ring kept ahead of the DMA (<=2 underruns)"; else echo "FAIL : quit/underruns"; fail=1; fi
chk "Beep! \(HDA\)"                                  "$LOG" "'beep' routes through the HDA codec when a controller is present"
chk "still-alive"                                    "$LOG" "shell keeps responding afterwards"
if [ "$CH" = 1 ]; then
  chk "chime: played \(HDA\)"                        "$LOG2" "CHIME=1 kernel plays the boot chime by itself"
  chk "chime-shell-ok"                               "$LOG2" "shell is usable after the boot chime"
else
  echo "FAIL : make CHIME=1 build"; fail=1
fi
[ "$fail" -eq 0 ] && echo "==== SYNTH OK ====" || { echo "==== SYNTH FAILED ===="; sed 's/\r//g' "$LOG" | tail -25; }
exit $fail
