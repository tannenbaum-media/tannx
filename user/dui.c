/* dui.c - the framebuffer toolkit shared by the TannX apps (see dui.h).
 * Draws straight into the firmware framebuffer with the 8x16 console font;
 * the font table lives here ONCE so every app that includes dui.h shares it
 * instead of carrying its own copy in the 128 KB blob. */
#include "dui.h"
#include "font8x16.h"

dui_t DUI;

int dui_init(void) {
    if (fb_get(&DUI.fb) < 0 || !DUI.fb.base || DUI.fb.w < 320) return -1;
    DUI.sc   = DUI.fb.w >= 1600 ? 2 : 1;
    DUI.cw   = 8 * DUI.sc;
    DUI.ch   = 16 * DUI.sc;
    DUI.cols = (int)DUI.fb.w / DUI.cw;
    DUI.rows = (int)DUI.fb.h / DUI.ch;
    return 0;
}

/* clipped once per rectangle, then straight row writes: fb_fillrect's
 * per-pixel bounds check is what made the rain and the full-screen clears
 * crawl under QEMU TCG */
void dui_fill(int x, int y, int w, int h, uint32_t col) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > (int)DUI.fb.w) w = (int)DUI.fb.w - x;
    if (y + h > (int)DUI.fb.h) h = (int)DUI.fb.h - y;
    if (w <= 0 || h <= 0) return;
    uint32_t *row = DUI.fb.base + (unsigned)y * DUI.fb.ppsl + x;
    for (int j = 0; j < h; j++, row += DUI.fb.ppsl)
        for (int i = 0; i < w; i++) row[i] = col;
}
void dui_clear(uint32_t col) { dui_fill(0, 0, (int)DUI.fb.w, (int)DUI.fb.h, col); }
void dui_hline(int x, int y, int w, uint32_t col) { dui_fill(x, y, w, 1, col); }
void dui_frame(int x, int y, int w, int h, uint32_t col) {
    dui_fill(x, y, w, 1, col); dui_fill(x, y + h - 1, w, 1, col);
    dui_fill(x, y, 1, h, col); dui_fill(x + w - 1, y, 1, h, col);
}
void dui_panel(int x, int y, int w, int h, uint32_t fill, uint32_t edge) {
    dui_fill(x, y, w, h, fill);
    dui_frame(x, y, w, h, edge);
}

/* one glyph, scaled sc, foreground only (the caller paints the background) */
static void glyph(int x, int y, unsigned char c, int sc, uint32_t col) {
    if (c < FONT_FIRST || c > FONT_LAST) c = '?';
    const unsigned char *g = font8x16 + (c - FONT_FIRST) * 16;
    for (int r = 0; r < 16; r++) {
        unsigned char bits = g[r];
        if (!bits) continue;
        for (int sy = 0; sy < sc; sy++) {
            int yy = y + r * sc + sy;
            if ((unsigned)yy >= DUI.fb.h) return;
            uint32_t *row = DUI.fb.base + (unsigned)yy * DUI.fb.ppsl;
            for (int b = 0; b < 8; b++) {
                if (!(bits & (0x80 >> b))) continue;
                for (int sx = 0; sx < sc; sx++) {
                    int xx = x + b * sc + sx;
                    if ((unsigned)xx < DUI.fb.w) row[xx] = col;
                }
            }
        }
    }
}

void dui_textpx(int x, int y, const char *s, int sc, uint32_t col) {
    for (int i = 0; s[i]; i++) glyph(x + i * 8 * sc, y, (unsigned char)s[i], sc, col);
}
void dui_text(int cx, int cy, const char *s, uint32_t col) {
    dui_textpx(cx * DUI.cw, cy * DUI.ch, s, DUI.sc, col);
}
void dui_text_big(int cx, int cy, const char *s, uint32_t col) {
    dui_textpx(cx * DUI.cw, cy * DUI.ch, s, DUI.sc * 2, col);
}
void dui_textn(int cx, int cy, const char *s, int n, uint32_t col) {
    int end = 0;
    for (int i = 0; i < n; i++) {
        if (!end && !s[i]) end = 1;
        unsigned char c = end ? ' ' : (unsigned char)s[i];
        if (c != ' ') glyph((cx + i) * DUI.cw, cy * DUI.ch, c, DUI.sc, col);
    }
}
int dui_textw(const char *s) { return dui_strlen(s); }

/* the fir-tree mark: three tiers + trunk, 11 x 20 units, sc px per unit */
void dui_logo(int x, int y, int sc) {
    static const unsigned char tier[3][2] = { {0, 6}, {4, 11}, {9, 17} };   /* rows */
    static const uint32_t cols[3] = { DUI_ACCENT2, DUI_ACCENT, 0x14B8A6u };
    for (int t = 0; t < 3; t++) {
        int r0 = tier[t][0], r1 = tier[t][1], span = r1 - r0;
        for (int r = r0; r < r1; r++) {
            int half = ((r - r0) * 5) / span + 1;     /* 1 .. 5 */
            dui_fill(x + (5 - half) * sc, y + r * sc, (2 * half + 1) * sc, sc, cols[t]);
        }
    }
    dui_fill(x + 4 * sc, y + 17 * sc, 3 * sc, 3 * sc, 0x7C5A3Cu);    /* trunk */
}

void dui_header(const char *app, const char *hint) {
    int h = 3 * DUI.ch;
    dui_fill(0, 0, (int)DUI.fb.w, h, DUI_PANEL);
    dui_hline(0, h - 1, (int)DUI.fb.w, DUI_ACCENT);
    dui_logo(DUI.cw, (h - 20 * DUI.sc * 2) / 2, DUI.sc * 2);
    dui_textpx(4 * DUI.cw, DUI.ch / 2, "TannX OS", DUI.sc, DUI_ACCENT);
    dui_textpx(4 * DUI.cw, DUI.ch / 2 + DUI.ch, app, DUI.sc * 1, DUI_TEXT);
    if (hint) dui_text(DUI.cols - dui_strlen(hint) - 1, 1, hint, DUI_MUTED);
}
void dui_footer(const char *keys) {
    int y = (DUI.rows - 1) * DUI.ch;
    dui_fill(0, y, (int)DUI.fb.w, DUI.ch + (int)DUI.fb.h - DUI.rows * DUI.ch, DUI_PANEL);
    dui_hline(0, y, (int)DUI.fb.w, DUI_LINE);
    dui_text(1, DUI.rows - 1, keys, DUI_MUTED);
}
void dui_bar(int x, int y, int w, int h, int permille, uint32_t col) {
    if (permille < 0) permille = 0; if (permille > 1000) permille = 1000;
    dui_fill(x, y, w, h, DUI_LINE);
    dui_fill(x, y, w * permille / 1000, h, col);
}

/* ---- keys ------------------------------------------------------------ */
int dui_poll(void) { return sys_getkey(); }
int dui_getkey(void) {
    for (;;) { int k = sys_getkey(); if (k) return k; sys_progress(50); sys_yield(); }
}
void dui_flush_keys(void) { while (sys_getkey()) ; }
void dui_sleep(int ticks) {
    uint32_t t0 = sys_uptime();
    while (sys_uptime() - t0 < (uint32_t)ticks) { sys_progress(50); sys_yield(); }
}

static void rl_draw(int cx, int cy, int w, const char *buf, int len) {
    dui_fill(cx * DUI.cw, cy * DUI.ch, w * DUI.cw, DUI.ch, DUI_PANEL2);
    int off = len > w - 2 ? len - (w - 2) : 0;        /* scroll long input */
    dui_textpx(cx * DUI.cw + DUI.cw / 2, cy * DUI.ch, buf + off, DUI.sc, DUI_TEXT);
    int cur = (len - off);
    dui_fill(cx * DUI.cw + DUI.cw / 2 + cur * DUI.cw, cy * DUI.ch + DUI.ch - 2 * DUI.sc, DUI.cw, 2 * DUI.sc, DUI_ACCENT);
}
int dui_readline(int cx, int cy, int w, char *buf, int cap) {
    int len = dui_strlen(buf);
    for (;;) {
        rl_draw(cx, cy, w, buf, len);
        int k = dui_getkey();
        if (k == DUI_KEY_ENTER || k == '\n' || k == DUI_KEY_ESC) return k == '\n' ? DUI_KEY_ENTER : k;
        if (k == DUI_KEY_BS || k == 127) { if (len) buf[--len] = 0; continue; }
        if (k >= 32 && k < 127 && len < cap - 1) { buf[len++] = (char)k; buf[len] = 0; }
    }
}

/* ---- run a shell command and read what it printed -------------------- */
static unsigned char con[4004];
static void con_line(int row, char *out) {
    const unsigned char *g = con + 4 + row * 160;
    int n = 0;
    for (int i = 0; i < 80; i++) { unsigned char c = g[i * 2]; out[i] = (c >= 32 && c < 127) ? (char)c : ' '; if (out[i] != ' ') n = i + 1; }
    out[n] = 0;
}
/* how many console rows start with the prompt - a finished command always
 * adds one (the new prompt), whatever the app itself printed meanwhile */
static int prompt_count(void) {
    sys_console(con);
    int n = 0; char l[81];
    for (int r = 0; r < 25; r++) { con_line(r, l); if (dui_startswith(l, "tannx> ")) n++; }
    return n;
}
int dui_console_rows(int from, char out[DUI_CON_LINES][81]) {
    int n = 0;
    sys_console(con);
    int r1 = con[1]; if (r1 > 25) r1 = 25;
    if (r1 < from) from = 0;                          /* the screen was cleared */
    for (int r = from; r < r1 && n < DUI_CON_LINES; r++) {
        con_line(r, out[n]);
        if (out[n][0]) n++;
    }
    return n;
}
int dui_run_shell(const char *cmd, char out[DUI_CON_LINES][81], int maxwait, int settle) {
    int p0 = prompt_count(), r0 = con[1];
    if (r0 > 24) r0 = 24;
    DUI.last_r0 = r0;
    if (sys_shell(cmd, dui_strlen(cmd)) != 0) return 0;
    uint32_t t0 = sys_uptime();
    for (;;) {
        int p = prompt_count();
        if (p > p0 || con[1] < r0) break;            /* new prompt, or 'clear' */
        if (sys_uptime() - t0 > (uint32_t)maxwait) break;
        dui_sleep(3);
    }
    if (settle > 0) dui_sleep(settle);                /* async agent output */
    return dui_console_rows(r0, out);
}

/* ---- strings ----------------------------------------------------------- */
int dui_strlen(const char *s) { int n = 0; while (s[n]) n++; return n; }
void dui_strcpy(char *d, const char *s, int cap) {
    int i = 0; while (s[i] && i < cap - 1) { d[i] = s[i]; i++; } d[i] = 0;
}
int dui_startswith(const char *s, const char *p) {
    while (*p) { if (*s != *p) return 0; s++; p++; } return 1;
}
char *dui_utoa(char *d, uint32_t v) {
    char t[12]; int n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *d++ = t[--n];
    *d = 0; return d;
}
int dui_atoi(const char *s) {
    int v = 0; while (*s == ' ') s++;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return v;
}
