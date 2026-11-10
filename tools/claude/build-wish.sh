#!/usr/bin/env bash
# ============================================================
#  TannX OS - build one wish with Claude Code.
#
#  The BUILD_HOOK of the wish loops (tools/claude/wish-loop.sh and
#  tools/lan/wish-loop.sh). Takes the wish text a user typed at the
#  tannx> prompt and lets Claude Code implement it, headless, in THIS
#  repository - on its own branch, behind the test gate:
#
#    1. refuses to start on a dirty working tree
#    2. creates branch wish/<slug> from the current HEAD
#    3. runs `claude -p` with a fixed prompt (the wish + CLAUDE.md) and a
#       restrictive permission set (file tools inside the repo, Bash only
#       for make / test scripts / read-only git / git add + commit)
#    4. re-runs the gate itself (WISH_GATE, default `make test32`) on the
#       committed tree - the agent's own claim is not trusted
#    5. green: stays on wish/<slug> (exit 0, the loop ships the new image)
#       red:   switches back, leaves wish/<slug> for inspection (exit 1)
#
#  Usage:  tools/claude/build-wish.sh "<wish text>"
#  Env:    DRY_RUN=1          print the claude command line, change nothing
#          CLAUDE_BIN=claude  the Claude Code CLI to run
#          WISH_MODEL=        model alias/name (default: the CLI's default)
#          WISH_GATE="make test32"   gate re-run after the agent finished
#          WISH_TIMEOUT=3600  seconds before the agent run is cut off
#          WISH_BUDGET_USD=   optional --max-budget-usd (API-key billing)
#          WISH_RESTRICTED=1  pass --restricted (0 = plain dontAsk mode)
#          WISH_LOG_DIR=wish-logs
#  Logs:   wish-logs/<time>-<slug>.log (readable) + .jsonl (raw stream)
#  Never pushes. Merging a wish branch is a human decision.
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "[build-wish] not inside a git repository" >&2; exit 2; }
cd "$REPO"

WISH="${1:-}"
[ -n "$WISH" ] || { echo "usage: $0 \"<wish text>\"" >&2; exit 2; }
WISH="$(printf '%s' "$WISH" | tr -d '\r' | tr '\n' ' ')"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
WISH_GATE="${WISH_GATE:-make test32}"
WISH_TIMEOUT="${WISH_TIMEOUT:-3600}"
WISH_RESTRICTED="${WISH_RESTRICTED:-1}"
LOG_DIR="${WISH_LOG_DIR:-wish-logs}"
DRY_RUN="${DRY_RUN:-0}"

say() { echo "[build-wish] $*"; }

# --- branch name: wish/<slug>, unique ----------------------------------
slug="$(printf '%s' "$WISH" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9]\{1,\}/-/g' \
        -e 's/^-//' | cut -c1-40 | sed -e 's/-$//')"
[ -n "$slug" ] || slug="wish"
branch="wish/$slug"; n=2
while git show-ref --verify --quiet "refs/heads/$branch"; do
  branch="wish/$slug-$n"; n=$((n+1))
done

# --- the prompt ---------------------------------------------------------
read -r -d '' PROMPT <<EOF
A user of TannX OS typed this wish at the tannx> prompt:

    WISH: $WISH

Build it. You are running headless inside the TannX OS repository,
on the branch $branch that was created for you from the current HEAD.

1. Read CLAUDE.md first and follow it - it is the operating manual
   (build, test gate, iron rules, where things live, how to build a wish).
   Read docs/ARCHITECTURE.md before touching the kernel or the ABI.
2. Implement the wish as a NEW shell command or a NEW ring-3 program in
   user/ (see CLAUDE.md, "Building a wish"). Prefer a ring-3 program when
   the wish fits one. Keep the change small and focused on this one wish.
3. Add a headless check for it (a test-<name>.sh driven over the serial
   console, plus a Makefile target) when it can be tested in QEMU.
4. Keep the gate green: \`make test32\` is mandatory; also run the suites
   for the areas you touched (make test-<name>). Never weaken or delete a
   test to get green.
5. Commit with \`git add <files>\` (never -A or .) and \`git commit\`:
   English message, subject says what, body says why, and state that it
   was verified in QEMU only. Leave the working tree clean.
6. Log the wish in docs/HISTORY.md, Part 3 (date | wish | result), in
   the same commit.

Hard limits: work only inside this repository; no network access, no
sudo, no git push, no branch switching, rebase or reset, and do not run
./wishes.sh --clear (the wish loop manages the slots). Bash is limited to
make, ./test*.sh, chmod +x on test scripts, read-only git and git add /
commit: run ONE plain command per Bash call (no pipes, &&, heredocs or
redirections - they are denied) and create files with the Write tool. If the wish is
impossible, unsafe or too big for one session, do not fake it: commit
only a short plan in ROADMAP.md and say so.

End with a short summary: what you built, how to use it at the tannx>
prompt, and which tests you ran with their result.
EOF

# --- permission set -----------------------------------------------------
# dontAsk: everything that is not explicitly allowed below is denied
# (there is nobody to answer a prompt). Paths are relative to the repo.
ALLOWED=(
  "Read(./**)" "Edit(./**)" "Write(./**)" "Glob" "Grep"
  "Bash(make *)" "Bash(make)" "Bash(./test*.sh)" "Bash(./test*.sh *)"
  "Bash(./wishes.sh)" "Bash(bash -n *)"
  "Bash(git status*)" "Bash(git diff*)" "Bash(git log*)" "Bash(git show*)"
  "Bash(git add *)" "Bash(git commit *)"
  "Bash(ls*)" "Bash(wc *)" "Bash(nm *)" "Bash(chmod +x ./test*.sh)" "Bash(chmod +x test*.sh)"
)
DENIED=(
  "WebFetch" "WebSearch" "Bash(git push*)" "Bash(git add -A*)" "Bash(git add .*)"
  "Bash(git checkout*)" "Bash(git switch*)" "Bash(git reset*)" "Bash(git rebase*)"
  "Bash(sudo *)" "Bash(curl *)" "Bash(wget *)" "Bash(./wishes.sh --clear*)"
)
CMD=("$CLAUDE_BIN" -p "$PROMPT"
     --permission-mode dontAsk
     --allowedTools "${ALLOWED[@]}"
     --disallowedTools "${DENIED[@]}"
     --output-format stream-json --verbose)
[ "$WISH_RESTRICTED" = 1 ] && CMD+=(--restricted --tools "Read,Edit,Write,Glob,Grep,Bash")
[ -n "${WISH_MODEL:-}" ] && CMD+=(--model "$WISH_MODEL")
[ -n "${WISH_BUDGET_USD:-}" ] && CMD+=(--max-budget-usd "$WISH_BUDGET_USD")

if [ "$DRY_RUN" = 1 ]; then
  say "DRY RUN - nothing is changed. Would create branch: $branch"
  say "gate after the agent: $WISH_GATE"
  say "command:"
  printf '  %q' "${CMD[@]}"; echo
  exit 0
fi

# --- preconditions --------------------------------------------------------
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || {
  say "Claude Code CLI '$CLAUDE_BIN' not found - see docs/CLAUDE-CODE.md"; exit 2; }
if [ -n "$(git status --porcelain)" ]; then
  say "working tree is dirty - commit or stash first, refusing to build:"
  git status --short | sed 's/^/    /'
  exit 2
fi
orig="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
base="$(git rev-parse HEAD)"

mkdir -p "$LOG_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/$stamp-${slug}.log"
RAW="$LOG_DIR/$stamp-${slug}.jsonl"
log() { echo "[build-wish] $*" | tee -a "$LOG"; }

# git needs an identity for the agent's commits
if [ -z "$(git config user.email)" ]; then
  export GIT_AUTHOR_NAME="TannX wish" GIT_AUTHOR_EMAIL="wish@tannx.invalid"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
fi

log "wish:   $WISH"
log "branch: $branch (from $orig @ ${base:0:10})"
log "log:    $LOG"
git switch -q -c "$branch" || { log "cannot create $branch"; exit 1; }

fail() {  # leave the branch for inspection, go back where we came from
  log "FAILED: $*"
  log "the branch $branch is kept for inspection: git log -p $orig..$branch"
  if [ -n "$(git status --porcelain)" ]; then
    git stash push -q -u -m "$branch leftovers" && log "uncommitted leftovers stashed (git stash list)"
  fi
  git switch -q "$orig" 2>/dev/null || git checkout -q "$orig"
  log "back on $orig - nothing shipped."
  exit 1
}

# --- phase 1: the agent ---------------------------------------------------
log "phase 1/2: Claude Code is building the wish (timeout ${WISH_TIMEOUT}s) ..."
{ printf '%q -p <prompt>' "$CLAUDE_BIN"; printf ' %q' "${CMD[@]:3}"; echo; } >>"$LOG"
timeout --foreground "$WISH_TIMEOUT" "${CMD[@]}" </dev/null 2>&1 \
  | tee "$RAW" | python3 "$HERE/stream-view.py" | tee -a "$LOG"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || fail "claude exited with $rc"

cur="$(git symbolic-ref --quiet --short HEAD || echo detached)"
[ "$cur" = "$branch" ] || fail "the agent left the branch (now on $cur)"
commits=$(git rev-list --count "$base..HEAD")
[ "$commits" -ge 1 ] || fail "the agent made no commit"
if [ -n "$(git status --porcelain)" ]; then
  log "warning: uncommitted leftovers - stashed, the gate runs on the commits only"
  git status --short | sed 's/^/    /' | tee -a "$LOG"
  git stash push -q -u -m "$branch leftovers"
fi
log "agent made $commits commit(s):"
git log --oneline "$base..HEAD" | sed 's/^/    /' | tee -a "$LOG"

# --- phase 2: our own gate -----------------------------------------------------
log "phase 2/2: gate on the committed tree: $WISH_GATE"
bash -c "$WISH_GATE" >>"$LOG" 2>&1
grc=$?
tail -n 5 "$LOG" | sed 's/^/    /'
[ "$grc" -eq 0 ] || fail "gate '$WISH_GATE' is red (exit $grc), see $LOG"

log "GREEN - $branch is ready. Review it before merging: git log -p $orig..$branch"
exit 0
