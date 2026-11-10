/* aui.c - framebuffer UI kit for the sound apps. Draws straight into the
 * framebuffer (no back buffer: the sbrk arena cannot hold a 1600p frame),
 * so callers repaint only what changed. Text is the kernel's 8x16 console
 * font, block-scaled by aui_sc. */
#include "aui.h"
#include "font8x16.h"

fb_t aui_fb;
int  aui_sc = 1;

int aui_begin(void) {
    if (fb_get(&aui_fb) < 0 || !aui_fb.base) return -1;
    aui_sc = aui_fb.w >= 2400 ? 3 : aui_fb.w >= 1500 ? 2 : 1;
    aui_rect(0, 0, aui_fb.w, aui_fb.h, AUI_BG);
    return 0;
}

void aui_rect(int x, int y, int w, int h, uint32_t col) { fb_fillrect(&aui_fb, x, y, w, h, col); }

uint32_t aui_mix(uint32_t a, uint32_t b, int t) {
    uint32_t r = 0;
    for (int sh = 0; sh < 24; sh += 8) {
        int ca = (a >> sh) & 0xff, cb = (b >> sh) & 0xff;
        r |= (uint32_t)(ca + (((cb - ca) * t) >> 8)) << sh;
    }
    return r;
}

/* rounded panel: fill, then a 1*sc hairline; the corners are cut by a
 * circle test so the whole thing reads as a soft card */
void aui_panel(int x, int y, int w, int h, uint32_t fill, uint32_t border) {
    int r = 6 * aui_sc, bw = aui_sc;
    for (int j = 0; j < h; j++) {
        int dy = j < r ? r - j - 1 : j >= h - r ? j - (h - r) : -1;
        int ins = 0;
        if (dy >= 0) {
            int k = 0;
            while (k < r && (r - k - 1) * (r - k - 1) + dy * dy > r * r) k++;   /* corner inset */
            ins = k;
        }
        int edge = (j < bw || j >= h - bw);
        fb_fillrect(&aui_fb, x + ins, y + j, w - 2 * ins, 1, edge ? border : fill);
        if (!edge) {
            fb_fillrect(&aui_fb, x + ins, y + j, bw, 1, border);
            fb_fillrect(&aui_fb, x + w - ins - bw, y + j, bw, 1, border);
        }
    }
}

void aui_text(int x, int y, const char *s, int scale, uint32_t col) {
    int sc = scale * aui_sc;
    for (; *s; s++, x += 8 * sc) {
        unsigned char ch = (unsigned char)*s;
        if (ch <= ' ' || ch < FONT_FIRST || ch > FONT_LAST) continue;
        const unsigned char *g = &font8x16[(ch - FONT_FIRST) * 16];
        for (int r = 0; r < 16; r++) {
            if (!g[r]) continue;
            for (int b = 0; b < 8; b++)
                if (g[r] & (0x80 >> b)) fb_fillrect(&aui_fb, x + b * sc, y + r * sc, sc, sc, col);
        }
    }
}
void aui_textc(int cx, int y, const char *s, int scale, uint32_t col) {
    aui_text(cx - strlen(s) * 8 * scale * aui_sc / 2, y, s, scale, col);
}

void aui_line(int x0, int y0, int x1, int y1, uint32_t col) {
    int dx = x1 > x0 ? x1 - x0 : x0 - x1, dy = y1 > y0 ? y1 - y0 : y0 - y1;
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx - dy;
    for (;;) {
        fb_fillrect(&aui_fb, x0, y0, aui_sc, aui_sc, col);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 > -dy) { err -= dy; x0 += sx; }
        if (e2 <  dx) { err += dx; y0 += sy; }
    }
}

void aui_chip(int x, int y, int w, const char *s, int active) {
    int h = AUI_CH + 8 * aui_sc;
    aui_panel(x, y, w, h, active ? AUI_ACCENT : AUI_PANEL2, active ? AUI_ACCENT : AUI_BORDER);
    aui_textc(x + w / 2, y + 4 * aui_sc, s, 1, active ? AUI_BG : AUI_MUTED);
}

char *aui_num(char *d, int v) {
    char t[12]; int n = 0;
    if (v < 0) { *d++ = '-'; v = -v; }
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *d++ = t[--n];
    *d = 0;
    return d;
}
char *aui_str(char *d, const char *s) { while (*s) *d++ = *s++; *d = 0; return d; }

/* horizontal level meter: 40 segments, mint -> amber -> red, lit up to
 * `level`, a single held segment at `peak` (both 0..32767, linear) */
void aui_meter(int x, int y, int w, int h, int level, int peak) {
    int n = 40, gap = aui_sc, sw = (w - (n - 1) * gap) / n;
    int lit = (level * n + 16383) / 32767, pk = (peak * n) / 32767;
    for (int i = 0; i < n; i++) {
        uint32_t c = i < 26 ? AUI_ACCENT : i < 34 ? AUI_WARN : AUI_DANGER;
        int on = i < lit || i == pk;
        aui_rect(x + i * (sw + gap), y, sw, h, on ? c : aui_mix(AUI_PANEL, c, 40));
    }
}

void aui_title(const char *app, const char *sub) {
    int h = AUI_CH + 12 * aui_sc;
    aui_rect(0, 0, aui_fb.w, h, AUI_PANEL);
    aui_rect(0, h, aui_fb.w, aui_sc, AUI_ACCENT2);
    aui_rect(16 * aui_sc, 6 * aui_sc, 6 * aui_sc, AUI_CH, AUI_ACCENT);        /* the brand tick */
    aui_text(30 * aui_sc, 6 * aui_sc, "TannX", 1, AUI_TEXT);
    aui_text(30 * aui_sc + 12 * AUI_CW, 6 * aui_sc, app, 1, AUI_ACCENT);
    aui_text(aui_fb.w - (strlen(sub) * AUI_CW) - 16 * aui_sc, 6 * aui_sc, sub, 1, AUI_MUTED);
}

void aui_footer(const char *hints) {
    int h = AUI_CH + 12 * aui_sc, y = aui_fb.h - h;
    aui_rect(0, y, aui_fb.w, h, AUI_PANEL);
    aui_rect(0, y, aui_fb.w, aui_sc, AUI_BORDER);
    aui_text(16 * aui_sc, y + 6 * aui_sc, hints, 1, AUI_MUTED);
    static const char tag[] = "Plant a wish. The agents grow it.";
    aui_text(aui_fb.w - (int)sizeof(tag) * AUI_CW - 8 * aui_sc, y + 6 * aui_sc, tag, 1, AUI_DIM);
}
