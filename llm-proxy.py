#!/usr/bin/env python3
# llm-proxy.py - the host half of the TannX OS LLM loop.
# TannX OS has no TLS (and never will), so it speaks plain HTTP to this
# proxy; the proxy talks to the configured LLM backend and returns plain
# ASCII text the OS console can print directly.
#
#   TannX OS (QEMU slirp 10.0.2.2:4080 / LAN <host-ip>:4080)
#      --POST /llm "[@backend] prompt"-->  llm-proxy.py  -->  LLM of choice
#      <--200 text/plain answer---------
#      --POST /stt <16 kHz mono WAV>----->  Whisper / STT_URL (the voice wish)
#
# SECURITY - TRUSTED LAN ONLY, NO AUTHENTICATION:
#   Anyone who can reach the port can spend your API budget (and, with
#   --backend claude, drive the Claude Code CLI on this machine). The proxy
#   therefore binds to 127.0.0.1 by default, which is all a QEMU guest
#   needs (slirp maps 10.0.2.2 to the host's loopback). For a bare-metal
#   TannX OS box pass --bind 0.0.0.0 (or a specific LAN address) ONLY on a
#   LAN you trust; the UDP discovery responder is enabled in that case only.
#   Request bodies are capped (MAX_BODY) and /compute work is bounded.
#
# MULTI-LLM: the prompt may start with '@<backend> ' to pick the model
# per request, e.g. in the OS:  llm @ollama what is your name
#   @api      Claude API      (ANTHROPIC_API_KEY; model via LLM_MODEL/--model)
#   @openai   any OpenAI-compatible endpoint (OpenAI/Mistral/Groq/vLLM/
#             llama.cpp...): LLM_OPENAI_BASE/_KEY/_MODEL
#   @ollama   local Ollama:   LLM_OLLAMA_BASE/_MODEL
#   @claude   Claude Code CLI ('claude -p') - only if the proxy was started
#             with --backend claude (never auto-selected, see ask_claude_cli)
#   @list     show the backends that are usable right now
# No '@' -> the default backend (--backend; 'auto' = api if ANTHROPIC_API_KEY
# is set, otherwise the proxy refuses to start unless --mock is given).
#
# Usage:
#   ANTHROPIC_API_KEY=sk-... ./llm-proxy.py                 # Claude API
#   LLM_OPENAI_KEY=... ./llm-proxy.py --backend openai
#   ./llm-proxy.py --backend ollama
#   ./llm-proxy.py --mock                                   # canned answers (tests)
#   ANTHROPIC_API_KEY=sk-... ./llm-proxy.py --bind 0.0.0.0  # trusted LAN only!
#
# Raw stdlib HTTP on purpose: no pip needed on the host; every backend is
# one POST with a documented JSON shape.

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proxy_ext                      # /fetch (www), /cast/* (Chromecast), /shot - see proxy_ext.py

API_URL = "https://api.anthropic.com/v1/messages"
DEFAULT_MODEL = os.environ.get("LLM_MODEL", "claude-opus-5-5")
MAX_BODY = int(os.environ.get("LLM_MAX_BODY", str(64 * 1024)))   # request size cap
# /compute: at most this many jobs run at once; each op also has its own
# size cap (see compute_job). Keeps one chatty client from pinning the host.
COMPUTE_SLOTS = threading.BoundedSemaphore(
    max(1, int(os.environ.get("LLM_COMPUTE_SLOTS", "2"))))
SYSTEM = (
    "You are answering inside TannX OS, a tiny bare-metal hobby OS with an "
    "80x25 text console. Answer in plain ASCII only (no markdown, no "
    "unicode, no emoji), at most ~12 short lines. Be direct and helpful."
)

MOCK_ANSWER = "AGENTOS-LLM-MOCK: the wish loop is live. You asked: "

# /script mode: the model writes a TannX OS script (llmscript command).
# The OS persists the answer into an AgentFS slot, so it must be NOTHING
# but executable lines - the system prompt carries the whole contract.
SCRIPT_SYSTEM = (
    "You write scripts for TannX OS, a tiny bare-metal hobby OS. Reply with "
    "ONLY the script: TannX OS shell commands, ONE per line, no commentary, "
    "no markdown, no blank lines. Max 6 lines, max 58 chars per line, total "
    "under 440 chars, plain ASCII. Available commands: "
    "spawn <math|scan|count|prime|gcd> (start an agent); "
    "task math <a> <op> <b>; task count <n>; task prime <n>; task gcd <a> <b> (queue work); "
    "tasks (show results); agents; sleep <n> (pause n ticks, 18 = 1 s); "
    "waittask <task#> (block until that task is done - prefer this over sleep); "
    "waitall (block until ALL queued tasks are done); "
    "echo <text>; beep; play <notes a-g>; sound (AC97 tone); hda (HDA tone); "
    "llm <question> (ask an LLM); offload <mandel|sum|primes|fib> <n> "
    "(offload a compute job to the proxy); script <slot> (run another slot); "
    "if <L> <=|!|<|>> <R> <cmd> (branch; L and R may each be a task# (its "
    "result), $ (register A), # (register B), and R may also be @<task2> or a "
    "literal n; e.g. 'if $ < 10 echo small' or 'if 0 = 541 echo prime'); "
    "repeat <n> (as the LAST line: run this script n times total); "
    "spawn ask (start the LLM agent) and task ask <slot> (that agent answers "
    "the slot's saved text INTO the slot - sleep 300 first, then load <slot>); "
    "set / setb <n>|@<task#>|+|-|*|/ <n> (TWO registers A and B; '$' = A and "
    "'#' = B substitute into any later command, e.g. set 0; setb @0; task count $; "
    "set + 1; if $ < 5 repeat - a counted loop). "
    "Example reply for 'count to 100':\n"
    "spawn count\ntask count 100\nwaittask 0\ntasks\necho done"
)

MOCK_SCRIPT = "spawn count\ntask count 100\nsleep 40\necho llm-made-this"

# autopilot: an llmscript prompt starting with 'autopilot' gets this
# contract instead - the model decides ONE next action AND must end with
# the continuation tail, so the OS asks again. Forever (ESC/Ctrl+C stops).
AUTOPILOT_SYSTEM = (
    SCRIPT_SYSTEM
    + " Additional autopilot commands: llmscript 7 autopilot <next task> "
    "(ask the LLM for the next script); wait (block until it arrived). "
    "You are the AUTOPILOT of this TannX OS instance: pick ONE small, "
    "interesting, NEW action per round (vary: compute something, play a "
    "tone, echo an observation...), then ALWAYS end your script with "
    "exactly these 3 lines so the loop continues:\n"
    "llmscript 7 autopilot <one short line: what to do next round>\n"
    "wait\nscript 7\n"
    "Your work is remembered across reboots. If a round builds something "
    "worth keeping, start that next-round line with 'tool:<name> ' so it is "
    "filed by name in your library (e.g. 'llmscript 7 autopilot tool:primes "
    "find primes up to 200'). To RE-RUN a tool you already built, set the "
    "next-round line to 'llmscript 7 autopilot rerun:<name>' and that saved "
    "program runs again."
)

MOCK_AUTOPILOT = ("echo autopilot-alive\n"
                  "spawn count\ntask count 100\nsleep 40\n"
                  "llmscript 7 autopilot continue\nwait\nscript 7")

# ---- the autopilot's long-term memory (persistence) --------------------
# A diskless (PXE-booted) box keeps its LLM-written slots in RAM, so a reboot wipes
# everything the autopilot built. But the proxy is the ONE stable,
# disk-backed component that SEES every program the loop writes (it
# generates them). So the proxy archives each autopilot script to a
# library file and, when a fresh session starts (a long gap = a reboot),
# re-seeds the system prompt from that memory - the loop builds ON its
# past work instead of starting from zero every boot. All host-side.
LIBRARY_PATH = os.environ.get(
    "LLM_LIBRARY",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "autopilot-library.jsonl"))
# A gap longer than this between autopilot requests means the box rebooted
# or sat idle -> treat the next request as a new session and re-seed.
SESSION_GAP = float(os.environ.get("LLM_SESSION_GAP", "120"))

# Stall breaker: if the autopilot writes the SAME script this many rounds in a
# row it has stalled - rotating on one plan instead of doing new work (a stuck
# model, or a backend that keeps echoing). The proxy breaks the rut: it returns
# a cool-down script that throttles (a long sleep, so the loop can't hammer the
# OS and the API every few seconds) and re-arms with a forced-variety mission.
# Host-side, 0 kernel bytes, and it keeps the loop alive rather than killing it.
STALL_LIMIT = max(2, int(os.environ.get("LLM_STALL_LIMIT", "3")))
COOLDOWN_SCRIPT = ("echo autopilot: stalled - same plan, cooling down\n"
                   "sleep 180\n"
                   "llmscript 7 autopilot do something completely different\n"
                   "wait\nscript 7")


def parse_tool_name(mission: str):
    """The model can name a keeper by starting its next-round mission with
    'tool:<name> ...' - we file that script under <name> in the library."""
    m = mission.strip()
    if m.lower().startswith("tool:"):
        rest = m[5:].strip().split()
        if rest:
            return "".join(c for c in rest[0] if c.isalnum() or c in "-_")[:40]
    return None


def retail(script: str) -> bytes:
    """Re-attach the autopilot continuation tail to a saved script so RE-RUNNING
    a stored tool still keeps the loop alive: drop the tool's own trailing
    'llmscript 7 autopilot.../wait/script 7' (it carried a stale next-mission)
    and append a fresh one that asks the LLM for the next move."""
    lines = [l for l in script.splitlines() if l.strip()]
    if (len(lines) >= 3 and lines[-1].strip() == "script 7"
            and lines[-2].strip() == "wait"
            and lines[-3].strip().lower().startswith("llmscript 7 autopilot")):
        lines = lines[:-3]
    lines += ["llmscript 7 autopilot continue", "wait", "script 7"]
    return "\n".join(lines)


class Library:
    """The autopilot's persistent memory, backed by a JSONL file."""

    def __init__(self, path):
        self.path = path
        self.last_ts = 0.0
        self.lock = threading.Lock()
        self.last_script = None        # the previous autopilot script ...
        self.stall = 0                 #   ... and how many rounds it has repeated

    @staticmethod
    def _norm(script):
        return "\n".join(l.strip() for l in script.strip().splitlines() if l.strip())

    def note_script(self, script):
        """Stall detector. Records this round's script and returns how many
        rounds in a row it has now been identical (0 = first time we saw it)."""
        norm = self._norm(script)
        with self.lock:
            if norm and norm == self.last_script:
                self.stall += 1
            else:
                self.last_script = norm
                self.stall = 0
            return self.stall

    def reset_stall(self):
        """After breaking a stall, forget the streak so the cool-down and the
        next genuine attempt get a fresh count (no immediate re-trigger)."""
        with self.lock:
            self.last_script = None
            self.stall = 0

    def _load(self):
        out = []
        try:
            with open(self.path, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            out.append(json.loads(line))
                        except ValueError:
                            pass
        except FileNotFoundError:
            pass
        return out

    def count(self):
        with self.lock:                # _load() must hold the lock too, or it
            return len(self._load())   #   races a concurrent archive() write

    def get(self, name):
        """The most recent saved script filed under <name>, or None - so the
        autopilot can RE-RUN a tool it built, not just remember it."""
        with self.lock:
            recs = self._load()
        for r in reversed(recs):
            if r.get("name") == name:
                return r.get("script")
        return None

    def archive(self, mission, script, name=None):
        rec = {"ts": int(time.time()), "mission": mission[:120], "script": script[:600]}
        if name:
            rec["name"] = name
        with self.lock:
            try:
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(rec) + "\n")
            except OSError as e:
                print(f"[llm-proxy] library write failed: {e}", file=sys.stderr)

    def new_session(self, now):
        """True if this request begins a fresh session (long gap = reboot/idle)."""
        with self.lock:
            gap = now - self.last_ts
            self.last_ts = now
            return gap > SESSION_GAP

    def seed(self):
        """A compact MEMORY note for the system prompt: named tools the loop
        built + the recent distinct missions it ran. Empty if the library is."""
        with self.lock:                # read under the lock (a concurrent
            recs = self._load()        #   archive() could otherwise be mid-write)
        if not recs:
            return "", 0, []
        tools, seen = [], set()
        for r in reversed(recs):
            n = r.get("name")
            if n and n not in seen:
                seen.add(n)
                tools.append(n)
        missions, mseen = [], set()
        for r in reversed(recs):
            m = (r.get("mission") or "").strip()
            key = m.lower()[:40]
            if m and key and key not in mseen:
                mseen.add(key)
                missions.append(m)
            if len(missions) >= 8:
                break
        parts = []
        if tools:
            parts.append("named tools you already built: " + ", ".join(tools[:12]) + ".")
        if missions:
            parts.append("recent things you did: " + "; ".join(missions) + ".")
        note = (" MEMORY from earlier sessions (this TannX OS has run before; its "
                "RAM slots reset on reboot but your memory does not): "
                + " ".join(parts)
                + " Build ON this - do something NEW that extends your past work; "
                "do not just repeat what is listed above. You can RE-RUN any "
                "named tool with 'llmscript 7 autopilot rerun:<name>'.")
        return note, len(recs), tools


def sanitize(text: str) -> bytes:
    """ASCII-only, CRLF line endings - exactly what the OS console eats."""
    out = []
    for ch in text:
        if ch == "\n":
            out.append("\r\n")
        elif ch == "\r":
            continue
        elif 0x20 <= ord(ch) < 0x7F or ch == "\t":
            out.append(ch)
        else:
            out.append("?")
    return "".join(out).encode("ascii", "replace")


def _post_json(url: str, body: dict, headers: dict) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", **headers}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


# ---- backends: each takes (prompt, system) -> answer text -------------
def ask_claude_cli(prompt: str, system: str) -> str:
    """Claude Code CLI ('claude -p') using the CLI's own login - no API key
    required. Opt-in only (--backend claude): prompts arrive unauthenticated
    over the network, so the CLI must never be able to act on this machine.
    It is therefore run with NO tools at all (--tools ""), with permission
    prompts auto-denied as a second line of defence (--permission-mode
    dontAsk), and in --bare mode so hooks, plugins and CLAUDE.md context from
    the current directory stay out of the exchange. The prompt goes in on
    stdin, so it can never be mistaken for a CLI flag."""
    r = subprocess.run(
        ["claude", "-p", "--bare", "--tools", "", "--permission-mode", "dontAsk",
         "--system-prompt", system],
        input=prompt, capture_output=True, text=True, timeout=300,
    )
    if r.returncode != 0:
        return f"LLM error: claude CLI exited {r.returncode}: {r.stderr.strip()[:200]}"
    return r.stdout.strip() or "(empty answer)"


def ask_claude_api(prompt: str, system: str) -> str:
    data = _post_json(API_URL, {
        "model": os.environ.get("LLM_MODEL", DEFAULT_MODEL),
        "max_tokens": 700,
        "system": system,
        "messages": [{"role": "user", "content": prompt}],
    }, {
        "x-api-key": os.environ.get("ANTHROPIC_API_KEY", ""),
        "anthropic-version": "2023-06-01",
    })
    if data.get("stop_reason") == "refusal":
        return "LLM declined the request (refusal)."
    return "".join(
        b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"
    ) or "(empty answer)"


def ask_openai(prompt: str, system: str) -> str:
    """Any OpenAI-compatible /chat/completions endpoint: OpenAI itself,
    Mistral, Groq, DeepSeek, vLLM, llama.cpp server, ..."""
    base = os.environ.get("LLM_OPENAI_BASE", "https://api.openai.com/v1").rstrip("/")
    key = os.environ.get("LLM_OPENAI_KEY", "")
    model = os.environ.get("LLM_OPENAI_MODEL", "gpt-4o-mini")
    data = _post_json(f"{base}/chat/completions", {
        "model": model,
        "max_tokens": 700,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": prompt}],
    }, {"Authorization": f"Bearer {key}"} if key else {})
    return data["choices"][0]["message"]["content"].strip() or "(empty answer)"


def ask_ollama(prompt: str, system: str) -> str:
    """Local Ollama (no key, fully offline LLMs on the dev box)."""
    base = os.environ.get("LLM_OLLAMA_BASE", "http://127.0.0.1:11434").rstrip("/")
    model = os.environ.get("LLM_OLLAMA_MODEL", "llama3.2")
    data = _post_json(f"{base}/api/chat", {
        "model": model, "stream": False,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": prompt}],
    }, {})
    return data["message"]["content"].strip() or "(empty answer)"


BACKENDS = {
    "claude": ask_claude_cli,
    "api":    ask_claude_api,
    "openai": ask_openai,
    "ollama": ask_ollama,
}


ENABLED = set(BACKENDS) - {"claude"}   # @claude only after --backend claude


def backend_available(name: str) -> bool:
    if name not in ENABLED:
        return False
    if name == "claude":
        return shutil.which("claude") is not None
    if name == "api":
        return bool(os.environ.get("ANTHROPIC_API_KEY"))
    return True   # openai/ollama: config is env-based, errors surface per call


def route(prompt: str, default: str, system: str) -> str:
    """'@<backend> prompt' picks the model per request; '@list' lists them."""
    name = default
    if prompt.startswith("@"):
        head, _, rest = prompt.partition(" ")
        name = head[1:].lower()
        prompt = rest.strip()
        if name == "list":
            avail = [n for n in BACKENDS if backend_available(n)]
            return "backends: " + " ".join(avail) + f" (default: {default})"
        if name not in BACKENDS:
            return f"LLM error: unknown backend '@{name}' (try @list)"
        if name not in ENABLED:
            return (f"LLM error: backend '@{name}' is disabled on this proxy "
                    "(start it with --backend claude to allow the CLI)")
        if not prompt:
            return f"usage: @{name} <prompt>"
    return BACKENDS[name](prompt, system)


# ---- compute offload ---------------------------------------------------
# The proxy is the OS's abstraction over resources the bare-metal box
# can't run itself: it offloads LLM work, and here it offloads COMPUTE.
# A ring-3 client posts a data-parallel job to /compute; the proxy runs
# it (here on the dev box CPU - a real deploy could fan it to a GPU host,
# exactly the proxy model) and returns the result as plain ASCII. No LLM
# backend involved, so it is fully deterministic and needs no API key.
# ---- /stt: the voice wish ('run voice' in the OS) ---------------------------
# The OS POSTs a 16 kHz mono WAV it recorded through its own HDA driver; we
# answer the transcript as plain text. Backends, first one that works:
#   STT_URL=http://host:port/path   any HTTP service taking the WAV body and
#                                   answering JSON {"text": ...} or plain text
#   faster_whisper (pip install faster-whisper), model STT_MODEL (default base)
#   whisper        (pip install openai-whisper), same model name
# Without any of them the OS gets a clear "STT error: ..." line. --mock
# answers MOCK_TRANSCRIPT so the gate (test-voice.sh) needs no model.
MOCK_TRANSCRIPT = "build a tetris game with a high score table"
STT_MAX_BODY = int(os.environ.get("STT_MAX_BODY", str(4 * 1024 * 1024)))
_stt_model = None


def stt_transcribe(wav: bytes) -> str:
    global _stt_model
    url = os.environ.get("STT_URL")
    if url:
        try:
            req = urllib.request.Request(url, data=wav, method="POST",
                                         headers={"Content-Type": "audio/wav"})
            with urllib.request.urlopen(req, timeout=120) as r:
                body = r.read().decode("utf-8", "replace").strip()
            try:
                text = json.loads(body).get("text", "")
            except (ValueError, AttributeError):
                text = body
            return text.strip() or "STT error: empty transcript from STT_URL"
        except Exception as e:                    # noqa: BLE001 - the OS prints it
            return f"STT error: STT_URL failed: {e}"
    model_name = os.environ.get("STT_MODEL", "base")
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(wav)
            path = f.name
        try:
            try:
                from faster_whisper import WhisperModel   # type: ignore
                if _stt_model is None:
                    _stt_model = ("faster", WhisperModel(model_name, compute_type="int8"))
                if _stt_model[0] == "faster":
                    segments, _ = _stt_model[1].transcribe(path)
                    return " ".join(sg.text.strip() for sg in segments).strip() \
                        or "STT error: empty transcript (silence?)"
            except ImportError:
                pass
            try:
                import whisper                             # type: ignore
                if _stt_model is None:
                    _stt_model = ("whisper", whisper.load_model(model_name))
                if _stt_model[0] == "whisper":
                    return (_stt_model[1].transcribe(path).get("text", "").strip()
                            or "STT error: empty transcript (silence?)")
            except ImportError:
                pass
        finally:
            os.unlink(path)
    except Exception as e:                        # noqa: BLE001
        return f"STT error: {e}"
    return ("STT error: no speech backend - pip install faster-whisper "
            "(or openai-whisper), or set STT_URL")


def compute_job(spec: str) -> str:
    if not COMPUTE_SLOTS.acquire(blocking=False):
        return "compute error: busy (too many concurrent jobs, try again)"
    try:
        return _compute_job(spec)
    finally:
        COMPUTE_SLOTS.release()


def _compute_job(spec: str) -> str:
    parts = spec.split()
    if not parts:
        return "compute error: empty job"
    op = parts[0].lower()
    try:
        if op == "mandel":                      # Mandelbrot set membership count over
            n = int(parts[1]) if len(parts) > 1 else 32   # an n x n grid - the classic
            n = max(1, min(n, 256))                       # GPU-parallel kernel
            inset = 0
            for j in range(n):
                ci = -1.5 + 3.0 * j / n
                for i in range(n):
                    cr = -2.0 + 3.0 * i / n
                    zr = zi = 0.0
                    k = 0
                    while k < 100 and zr * zr + zi * zi <= 4.0:
                        zr, zi = zr * zr - zi * zi + cr, 2.0 * zr * zi + ci
                        k += 1
                    if k == 100:
                        inset += 1
            return f"mandel {n}x{n} = {inset} in-set (offloaded; a GPU host parallelises this)"
        if op == "sum":                         # trivial deterministic job (1..n)
            n = int(parts[1]) if len(parts) > 1 else 0
            return f"sum 1..{n} = {n * (n + 1) // 2}"
        if op == "primes":                      # count primes <= n (sieve)
            n = max(0, min(int(parts[1]) if len(parts) > 1 else 0, 5_000_000))
            sieve = bytearray([1]) * (n + 1)
            if n >= 0:
                sieve[0] = 0
            if n >= 1:
                sieve[1] = 0
            i = 2
            while i * i <= n:
                if sieve[i]:
                    sieve[i * i:: i] = bytearray(len(sieve[i * i:: i]))
                i += 1
            return f"primes <= {n} = {sum(sieve)} (offloaded sieve)"
        if op == "fib":                         # nth Fibonacci (big-int, offload-worthy)
            n = max(0, min(int(parts[1]) if len(parts) > 1 else 0, 100_000))
            a, b = 0, 1
            for _ in range(n):
                a, b = b, a + b
            s = str(a)
            shown = s if len(s) <= 60 else s[:30] + "..." + s[-27:]
            return f"fib {n} = {shown} ({len(s)} digits, offloaded)"
        return f"compute error: unknown job '{op}' (try: mandel <n> | sum <n> | primes <n> | fib <n>)"
    except (ValueError, IndexError):
        return f"compute error: bad args for '{op}'"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # matches the OS's minimal TCP client
    server_version = "agentos-llm-proxy/1.0"

    def _reply(self, code: int, text: str):
        payload = sanitize(text)
        if not payload.endswith(b"\r\n"):
            payload += b"\r\n"
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if proxy_ext.handles(self.path):           # GET /fetch?url=... for curl and humans
            code, text = proxy_ext.handle(self.path, b"", self.server.mock)  # type: ignore[attr-defined]
            self._reply(code, text)
            return
        self._reply(200, "ok" if self.path == "/health" else "agentos llm proxy")

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            self._reply(400, "LLM error: bad Content-Length")
            return
        if self.path == "/stt":                 # speech-to-text: a WAV body, not text
            if n < 44 or n > STT_MAX_BODY:
                self._reply(413, f"STT error: WAV body must be 44..{STT_MAX_BODY} bytes")
                return
            wav = self.rfile.read(n)
            print(f"[llm-proxy] stt: {n} bytes of audio", flush=True)
            self._reply(200, MOCK_TRANSCRIPT if self.server.mock       # type: ignore[attr-defined]
                        else stt_transcribe(wav))
            return
        if n < 0 or n > (proxy_ext.MAX_SHOT if self.path == "/shot" else MAX_BODY):
            self._reply(413, f"LLM error: request body too large (max {MAX_BODY} bytes)")
            return
        if proxy_ext.handles(self.path):           # web / cast / screenshot: raw body, own handler
            code, text = proxy_ext.handle(self.path, self.rfile.read(n), self.server.mock)  # type: ignore[attr-defined]
            self._reply(code, text)
            return
        prompt = self.rfile.read(n).decode("utf-8", "replace").strip()
        if not prompt:
            self._reply(200, "LLM error: empty prompt")
            return
        if self.path == "/compute":             # compute offload, not an LLM call
            print(f"[llm-proxy] compute: {prompt!r}", flush=True)
            self._reply(200, compute_job(prompt))
            return
        script_mode = self.path == "/script"
        auto_mode = script_mode and prompt.lower().startswith("autopilot")
        kind = "autopilot" if auto_mode else "script" if script_mode else "prompt"
        print(f"[llm-proxy] {kind}: {prompt!r}", flush=True)

        # Autopilot persistence. On a fresh session (a long gap since
        # the last round = the box rebooted), re-seed the contract from the
        # library so the loop builds on its past work.
        lib = self.server.library                 # type: ignore[attr-defined]
        mission, system = "", AUTOPILOT_SYSTEM
        if auto_mode:
            mission = prompt[len("autopilot"):].strip()
            fresh = lib.new_session(time.time())  # new session? (and update last_ts)
            # the autopilot can RE-RUN a tool it built earlier: a 'rerun:<name>'
            # mission serves the saved script straight from the library (no LLM).
            if mission.lower().startswith("rerun:"):
                rest = mission[6:].strip().split()
                nm = "".join(c for c in rest[0] if c.isalnum() or c in "-_")[:40] if rest else ""
                saved = lib.get(nm) if nm else None
                if saved:
                    print(f"[llm-proxy] autopilot: RE-RUN saved tool '{nm}'", flush=True)
                    self._reply(200, retail(saved))
                    return
                print(f"[llm-proxy] autopilot: rerun '{nm}' not in library, asking LLM",
                      flush=True)
            if fresh:
                note, n, tools = lib.seed()
                if note:
                    system = AUTOPILOT_SYSTEM + note
                    print(f"[llm-proxy] autopilot: NEW SESSION - seeded from "
                          f"{n} memories (tools: {tools})", flush=True)

        if self.server.mock:                      # type: ignore[attr-defined]
            answer = (MOCK_AUTOPILOT if auto_mode
                      else MOCK_SCRIPT if script_mode else MOCK_ANSWER + prompt)
        else:
            try:
                answer = route(prompt, self.server.backend,       # type: ignore[attr-defined]
                               system if auto_mode
                               else SCRIPT_SYSTEM if script_mode else SYSTEM)
            except subprocess.TimeoutExpired:
                answer = "LLM error: claude CLI timed out"
            except urllib.error.HTTPError as e:
                answer = f"LLM error: API returned {e.code}: {e.read()[:200].decode('utf-8','replace')}"
            except Exception as e:                # noqa: BLE001 - OS just prints it
                answer = f"LLM error: {e}"

        # A real autopilot script (not a backend error / empty answer) is both
        # the software the OS is building AND a round we judge for stagnation.
        if (auto_mode and answer.strip()
                and not answer.startswith("LLM error") and answer != "(empty answer)"):
            # Same plan too many rounds running? Break the rut with a
            # throttled, variety-forcing cool-down instead of rotating on it.
            if lib.note_script(answer) >= STALL_LIMIT - 1:
                print(f"[llm-proxy] autopilot: STALL break - same plan x{STALL_LIMIT}, "
                      "cooling down", flush=True)
                lib.reset_stall()
                self._reply(200, COOLDOWN_SCRIPT)
                return
            lib.archive(mission, answer, parse_tool_name(mission))

        self._reply(200, answer)

    def log_message(self, fmt, *args):            # quiet; we log prompts above
        pass


def discovery_responder(port: int):
    """TannX OS on a real LAN has no idea what IP the host is. It broadcasts
    "AGENTOS-PROXY?" to :4080; we answer "AGENTOS-PROXY!" so it learns our
    IP + MAC and points its HTTP at us. Reply by broadcast - the OS reads
    the sender off the frame, so it needs no routable address for the
    reply. Runs in a daemon thread, and only when the proxy is bound to a
    non-loopback address (a loopback-only proxy must not announce itself)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        s.bind(("", port))
    except OSError as e:
        print(f"[llm-proxy] discovery off ({e})", flush=True)
        return
    while True:
        try:
            data, addr = s.recvfrom(512)
        except OSError:
            continue
        if data[:14] == b"AGENTOS-PROXY?":
            for dst in ("255.255.255.255", addr[0]):
                try: s.sendto(b"AGENTOS-PROXY!", (dst, port))
                except OSError: pass
            print(f"[llm-proxy] discovery: announced to {addr[0]}", flush=True)


def is_loopback(addr: str) -> bool:
    return addr in ("localhost", "::1") or addr.startswith("127.")


def main():
    ap = argparse.ArgumentParser(
        description="TannX OS LLM proxy (plain HTTP from the OS -> an LLM backend). "
                    "No authentication: bind to a LAN address only on a trusted LAN.")
    ap.add_argument("--port", type=int, default=4080)
    ap.add_argument("--bind", default="127.0.0.1",
                    help="address to listen on (default 127.0.0.1 = QEMU guests only; "
                         "--bind 0.0.0.0 serves a trusted LAN and enables UDP discovery)")
    ap.add_argument("--model", default=DEFAULT_MODEL,
                    help="Claude API model for @api (default from LLM_MODEL)")
    ap.add_argument("--mock", action="store_true",
                    help="answer with a canned string (headless tests, no API key)")
    ap.add_argument("--backend", default="auto",
                    choices=["auto", "claude", "cli", "api", "openai", "ollama"],
                    help="default backend; 'auto' = api when ANTHROPIC_API_KEY is set. "
                         "'claude'/'cli' runs the Claude Code CLI (never auto-selected). "
                         "Per-request override: prompt prefix '@<backend> '")
    ap.add_argument("--library", default=LIBRARY_PATH,
                    help="autopilot persistence: JSONL file the loop's programs "
                         "are archived to and re-seeded from")
    args = ap.parse_args()

    os.environ["LLM_MODEL"] = args.model          # @api model (see ask_claude_api)
    backend = {"cli": "claude"}.get(args.backend, args.backend)
    if backend == "claude":
        ENABLED.add("claude")                     # explicit opt-in only
    if backend == "auto":
        backend = "api" if os.environ.get("ANTHROPIC_API_KEY") else ""
    if not args.mock:
        if not backend:
            print("llm-proxy: no ANTHROPIC_API_KEY set. Export one (--backend api), "
                  "use --backend openai/ollama, --mock for tests, or explicitly "
                  "--backend claude for the Claude Code CLI.", file=sys.stderr)
            sys.exit(2)
        if not backend_available(backend):
            print(f"llm-proxy: backend '{backend}' is not usable here "
                  "(missing CLI or key)", file=sys.stderr)
            sys.exit(2)

    lan = not is_loopback(args.bind)
    if lan:
        threading.Thread(target=discovery_responder, args=(args.port,), daemon=True).start()

    srv = ThreadingHTTPServer((args.bind, args.port), Handler)
    srv.mock = args.mock          # type: ignore[attr-defined]
    srv.backend = backend or "api"  # type: ignore[attr-defined]
    srv.library = Library(args.library)  # type: ignore[attr-defined]
    mode = "MOCK" if args.mock else f"live (default @{backend})"
    disc = "+UDP discovery" if lan else "loopback only, no discovery"
    print(f"[llm-proxy] listening on {args.bind}:{args.port} - {mode} ({disc})", flush=True)
    if lan:
        print("[llm-proxy] WARNING: no authentication - serve a trusted LAN only", flush=True)
    print(f"[llm-proxy] autopilot memory: {args.library} ({srv.library.count()} programs)", flush=True)  # type: ignore[attr-defined]
    srv.serve_forever()


if __name__ == "__main__":
    main()
