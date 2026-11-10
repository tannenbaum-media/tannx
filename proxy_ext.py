#!/usr/bin/env python3
# proxy_ext.py - the host-side extras of llm-proxy.py. The OS has no TLS and
# never will, so everything that needs the real Internet or a LAN device goes
# through the proxy as plain HTTP:
#
#   /fetch           the text web browser ('run www'): GET /fetch?url=... or
#                    POST /fetch with the URL as the body -> readable text with
#                    numbered links. http(s) only, size-capped, and it REFUSES
#                    private / loopback / link-local targets (SSRF guard: the
#                    proxy must not become a door into the LAN it runs on).
#   /cast/...        Chromecast ('run cast'): mDNS discovery via pychromecast
#                    (or the catt CLI), YouTube via the YouTube receiver, other
#                    http(s) media via the default media receiver. The proxy
#                    only ever connects to the Chromecasts it discovered.
#   /shot            'run shot' without a FAT volume: the OS uploads its BMP
#                    screenshot, the proxy writes it to AGENTOS_SHOT_DIR
#                    (default ./shots) and converts it to PNG when PIL is there.
#
# --mock answers every endpoint without touching the network: a fixed page
# for /fetch (its links point back at the mock), a simulated "Living Room TV"
# for /cast with a clock-driven position, and /shot still writes the file.
# All replies are ASCII text; llm-proxy's _reply sanitizes anyway.
import html.parser
import ipaddress
import os
import re
import socket
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

MAX_SHOT = 8 * 1024 * 1024          # a 2560x1600 BMP downscaled x2 is ~3 MB
FETCH_HTML_CAP = 512 * 1024         # how much of a page we read
FETCH_TEXT_CAP = 24 * 1024          # how much text we hand to the OS (its buffer is 32 KB)
FETCH_MAX_LINKS = 99
FETCH_TIMEOUT = 15
SHOT_DIR = os.environ.get("AGENTOS_SHOT_DIR", "shots")
USER_AGENT = "TannXOS-www/1.0 (+text browser via llm-proxy)"


def handles(path: str) -> bool:
    return path == "/fetch" or path.startswith("/fetch?") or path.startswith("/cast/") or path == "/shot"


def handle(path: str, body: bytes, mock: bool):
    """-> (http status, ascii text)"""
    try:
        if path == "/fetch" or path.startswith("/fetch?"):
            url = ""
            if "?" in path:
                url = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query).get("url", [""])[0]
            if not url:
                url = body.decode("utf-8", "replace").strip()
            return 200, fetch_text(url, mock)
        if path.startswith("/cast/"):
            return 200, cast_request(path[6:], body.decode("utf-8", "replace"), mock)
        if path == "/shot":
            return 200, save_shot(body)
    except Exception as e:                       # never take the proxy down over an app request
        return 200, f"error: {type(e).__name__}: {e}"
    return 404, "unknown endpoint"


# ---------------------------------------------------------------- ascii
_TRANS = {0xa0: " ", 0x2018: "'", 0x2019: "'", 0x201a: "'", 0x201c: '"', 0x201d: '"',
          0x201e: '"', 0x2013: "-", 0x2014: "-", 0x2026: "...", 0x2022: "*", 0x00b7: "*",
          0x00ab: '"', 0x00bb: '"', 0x2192: "->", 0x2190: "<-", 0x00d7: "x", 0x20ac: "EUR"}

def asciify(s: str) -> str:
    s = s.translate(_TRANS)
    s = unicodedata.normalize("NFKD", s)
    return s.encode("ascii", "ignore").decode("ascii")


# ---------------------------------------------------------------- /fetch
class SSRFError(Exception):
    pass

def check_url(url: str) -> str:
    """http(s) only, a public host: every address the name resolves to must be
    global (no loopback, RFC1918, link-local, CGNAT, multicast, reserved).
    Returns the normalized URL. The check is repeated for every redirect."""
    u = urllib.parse.urlsplit(url.strip())
    if u.scheme not in ("http", "https"):
        raise SSRFError("only http:// and https:// URLs are fetched")
    host = u.hostname
    if not host or u.username or u.password:
        raise SSRFError("bad URL")
    if host.lower() in ("localhost", "localhost.localdomain") or host.endswith(".local") or host.endswith(".internal"):
        raise SSRFError(f"refusing local host '{host}'")
    try:
        infos = socket.getaddrinfo(host, u.port or (443 if u.scheme == "https" else 80),
                                   proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise SSRFError(f"cannot resolve '{host}': {e.strerror or e}")
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global or ip.is_multicast:
            raise SSRFError(f"refusing '{host}' -> {ip} (private / local address)")
    return urllib.parse.urlunsplit(u)


class _Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)                        # a redirect must not escape the guard
        return super().redirect_request(req, fp, code, msg, headers, newurl)

_BLOCK = {"p", "div", "br", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
          "blockquote", "pre", "section", "article", "header", "footer", "nav", "aside", "form",
          "dl", "dt", "dd", "hr", "figure", "figcaption", "main", "details", "summary", "option",
          "address", "center", "td", "th"}
_SKIP = {"script", "style", "noscript", "head", "svg", "template", "iframe", "canvas", "object"}

class TextExtractor(html.parser.HTMLParser):
    def __init__(self, base):
        super().__init__(convert_charrefs=True)
        self.base, self.out, self.links, self.linkidx = base, [], [], {}
        self.title, self.in_title, self.skip = "", False, 0
        self.href = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in _SKIP: self.skip += 1; return
        if tag == "title": self.in_title = True; return
        if tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            self.out.append("\n\n" + "#" * int(tag[1]) + " ")
        elif tag == "li": self.out.append("\n - ")
        elif tag == "hr": self.out.append("\n----\n")
        elif tag in ("td", "th"): self.out.append("  ")
        elif tag in _BLOCK: self.out.append("\n")
        if tag == "a" and a.get("href"):
            href = a["href"].strip()
            if href.startswith(("http://", "https://", "/", ".", "?")) or (":" not in href and not href.startswith("#")):
                self.href = urllib.parse.urljoin(self.base, href)
        if tag == "img" and a.get("alt"):
            self.out.append(f"[img: {a['alt'].strip()}]")

    def handle_endtag(self, tag):
        if tag in _SKIP: self.skip = max(0, self.skip - 1); return
        if tag == "title": self.in_title = False; return
        if tag == "a" and self.href:
            n = self.linkidx.get(self.href)
            if n is None and len(self.links) < FETCH_MAX_LINKS:
                self.links.append(self.href); n = len(self.links); self.linkidx[self.href] = n
            if n is not None: self.out.append(f"[{n}]")
            self.href = None
        elif tag in _BLOCK: self.out.append("\n")

    def handle_data(self, data):
        if self.in_title: self.title += data; return
        if self.skip: return
        self.out.append(data)

def html_to_text(raw: str, base: str):
    p = TextExtractor(base)
    try:
        p.feed(raw); p.close()
    except Exception:
        pass
    text = "".join(p.out)
    lines = []
    for ln in text.split("\n"):
        ln = re.sub(r"[ \t\r\f\v]+", " ", ln).strip()
        if ln or (lines and lines[-1]): lines.append(ln)
    return " ".join(p.title.split()), "\n".join(lines).strip(), p.links

def fetch_text(url: str, mock: bool) -> str:
    if not url:
        return "error: no URL (usage: run www <url>)"
    if "://" not in url:
        url = "https://" + url
    if mock:
        return mock_page(url)
    try:
        final = check_url(url)
        req = urllib.request.Request(final, headers={"User-Agent": USER_AGENT, "Accept": "text/html,text/plain;q=0.9,*/*;q=0.5",
                                                     "Accept-Language": "en,de;q=0.8"})
        opener = urllib.request.build_opener(_Redirects())
        with opener.open(req, timeout=FETCH_TIMEOUT) as r:
            ctype = r.headers.get("Content-Type", "text/html")
            final = r.geturl()
            if not any(t in ctype for t in ("text/html", "text/plain", "xhtml", "xml", "json")):
                return f"TITLE: (binary)\nURL: {final}\n\nThe server sent {ctype.split(';')[0]} - not a text page.\n--LINKS--\n"
            raw = r.read(FETCH_HTML_CAP + 1)
            truncated = len(raw) > FETCH_HTML_CAP
            raw = raw[:FETCH_HTML_CAP]
            m = re.search(r"charset=([\w-]+)", ctype)
            enc = m.group(1) if m else None
    except SSRFError as e:
        return f"error: {e}"
    except urllib.error.HTTPError as e:
        return f"error: HTTP {e.code} {e.reason} for {url}"
    except Exception as e:
        return f"error: {type(e).__name__}: {e}"
    if not enc:
        m = re.search(rb"charset=[\"']?([\w-]+)", raw[:4096])
        enc = m.group(1).decode("ascii", "ignore") if m else "utf-8"
    try:
        page = raw.decode(enc, "replace")
    except LookupError:
        page = raw.decode("utf-8", "replace")
    if "text/plain" in ctype or "json" in ctype:
        title, text, links = "", page, []
    else:
        title, text, links = html_to_text(page, final)
    text = asciify(text)
    if len(text) > FETCH_TEXT_CAP:
        text = text[:FETCH_TEXT_CAP] + "\n\n[... page truncated by the proxy]"
    elif truncated:
        text += "\n\n[... page truncated by the proxy]"
    out = [f"TITLE: {asciify(title) or final}", f"URL: {final}", "", text, "", "--LINKS--"]
    out += [f"{i + 1} {asciify(u)}" for i, u in enumerate(links)]
    return "\n".join(out) + "\n"

def mock_page(url: str) -> str:
    where = asciify(url)
    return ("TITLE: TannX mock page\n"
            f"URL: {where}\n\n"
            "# Welcome to the mock web\n"
            f"You asked for: {where}\n"
            "This page comes from llm-proxy.py --mock, so the headless test needs no Internet. "
            "A real proxy fetches the page over HTTPS on the host, strips the HTML to text and "
            "numbers the links, like these: the forest [1], the manifesto [2] and a long link [3].\n"
            " - item one\n - item two [1]\n"
            "----\n"
            "Keys in the browser: j/k scroll, space/b page, a number + Enter follows a link, "
            "h goes back, g opens the address line, q quits.\n"
            "--LINKS--\n"
            "1 http://mock.test/forest\n"
            "2 http://mock.test/manifesto\n"
            "3 http://mock.test/a/rather/long/path/that/keeps/going\n")


# ---------------------------------------------------------------- /cast
_MOCK = {"state": "IDLE", "title": "", "url": "", "t0": 0.0, "pos0": 0.0, "dur": 212.0, "vol": 0.5}
_casts = {}            # pychromecast objects by friendly name (connected once)

def _yt_id(url: str):
    m = re.search(r"(?:youtu\.be/|v=|/shorts/|/embed/)([\w-]{11})", url)
    return m.group(1) if m else None

def _mock_pos():
    if _MOCK["state"] == "PLAYING":
        p = _MOCK["pos0"] + (time.time() - _MOCK["t0"])
        if p >= _MOCK["dur"]:
            _MOCK["state"] = "IDLE"; return _MOCK["dur"]
        return p
    return _MOCK["pos0"]

def _mock_status():
    pos = _mock_pos()
    return (f"device=Living Room TV\nstate={_MOCK['state']}\ntitle={_MOCK['title']}\n"
            f"pos={int(pos)}\ndur={int(_MOCK['dur'])}\nvol={int(_MOCK['vol'] * 100)}\n")

def cast_request(op: str, body: str, mock: bool) -> str:
    lines = [l.strip() for l in body.split("\n")]
    device = lines[0] if lines else ""
    arg = lines[1] if len(lines) > 1 else ""
    if mock:
        return _cast_mock(op, device, arg)
    backend = cast_backend()
    if not backend:
        return ("error: no Chromecast backend on the proxy host.\n"
                "Install one:  pip install pychromecast   (or the catt CLI)\n"
                "and run llm-proxy.py on a machine in the same LAN as the TV\n"
                "(--bind 0.0.0.0 only if the OS runs on real hardware).")
    return _cast_real(backend, op, device, arg)

def _cast_mock(op, device, arg):
    if op == "devices":
        return "Living Room TV|Chromecast (mock)|192.0.2.10\n"
    if device and device != "Living Room TV":
        return f"error: no such device '{device}'"
    if op == "play":
        if not arg.startswith(("http://", "https://")):
            return "error: only http(s) media or YouTube URLs can be cast"
        vid = _yt_id(arg)
        _MOCK.update(state="PLAYING", url=arg, t0=time.time(), pos0=0.0,
                     title=(f"YouTube video {vid}" if vid else arg.rsplit("/", 1)[-1] or arg))
        return "ok playing\n" + _mock_status()
    if op == "pause":
        if _MOCK["state"] == "PLAYING":
            _MOCK.update(pos0=_mock_pos(), state="PAUSED")
        return "ok paused\n" + _mock_status()
    if op == "resume":
        if _MOCK["state"] == "PAUSED":
            _MOCK.update(t0=time.time(), state="PLAYING")
        return "ok playing\n" + _mock_status()
    if op == "stop":
        _MOCK.update(state="IDLE", pos0=0.0, title="")
        return "ok stopped\n" + _mock_status()
    if op == "volume":
        v = _MOCK["vol"]
        if arg == "+": v += 0.1
        elif arg == "-": v -= 0.1
        else:
            try: v = float(arg)
            except ValueError: return "error: volume is +, - or 0..1"
            if v > 1: v /= 100.0
        _MOCK["vol"] = max(0.0, min(1.0, v))
        return "ok volume\n" + _mock_status()
    if op == "status":
        return _mock_status()
    return f"error: unknown cast op '{op}'"

def cast_backend():
    try:
        import pychromecast  # noqa: F401
        return "pychromecast"
    except ImportError:
        pass
    for p in os.environ.get("PATH", "").split(os.pathsep):
        if os.path.isfile(os.path.join(p, "catt")):
            return "catt"
    return ""

def _cast_real(backend, op, device, arg):
    """Drives a real Chromecast. UNTESTED against hardware in this repository -
    written from the pychromecast / catt documentation; please report what
    your TV does. Only devices found by discovery are ever contacted."""
    if op == "play" and not arg.startswith(("http://", "https://")):
        return "error: only http(s) media or YouTube URLs can be cast"
    if backend == "catt":
        return _cast_catt(op, device, arg)
    import pychromecast
    if op == "devices" or not _casts:
        casts, browser = pychromecast.get_chromecasts(timeout=6)
        try:
            for c in casts:
                info = getattr(c, "cast_info", None)
                name = (info.friendly_name if info else getattr(c, "name", "?"))
                _casts[name] = c
            if op == "devices":
                out = []
                for name, c in _casts.items():
                    info = getattr(c, "cast_info", None)
                    model = getattr(info, "model_name", "Chromecast") if info else "Chromecast"
                    host = getattr(info, "host", "?") if info else "?"
                    out.append(f"{name}|{model}|{host}")
                return ("\n".join(out) + "\n") if out else "error: no Chromecast found on this LAN\n"
        finally:
            try: browser.stop_discovery()
            except Exception: pass
    if not device:
        device = next(iter(_casts), "")
    c = _casts.get(device)
    if not c:
        return f"error: no such device '{device}' (run devices first)"
    c.wait(timeout=10)
    mc = c.media_controller
    if op == "play":
        vid = _yt_id(arg)
        if vid:
            from pychromecast.controllers.youtube import YouTubeController
            yt = YouTubeController(); c.register_handler(yt); yt.play_video(vid)
        else:
            mime = "audio/mpeg" if arg.lower().endswith((".mp3", ".m4a")) else "video/mp4"
            mc.play_media(arg, mime); mc.block_until_active(timeout=10)
        time.sleep(1.0)
        return "ok playing\n" + _pc_status(c)
    if op == "pause": mc.pause(); return "ok paused\n" + _pc_status(c)
    if op == "resume": mc.play(); return "ok playing\n" + _pc_status(c)
    if op == "stop": mc.stop(); return "ok stopped\n" + _pc_status(c)
    if op == "volume":
        if arg == "+": c.volume_up(0.1)
        elif arg == "-": c.volume_down(0.1)
        else:
            v = float(arg); c.set_volume(v / 100.0 if v > 1 else v)
        time.sleep(0.3)
        return "ok volume\n" + _pc_status(c)
    if op == "status":
        try: mc.update_status(); time.sleep(0.3)
        except Exception: pass
        return _pc_status(c)
    return f"error: unknown cast op '{op}'"

def _pc_status(c):
    st = c.media_controller.status
    info = getattr(c, "cast_info", None)
    name = info.friendly_name if info else getattr(c, "name", "?")
    vol = int((c.status.volume_level if c.status else 0) * 100)
    return (f"device={asciify(name)}\nstate={st.player_state or 'IDLE'}\ntitle={asciify(st.title or '')}\n"
            f"pos={int(st.current_time or 0)}\ndur={int(st.duration or 0)}\nvol={vol}\n")

def _catt(args, timeout=25):
    r = subprocess.run(["catt"] + args, capture_output=True, text=True, timeout=timeout)
    return (r.stdout + r.stderr).strip()

def _cast_catt(op, device, arg):
    if op == "devices":
        out = []
        for ln in _catt(["scan"]).splitlines():
            m = re.match(r"([\d.]+)\s+-\s+(.+?)\s+-\s+(.+)$", ln.strip())
            if m: out.append(f"{m.group(2)}|{m.group(3)}|{m.group(1)}")
        return ("\n".join(out) + "\n") if out else "error: no Chromecast found (catt scan)\n"
    d = ["-d", device] if device else []
    if op == "play": return "ok playing\n" + _catt(d + ["cast", arg], 60)
    if op == "pause": return "ok paused\n" + _catt(d + ["pause"])
    if op == "resume": return "ok playing\n" + _catt(d + ["play"])
    if op == "stop": return "ok stopped\n" + _catt(d + ["stop"])
    if op == "volume":
        if arg == "+": return "ok volume\n" + _catt(d + ["volumeup"])
        if arg == "-": return "ok volume\n" + _catt(d + ["volumedown"])
        v = float(arg); return "ok volume\n" + _catt(d + ["volume", str(int(v if v > 1 else v * 100))])
    if op == "status":
        st = _catt(d + ["status"])
        kv = dict(re.findall(r"^(\w[\w ]*?):\s*(.+)$", st, re.M))
        return (f"device={device}\nstate={kv.get('State', 'UNKNOWN').upper()}\ntitle={asciify(kv.get('Title', ''))}\n"
                f"pos=0\ndur=0\nvol={kv.get('Volume', '0')}\n")
    return f"error: unknown cast op '{op}'"


# ---------------------------------------------------------------- /shot
def save_shot(data: bytes) -> str:
    if len(data) < 54 or data[:2] != b"BM":
        return "error: not a BMP"
    if len(data) > MAX_SHOT:
        return f"error: screenshot too large (max {MAX_SHOT} bytes)"
    os.makedirs(SHOT_DIR, exist_ok=True)
    name = time.strftime("tannx-%Y%m%d-%H%M%S")
    bmp = os.path.join(SHOT_DIR, name + ".bmp")
    with open(bmp, "wb") as f:
        f.write(data)
    try:
        from PIL import Image
        png = os.path.join(SHOT_DIR, name + ".png")
        Image.open(bmp).save(png)
        os.unlink(bmp)
        return f"saved {os.path.abspath(png)}"
    except Exception:
        return f"saved {os.path.abspath(bmp)}"


if __name__ == "__main__":          # python3 proxy_ext.py <url>  - fetch a page to the terminal
    print(fetch_text(sys.argv[1] if len(sys.argv) > 1 else "", mock="--mock" in sys.argv))
