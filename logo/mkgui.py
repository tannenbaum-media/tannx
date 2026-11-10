"""mkgui.py - the desktop's pre-rendered RLE assets (called by mklogo.py).

Outputs (committed, so the kernel build needs only binutils):
  logo/brand-u1.inc, brand-u2.inc   top-bar brand: fir mark + Lato wordmark
                                    ("Tann" white, "X" aurora gradient,
                                    small "OS"), pre-blended on SURFACE2, for
                                    UI scale u = 1 / 2 (mark 14u px tall)
  logo/fir-u1.inc, fir-u2.inc       the Tannenbaum Media fir as a TWO-TONE
                                    silhouette (240 / 480 px tall), index 0
                                    transparent. The kernel draws it on the
                                    wallpaper with the asset palette and
                                    inside the terminal with a palette
                                    override (rle_pal_ovr), so one asset
                                    serves both.

RLE format v2 (draw_rle in agentos32.S):

    .long width, height, ncolors       # ncolors <= 64, index 0 = TRANSPARENT
    .long palette[ncolors]             # 0x00RRGGBB (entry 0 is a placeholder)
    .word rowoff[height]               # offset of each row's first run byte,
                                       #   relative to the run data (row index
                                       #   = cheap clipping / partial repaints)
    runs, one row after another, a run NEVER crosses a row:
        bits 0-5 = palette index, bits 6-7 = run length - 1 (1..3 px);
        bits 6-7 == 3: the NEXT byte + 4 is the run length (4..259 px)
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 4                                   # supersampling for the Lato text

# design tokens (SPEC.md section 3)
SURFACE2 = 0x183029                      # top bar (flat - the brand is pre-blended on it)
BG_BOT = 0x122823                        # wallpaper, last row
BRAND_LO = 0x2A6B60                      # fir body  (Tannenbaum Media #30544F, lifted)
BRAND_MID = 0x4F9E9B                     # fir rims
TEAL_LO = (0x2a, 0x6b, 0x60)
TEAL_HI = (0x6f, 0xc6, 0xb4)
AURORA0 = (0x2d, 0xd4, 0xbf)             # wordmark accent gradient
AURORA1 = (0x4f, 0xb0, 0xa8)
WHITE = (0xf1, 0xf5, 0xf8)
GREY = (0x8d, 0x9c, 0xab)

LATO = "/usr/share/fonts/truetype/lato/"
TREE_SRC = os.path.join(HERE, "tbm-tree.png")   # the web logo's fir (alpha = shape)


def rgb(c):
    return ((c >> 16) & 255, (c >> 8) & 255, c & 255)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def tree_layer(height, lo=TEAL_LO, hi=TEAL_HI, silhouette=None):
    """The fir at `height` px as an RGBA layer: anti-aliased teal ramp, or
    (silhouette=(lo, hi)) a hard two-tone cut-out (safe on gradients)."""
    src = Image.open(TREE_SRC).convert("RGBA")
    shade = src.convert("RGB").filter(ImageFilter.GaussianBlur(3))   # smooth the grain
    shade.putalpha(src.getchannel("A"))
    w = round(src.width * height / src.height)
    s = shade.resize((w, height), Image.LANCZOS)
    out = Image.new("RGBA", s.size)
    sp, op = s.load(), out.load()
    for y in range(height):
        for x in range(w):
            r, g, b, a = sp[x, y]
            if not a:
                continue
            t = (0.3 * r + 0.59 * g + 0.11 * b) / 110.0
            if silhouette is not None:
                if a < 128:
                    continue
                op[x, y] = rgb(silhouette[1] if t > 0.55 else silhouette[0]) + (255,)
            else:
                t = min(1.0, max(0.0, t))
                op[x, y] = lerp(lo, hi, t) + (a,)
    return out


def wordmark_img(px, bg):
    """'Tann' white + 'X' aurora gradient (Lato Black px) + small 'OS',
    rendered 4x and downsampled onto the flat colour bg."""
    f = ImageFont.truetype(LATO + "Lato-Black.ttf", px * SS)
    fo = ImageFont.truetype(LATO + "Lato-Bold.ttf", int(px * 0.42) * SS)
    d0 = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    w_a = d0.textlength("Tann", font=f)
    w_f = d0.textlength("X", font=f)
    w_o = d0.textlength("OS", font=fo)
    W = int(w_a + w_f + px * 0.18 * SS + w_o) + 2 * SS
    H = int(px * 1.25) * SS
    im = Image.new("RGB", (W, H), rgb(bg))
    d = ImageDraw.Draw(im)
    base = int(px * 1.0) * SS
    d.text((0, base), "Tann", font=f, fill=WHITE, anchor="ls")
    mask = Image.new("L", (W, H))
    ImageDraw.Draw(mask).text((w_a, base), "X", font=f, fill=255, anchor="ls")
    grad = Image.new("RGB", (W, H))
    gd = ImageDraw.Draw(grad)
    x0, x1 = int(w_a), int(w_a + w_f)
    for gx in range(x0, x1 + 1):
        gd.line([(gx, 0), (gx, H)], fill=lerp(AURORA0, AURORA1, (gx - x0) / max(1, x1 - x0)))
    im.paste(grad, (0, 0), mask)
    d.text((w_a + w_f + px * 0.18 * SS, base), "OS", font=fo, fill=GREY, anchor="ls")
    return im.resize((W // SS, H // SS), Image.LANCZOS).convert("RGBA")


def brand(u):
    """Top-bar brand for UI scale u: mark (14u tall) at (0, 2u), wordmark
    (Lato 14u) at x = mark + 8u, y = 0. The kernel blits it at (MARGIN, 2u)."""
    mark = tree_layer(14 * u)
    wm = wordmark_img(14 * u, SURFACE2)
    W = mark.width + 8 * u + wm.width
    H = max(wm.height, 16 * u)
    im = Image.new("RGBA", (W, H), rgb(SURFACE2) + (255,))
    im.paste(mark, (0, 2 * u), mark)
    im.paste(wm, (mark.width + 8 * u, 0), wm)
    return im


def fir(u):
    """Two-tone silhouette, 240u px tall, in the wallpaper tones
    (lerp(BG_BOT, BRAND_LO|MID, 0.12)); index 0 transparent."""
    lo = lerp(rgb(BG_BOT), rgb(BRAND_LO), 0.12)
    hi = lerp(rgb(BG_BOT), rgb(BRAND_MID), 0.12)
    return tree_layer(240 * u, silhouette=(lo[0] << 16 | lo[1] << 8 | lo[2],
                                           hi[0] << 16 | hi[1] << 8 | hi[2]))


ASSETS = {"brand-u1": lambda: brand(1), "brand-u2": lambda: brand(2),
          "fir-u1": lambda: fir(1), "fir-u2": lambda: fir(2)}


def encode(img, name, ncol=63):
    """RGBA image -> (.inc text, run bytes, decoded preview). Alpha < 128 ->
    index 0 (transparent); the opaque pixels are quantised to <= 63 colours."""
    w, h = img.size
    alpha = img.getchannel("A").load()
    q = img.convert("RGB").quantize(colors=ncol, method=Image.Quantize.FASTOCTREE,
                                    dither=Image.Dither.NONE)
    pal = q.getpalette()
    data = list(q.getdata())
    used = sorted(set(data[y * w + x] for y in range(h) for x in range(w) if alpha[x, y] >= 128))
    assert len(used) <= 63, len(used)
    remap = {old: new + 1 for new, old in enumerate(used)}
    colors = [0] + [(pal[3 * o] << 16) | (pal[3 * o + 1] << 8) | pal[3 * o + 2] for o in used]
    idx = [remap[data[y * w + x]] if alpha[x, y] >= 128 else 0 for y in range(h) for x in range(w)]
    runs = bytearray()
    rowoff = []
    for y in range(h):
        rowoff.append(len(runs))
        row = idx[y * w:(y + 1) * w]
        i = 0
        while i < w:
            v = row[i]
            n = 1
            while i + n < w and row[i + n] == v and n < 259:
                n += 1
            if n <= 3:
                runs.append(((n - 1) << 6) | v)
            else:
                runs += bytes([(3 << 6) | v, n - 4])
            i += n
    assert len(runs) < 65536
    lines = ["# generated by logo/mkgui.py - do not edit (desktop asset %s)" % name,
             "# %d x %d px, %d colours (0 = transparent), %d bytes of runs (RLE v2: mkgui.py)"
             % (w, h, len(colors), len(runs)),
             "    .long %d, %d, %d" % (w, h, len(colors))]
    for k in range(0, len(colors), 8):
        lines.append("    .long " + ", ".join("0x%06x" % c for c in colors[k:k + 8]))
    for k in range(0, len(rowoff), 16):
        lines.append("    .word " + ",".join("%d" % b for b in rowoff[k:k + 16]))
    for k in range(0, len(runs), 16):
        lines.append("    .byte " + ",".join("%d" % b for b in runs[k:k + 16]))
    dec = Image.new("RGB", (w, h))
    dec.putdata([rgb(colors[v]) if v else (255, 0, 255) for v in idx])
    return "\n".join(lines) + "\n", len(runs), dec


def main(prev=None):
    total = 0
    for name, fn in ASSETS.items():
        img = fn()
        inc, n, dec = encode(img, name)
        open(os.path.join(HERE, "%s.inc" % name), "w").write(inc)
        size = len(inc.encode()) and (12 + 4 * 64 + 2 * img.height + n)
        total += size
        print("%s: %dx%d, %d run bytes (~%d B in the kernel)" % (name, img.width, img.height, n, size))
        if prev:
            dec.save(os.path.join(prev, "prev-%s.png" % name))
    print("desktop assets total ~%d B" % total)


if __name__ == "__main__":
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else None)
