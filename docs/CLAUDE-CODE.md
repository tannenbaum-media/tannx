# Build it with Claude Code

TannX OS ships with a ready-made integration for
[Claude Code](https://docs.claude.com/en/docs/claude-code), Anthropic's
coding agent CLI. It closes the wish loop on one machine: you boot the OS
in QEMU, type what software you want at the `tannx>` prompt, Claude Code
builds it in this repository, the test gate runs, and the OS reboots with
the new feature in it.

```
 +------------- TannX OS in QEMU --------------+
 |  tannx> diskon                                    |
 |  tannx> wish a command that shows a clock         |   disk slot (LBA 265-272)
 |  (or: netwish <text>, or the desktop wish field)   |   or UDP -> 127.0.0.1:4711
 +----------------------------------------------------+
                 |  tools/claude/wish-loop.sh notices the wish, stops the VM
                 v
   tools/claude/build-wish.sh "<wish>"
     git switch -c wish/<slug>
     claude -p "<wish + CLAUDE.md rules>"  (restricted permissions)
     make test32 on the agent's commits    (the hook's own gate)
                 |  green: stay on the branch     red: back, branch kept
                 v
   clear the slot, make agentos32.img live32, boot the new image
```

## Setup

1. Build prerequisites as in the README quickstart (binutils, gcc,
   python3, qemu-system-x86, mtools).
2. Install Claude Code and log in once, interactively:

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash    # or: npm install -g @anthropic-ai/claude-code
   claude                                            # log in (Claude account or API key), then /exit
   claude --version
   ```

   Headless runs use the same login. With an API key instead, export
   `ANTHROPIC_API_KEY` before starting the loop.
3. Commit or stash your own changes - the loop refuses to start on a
   dirty working tree (every wish becomes a commit on its own branch).

## Use

```bash
make wish-loop               # builds, boots the live image, waits for wishes
```

In the OS window:

```
tannx> diskon
tannx> wish a command that prints a fir tree
```

`netwish <text>` and the wish field of the desktop work too (no `diskon`
needed; the OS may print "no ack" - the loop received it anyway). The
console shows each phase: wish received, VM stopped, Claude Code's steps
(one line per tool call), the gate, slot cleared, rebuild, reboot. When
the VM is back, try the new command. Closing the QEMU window or Ctrl-C
ends the loop.

Without a display (SSH, server) the VM runs headless with VNC on
`127.0.0.1:5905`; type into its serial console from a second terminal:

```bash
HEADLESS=1 make wish-loop
tools/claude/wish-loop.sh --send "netwish a command that counts to ten"
```

One wish without the VM:

```bash
tools/claude/build-wish.sh "a command that prints the uptime in minutes"
DRY_RUN=1 tools/claude/build-wish.sh "..."   # only print the claude command line
make wish-dry-run WISH="..."                 # the same via make
```

The LAN loop for a real test PC (`tools/lan/wish-loop.sh`, wishes via
`netwish` + `wishd`, delivery via `ship.sh`) uses `build-wish.sh` as its
build hook automatically when `claude` is on PATH; `BUILD_HOOK=` (empty)
keeps its manual mode.

### Knobs

| Variable | Default | Meaning |
|---|---|---|
| `WISH_GATE` | `make test32` | gate the hook re-runs on the agent's commits |
| `WISH_MODEL` | CLI default | `--model` for the agent (e.g. `sonnet`, `opus`) |
| `WISH_TIMEOUT` | `3600` | seconds before an agent run is cut off |
| `WISH_BUDGET_USD` | unset | `--max-budget-usd` cap per wish (API-key billing) |
| `WISH_RESTRICTED` | `1` | pass `--restricted` (see below); `0` = dontAsk only |
| `CLAUDE_BIN` | `claude` | the CLI binary |
| `BUILD_HOOK` | `tools/claude/build-wish.sh` | any command that takes the wish as `$1` |
| `HEADLESS` / `VNC` | auto / `5` | no window; VNC display number or `none` |
| `POLL` | `2` | seconds between wish checks |

## What the agent may do

`build-wish.sh` runs, in the repository root:

```
claude -p "<prompt>" \
  --permission-mode dontAsk \
  --allowedTools "Read(./**)" "Edit(./**)" "Write(./**)" Glob Grep \
                 "Bash(make *)" "Bash(make)" "Bash(./test*.sh)" "Bash(./test*.sh *)" \
                 "Bash(./wishes.sh)" "Bash(bash -n *)" \
                 "Bash(git status*)" "Bash(git diff*)" "Bash(git log*)" "Bash(git show*)" \
                 "Bash(git add *)" "Bash(git commit *)" "Bash(ls*)" "Bash(wc *)" "Bash(nm *)" \
                 "Bash(chmod +x ./test*.sh)" "Bash(chmod +x test*.sh)" \
  --disallowedTools WebFetch WebSearch "Bash(git push*)" "Bash(git add -A*)" "Bash(git add .*)" \
                 "Bash(git checkout*)" "Bash(git switch*)" "Bash(git reset*)" "Bash(git rebase*)" \
                 "Bash(sudo *)" "Bash(curl *)" "Bash(wget *)" "Bash(./wishes.sh --clear*)" \
  --output-format stream-json --verbose \
  --restricted --tools "Read,Edit,Write,Glob,Grep,Bash"
```

- `dontAsk`: nothing prompts; whatever is not on the allow list is denied.
- `--restricted`: only the listed built-in tools exist, file tools are
  confined to the repository, user/project settings files are ignored (so
  a wish branch cannot widen its own permissions via `.claude/settings.json`)
  and permission bypass is refused.
- The prompt names the wish, points at `CLAUDE.md` (the agent manual:
  build, gate, rules, where things live, how to build a wish safely) and
  requires a new shell command or ring-3 program, a headless test where
  possible, a green `make test32` and a commit on `wish/<slug>`.
- After the agent, the hook checks that it stayed on its branch and made
  at least one commit, stashes stray uncommitted files, and runs
  `WISH_GATE` itself. Only green ships; red switches back and leaves
  `wish/<slug>` for inspection.
- Every wish gets `wish-logs/<time>-<slug>.log` (readable) and `.jsonl`
  (raw stream, including the session id for `claude --resume`). Both,
  like `.wish-loop/` (serial logs, history), are gitignored.

## Safety notes

- **Local only.** The loop runs QEMU with user networking on your machine.
  The wish listener binds `127.0.0.1:4711`, so no other host on the LAN
  can inject a wish (and with it, a prompt).
- **Edits only this repository, never pushes.** Wishes stack: each branch
  starts from the one the VM was running. Nothing is merged. Review a
  branch before merging it: `git log -p <base>..wish/<slug>`, then run
  `make test-all` on it.
- **`make` runs code.** The agent may edit the Makefile and the test
  scripts, and `Bash(make *)` then runs them - as you, with your files.
  The permission set keeps an honest agent on track; it is not a sandbox
  against a malicious one. For untrusted wishes run the loop in a VM or
  container, or enable Claude Code's sandboxing in managed settings.
- The wish text goes into the prompt verbatim. Only you type wishes into
  your VM - keep it that way.

## Costs and usage

Each wish is a full agent session: reading `CLAUDE.md` and the relevant
code, editing, building and running QEMU suites, often several dozen
turns. On a Claude subscription it counts against your usage limits; with
an API key it is billed per token - set `WISH_BUDGET_USD` to cap a single
wish and `WISH_MODEL` to choose a cheaper model. `make test-wish-loop` and
`DRY_RUN=1` make no model calls at all.

## Testing the integration

```bash
make wish-dry-run        # prints the exact claude command, changes nothing
make test-wish-loop      # e2e with a stub claude in a throwaway clone (headless, ~8 min)
```

`test-wish-loop` boots the VM, sends a `netwish` and a disk `wish`,
checks that each reaches the hook, lands as one commit on its own
`wish/<slug>` branch behind a green `make test32`, that the slot is
cleared and the VM comes back with the rebuilt image, and then exercises
the failure paths (agent error, red gate, dirty tree). It is not part of
`test-all`.
