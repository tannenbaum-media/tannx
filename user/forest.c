/* forest.c - 'forest' / 'run forest': the agents as a living forest.
 *
 * A full-screen framebuffer animation of the agent table (SYS_AGENTS, read
 * every frame): each of the 8 agent slots is a fir at its own spot on the
 * ground. An empty slot is a sapling; a spawned agent is a young fir that
 * gains a tier for every task it has completed (the +4 'done' word), so a
 * forest that has worked grows tall. Crowns sway in a slow wind, a busy
 * agent's tree carries a pulsing glow. Tasks in flight are seeds: a
 * running task is a bright seed flying from the wish source under the
 * header along an arc to the top of its agent's tree (looping while it
 * runs); a waiting task orbits the source until an agent claims it.
 * Aurora curtains and twinkling stars fill the sky; the header counts
 * agents and finished tasks. q or Esc returns to the shell.
 *
 * Rendering, and why it is shaped like this: under QEMU TCG a guest
 * instruction costs ~30 host cycles and every framebuffer store goes
 * through the softmmu, so a 2560x1600 full repaint (4M pixels) takes
 * seconds. The scene is therefore painted once in full and then updated
 * through DIRTY RECTANGLES only: the swaying crowns, the seeds, the wish
 * source, a rolling strip of the aurora, a few twinkling stars per frame,
 * and a slot's whole column when its agent/done count changes. Every rect
 * is rendered into a sbrk'd band buffer (W x BAND) by the same clipped
 * pipeline (sky -> ground -> trees -> seeds -> text) and copied to the
 * framebuffer, so there is never a half-drawn tree on screen. Geometry
 * scales with the framebuffer (1024x768 .. 2560x1600). Integer math only,
 * Q12 sine table, no FPU. Yields to the scheduler after every frame. */
#include "libc.h"
#include "sintab.h"
#include "font8x16.h"

#define BAND 96
#define NSLOT 8

static fb_t      fb;
static uint32_t *bb;                 /* band buffer: W x BAND                 */
static int W, H, SC;                 /* screen size, UI scale (1 or 2)        */
static int by, bh;                   /* rows of the rect being drawn          */
static int cx0, cx1;                 /* x clip [cx0, cx1) of the rect         */
static uint32_t sky[2048];           /* per-row sky colour (H <= 2048)        */
static int frame;

/* ---- colour helpers (0x00RRGGBB in a BGRx framebuffer) ------------------ */
#define ACCENT   0x2DD4BFu
#define TEAL_D   0x2A6B60u
#define TEAL_L   0x6FC6B4u
#define SURF0    0x0A1614u
#define SURF1    0x122823u

static inline uint32_t mix(uint32_t a, uint32_t b, int t) {    /* t 0..256 */
    uint32_t rb = ((a & 0xff00ff) * (256 - t) + (b & 0xff00ff) * t) >> 8;
    uint32_t g  = ((a & 0x00ff00) * (256 - t) + (b & 0x00ff00) * t) >> 8;
    return (rb & 0xff00ff) | (g & 0x00ff00);
}
static inline uint32_t addc(uint32_t a, uint32_t b, int t) {   /* a + b*t/256, saturating */
    int r = (a >> 16) + (((b >> 16) & 255) * t >> 8);
    int g = ((a >> 8) & 255) + (((b >> 8) & 255) * t >> 8);
    int bl = (a & 255) + ((b & 255) * t >> 8);
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (bl > 255) bl = 255;
    return ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)bl;
}
/* SIN(a)/COS(a): Q12, a in 1/256 turns - from sintab.h */

/* ---- rect-clipped primitives ------------------------------------------ */
static inline void pset(int x, int y, uint32_t c) {
    if (x < cx0 || x >= cx1) return;
    y -= by;
    if ((unsigned)y >= (unsigned)bh) return;
    bb[y * W + x] = c;
}
static inline uint32_t pget(int x, int y) {
    if (x < cx0 || x >= cx1) return 0;
    y -= by;
    if ((unsigned)y >= (unsigned)bh) return 0;
    return bb[y * W + x];
}
static void hline(int x0, int x1, int y, uint32_t c) {
    y -= by;
    if ((unsigned)y >= (unsigned)bh) return;
    if (x0 < cx0) x0 = cx0;
    if (x1 >= cx1) x1 = cx1 - 1;
    uint32_t *row = bb + y * W;
    for (int x = x0; x <= x1; x++) row[x] = c;
}
/* additive glow: a soft disc of radius r, colour c, strength s (0..256) */
static void glow(int cx, int cy, int r, uint32_t c, int s) {
    if (cy + r < by || cy - r >= by + bh || cx + r < cx0 || cx - r >= cx1) return;
    int rr = r * r + 1;
    for (int y = cy - r; y <= cy + r; y++) {
        if (y < by || y >= by + bh) continue;
        int dy2 = (y - cy) * (y - cy);
        for (int x = cx - r; x <= cx + r; x++) {
            if (x < cx0 || x >= cx1) continue;
            int d2 = (x - cx) * (x - cx) + dy2;
            if (d2 > rr) continue;
            int k = 256 - 256 * d2 / rr;                   /* 256 at the centre */
            k = (k * k >> 8) * s >> 8;
            bb[(y - by) * W + x] = addc(bb[(y - by) * W + x], c, k);
        }
    }
}

/* 8x16 console font, scaled by sc, 1px drop shadow for legibility */
static void draw_char(int x0, int y0, unsigned char ch, int sc, uint32_t fg) {
    if (ch < FONT_FIRST || ch > FONT_LAST) return;
    if (y0 + 17 * sc <= by || y0 >= by + bh || x0 + 9 * sc <= cx0 || x0 >= cx1) return;
    const unsigned char *g = &font8x16[(ch - FONT_FIRST) * 16];
    for (int r = 0; r < 16; r++)
        for (int b = 0; b < 8; b++)
            if (g[r] & (0x80 >> b))
                for (int yy = 0; yy < sc; yy++)
                    for (int xx = 0; xx < sc; xx++) {
                        pset(x0 + b * sc + xx + sc, y0 + r * sc + yy + sc, 0x05100D);
                        pset(x0 + b * sc + xx, y0 + r * sc + yy, fg);
                    }
}
static void draw_text(int x, int y, const char *s, int sc, uint32_t fg) {
    if (y + 17 * sc <= by || y >= by + bh) return;
    while (*s) { draw_char(x, y, (unsigned char)*s, sc, fg); x += 8 * sc; s++; }
}
static int text_w(const char *s, int sc) { return strlen(s) * 8 * sc; }
static char *putnum(char *p, uint32_t v) {
    char b[12]; int i = 0;
    if (!v) b[i++] = '0';
    while (v) { b[i++] = '0' + (char)(v % 10); v /= 10; }
    while (i) *p++ = b[--i];
    *p = 0;
    return p;
}
static char *putstr(char *p, const char *s) { while (*s) *p++ = *s++; *p = 0; return p; }

/* ---- the scene -------------------------------------------------------- */
static int ground_y;                  /* horizon / tree feet                   */
static int wind;                      /* global sway phase                     */
static int pitch;                     /* tree spacing                          */

/* per-frame snapshot of the tables + the derived tree geometry */
static unsigned char ag[192], ag_prev[192];
static int n_agents, n_done, n_running, n_waiting;
typedef struct { int cx, ht, tiers, used, busy, done, maxhw, amp, top; } tree_t;
static tree_t T[NSLOT];

static const char *typ_name(int t) {
    switch (t) {
        case 0: return "math";  case 1: return "scan";  case 2: return "count";
        case 3: return "prime"; case 5: return "ask";   case 6: return "gcd";
        case 4: return "program";
        default: return "agent";
    }
}

static void snapshot(void) {
    if (sys_agents(ag) < 0) memset(ag, 0, sizeof ag);
    n_agents = n_done = n_running = n_waiting = 0;
    int margin = W / 12;
    for (int s = 0; s < NSLOT; s++) {
        tree_t *t = &T[s];
        t->cx = margin + (W - 2 * margin) * (2 * s + 1) / 16;
        t->used = ag[s * 8] && ag[s * 8 + 1] != 4;
        t->busy = t->used && ag[s * 8 + 2] == 1;
        t->done = ag[s * 8 + 4] | (ag[s * 8 + 5] << 8);
        if (t->used) {
            n_agents++; n_done += t->done;
            int k = 2 + t->done; if (k > 7) k = 7;
            t->tiers = k;
            t->ht = H * (10 + 5 * k) / 100;             /* 2 tiers: 20% .. 7: 45% */
        } else { t->tiers = 1; t->ht = H / 16; }        /* sapling */
        t->maxhw = t->ht * 3 / 10;
        if (t->maxhw > pitch * 9 / 20) t->maxhw = pitch * 9 / 20;
        t->amp = t->ht / 14 + 2;
        t->top = ground_y - t->ht;
    }
    for (int i = 0; i < 8; i++) {
        if (!ag[64 + i * 16]) continue;
        int st = ag[64 + i * 16 + 2];
        if (st == 1) n_running++; else if (st == 0) n_waiting++;
    }
}

/* a fir: feet at (cx, fy), total height ht, `tiers` tiers, sway amplitude
 * amp (px at the top; only the upper 45 % moves, so the dirty rect stays
 * small), lit = busy crown, dim = sapling. Drawn bottom tier first. */
static void fir(int cx, int fy, int ht, int tiers, int maxhw, int amp, int phase, int lit, int dim) {
    int top = fy - ht;
    int trunk_h = ht / 6 + 1;
    int span = ht - trunk_h;                      /* the tiered crown        */
    int step = span / (tiers + 1);                /* apex-to-apex distance   */
    int tier_h = step * 2;                        /* each tier overlaps the next */
    uint32_t body = dim ? mix(TEAL_D, SURF0, 160) : TEAL_D;
    uint32_t edge = dim ? mix(TEAL_L, SURF0, 150) : TEAL_L;
    uint32_t trunk = dim ? 0x2A2118 : 0x4A3728;
    int tw = ht / 24 + 1;
    for (int y = fy - trunk_h - step; y <= fy; y++)
        hline(cx - tw, cx + tw, y, trunk);
    for (int k = tiers - 1; k >= 0; k--) {
        int apex = top + k * step;
        int tip  = apex + tier_h;
        if (tip > fy - trunk_h / 2) tip = fy - trunk_h / 2;
        int hw = maxhw * (tiers - k) / tiers;     /* lower tiers are wider */
        if (hw < 2) hw = 2;
        int y0 = apex < by ? by : apex, y1 = tip >= by + bh ? by + bh - 1 : tip;
        for (int y = y0; y <= y1; y++) {
            int u = (y - apex) * 256 / (tip - apex + 1);           /* 0..256 */
            int half = hw * (u * u >> 8) / 256 + hw * u / 512;      /* a slight curve */
            int hgt = fy - y - ht * 11 / 20;                       /* sway: upper 45 % only */
            int sx = 0;
            if (hgt > 0) { int f = hgt * 256 / (ht * 9 / 20 + 1); sx = (amp * (f * f >> 8) >> 8) * SIN(wind + phase) >> 12; }
            int xl = cx + sx - half, xr = cx + sx + half;
            uint32_t c = y == apex ? edge : body;
            c = mix(c, SURF0, (tiers - 1 - k) * 18);                /* lower = shadier */
            int droop = (tip - apex) / 3, gap = 0;                  /* swept tips: the */
            if (y > tip - droop && droop > 0)                       /*   lower edge rises */
                gap = (y - (tip - droop)) * half / droop;           /*   toward the stem */
            if (gap >= half) continue;
            if (gap > 0) { hline(xl, xl + half - gap, y, c); hline(xr - half + gap, xr, y, c); }
            else hline(xl, xr, y, c);
            if (half >= 2) hline(xl, xl + (half >= 10 ? 2 : 1), y, edge);   /* lit left edge */
        }
    }
    if (lit) {                                    /* the crown: a working agent */
        int sx = amp * SIN(wind + phase) >> 12;
        int pulse = 180 + (SIN(frame * 6 + phase) * 60 >> 12);
        glow(cx + sx, top + step / 2, ht / 6 + 4, ACCENT, pulse);
        glow(cx + sx, top + step / 2, 3 * SC, 0xFFFFFF, 220);
    }
}

/* ---- sky: gradient + aurora + stars --------------------------------------
 * The aurora is sampled once per frame on a coarse grid (every AX columns x
 * AY rows) and bilinearly expanded per pixel through a per-row colour LUT
 * (32 steps of "sky + aurora light") - no sines or divisions per pixel. */
#define AX 4
#define AY 4
#define ALEV 64
static unsigned char *amap;          /* AH x AW coarse intensity              */
static unsigned char *arow_lit;      /* per coarse row: any light at all?     */
static uint32_t *alut;               /* [H][ALEV] sky + aurora light          */
static int AW, AH;
static int nstars;
static short *st_x, *st_y;           /* the star field                        */
static unsigned char *st_ph;

static int sky_init(void) {
    AW = W / AX + 2; AH = ground_y / AY + 2;
    amap = (unsigned char *)malloc((uint32_t)(AW * AH));
    arow_lit = (unsigned char *)malloc((uint32_t)AH);
    alut = (uint32_t *)malloc((uint32_t)H * ALEV * 4);
    nstars = W * H / 9000 + 60;
    st_x = (short *)malloc((uint32_t)nstars * 2);
    st_y = (short *)malloc((uint32_t)nstars * 2);
    st_ph = (unsigned char *)malloc((uint32_t)nstars);
    if (!amap || !arow_lit || !alut || !st_x || !st_y || !st_ph) return -1;
    for (int y = 0; y < H; y++) {
        /* curtain colour: accent teal high up, greener toward the horizon */
        uint32_t col = mix(ACCENT, 0x3DDC7A, y * 256 / (ground_y + 1));
        for (int i = 0; i < ALEV; i++)
            alut[y * ALEV + i] = addc(sky[y], col, i * 256 / (ALEV - 1));
    }
    uint32_t seed = 0x2DD4BF;
    for (int i = 0; i < nstars; i++) {
        seed = seed * 1103515245u + 12345u; st_x[i] = (short)((seed >> 8) % (uint32_t)W);
        seed = seed * 1103515245u + 12345u; st_y[i] = (short)((seed >> 8) % (uint32_t)(ground_y * 9 / 10));
        seed = seed * 1103515245u + 12345u; st_ph[i] = (unsigned char)(seed >> 8);
    }
    return 0;
}

/* (re)sample the coarse rows [ys0, ys1) at the current aurora phase. The
 * map is a MOSAIC: only the strip being repainted this frame is resampled,
 * so every later dirty rect in the sky reproduces exactly what is on screen
 * around it (no phase seams at rect borders). The drift is slow (one
 * phase step per 3 frames, 64-step LUT) so neighbouring strips, one frame
 * apart, join invisibly and the cycle's wrap seam is a few pixels of a
 * soft curtain. */
static void aurora_sample(int ys0, int ys1) {
    int ph = frame / 3;
    for (int xs = 0; xs < AW; xs++) {
        int x = xs * AX;
        int a1 = SIN(x * 3 / (SC * 4) + ph) * (H / 18) >> 12;
        int a2 = SIN(x * 5 / (SC * 4) - ph + 90) * (H / 24) >> 12;
        int c1 = H * 22 / 100 + a1, c2 = H * 34 / 100 + a2;
        int w1 = H / 9 + (SIN(x / (SC * 2) + ph) * (H / 40) >> 12);
        int w2 = H / 14;
        int s1 = 110 + (SIN(x / (3 * SC) + ph * 2) * 50 >> 12);
        int s2 = 70 + (SIN(x / (2 * SC) - ph + 40) * 40 >> 12);
        int inv1 = 65536 / (w1 + 1), inv2 = 65536 / (w2 + 1);
        for (int ys = ys0; ys < ys1; ys++) {
            int y = ys * AY;
            int d1 = y - c1; if (d1 < 0) d1 = -d1;
            int d2 = y - c2; if (d2 < 0) d2 = -d2;
            int k = 0;
            if (d1 < w1) k += (w1 - d1) * s1 * inv1 >> 16;
            if (d2 < w2) k += (w2 - d2) * s2 * inv2 >> 16;
            if (k > 255) k = 255;
            amap[ys * AW + xs] = (unsigned char)k;
            if (k) arow_lit[ys] = 1;
        }
    }
}
/* the strips are AY-aligned so a strip owns whole coarse rows */
static int strip_y0(int s, int n) { return (ground_y * s / n) / AY * AY; }

static void draw_sky(void) {
    for (int y = by; y < by + bh; y++) {
        uint32_t *row = bb + (y - by) * W;
        uint32_t base = sky[y];
        int ys = y / AY, fy = y % AY;
        if (y >= ground_y || (!arow_lit[ys] && !arow_lit[ys + 1])) {
            for (int x = cx0; x < cx1; x++) row[x] = base;
            continue;
        }
        const unsigned char *r0 = amap + ys * AW, *r1 = r0 + AW;
        const uint32_t *lut = alut + y * ALEV;
        int x = cx0, xs = x / AX, fx = x % AX;
        int a = r0[xs] * (AY - fy) + r1[xs] * fy;              /* left column  */
        int b = r0[xs + 1] * (AY - fy) + r1[xs + 1] * fy;      /* right column */
        for (; x < cx1; x++) {
            if (fx == AX) {
                fx = 0; xs++;
                a = r0[xs] * (AY - fy) + r1[xs] * fy;
                b = r0[xs + 1] * (AY - fy) + r1[xs + 1] * fy;
            }
            int k = (a * (AX - fx) + b * fx) >> 4;             /* /(AX*AY)      */
            row[x] = lut[k >> 2];                              /* 0..255 -> 0..63 */
            fx++;
        }
    }
    /* stars, twinkling */
    for (int i = 0; i < nstars; i++) {
        int x = st_x[i], y = st_y[i];
        if (y < by - 1 || y > by + bh || x < cx0 - 1 || x > cx1) continue;
        int br = 140 + (SIN(frame * 3 + st_ph[i]) * 100 >> 12);
        uint32_t c = mix(0xC8E8E0, 0xFFFFFF, br);
        pset(x, y, addc(pget(x, y), c, br));
        if ((st_ph[i] & 7) == 0) {
            pset(x - 1, y, addc(pget(x - 1, y), c, br / 2)); pset(x + 1, y, addc(pget(x + 1, y), c, br / 2));
            pset(x, y - 1, addc(pget(x, y - 1), c, br / 2)); pset(x, y + 1, addc(pget(x, y + 1), c, br / 2));
        }
    }
}

static void draw_ground(void) {
    if (by + bh <= ground_y - 4) return;
    for (int y = ground_y - 3; y < H; y++) {
        if (y < by || y >= by + bh) continue;
        uint32_t c;
        if (y < ground_y) c = mix(0x1B3B33, sky[ground_y], 100);
        else c = mix(0x10231E, SURF0, (y - ground_y) * 200 / (H - ground_y + 1));
        hline(cx0, cx1 - 1, y, c);
    }
}

static void draw_trees(void) {
    for (int s = 0; s < NSLOT; s++) {
        tree_t *t = &T[s];
        int reach = t->maxhw + t->amp + t->ht / 6 + 8;        /* widest thing it draws */
        if (t->cx + reach < cx0 || t->cx - reach >= cx1) continue;
        if (t->used && t->busy && by + bh > ground_y)      /* ground glow under a worker */
            glow(t->cx, ground_y + 2, t->ht / 4, TEAL_D, 90);
        fir(t->cx, ground_y, t->ht, t->tiers, t->maxhw, t->amp, s * 37, t->busy, !t->used);
        if (by + bh <= ground_y) continue;
        /* label under the tree: "0 prime / 3 tasks" or "sapling" */
        char buf[40], *p = buf;
        if (t->used) {
            p = putnum(p, (uint32_t)s); p = putstr(p, " ");
            p = putstr(p, typ_name(ag[s * 8 + 1]));
        } else p = putstr(p, "sapling");
        int ty = ground_y + 6 * SC;
        draw_text(t->cx - text_w(buf, SC) / 2, ty, buf, SC,
                  t->used ? (t->busy ? 0xE8FFFA : 0xC8D2D0) : 0x4A6A64);
        if (t->used) {
            p = putnum(buf, (uint32_t)t->done); p = putstr(p, t->done == 1 ? " task" : " tasks");
            draw_text(t->cx - text_w(buf, SC) / 2, ty + 18 * SC, buf, SC, t->busy ? ACCENT : 0x6FA89E);
        }
    }
}

/* seeds: one per task in flight. Running -> flies source->tree along an
 * arc, waiting -> orbits the source (the wish mark under the header). */
#define SRC_X (W / 2)
#define SRC_Y (H / 9)
static void seed_pos(int i, int p, int *px, int *py) {        /* p: 0..255 along the arc */
    int a = ag[64 + i * 16 + 3];
    int tx = T[a & 7].cx, ty = T[a & 7].top + 4 * SC;
    *px = SRC_X + (tx - SRC_X) * p / 256;
    *py = SRC_Y + (ty - SRC_Y) * p / 256 - (SIN(p / 2) * (H / 10) >> 12);
}
static void draw_seeds(void) {
    for (int i = 0; i < 8; i++) {
        if (!ag[64 + i * 16]) continue;
        int st = ag[64 + i * 16 + 2];
        int px, py;
        if (st == 1 && ag[64 + i * 16 + 3] < 8) {
            int p = (frame * 3 + i * 61) & 255;
            for (int k = 6; k >= 1; k--) {                     /* fading trail */
                int q = p - k * 5; if (q < 0) continue;
                seed_pos(i, q, &px, &py);
                glow(px, py, 2 * SC + 1, ACCENT, 180 * (7 - k) / 7);
            }
            seed_pos(i, p, &px, &py);
            glow(px, py, 7 * SC, ACCENT, 230);
            glow(px, py, 2 * SC, 0xFFFFFF, 255);
        } else if (st == 0) {
            int ang = frame * 2 + i * 32;
            px = SRC_X + (COS(ang) * (W / 40) >> 12);
            py = SRC_Y + (SIN(ang) * (H / 50) >> 12);
            glow(px, py, 5 * SC, 0x9FF0E0, 170);
            glow(px, py, SC + 1, 0xFFFFFF, 220);
        }
    }
    int pulse = 120 + (SIN(frame * 4) * 60 >> 12);            /* the source itself */
    glow(SRC_X, SRC_Y, 10 * SC, ACCENT, pulse);
    glow(SRC_X, SRC_Y, 2 * SC, 0xFFFFFF, 200);
}

#define HDR_X (24 * SC)
#define HDR_Y (18 * SC)
#define HDR_H (56 * SC)
static void draw_header(void) {
    if (by >= HDR_Y + HDR_H) return;
    int x = HDR_X, y = HDR_Y;
    fir(x + 10 * SC, y + 30 * SC, 30 * SC, 3, 9 * SC, 0, 0, 0, 0);   /* the icon */
    draw_text(x + 26 * SC, y, "TannX", 2 * SC, ACCENT);
    char buf[64], *p = buf;
    p = putstr(p, "- ");
    p = putnum(p, (uint32_t)n_agents); p = putstr(p, n_agents == 1 ? " agent, " : " agents, ");
    p = putnum(p, (uint32_t)n_done);   p = putstr(p, n_done == 1 ? " task done" : " tasks done");
    draw_text(x + 26 * SC + text_w("TannX ", 2 * SC), y + 8 * SC, buf, SC, 0xC8D2D0);
    p = buf;
    p = putnum(p, (uint32_t)n_running); p = putstr(p, " running, ");
    p = putnum(p, (uint32_t)n_waiting); p = putstr(p, " waiting - seeds fly to the tree that works");
    draw_text(x + 26 * SC, y + 36 * SC, buf, SC, 0x6FA89E);
    const char *hint = "Plant a wish. The agents grow it.   q quits";
    draw_text(W - text_w(hint, SC) - 24 * SC, y + 2 * SC, hint, SC, 0x7FB8AE);
}
static void draw_legend(void) {
    int y = H - 28 * SC;
    if (by + bh <= y) return;
    draw_text(24 * SC, y, "a tree per agent slot - it grows a tier per task done - "
                          "glowing crown = working - seeds = tasks in flight", SC, 0x4F7F77);
}

/* copy the finished band rows [cx0,cx1) to the framebuffer. A plain store
 * loop: under TCG `rep movsl` exits the translation block per iteration and
 * is several times slower than this. */
static void blit_band(void) {
    for (int y = 0; y < bh; y++) {
        uint32_t *dst = fb.base + (unsigned)(by + y) * fb.ppsl + cx0;
        const uint32_t *src = bb + y * W + cx0;
        int n = cx1 - cx0, i = 0;
        for (; i + 8 <= n; i += 8) {
            dst[i] = src[i]; dst[i + 1] = src[i + 1]; dst[i + 2] = src[i + 2]; dst[i + 3] = src[i + 3];
            dst[i + 4] = src[i + 4]; dst[i + 5] = src[i + 5]; dst[i + 6] = src[i + 6]; dst[i + 7] = src[i + 7];
        }
        for (; i < n; i++) dst[i] = src[i];
    }
}

static int quit;
static uint32_t prof[6];              /* kcycles per dirty-rect category (rdtsc) */
static int prof_cat;
static inline uint32_t tsc(void) { uint32_t lo, hi; __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi)); return lo; }
static void poll_key(void) {
    int k = sys_getkey();
    if (k == 'q' || k == KEY_ESC) quit = 1;
}

/* render one rectangle through the whole pipeline, band by band */
static void render_rect(int x0, int y0, int x1, int y1) {
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > W) x1 = W;
    if (y1 > H) y1 = H;
    if (x0 >= x1 || y0 >= y1) return;
    uint32_t t_in = tsc();
    cx0 = x0; cx1 = x1;
    for (by = y0; by < y1 && !quit; by += BAND) {
        bh = y1 - by < BAND ? y1 - by : BAND;
        draw_sky();
        draw_ground();
        draw_trees();
        draw_seeds();
        draw_header();
        draw_legend();
        blit_band();
        poll_key();
    }
    prof[prof_cat] += (tsc() - t_in) >> 10;
}

/* dirty rects of the moving seeds (previous frame's box, per task) */
static int seed_box[8][4];
static void seed_bbox(int i, int *b) {
    int p = (frame * 3 + i * 61) & 255, px, py;
    int m = 8 * SC + 2;
    b[0] = W; b[1] = H; b[2] = 0; b[3] = 0;
    for (int k = 0; k <= 6; k++) {
        int q = p - k * 5; if (q < 0) q = 0;
        seed_pos(i, q, &px, &py);
        if (px - m < b[0]) b[0] = px - m;
        if (py - m < b[1]) b[1] = py - m;
        if (px + m > b[2]) b[2] = px + m;
        if (py + m > b[3]) b[3] = py + m;
    }
}

int forest_main(void) {
    if (fb_get(&fb) < 0 || !fb.base || fb.w < 320 || fb.h < 200 || fb.h > 2048) {
        print("forest: no framebuffer (text mode) - boot with the VBE/GOP console\r\n");
        return 1;
    }
    W = (int)fb.w; H = (int)fb.h;
    SC = W >= 1900 ? 2 : 1;
    bb = (uint32_t *)malloc((uint32_t)W * BAND * 4);
    ground_y = H * 80 / 100;
    pitch = (W - 2 * (W / 12)) / 8;
    for (int y = 0; y < H; y++) {                       /* night sky -> surface teal */
        int t = y * 256 / (ground_y + 1); if (t > 256) t = 256;
        sky[y] = mix(0x03070C, SURF1, t);
    }
    if (!bb || sky_init() < 0) { print("forest: out of memory\r\n"); return 1; }
    snapshot();
    memcpy(ag_prev, ag, sizeof ag);
    printf("forest: ready %dx%d, %d agents, %d tasks done\r\n", W, H, n_agents, n_done);

    for (int ys = 0; ys < AH; ys++) arow_lit[ys] = 0;
    aurora_sample(0, AH);
    render_rect(0, 0, W, H);                            /* the full first frame */
    int prev_hdr = -1;
    int nstrip = H >= 1200 ? 20 : 12;                   /* sky strips: one refreshed per frame */
    uint32_t t0 = sys_uptime();
    while (!quit) {
        uint32_t tick = sys_uptime();
        frame++;
        wind = frame;
        snapshot();
        /* 1. slots whose agent/done/status changed: repaint the whole column */
        prof_cat = 0;
        for (int s = 0; s < NSLOT; s++)
            if (memcmp(ag + s * 8, ag_prev + s * 8, 8) != 0) {
                int hx = pitch / 2 + T[s].amp + 2;
                render_rect(T[s].cx - hx, HDR_Y + HDR_H, T[s].cx + hx, H);
            }
        memcpy(ag_prev, ag, sizeof ag);
        /* 2. the header when its counters change */
        int hdr = (n_agents << 24) ^ (n_done << 12) ^ (n_running << 6) ^ n_waiting;
        if (hdr != prev_hdr) { prev_hdr = hdr; render_rect(0, 0, W, HDR_Y + HDR_H); }
        prof_cat = 1;
        /* 3. one rolling strip of the aurora sky, resampled at today's phase */
        int s = frame % nstrip;
        int sy0 = strip_y0(s, nstrip), sy1 = strip_y0(s + 1, nstrip);
        for (int ys = sy0 / AY; ys < sy1 / AY; ys++) arow_lit[ys] = 0;
        aurora_sample(sy0 / AY, sy1 / AY);
        render_rect(0, sy0, W, sy1);
        prof_cat = 2;
        /* 4. the swaying crowns (upper half of every tree) + busy glows */
        for (int i = 0; i < NSLOT; i++) {
            tree_t *t = &T[i];
            int r = t->busy ? t->ht / 6 + 8 : 0;
            int hx = t->maxhw * 3 / 5 + t->amp + 3;
            if (hx < r) hx = r;
            render_rect(t->cx - hx, t->top - r - 2, t->cx + hx + 1, ground_y - t->ht * 11 / 20 + 2);
        }
        prof_cat = 3;
        /* 5. seeds: previous + current box of every task in flight, the source */
        for (int i = 0; i < 8; i++) {
            int b[4];
            if (ag[64 + i * 16] && ag[64 + i * 16 + 2] == 1 && ag[64 + i * 16 + 3] < 8) {
                seed_bbox(i, b);
                int u[4] = { b[0], b[1], b[2], b[3] };
                if (seed_box[i][2] > seed_box[i][0]) {       /* union with last frame */
                    if (seed_box[i][0] < u[0]) u[0] = seed_box[i][0];
                    if (seed_box[i][1] < u[1]) u[1] = seed_box[i][1];
                    if (seed_box[i][2] > u[2]) u[2] = seed_box[i][2];
                    if (seed_box[i][3] > u[3]) u[3] = seed_box[i][3];
                }
                render_rect(u[0], u[1], u[2], u[3]);
                memcpy(seed_box[i], b, sizeof b);
            } else if (seed_box[i][2] > seed_box[i][0]) {    /* it landed: erase */
                render_rect(seed_box[i][0], seed_box[i][1], seed_box[i][2], seed_box[i][3]);
                seed_box[i][2] = seed_box[i][0] = 0;
            }
        }
        int ox = W / 40 + 12 * SC, oy = H / 50 + 12 * SC;
        render_rect(SRC_X - ox, SRC_Y - oy, SRC_X + ox, SRC_Y + oy);
        prof_cat = 4;
        /* 6. a few twinkling stars per frame */
        for (int k = 0; k < 24; k++) {
            int i = (frame * 24 + k) % nstars;
            render_rect(st_x[i] - 1, st_y[i] - 1, st_x[i] + 2, st_y[i] + 2);
        }
        poll_key();
        /* be a good neighbour: a frame that finished inside its timer tick
         * gives the rest of the tick away (SYS_YIELD = hlt until the next
         * tick, 55 ms); a frame that already spanned a tick was preempted
         * by the round-robin anyway, so it goes straight on - and while
         * agents work, the forest only ever gets its round-robin share. */
        if (sys_uptime() == tick && n_running == 0) sys_yield();
    }
    uint32_t dt = sys_uptime() - t0;
    printf("forest: quit after %d frames (%d ms/frame)\r\n", frame,
           frame ? (int)(dt * 55 / (uint32_t)frame) : 0);
    printf("forest: kcycles columns+header=%u strip=%u crowns=%u seeds=%u stars=%u\r\n",
           prof[0], prof[1], prof[2], prof[3], prof[4]);
    return 0;
}
