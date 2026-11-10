#!/usr/bin/env bash
# ============================================================
#  TannX OS wish bridge - the host end of the serial wire.
#  The serial console IS this OS's internet. This script is the
#  counterpart to the kernel's 'sendwishes': it listens on a serial
#  line, logs everything, and harvests the framed wish block
#  (<<AGENTOS-WISHES ... AGENTOS-END) into a queue file the LLM reads.
#
#  Usage:
#    ./wish-bridge.sh [/dev/ttyUSB0]          listen + harvest (Ctrl-C quits)
#    ./wish-bridge.sh --send "cmd" [dev]      type one command into the OS
#
#  Wire: null-modem cable from the target PC's COM1 to a USB-serial
#  adapter here. 115200 8N1, same as the kernel's serial_init.
#  The harvested queue (wish-queue.txt) feeds 'make wishes'/the LLM.
# ============================================================
set -u
DEV="${1:-/dev/ttyUSB0}"
BAUD=115200
QUEUE="wish-queue.txt"
LOG="wish-bridge.log"

if [ "${1:-}" = "--send" ]; then
  CMD="${2:?command missing}"
  DEV="${3:-/dev/ttyUSB0}"
  [ -e "$DEV" ] || { echo "serial device not found: $DEV"; exit 2; }
  stty -F "$DEV" $BAUD cs8 -cstopb -parenb raw -echo 2>/dev/null
  # char by char + CR, like test.sh - the kernel polls COM1 between keys
  for ((i = 0; i < ${#CMD}; i++)); do printf '%s' "${CMD:$i:1}" > "$DEV"; sleep 0.02; done
  printf '\r' > "$DEV"
  echo "sent: $CMD"
  exit 0
fi

[ -e "$DEV" ] || { echo "serial device not found: $DEV (plug in the adapter?)"; exit 2; }
stty -F "$DEV" $BAUD cs8 -cstopb -parenb raw -echo 2>/dev/null

echo "wish bridge listening on $DEV @ $BAUD - Ctrl-C to stop."
echo "  log:   $LOG"
echo "  queue: $QUEUE   (type 'sendwishes' in the OS to harvest)"
echo

infield=0
# read the serial stream line by line, strip CR, tee to the log
stdbuf -oL tr -d '\r' < "$DEV" | tee -a "$LOG" | while IFS= read -r line; do
  case "$line" in
    "<<AGENTOS-WISHES") infield=1; echo "[bridge] harvesting wishes..." ;;
    "AGENTOS-END")      infield=0; echo "[bridge] done -> $QUEUE" ;;
    WISH:*)
      if [ "$infield" = 1 ]; then
        text="${line#WISH:}"
        # de-dupe: only append wishes we have not queued before
        if ! grep -qxF "$text" "$QUEUE" 2>/dev/null; then
          echo "$text" >> "$QUEUE"
          echo "[bridge] + $text"
        fi
      fi ;;
  esac
done
