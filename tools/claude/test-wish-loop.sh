#!/usr/bin/env bash
# ============================================================
#  test-wish-loop: the Claude Code wish loop, end to end, with a STUB
#  'claude' on PATH (tools/claude/stub/claude) - no model calls, headless.
#
#  In a throwaway clone of this repository (your tree is not touched):
#    boot #1  'netwish greet the forest'       -> net wire  -> hook -> rebuild
#    boot #2  'diskon' + 'wish count the trees' -> disk slot -> hook -> rebuild
#    boot #3  must come up; the slot must be cleared
#  then the hook's failure paths directly: agent error, red gate, dirty tree.
#  Each successful hook run re-runs the gate (TEST_GATE, default
#  `make test32`), so this takes a few minutes.
#  KEEP=1 keeps the scratch directory for inspection.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tannx-wishloop.XXXXXX")"
W="$TMP/repo"
LOOP_PID=""
fail=0

cleanup() {
  if [ -n "$LOOP_PID" ]; then kill -TERM "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null; fi
  if [ "${KEEP:-0}" = 1 ]; then echo "(kept: $TMP)"; else rm -rf "$TMP"; fi
}
trap cleanup EXIT

ok()   { echo "OK   : $*"; }
miss() { echo "FAIL : $*"; fail=1; }
check() { if eval "$1"; then ok "$2"; else miss "$2"; fi; }
wait_for() {  # wait_for <file> <fixed string> <seconds>
  local t=0
  until grep -aqF -- "$2" "$1" 2>/dev/null; do
    sleep 1; t=$((t+1))
    [ "$t" -ge "$3" ] && { echo "TIMEOUT waiting for '$2' in $1"; return 1; }
  done
  return 0
}
G() { git -C "$W" "$@"; }

# --- throwaway clone with the CURRENT working-tree versions of the files ---
echo "[test] scratch clone in $W"
git clone -q "$REPO" "$W" || exit 1
(cd "$REPO" && git ls-files -co --exclude-standard -z | xargs -0 -r ls -d 2>/dev/null \
   | tr '\n' '\0' | tar --null -T - -cf -) | tar -C "$W" -xf -
G config user.name "wish-loop test"; G config user.email "test@tannx.invalid"
G ls-files -mo --exclude-standard -z | (cd "$W" && xargs -0 -r git add --)
G diff --cached --quiet || G commit -q -m "test overlay: working-tree state"
base_branch="$(G symbolic-ref --short HEAD)"

mkdir -p "$TMP/bin"; cp "$HERE/stub/claude" "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"
export STUB_ARGV_LOG="$TMP/argv.txt"
export WISH_GATE="${TEST_GATE:-make test32}"

# --- the loop -----------------------------------------------------------
(cd "$W" && HEADLESS=1 VNC=none POLL=1 exec tools/claude/wish-loop.sh) >"$TMP/loop.log" 2>&1 &
LOOP_PID=$!
R="$W/.wish-loop"
send() { (cd "$W" && tools/claude/wish-loop.sh --send "$1"); sleep 1; }

echo "[test] boot #1 ..."
wait_for "$R/serial-1.log" "tannx> " 120 || { tail -n 30 "$TMP/loop.log"; exit 1; }
send "netwish greet the forest"
echo "[test] net wish sent - hook + gate running ..."
wait_for "$R/serial-2.log" "tannx> " 900 || { tail -n 40 "$TMP/loop.log"; exit 1; }
echo "[test] boot #2 up - typing a disk wish"
send "diskon"
send "wish count the trees"
wait_for "$R/serial-2.log" "Wish stored on disk" 20
wait_for "$R/serial-3.log" "tannx> " 900 || { tail -n 40 "$TMP/loop.log"; exit 1; }
echo "[test] boot #3 up"
sleep 2
kill -TERM "$LOOP_PID"; wait "$LOOP_PID" 2>/dev/null; LOOP_PID=""

echo "==== wish loop console ===="
grep -E '^(====|\[wish-loop\]|\[build-wish\])' "$TMP/loop.log" | sed 's/^/  /'
echo "==== checks ===="
check 'grep -q "WISH (net): greet the forest" "$TMP/loop.log"'   "net wish (netwish over QEMU user net) reached the loop"
check 'grep -q "WISH (disk): count the trees" "$TMP/loop.log"'   "disk wish (wish slot in the live image) was harvested"
check 'G show-ref -q --verify refs/heads/wish/greet-the-forest'  "hook created branch wish/greet-the-forest"
check 'G show-ref -q --verify refs/heads/wish/count-the-trees'   "hook created branch wish/count-the-trees"
check 'G merge-base --is-ancestor wish/greet-the-forest wish/count-the-trees' "wish branches stack (2nd built on the 1st)"
check '[ "$(G symbolic-ref --short HEAD)" = wish/count-the-trees ]' "the loop runs the newest wish branch"
check '[ "$(G show wish/count-the-trees:wish-stub.txt)" = "$(printf "greet the forest\ncount the trees")" ]' "both stub changes are committed"
check '[ "$(G rev-list --count "$base_branch..wish/count-the-trees")" = 2 ]' "exactly one commit per wish"
check '(cd "$W" && ./wishes.sh agentos32-live.img | grep -q "no pending wishes")' "wish slot cleared in the live image"
check '[ "$(grep -c "built on" "$R/history.txt")" = 2 ]'         "history.txt logs both wishes as built"
check '[ "$(grep -l GREEN "$W"/wish-logs/*.log | wc -l)" = 2 ]'  "one log per wish under wish-logs/, both green"
check 'grep -q "phase 2/2: gate on the committed tree: $WISH_GATE" "$TMP/loop.log"' "the hook re-ran the gate itself"
check 'grep -q "restarting TannX OS with the new image" "$TMP/loop.log"' "VM restarted with the rebuilt image"
check '[ -z "$(G status --porcelain)" ]'                         "working tree clean after the loop"
check 'grep -qx -- "--permission-mode" "$STUB_ARGV_LOG" && grep -qx dontAsk "$STUB_ARGV_LOG"' "claude ran in dontAsk permission mode"
check 'grep -qxF -- "Bash(git push*)" "$STUB_ARGV_LOG"'           "git push is explicitly denied"
check 'grep -qx -- "--restricted" "$STUB_ARGV_LOG"'              "claude ran with --restricted"
check '! grep -qx -- "--dangerously-skip-permissions" "$STUB_ARGV_LOG"' "no permission bypass"

echo "==== hook failure paths ===="
H="tools/claude/build-wish.sh"
(cd "$W" && STUB_FAIL=1 $H "broken wish") >"$TMP/f1.log" 2>&1; rc=$?
check '[ $rc = 1 ] && G show-ref -q --verify refs/heads/wish/broken-wish && [ "$(G symbolic-ref --short HEAD)" = wish/count-the-trees ]' \
      "agent error: exit 1, branch kept, back on the previous branch"
(cd "$W" && WISH_GATE=false $H "red gate") >"$TMP/f2.log" 2>&1; rc=$?
check '[ $rc = 1 ] && [ "$(G rev-list --count wish/count-the-trees..wish/red-gate)" = 1 ] && [ "$(G symbolic-ref --short HEAD)" = wish/count-the-trees ]' \
      "red gate: exit 1, commit left on wish/red-gate, nothing shipped"
touch "$W/dirt.txt"
(cd "$W" && $H "dirty tree") >"$TMP/f3.log" 2>&1; rc=$?
check '[ $rc = 2 ] && ! G show-ref -q --verify refs/heads/wish/dirty-tree' "dirty tree: refused (exit 2), no branch"
rm -f "$W/dirt.txt"
out="$(cd "$W" && DRY_RUN=1 $H "dry run wish")"; rc=$?
check '[ $rc = 0 ] && grep -q -- "--allowedTools" <<<"$out" && ! G show-ref -q --verify refs/heads/wish/dry-run-wish' \
      "DRY_RUN=1 prints the command and changes nothing"

if [ "$fail" = 0 ]; then echo "==== WISH-LOOP OK ===="; else
  echo "---- loop log tail ----"; tail -n 40 "$TMP/loop.log"; echo "==== WISH-LOOP FAILED ===="; fi
exit "$fail"
