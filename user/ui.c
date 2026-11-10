/* ui.c - the full-screen toolkit for the TannX programs (see ui.h).
 * Pure software over the framebuffer the kernel hands out via SYS_FBINFO;
 * nothing here touches the kernel except fbinfo, getkey and kbgrab. */
#include "ui.h"
#include "font8x16.h"

fb_t ui_fb;
int  ui_sc = 1;

int ui_init(void) {
    if (fb_get(&ui_fb) < 0 || !ui_fb.base || ui_fb.w < 320 || ui_fb.h < 200) return -1;
    ui_sc = (ui_fb.w >= 1900) ? 2 : 1;        /* 1080p+ : doubled cells */
    sys_kbgrab();
    while (sys_getkey()) { }                  /* drop what the shell was typed before us */
    return 0;
}

/* ---- primitives --------------------------------------------------- */
void ui_fill(int x, int y, int w, int h, uint32_t col) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > UI_W) w = UI_W - x;
    if (y + h > UI_H) h = UI_H - y;
    if (w <= 0 || h <= 0) return;
    for (int j = 0; j < h; j++) {
        uint32_t *row = ui_fb.base + (unsigned)(y + j) * ui_fb.ppsl + x;
        for (int i = 0; i < w; i++) row[i] = col;
    }
}
void ui_hline(int x, int y, int w, uint32_t col) { ui_fill(x, y, w, 1, col); }
void ui_vline(int x, int y, int h, uint32_t col) { ui_fill(x, y, 1, h, col); }

/* horizontal inset of a quarter circle of radius r at row dy (0 = outermost) */
static int corner_inset(int r, int dy) {
    int yy = r - dy;                    /* 1..r */
    int rr = r * r - yy * yy + r;       /* + r: round the circle out a little */
    int s = 0;
    while ((s + 1) * (s + 1) <= rr) s++;
    return r - s;
}

void ui_round(int x, int y, int w, int h, int r, uint32_t col) {
    if (r * 2 > h) r = h / 2;
    if (r * 2 > w) r = w / 2;
    if (r < 1) { ui_fill(x, y, w, h, col); return; }
    for (int j = 0; j < h; j++) {
        int in = 0;
        if (j < r)           in = corner_inset(r, j);
        else if (j >= h - r) in = corner_inset(r, h - 1 - j);
        ui_fill(x + in, y + j, w - 2 * in, 1, col);
    }
}

/* row inset of a rounded box of height h, radius r, at row j */
static int row_inset(int r, int h, int j) {
    if (j < r)      return corner_inset(r, j);
    if (j >= h - r) return corner_inset(r, h - 1 - j);
    return 0;
}

void ui_frame(int x, int y, int w, int h, int r, uint32_t col) {
    if (r * 2 > h) r = h / 2;
    if (r * 2 > w) r = w / 2;
    for (int j = 0; j < h; j++) {
        int in = row_inset(r, h, j);
        if (j == 0 || j == h - 1) { ui_fill(x + in, y + j, w - 2 * in, 1, col); continue; }
        int nb = row_inset(r, h, j < r ? j - 1 : j + 1);   /* the outer neighbour */
        int lo = in < nb ? in : nb, hi = in < nb ? nb : in;
        ui_fill(x + lo, y + j, hi - lo + 1, 1, col);
        ui_fill(x + w - 1 - hi, y + j, hi - lo + 1, 1, col);
    }
}

uint32_t ui_blend(uint32_t dst, uint32_t src, int a) {
    if (a <= 0) return dst;
    if (a >= 256) return src;
    uint32_t r = (((dst >> 16) & 255) * (256 - a) + ((src >> 16) & 255) * a) >> 8;
    uint32_t g = (((dst >> 8) & 255) * (256 - a) + ((src >> 8) & 255) * a) >> 8;
    uint32_t b = ((dst & 255) * (256 - a) + (src & 255) * a) >> 8;
    return (r << 16) | (g << 8) | b;
}
uint32_t ui_dim(uint32_t c, int bri) {
    uint32_t r = (((c >> 16) & 255) * bri) / 255;
    uint32_t g = (((c >> 8) & 255) * bri) / 255;
    uint32_t b = ((c & 255) * bri) / 255;
    return (r << 16) | (g << 8) | b;
}

/* ---- text ----------------------------------------------------------- */
/* one glyph at scale sc, transparent background (set bits only) */
static void glyph(int x0, int y0, unsigned char ch, int sc, uint32_t col) {
    if (ch < FONT_FIRST || ch > FONT_LAST) ch = '?';
    const unsigned char *g = &font8x16[(ch - FONT_FIRST) * 16];
    for (int r = 0; r < 16; r++) {
        unsigned char bits = g[r];
        if (!bits) continue;
        for (int c = 0; c < 8; c++)
            if (bits & (0x80 >> c)) ui_fill(x0 + c * sc, y0 + r * sc, sc, sc, col);
    }
}

void ui_text_s(int x, int y, const char *s, int sc, uint32_t col) {
    for (; *s; s++, x += 8 * sc) {
        if (*s == ' ') continue;
        if (x >= UI_W) return;
        glyph(x, y, (unsigned char)*s, sc, col);
    }
}
void ui_text(int x, int y, const char *s, uint32_t col) { ui_text_s(x, y, s, ui_sc, col); }
void ui_textn(int x, int y, const char *s, int n, uint32_t col) {
    for (int i = 0; i < n && s[i]; i++, x += UI_CW) {
        if (s[i] == ' ') continue;
        if (x >= UI_W) return;
        glyph(x, y, (unsigned char)s[i], ui_sc, col);
    }
}
int ui_text_w(const char *s, int sc) { return strlen(s) * 8 * sc; }

/* opaque cells: every cell is painted bg first (the editor's row redraw and
 * the status bars rely on this - no clearing pass needed). n < 0 = whole s. */
void ui_text_bg(int x, int y, const char *s, int n, uint32_t col, uint32_t bg) {
    int sc = ui_sc;
    for (int i = 0; (n < 0 || i < n) && s[i]; i++, x += UI_CW) {
        if (x >= UI_W) return;
        unsigned char ch = (unsigned char)s[i];
        if (ch < FONT_FIRST || ch > FONT_LAST) ch = '?';
        const unsigned char *g = &font8x16[(ch - FONT_FIRST) * 16];
        for (int r = 0; r < 16; r++) {
            unsigned char bits = g[r];
            for (int c = 0; c < 8; c++)
                ui_fill(x + c * sc, y + r * sc, sc, sc, (bits & (0x80 >> c)) ? col : bg);
        }
    }
}

int ui_chip(int x, int y, const char *label, uint32_t dot, uint32_t bg, uint32_t fg) {
    int h = UI_CH + UI_CH / 2;
    int pad = UI_CW;
    int dw = UI_CW / 2 + 2;                      /* dot diameter */
    int w = pad + dw + UI_CW / 2 + ui_text_w(label, ui_sc) + pad;
    ui_round(x, y, w, h, h / 2, bg);
    ui_round(x + pad, y + (h - dw) / 2, dw, dw, dw / 2, dot);
    ui_text(x + pad + dw + UI_CW / 2, y + (h - UI_CH) / 2, label, fg);
    return w;
}

/* ---- input ------------------------------------------------------------ */
int ui_key(void) {
    int k = sys_getkey();
    if (k == 0x7f) return UI_BS;                 /* DEL byte from a terminal */
    return k;
}

/* ---- formatting ------------------------------------------------------- */
int ui_utoa(char *d, uint32_t v) {
    char t[12]; int n = 0, i = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) d[i++] = t[--n];
    d[i] = 0;
    return i;
}
int ui_itoa(char *d, int v) {
    if (v < 0) { d[0] = '-'; return 1 + ui_utoa(d + 1, (uint32_t)(-v)); }
    return ui_utoa(d, (uint32_t)v);
}
int ui_cat(char *d, const char *s) {
    int i = 0;
    while (s[i]) { d[i] = s[i]; i++; }
    d[i] = 0;
    return i;
}
int ui_hms(char *d, uint32_t secs) {
    uint32_t h = secs / 3600, m = (secs / 60) % 60, s = secs % 60;
    int i = 0;
    if (h >= 100) i = ui_utoa(d, h);
    else { d[i++] = (char)('0' + h / 10); d[i++] = (char)('0' + h % 10); }
    d[i++] = ':';
    d[i++] = (char)('0' + m / 10); d[i++] = (char)('0' + m % 10); d[i++] = ':';
    d[i++] = (char)('0' + s / 10); d[i++] = (char)('0' + s % 10); d[i] = 0;
    return i;
}
