#!/usr/bin/env python3
"""mklogo.py - generates the TannX OS boot logos (host build tool).

Outputs (committed, so the kernel build itself needs only binutils):
  logo/banner-<V>.inc   text-console boot banner for variant V (A/B/C):
                        CP437 half blocks + shades, colour via 0x01 <attr>
                        escapes (printed by puts_attr in the kernel)
  logo/brand-u<1|2>.inc desktop top-bar brand (fir mark + wordmark), RLE v2
  logo/fir-u<1|2>.inc   desktop fir silhouette (wallpaper + terminal), RLE v2
  logo/font-extra.inc   the CP437 glyphs the framebuffer font adds

Usage:  python3 logo/mklogo.py [--preview DIR]
Needs PIL (and the Lato font) only for the GUI images.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from cp437 import EXTRA  # noqa: E402

VERSION = "v2.87"
# The wordmark: W_A in white, W_B in the aurora teal ("Tann" + "X").
W_A, W_B = "Tann", "X"
TAGLINE = "Plant a wish. The agents grow it."
MADEBY = "made by Tannenbaum Media"

# VGA colours. 2, 3 and 9 are otherwise unused by the OS and are
# re-programmed to the Tannenbaum Media teal (VGA DAC in text mode,
# vga_pal on the framebuffer) - see logo_palette in the kernel.
BLK, TEAL_D, TEAL_L, LGRY, DGRY, AURORA, WHT = 0, 2, 3, 7, 8, 9, 15
VGA_RGB = [0x000000, 0x0000AA, 0x2a6b60, 0x6fc6b4, 0xAA0000, 0xAA00AA,
           0xAA5500, 0xAAAAAA, 0x555555, 0x2dd4bf, 0x55FF55, 0x55FFFF,
           0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF]

# ---------------------------------------------------------------------
#  Pixel fonts for the wordmark. One "pixel" = one text column wide and
#  half a text row tall (a half block), i.e. roughly square on screen.
# ---------------------------------------------------------------------
# BIG: cap height 7, x-height 5, descender 2. Rows listed top (cap line)
# to bottom (descender line) = 9 rows.
BIG = {
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#..",
          ".....", "....."],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#",
          ".....", "....."],
    "a": ["....", "....", ".##.", "...#", ".###", "#..#", ".###",
          "....", "...."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#",
          ".....", "....."],
    "F": ["####", "#...", "#...", "###.", "#...", "#...", "#...",
          "....", "...."],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###.",
          ".....", "....."],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####.",
          ".....", "....."],
    "g": ["....", "....", ".###", "#..#", "#..#", "#..#", ".###",
          "...#", "###."],
    "e": ["....", "....", ".##.", "#..#", "####", "#...", ".###",
          "....", "...."],
    "n": ["....", "....", "###.", "#..#", "#..#", "#..#", "#..#",
          "....", "...."],
    "t": ["...", ".#.", "###", ".#.", ".#.", ".#.", "..#",
          "...", "..."],
    "o": ["....", "....", ".##.", "#..#", "#..#", "#..#", ".##.",
          "....", "...."],
    "r": ["...", "...", "#.#", "##.", "#..", "#..", "#..",
          "...", "..."],
    "s": ["....", "....", ".###", "#...", ".##.", "...#", "###.",
          "....", "...."],
    " ": ["..", "..", "..", "..", "..", "..", "..", "..", ".."],
}

def text_width(font, text, gap=1):
    return sum(len(font[c][0]) for c in text) + gap * (len(text) - 1)


class Canvas:
    """80 x rows text screen; pixel layer of 80 x 2*rows half blocks plus
    an overlay of literal cells (text, shade chars)."""

    def __init__(self, rows, cols=80):
        self.rows, self.cols = rows, cols
        self.pix = [[None] * cols for _ in range(rows * 2)]
        self.cells = {}

    def px(self, x, y, c):
        if 0 <= x < self.cols and 0 <= y < self.rows * 2:
            self.pix[y][x] = c

    def text(self, x, row, s, fg, bg=BLK):
        for i, ch in enumerate(s):
            self.cells[(x + i, row)] = (ord(ch), fg, bg)

    def cell(self, x, row, ch, fg, bg=BLK):
        self.cells[(x, row)] = (ch, fg, bg)

    def word(self, font, x, y, text, color):
        """Draw text in a pixel font; returns the x after the last glyph."""
        for ch in text:
            g = font[ch]
            for gy, line in enumerate(g):
                for gx, p in enumerate(line):
                    if p == "#":
                        self.px(x + gx, y + gy, color)
            x += len(g[0]) + 1
        return x

    def blit(self, x, y, art):
        """art: rows of colours / None, as made by tbm_fir()."""
        for gy, row in enumerate(art):
            for gx, c in enumerate(row):
                if c is not None:
                    self.px(x + gx, y + gy, c)

    def resolve(self):
        """-> rows of (char, fg, bg) cells."""
        out = []
        for r in range(self.rows):
            line = []
            for x in range(self.cols):
                if (x, r) in self.cells:
                    line.append(self.cells[(x, r)])
                    continue
                t, b = self.pix[2 * r][x], self.pix[2 * r + 1][x]
                line.append(half_cell(t, b, x, r))
            out.append(line)
        return out


def half_cell(t, b, x, r):
    if t is None and b is None:
        return (0x20, LGRY, BLK)
    if t == b:
        return (0xDB, t, BLK)
    if b is None:
        return (0xDF, t, BLK)
    if t is None:
        return (0xDC, b, BLK)
    if b <= 7:
        return (0xDF, t, b)
    if t <= 7:
        return (0xDC, b, t)
    raise ValueError("cell %d,%d: no 8-colour background for %r/%r" % (x, r, t, b))


# ---------------------------------------------------------------------
#  The Tannenbaum Media fir, rasterised from its geometry: layered tiers
#  whose lower edge rises toward the stem, so each tier ends in two swept,
#  drooping tips; a thin trunk; a flat ground line. Upper edges catch the
#  light (TEAL_L), the body is TEAL_D - like the web logo's lighter rims.
# ---------------------------------------------------------------------
def fir_geometry(tiers=5):
    """Tier list in a 21 x 18 px box: (apex_y, tip_y, half_w, centre_thick)."""
    full = [(0, 3.2, 2.6, 3.0), (2.6, 6.4, 4.3, 3.2), (5.6, 9.6, 6.0, 3.4),
            (8.6, 12.8, 7.7, 3.6), (11.6, 16.0, 9.6, 3.0)]
    return full[5 - tiers:]


def tbm_fir(w=19, h=18, tiers=5, ground=True, ss=6, exp=1.3, lit=1):
    cx = w / 2
    geo = fir_geometry(tiers)
    top = geo[0][0]
    span = 17.2 - top                 # geometry -> box scale (vertical)
    sy_ = (h - 1) / span
    sx_ = (w / 21.0)
    tl = [((a - top) * sy_, (b - top) * sy_, hw * sx_, t * sy_) for a, b, hw, t in geo]
    last_tip = tl[-1][1]

    def inside(x, y):
        d = abs(x - cx)
        for a, b, hw, t in tl:
            if d > hw:
                continue
            u = d / hw
            yu = a + (b - a) * u ** exp
            yl = (a + t) + (b - a - t) * u ** 0.9
            if yu <= y <= yl:
                return True
        if d <= 0.5 and tl[-1][0] + tl[-1][3] <= y <= h - 1:
            return True                                   # trunk (below the tiers)
        if ground:
            gw = cx - 0.5
            if d <= gw:
                th = 1.2 * (1 - (d / gw) ** 2)
                gy = h - 0.6
                if gy - th / 2 <= y <= gy + th / 2:
                    return True
        return False

    grid = []
    for py in range(h):
        row = []
        for px in range(w):
            c = sum(inside(px + (i + .5) / ss, py + (j + .5) / ss)
                    for i in range(ss) for j in range(ss))
            row.append(c * 2 >= ss * ss)
        grid.append(row)
    art = []
    for py in range(h):
        out = []
        for px in range(w):
            if not grid[py][px]:
                out.append(None)
            elif lit and (py == 0 or not grid[py - 1][px]) and py < last_tip + 0.5 \
                    and abs(px + 0.5 - cx) > lit - 0.5:
                out.append(TEAL_L)                       # lit upper edge
            else:
                out.append(TEAL_D)
        art.append(out)
    return art


def wordmark_big(cv, x, y, gap_words=0):
    """W_A white + W_B aurora teal, one word. Returns end x."""
    x = cv.word(BIG, x, y, W_A, WHT)
    x += gap_words
    return cv.word(BIG, x, y, W_B, AURORA)


def big_width(gap_words=0):
    return text_width(BIG, W_A) + 1 + gap_words + text_width(BIG, W_B)


def credit(cv, x, row):
    """'made by Tannenbaum Media  v2.87' - returns end x."""
    cv.text(x, row, "made by ", DGRY)
    cv.text(x + 8, row, MADEBY[8:], LGRY)
    cv.text(x + len(MADEBY) + 2, row, VERSION, TEAL_L)
    return x + len(MADEBY) + 2 + len(VERSION)


def one_line(cv, row):
    """tagline  .  credit, centred on one row."""
    n = len(TAGLINE) + 5 + len(MADEBY) + 2 + len(VERSION)
    lx = (80 - n) // 2
    cv.text(lx, row, TAGLINE, LGRY)
    cv.cell(lx + len(TAGLINE) + 2, row, 0xFA, DGRY)
    credit(cv, lx + len(TAGLINE) + 5, row)


# ---------------------------------------------------------------------
#  The three variants
# ---------------------------------------------------------------------
def variant_a():
    """Fir left, big wordmark right, tagline + credit under it."""
    cv = Canvas(9)
    cv.blit(1, 0, tbm_fir())
    wx = 23
    wordmark_big(cv, wx, 1)
    cv.text(wx, 6, TAGLINE, LGRY)
    credit(cv, wx, 7)
    return cv


def variant_b():
    """Centred emblem: <fir> + wordmark on one baseline, one line below."""
    cv = Canvas(10)
    fw, fh = 17, 16
    w = fw + 3 + big_width()
    x0 = (80 - w) // 2
    fy = 0
    cv.blit(x0, fy, tbm_fir(fw, fh, tiers=4))
    wordmark_big(cv, x0 + fw + 3, fy + fh - 9)
    one_line(cv, 9)
    return cv


# hand-drawn small firs for the skyline: tiers with swept tips, stem
MINI_FIRS = [
    ["...#...", "..###..", ".#####.", "..###..", ".#####.", "#######", "...#..."],
    ["..#..", ".###.", "..#..", ".###.", "#####", "..#.."],
]


def lit_sprite(rows):
    """'#' rows -> colours: pixels with nothing above them are lit."""
    out = []
    for y, line in enumerate(rows):
        out.append([None if p != "#" else
                    (TEAL_L if (y == 0 or rows[y - 1][x] != "#") and y < len(rows) - 1
                     else TEAL_D) for x, p in enumerate(line)])
    return out


def skyline(cv, x0, x1, ground, gap=2):
    """As many small firs (tall/short alternating, odd count so both ends
    are tall) as fit, centred, standing on a ground line from x0 to x1."""
    n = 1
    while True:
        m = n + 2
        w = (m // 2 + 1) * 7 + (m // 2) * 5 + gap * (m - 1)
        if w > x1 - x0 - 2:
            break
        n = m
    arts = [lit_sprite(MINI_FIRS[i % 2]) for i in range(n)]
    tot = sum(len(a[0]) for a in arts) + gap * (len(arts) - 1)
    x = x0 + (x1 - x0 - tot) // 2
    for a in arts:
        cv.blit(x, ground - len(a), a)
        x += len(a[0]) + gap
    for gx in range(x0, x1):
        cv.px(gx, ground, TEAL_D)


def variant_c():
    """Compact: centred wordmark + OS, a forest edge as the underline,
    one line of text."""
    cv = Canvas(10)
    w = big_width() + 2 + 4
    x0 = (80 - w) // 2
    end = wordmark_big(cv, x0, 0)
    cv.text(end + 2, 1, " OS ", WHT, TEAL_D)
    skyline(cv, x0, end + 5, 17)
    one_line(cv, 9)
    return cv


VARIANTS = {"A": variant_a, "B": variant_b, "C": variant_c}


# ---------------------------------------------------------------------
#  Output: kernel include + preview
# ---------------------------------------------------------------------
def emit_banner(cells, name):
    """Byte stream for puts_attr: 0x01 <attr> sets the colour, rest putc."""
    out = bytearray(b"\r\n")
    attr = None
    for line in cells:
        # trim trailing blanks
        n = len(line)
        while n and line[n - 1][0] == 0x20 and line[n - 1][2] == BLK:
            n -= 1
        for ch, fg, bg in line[:n]:
            a = (bg << 4) | fg
            if ch == 0x20 and bg == BLK and attr is not None and (attr >> 4) == 0:
                out.append(0x20)
                continue
            if a != attr:
                out += bytes([0x01, a])
                attr = a
            out.append(ch)
        out += b"\r\n"
    out += b"\r\n"                     # breathing room before the welcome line
    out.append(0)
    lines = ["# generated by logo/mklogo.py - do not edit (variant %s)" % name]
    for i in range(0, len(out), 16):
        lines.append("    .byte " + ",".join("0x%02x" % b for b in out[i:i + 16]))
    return "\n".join(lines) + "\n", len(out)


def load_font():
    """ASCII 32..126 8x16 font from agentos32.S (the kernel's own)."""
    glyphs = {}
    src = open(os.path.join(HERE, "..", "agentos32.S")).read().splitlines()
    i = next(n for n, l in enumerate(src) if l.startswith("font8x16:"))
    code = 32
    for l in src[i + 1:]:
        l = l.strip()
        if not l.startswith(".byte"):
            break
        vals = l.split("#")[0].replace(".byte", "").split(",")
        glyphs[code] = [int(v, 16) for v in vals]
        code += 1
    glyphs.update(EXTRA)
    return glyphs


def preview(cells, path, nine=True):
    from PIL import Image
    font = load_font()
    cw = 9 if nine else 8
    img = Image.new("RGB", (80 * cw, len(cells) * 16))
    p = img.load()
    for r, line in enumerate(cells):
        for x, (ch, fg, bg) in enumerate(line):
            g = font.get(ch, font[32])
            for gy in range(16):
                bits = g[gy]
                for gx in range(cw):
                    if gx < 8:
                        on = bits & (0x80 >> gx)
                    else:
                        on = (0xC0 <= ch <= 0xDF) and (bits & 1)
                    c = VGA_RGB[fg if on else bg]
                    p[x * cw + gx, r * 16 + gy] = ((c >> 16) & 255, (c >> 8) & 255, c & 255)
    img = img.resize((img.width * 2, img.height * 2), Image.NEAREST)
    img.save(path)


def emit_font_extra():
    lines = ["# generated by logo/mklogo.py - CP437 glyphs for the framebuffer",
             "# font (shades, blocks, a few box/dot chars). fb_glyph maps the",
             "# codes via font_cp437_map; order here = index in font_extra."]
    lines.append("font_extra:")
    for code in sorted(EXTRA):
        lines.append("    .byte " + ",".join("0x%02x" % b for b in EXTRA[code])
                     + "   # 0x%02X" % code)
    lines.append("font_cp437_map:                  # 0x80..0xFF -> 1 + index, 0 = blank")
    m = [0] * 128
    for i, code in enumerate(sorted(EXTRA)):
        m[code - 0x80] = i + 1
    for i in range(0, 128, 16):
        lines.append("    .byte " + ",".join("%d" % v for v in m[i:i + 16]))
    lines.append("font_extra_utf8:                 # the same glyphs as UTF-8 (serial), 4 bytes each")
    for code in sorted(EXTRA):
        u = bytes([code]).decode("cp437").encode("utf-8")
        assert len(u) <= 3
        u = u + bytes(4 - len(u))
        lines.append("    .byte " + ",".join("0x%02x" % b for b in u) + "   # U+%04X" % ord(bytes([code]).decode("cp437")))
    return "\n".join(lines) + "\n"


def emit_font_extra_c():
    codes = sorted(EXTRA)
    m = [0] * 128
    for i, code in enumerate(codes):
        m[code - 0x80] = i + 1
    out = ["/* font_cp437.h - generated by logo/mklogo.py, do not edit.",
           " * The CP437 block/shade glyphs the boot logo uses (same bitmaps as",
           " * the kernel's font_extra): font_cp437_map[ch - 0x80] = 1 + index. */",
           "#ifndef AGENTOS_FONT_CP437_H", "#define AGENTOS_FONT_CP437_H",
           "static const unsigned char font_extra[%d][16] = {" % len(codes)]
    for code in codes:
        out.append("  {" + ",".join("0x%02x" % b for b in EXTRA[code]) + "},  /* 0x%02X */" % code)
    out.append("};")
    out.append("static const unsigned char font_cp437_map[128] = {")
    for i in range(0, 128, 16):
        out.append("  " + ",".join("%d" % v for v in m[i:i + 16]) + ",")
    out += ["};", "#endif", ""]
    return "\n".join(out)


def main():
    prev = None
    if "--preview" in sys.argv:
        prev = sys.argv[sys.argv.index("--preview") + 1]
    for name, fn in VARIANTS.items():
        cells = fn().resolve()
        inc, n = emit_banner(cells, name)
        open(os.path.join(HERE, "banner-%s.inc" % name), "w").write(inc)
        print("banner-%s: %d bytes" % (name, n))
        if prev:
            preview(cells, os.path.join(prev, "prev-%s-text.png" % name))
    open(os.path.join(HERE, "font-extra.inc"), "w").write(emit_font_extra())
    open(os.path.join(HERE, "..", "user", "font_cp437.h"), "w").write(emit_font_extra_c())
    if "--no-gui" not in sys.argv:
        import mkgui
        mkgui.main(prev)


if __name__ == "__main__":
    main()
