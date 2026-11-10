#!/usr/bin/env bash
# ============================================================
#  TannX OS wish loop - the host half, closed.
#  Harvests wishes over UDP (wishd) and, when a NEW one lands,
#  announces it, lets it be built, then SHIPS it to the test PC
#  and confirms - the OS wishes, the host delivers, hands-off.
#
#  The build step is where the LLM lives, so it is pluggable:
#    ./wish-loop.sh                       # announce, wait for Enter, ship
#    BUILD_HOOK="./mybuild.sh" ./wish-loop.sh   # auto: run hook, then ship
#  A hook gets the wish text as $1; it should edit/build the source.
#  When the Claude Code CLI (`claude`) is on PATH and BUILD_HOOK is unset,
#  the hook defaults to tools/claude/build-wish.sh (docs/CLAUDE-CODE.md);
#  BUILD_HOOK= (set, empty) keeps the manual announce-and-Enter mode.
#
#  Needs a kernel built with REMOTE_CTL=1 and a trusted LAN; the
#  queue file lives in the repository root (wish-queue.txt).
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lan-env.sh"
cd "$REPO_ROOT"
QUEUE="${AGENTOS_WISH_QUEUE:-wish-queue.txt}"
export AGENTOS_WISH_QUEUE="$QUEUE"
touch "$QUEUE"
if [ -z "${BUILD_HOOK+set}" ] && command -v claude >/dev/null 2>&1; then
  BUILD_HOOK="$REPO_ROOT/tools/claude/build-wish.sh"
fi

if ! pgrep -f "[w]ishd" >/dev/null 2>&1; then
  "$HERE/wishd.sh" >/tmp/agentos-wishd.log 2>&1 &
  echo "[wish-loop] started wishd (UDP :4711, log /tmp/agentos-wishd.log)"
fi
echo "[wish-loop] watching $QUEUE - wish on the test PC with 'netwish <text>'"
seen=$(wc -l < "$QUEUE")
while true; do
  now=$(wc -l < "$QUEUE")
  if [ "$now" -gt "$seen" ]; then
    wish="$(sed -n "$((seen+1))p" "$QUEUE")"
    seen=$now
    [ -z "$wish" ] && continue
    echo "=================================================="
    echo "[wish-loop] NEW WISH: $wish"
    if [ -n "${BUILD_HOOK:-}" ]; then
      echo "[wish-loop] build hook: $BUILD_HOOK"
      "$BUILD_HOOK" "$wish" || { echo "[wish-loop] hook failed; not shipping"; continue; }
    else
      read -rp "[wish-loop] build it, then Enter to ship (s=skip): " a
      [ "$a" = "s" ] && { echo "[wish-loop] skipped"; continue; }
    fi
    "$HERE/ship.sh"
  fi
  sleep 2
done
