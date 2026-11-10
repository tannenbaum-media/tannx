#!/usr/bin/env bash
# ============================================================
#  TannX OS - the local wish loop: type a wish, get the software.
#
#  Everything on ONE machine, no LAN, no test PC:
#    1. builds the image and boots the live image in QEMU
#       (a window when there is a display, else headless + VNC)
#    2. watches for wishes from the running OS on two wires:
#         - disk:  `wish <text>` (after `diskon`) writes a slot at
#                  LBA 265-272 of agentos32-live.img - harvested with
#                  wishes.sh while the VM runs
#         - net:   `netwish <text>` and the desktop's wish field send a
#                  UDP datagram; QEMU's user network hands it to
#                  127.0.0.1:4711, where this loop listens (loopback only)
#    3. per wish: stops the VM, runs the BUILD_HOOK (default
#       tools/claude/build-wish.sh = Claude Code on branch wish/<slug>),
#       clears the slot, rebuilds, boots the VM again with the new image
#
#  Usage:  tools/claude/wish-loop.sh            (or: make wish-loop)
#          tools/claude/wish-loop.sh --send "<line>"   type a line into
#                                               the running VM's console
#  Env:    BUILD_HOOK=<cmd>   hook that gets the wish text as $1
#          HEADLESS=1         no window (default when DISPLAY is unset)
#          VNC=5              headless VNC display :5 (port 5905), none = off
#          POLL=2             seconds between wish checks
#          WISH_RUN_DIR=.wish-loop   serial logs, sockets, history
#          QEMU_EXTRA="..."   extra qemu-system-i386 arguments
#  Wish branches stack: each one starts from the branch the VM is running.
#  Nothing is merged or pushed - review the wish/* branches yourself.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "[wish-loop] not inside a git repository" >&2; exit 2; }
cd "$REPO"

RUN="${WISH_RUN_DIR:-.wish-loop}"
IMG="agentos32-live.img"
POLL="${POLL:-2}"
BUILD_HOOK="${BUILD_HOOK:-$HERE/build-wish.sh}"
VNC="${VNC:-5}"
NET_PORT=4711
if [ -z "${HEADLESS:-}" ]; then
  HEADLESS=1
  { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; } && HEADLESS=0
fi
mkdir -p "$RUN"
SOCK="$RUN/serial.sock"

say()   { echo "[wish-loop] $*"; }
phase() { echo; echo "==== [wish-loop] $* ===="; }

# --- --send: type one line into the running VM (char by char + CR) -----
if [ "${1:-}" = "--send" ]; then
  line="${2:?line missing}"
  [ -S "$SOCK" ] || { say "no running wish-loop VM ($SOCK missing)"; exit 2; }
  exec python3 - "$SOCK" "$line" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
for c in sys.argv[2]:
    s.send(c.encode()); time.sleep(0.03)   # the kernel polls COM1 between keys
s.send(b"\r"); time.sleep(0.2); s.close()
PY
fi

for t in qemu-system-i386 make git python3; do
  command -v "$t" >/dev/null 2>&1 || { say "missing: $t"; exit 2; }
done
hook_bin="${BUILD_HOOK%% *}"
if [ "$hook_bin" = "$HERE/build-wish.sh" ] && ! command -v "${CLAUDE_BIN:-claude}" >/dev/null 2>&1; then
  say "Claude Code CLI not found (install: see docs/CLAUDE-CODE.md), or set BUILD_HOOK"
  exit 2
fi
if [ -n "$(git status --porcelain)" ]; then
  say "working tree is dirty - the build hook would refuse every wish. Commit or stash first."
  git status --short | sed 's/^/    /'
  exit 2
fi

QPID=""; NPID=""; BOOT=0; UP=0; NET_SEEN=0
NETQ="$RUN/net-queue.txt"
: > "$NETQ"

build_image() {
  say "building the image (make agentos32.img live32) ..."
  if make agentos32.img live32 >"$RUN/build.log" 2>&1; then
    say "image ready: $IMG"
  else
    tail -n 20 "$RUN/build.log" | sed 's/^/    /'; return 1
  fi
}

start_vm() {
  BOOT=$((BOOT+1)); UP=0
  SER="$RUN/serial-$BOOT.log"
  rm -f "$SOCK" "$SER"
  local disp=()
  if [ "$HEADLESS" = 1 ]; then
    disp=(-display none -monitor none)
    [ "$VNC" != none ] && disp+=(-vnc "127.0.0.1:$VNC")
  fi
  # shellcheck disable=SC2086
  qemu-system-i386 -drive format=raw,file="$IMG" \
    -netdev user,id=n0 -device rtl8139,netdev=n0 \
    -chardev socket,id=ser0,path="$SOCK",server=on,wait=off,logfile="$SER" \
    -serial chardev:ser0 "${disp[@]}" ${QEMU_EXTRA:-} \
    >"$RUN/qemu.log" 2>&1 &
  QPID=$!
  ln -sf "serial-$BOOT.log" "$RUN/serial.log"
  local how="window"
  [ "$HEADLESS" = 1 ] && how="headless${VNC:+, VNC 127.0.0.1:$VNC}"
  [ "$HEADLESS" = 1 ] && [ "$VNC" = none ] && how="headless, no VNC"
  say "VM boot #$BOOT ($how), pid $QPID, serial log $SER"
}

stop_vm() {
  [ -n "$QPID" ] || return 0
  kill -TERM "$QPID" 2>/dev/null
  wait "$QPID" 2>/dev/null
  QPID=""
  say "VM stopped"
}

start_net() {  # loopback UDP listener for netwish / the desktop wish field
  python3 -u - "$NET_PORT" "$NETQ" >"$RUN/net.log" 2>&1 <<'PY' &
import socket, sys
port, queue = int(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))          # loopback only: no LAN host can wish
last = None
while True:
    data, _ = s.recvfrom(2048)
    msg = data.decode("ascii", "replace").rstrip("\x00").strip()
    if not msg.startswith("AGENTOS-WISH: "):
        continue
    text = " ".join(msg[len("AGENTOS-WISH: "):].split())
    if not text or text == last:     # netwish re-sends until acked
        continue
    last = text
    with open(queue, "a") as f:
        f.write(text + "\n")
    print("+", text, flush=True)
PY
  NPID=$!
}

cleanup() {
  trap - EXIT INT TERM
  stop_vm
  [ -n "$NPID" ] && kill "$NPID" 2>/dev/null
  rm -f "$SOCK"
  say "bye."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

disk_wishes() {  # -> "<slot> <text>" lines
  ./wishes.sh "$IMG" | sed -n 's/^.* wish\[\([0-7]\)\]: /\1 /p'
}
net_wishes() {   # -> new lines of the net queue since the last call
  local n; n=$(wc -l <"$NETQ")
  [ "$n" -gt "$NET_SEEN" ] && sed -n "$((NET_SEEN+1)),${n}p" "$NETQ"
}

process_wish() {  # process_wish <disk|net> <slot|-> <text>
  local src="$1" slot="$2" text="$3" pre rc result
  pre="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
  phase "WISH ($src): $text"
  say "build hook: $BUILD_HOOK"
  "$BUILD_HOOK" "$text"
  rc=$?
  case $rc in
    0) result="built on $(git symbolic-ref --quiet --short HEAD)" ;;
    2) say "the hook refused to start (exit 2) - wish kept, stopping the loop"
       return 2 ;;
    *) result="FAILED (exit $rc)" ;;
  esac
  if [ "$src" = disk ]; then ./wishes.sh --clear "$slot" "$IMG" >/dev/null; fi
  say "wish slot cleared ($src${slot:+ $slot}) - result: $result"
  printf '%s | %s | %s | %s\n' "$(date '+%F %T')" "$src" "$text" "$result" >>"$RUN/history.txt"
  # the new tree must build; if not, go back to where we were
  if ! build_image; then
    say "the new tree does not build - back to $pre"
    git switch -q "$pre" 2>/dev/null || git checkout -q "$pre"
    build_image || return 1
  fi
  return 0
}

phase "TannX OS wish loop - repo $REPO, on $(git symbolic-ref --quiet --short HEAD || echo detached)"
say "build hook: $BUILD_HOOK"
build_image || exit 1
start_net
start_vm
say "type at the tannx> prompt:  diskon   then   wish <what you want>"
say "  (or netwish <text>, or the desktop wish field). Ctrl-C ends the loop."

while true; do
  sleep "$POLL"
  if [ -n "$QPID" ] && ! kill -0 "$QPID" 2>/dev/null; then
    QPID=""
    phase "the VM was closed - wish loop ends"
    exit 0
  fi
  if [ "$UP" = 0 ] && grep -aq 'tannx> ' "$SER" 2>/dev/null; then
    UP=1; say "TannX OS is up (boot #$BOOT) - waiting for wishes"
  fi
  dw="$(disk_wishes)"; nw="$(net_wishes)"
  [ -z "$dw$nw" ] && continue

  phase "new wish(es) - stopping the VM to build"
  stop_vm
  dw="$(disk_wishes)"                     # final read with the VM down
  NET_SEEN=$(wc -l <"$NETQ")
  stopped=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    process_wish disk "${l%% *}" "${l#* }" || { stopped=1; break; }
  done <<<"$dw"
  if [ "$stopped" = 0 ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      process_wish net "" "$l" || { stopped=1; break; }
    done <<<"$nw"
  fi
  [ "$stopped" = 1 ] && exit 1
  phase "restarting TannX OS with the new image (branch $(git symbolic-ref --quiet --short HEAD || echo detached))"
  start_vm
done
