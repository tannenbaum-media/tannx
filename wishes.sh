#!/usr/bin/env bash
# ============================================================
#  TannX OS wish harvester - the LLM side of the 'wish' command.
#  Reads the wish slots (LBA 265-272, magic 'AW') out of TannX OS
#  disk images and prints them as prompts. Checks BOTH live
#  images by default - the wish loop works on the BIOS path
#  (agentos32-live.img) and the UEFI path (uefi-live.img, where
#  the slots live in the MBR gap before the ESP partition).
#  Usage: ./wishes.sh [image]              scan one image
#         ./wishes.sh --clear <n> [image]  clear slot n after building
# ============================================================
set -u

scan() {  # scan <image> -> prints pending wishes, returns 0 if any
  local img="$1" found=1 i off hdr len txt
  for i in 0 1 2 3 4 5 6 7; do
    off=$(( (265+i)*512 ))
    # header as hex via od - raw bytes in $() would trip over NUL bytes
    hdr=$(dd if="$img" bs=1 skip=$off count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$hdr" = "4157" ]; then    # 'A' 'W'
      len=$(dd if="$img" bs=1 skip=$((off+2)) count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
      txt=$(dd if="$img" bs=1 skip=$((off+3)) count="${len:-0}" 2>/dev/null)
      echo "$img wish[$i]: $txt"
      found=0
    fi
  done
  return $found
}

if [ "${1:-}" = "--clear" ]; then
  n="${2:?slot number missing}"
  img="${3:-agentos32-live.img}"
  [ -f "$img" ] || { echo "image not found: $img"; exit 2; }
  dd if=/dev/zero of="$img" bs=1 seek=$(( (265+n)*512 )) count=3 \
     conv=notrunc status=none
  echo "wish[$n] cleared in $img."
  exit 0
fi

if [ -n "${1:-}" ]; then
  IMAGES="$1"
else
  IMAGES=""
  [ -f agentos32-live.img ] && IMAGES="$IMAGES agentos32-live.img"
  [ -f uefi-live.img ]      && IMAGES="$IMAGES uefi-live.img"
  [ -z "$IMAGES" ] && IMAGES="agentos32.img"
fi

any=1
for img in $IMAGES; do
  [ -f "$img" ] || { echo "image not found: $img"; continue; }
  scan "$img" && any=0
done
[ "$any" -eq 1 ] && echo "no pending wishes in: $IMAGES"
exit 0
