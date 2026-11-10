#!/usr/bin/env bash
# ============================================================
#  Agents-language test (first cut). Saves a script
#  into an AgentFS slot, executes it with 'script <slot>' and checks the
#  statements ran in order: an agent pipeline computes (prime 100 = 541),
#  'sleep' paces, and a final echo proves the chain completed.
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }

make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

IMG="$(mktemp /tmp/agentos_scr_XXXX.img)"
cp agentos32.img "$IMG"

LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
qemu-system-i386 -drive format=raw,file="$IMG" -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
send() { local s="$1" i; for ((i=0;i<${#s};i++)); do printf '%s' "${s:$i:1}" >&3; sleep 0.02; done; printf '\r' >&3; }
sleep 4
send 'script 9'                 # bad slot -> usage
sleep 2
send 'repeat 2'                 # outside any script -> usage
sleep 1
send 'if x'                     # broken condition -> usage
sleep 1
send 'diskon'
sleep 1
send 'save 4 spawn prime, task prime 100, sleep 40, echo sdone'
sleep 1                         # (typed lines cap at LINEMAX=254 chars since v2.78)
send 'script 4'
sleep 10                        # spawn+claim+compute+sleep 40 ticks (~2.2s)+echo
# conditionals + repeat: task 0's result is 541 now; the slot runs twice
send 'save 5 if 0 = 541 echo y541, if 0 ! 541 echo n541, repeat 2'
sleep 1
send 'script 5'
sleep 4
# the register: interactive set/$ ...
send 'set 5'
sleep 1
send 'echo reg=$'
sleep 1
# register arithmetic: 20 +5=25 -3=22 *2=44 /4=11; then /0 is guarded (unchanged)
send 'set 20'
sleep 1
send 'set + 5'
sleep 1
send 'set - 3'
sleep 1
send 'set * 2'
sleep 1
send 'set / 4'
sleep 1
send 'echo ar=$'
sleep 1
send 'set / 0'
sleep 1
send 'echo dz=$'
sleep 1
# second register (setb / '#') + arithmetic, independent of register A (still 11)
send 'setb 100'
sleep 1
send 'setb + 50'                 # B = 150
sleep 1
send 'echo b2=# a2=$'            # -> b2=150 a2=11 (A untouched by setb)
sleep 1
# if branching on the registers directly (not just task results): A<100, B>100,
# and register-vs-register A != B
send 'if $ < 100 echo iflt'      # 11 < 100 -> fires
sleep 1
send 'if # > 100 echo ifgt'      # 150 > 100 -> fires
sleep 1
send 'if $ ! # echo ifne'        # 11 != 150 -> fires (register vs register)
sleep 1
send 'if $ = # echo ifeq'        # 11 == 150? no -> must NOT fire
sleep 1
# if task-vs-task: compare one agent result against another via @<task2>.
# reap -> fresh indices; count 50 = 1275 (task 0), prime 50 = 229 (task 1);
# 'if 0 > @1' fires (1275 > 229) -> cok.
send 'reap'
sleep 1
send 'spawn count'
sleep 1
send 'spawn prime'
sleep 1
send 'save 1 task count 50,task prime 50,waitall,if 0 > @1 echo cok'
sleep 1
send 'script 1'
sleep 8
# ... and the pipe: task 0's result (541) becomes task count's argument;
# sum 1..541 = 146611 proves the substitution really happened
send 'spawn count'
sleep 1
send 'save 6 set @0, task count $, sleep 60, if 1 = 146611 echo pipd'
sleep 1
send 'script 6'
sleep 8
# waittask: the DETERMINISTIC join - no 'sleep' guess, block until the task is done.
# reap clears the done tasks so the next 'task' is index 0 again (and frees the idle
# prime agent, so spawn a fresh one). 'wtok' prints ONLY if waittask really blocked
# until prime 200 = 1223 landed - if it didn't, 'if 0 = 1223' would see a stale 0.
send 'reap'
sleep 1
send 'spawn prime'
sleep 1
send 'save 3 task prime 200, waittask 0, if 0 = 1223 echo wtok'
sleep 1
send 'script 3'
sleep 8
# waitall: fan-out join - two agents, two tasks, ONE barrier. 'wj' is IN the chain
# right after waitall (no sleep), so it prints only if waitall blocked until the
# prime task landed (50th prime = 229). 'wk' (typed) confirms the 2nd task's result
# (count 50 = 1275). reap resets the task indices to 0/1. (kept dense from the old
# 62-char typed cap - harmless since the v2.78 raise to LINEMAX=254.)
send 'reap'
sleep 1
send 'spawn prime'
sleep 1
send 'spawn count'
sleep 1
send 'save 2 task prime 50,task count 50,waitall,if 0 = 229 echo wj'
sleep 1
send 'script 2'
sleep 8
send 'if 1 = 1275 echo wk'
sleep 2
# if <,>: threshold logic on a task result (task 1 = count 50 = 1275).
send 'if 1 > 1000 echo gt-y'      # 1275 > 1000 -> fires
sleep 1
send 'if 1 < 1000 echo lt-n'      # 1275 < 1000 -> does NOT fire
sleep 1
send 'if 1 < 2000 echo lt-y'      # 1275 < 2000 -> fires
sleep 1
send 'echo shell-lives'
sleep 2
send 'halt'
sleep 1
exec 3>&- 2>/dev/null
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO" "$IMG"

echo "==== script output ===="
sed 's/\r//g' "$LOG" | grep -E "usage: script|script-done|541|shell-lives|prime" | head -12
echo "==== checks ===="
fail=0
chk() { if grep -qE "$1" "$LOG"; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }
chk "usage: script"        "bad slot prints usage"
chk "usage: repeat"        "repeat outside a script prints usage"
chk "usage: if"            "broken if prints usage"
chk "prime\) agent ready"  "script statement 1: agent spawned"
chk "= 541"                "script pipeline computed (prime 100 = 541)"
chk "sdone"                "script ran to its last statement"
Y=$(grep -ac "^y541" <(sed 's/\r//' "$LOG"))
N=$(grep -ac "^n541" <(sed 's/\r//' "$LOG"))
if [ "$Y" -eq 2 ]; then echo "OK   : 'if 0 = 541' fired on both repeat rounds (y541 x2)"; else echo "FAIL : if-equal/repeat (y541 x$Y, want 2)"; fail=1; fi
if [ "$N" -eq 0 ]; then echo "OK   : 'if 0 ! 541' correctly never fired"; else echo "FAIL : if-not-equal fired ($N)"; fail=1; fi
chk "reg=5"                "'\$' substitutes the register interactively"
chk "ar=11"                "register arithmetic: 20 +5 -3 *2 /4 = 11 (set - * /)"
chk "dz=11"                "set / 0 is guarded: register unchanged (still 11)"
chk "b2=150 a2=11"         "second register: 'setb 100; setb + 50' = 150, A untouched (11)"
chk "iflt"                 "if on register A: 'if \$ < 100' fires"
chk "ifgt"                 "if on register B: 'if # > 100' fires"
chk "ifne"                 "if register-vs-register: 'if \$ ! #' (11 != 150) fires"
IEQ=$(grep -ac "^ifeq" <(sed 's/\r//' "$LOG"))
if [ "$IEQ" -eq 0 ]; then echo "OK   : 'if \$ = #' (11 == 150) correctly never fired"; else echo "FAIL : if-eq-reg fired ($IEQ)"; fail=1; fi
chk "cok"                  "if task-vs-task: 'if 0 > @1' (count 1275 > prime 229) fires"
chk "pipd"                 "register pipe: @0 result -> task count \$ -> 146611"
chk "wtok"                 "waittask blocked until the agent task finished (deterministic join, no sleep)"
chk "wj"                   "waitall barrier held until the prime task finished (fan-out join, in-chain)"
chk "wk"                   "waitall: the 2nd fanned-out task (count 50) also computed (1275)"
chk "gt-y"                 "if >: 1275 > 1000 fires"
chk "lt-y"                 "if <: 1275 < 2000 fires"
N2=$(grep -ac "^lt-n" <(sed 's/\r//' "$LOG"))
if [ "$N2" -eq 0 ]; then echo "OK   : if <: 1275 < 1000 correctly does NOT fire"; else echo "FAIL : if < false branch fired ($N2)"; fail=1; fi
chk "shell-lives"          "shell back at the prompt afterwards"
[ "$fail" -eq 0 ] && echo "==== SCRIPT OK ====" || { echo "==== SCRIPT FAILED ===="; sed 's/\r//g' "$LOG" | tail -30; }
rm -f "$LOG"
exit $fail
