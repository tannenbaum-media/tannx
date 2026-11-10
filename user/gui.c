/* gui.c - the Dark Glass compositor (ring-3). Owns the framebuffer and
 * renders a modern desktop: a deep navy gradient wallpaper, a translucent
 * top bar with a live clock, and a frosted-glass console panel that mirrors
 * the kernel text console (read through SYS_CONSOLE - 0xB8000 itself stays
 * supervisor-only). The shell keeps running underneath; we just render.
 *
 * No back buffer: the sbrk arena is only 8 MB, too small for a 1080p/1600p
 * framebuffer. Instead we composite DIRECTLY to the framebuffer and compute
 * the wallpaper colour analytically wherever glass goes on top, so alpha
 * blending needs no slow read-back of the uncached framebuffer. Static parts
 * (wallpaper, bars, panel) are drawn once; only the console cells and the
 * clock redraw, and only when they change - so an idle desktop costs nothing.
 */
#include "libc.h"
#include "font8x16.h"
#include "font_cp437.h"
#include "sintab.h"

/* ---- palette (BGRx, 0x00RRGGBB) -------------------------------------- */
#define ACCENT   0x22d3ee        /* neon cyan accent                      */
#define ACCENT2  0x3b82f6        /* secondary blue                        */
#define TITLECOL 0xe8eefc

/* VGA 16-colour -> Dark Glass palette (console text keeps its colours:
 * cyan labels, green results, etc. stay legible against the glass). */
static const uint32_t vga_pal[16] = {
    0x223044, 0x3b82f6, 0x2a6b60, 0x6fc6b4,   /* 2/3/9: the boot logo's  */
    0xf87171, 0xc084fc, 0xfacc15, 0xc8d2e0,   /*   teals (kernel vga_pal) */
    0x4b5563, 0x2dd4bf, 0x86efac, 0x67e8f9,
    0xfca5a5, 0xd8b4fe, 0xfde047, 0xffffff,
};

/* ALL the compositor's mutable state. It lives at a FIXED user-RAM address
 * (below), NOT in .bss/.data - because every ring-3 program is the same image
 * at 0x400000, so another program's crt0 zeros the shared .bss, and on a disk
 * boot run_start even reloads .data. Keeping our state out here - above the
 * heap, below the stack - makes the running compositor immune: launching ANY
 * program (a game, llm, the autopilot) can no longer corrupt it. The const
 * font/sine/icosahedron tables stay in .rodata, which crt0 never touches. */
struct gui {
    uint32_t *FB; uint32_t FBW, FBH, FBPP;
    int SC, CELLW, CELLH, TOPBAR, COX, COY, PANX, PANY, PANW, PANH;
    int SPIN_CX, SPIN_CY, SPIN_R, SPIN_ON;
    unsigned char ICO_E[30][2]; int ICO_NE;
    unsigned char ICO_F[20][3]; int ICO_NF;     /* the 20 triangular faces */
    unsigned char gridcache[4000];
    int cur_cx, cur_cy;
    int busy;                    /* P4: an agent is working -> "thinking" pulse */
    int vgpu_on;                 /* rendering via virtio-gpu (vs the firmware FB) */
    unsigned char con[4004];     /* the SYS_CONSOLE snapshot. MUST live here, not
                                  * on the stack: a 4004-byte local on the 4 KB
                                  * ring-3 stack overflows into the adjacent TID's
                                  * stack and smashed a launching game's return
                                  * address (-> #PF at a console-text address). */
};
#define G ((struct gui *)0x01800000)
#define FB      (G->FB)
#define FBW     (G->FBW)
#define FBH     (G->FBH)
#define FBPP    (G->FBPP)
#define SC      (G->SC)
#define CELLW   (G->CELLW)
#define CELLH   (G->CELLH)
#define TOPBAR  (G->TOPBAR)
#define COX     (G->COX)
#define COY     (G->COY)
#define PANX    (G->PANX)
#define PANY    (G->PANY)
#define PANW    (G->PANW)
#define PANH    (G->PANH)
#define SPIN_CX (G->SPIN_CX)
#define SPIN_CY (G->SPIN_CY)
#define SPIN_R  (G->SPIN_R)
#define SPIN_ON (G->SPIN_ON)
#define ICO_E   (G->ICO_E)
#define ICO_NE  (G->ICO_NE)
#define ICO_F   (G->ICO_F)
#define ICO_NF  (G->ICO_NF)
#define gridcache (G->gridcache)
#define cur_cx  (G->cur_cx)
#define cur_cy  (G->cur_cy)
#define g_busy  (G->busy)
#define vgpu_on (G->vgpu_on)

/* virtio-gpu backend (user/vgpu.c): optional GPU-backed display for the
 * compositor. vgpu_setup() returns a user-RAM framebuffer to render into (or
 * NULL = no virtio-gpu), vgpu_present() pushes a frame to the scanout. */
uint32_t *vgpu_setup(int *w, int *h);
void vgpu_present(void);

static inline void px(int x, int y, uint32_t c) {
    if ((unsigned)x < FBW && (unsigned)y < FBH) FB[(unsigned)y * FBPP + x] = c;
}

/* deep navy gradient: #0a0e1a (top) -> #141c2e (bottom) */
static uint32_t wp_color(int y) {
    int t = (FBH > 1) ? (y * 255 / (int)(FBH - 1)) : 0;
    if (t < 0) t = 0; if (t > 255) t = 255;
    int r = 0x0a + 10 * t / 255;
    int g = 0x0e + 14 * t / 255;
    int b = 0x1a + 20 * t / 255;
    return (uint32_t)((r << 16) | (g << 8) | b);
}

/* alpha-blend src over dst, a = 0..255 */
static uint32_t blend(uint32_t dst, uint32_t src, int a) {
    int dr = (dst >> 16) & 0xff, dg = (dst >> 8) & 0xff, db = dst & 0xff;
    int sr = (src >> 16) & 0xff, sg = (src >> 8) & 0xff, sb = src & 0xff;
    int r = (sr * a + dr * (255 - a)) / 255;
    int g = (sg * a + dg * (255 - a)) / 255;
    int b = (sb * a + db * (255 - a)) / 255;
    return (uint32_t)((r << 16) | (g << 8) | b);
}

static void draw_wallpaper(void) {
    for (uint32_t y = 0; y < FBH; y++) {
        uint32_t c = wp_color((int)y);
        uint32_t *row = FB + y * FBPP;
        for (uint32_t x = 0; x < FBW; x++) row[x] = c;
    }
}

/* a soft drop shadow on the bottom + right of a panel rect (a top-left light),
 * painted on the wallpaper BEFORE the glass goes down so the panel floats. The
 * falloff is analytic - blend(wallpaper, black, alpha) where alpha decays over
 * SH_R px from the edge - so no framebuffer read-back (safe on real hardware). */
#define SH_R  20             /* shadow softness (px) */
#define SH_A  95             /* peak shadow alpha at the panel edge */
static void panel_shadow(int x, int y, int w, int h) {
    /* bottom band, extended into the bottom-right corner */
    for (int j = 1; j <= SH_R; j++) {
        int yy = y + h + j;
        if ((unsigned)yy >= FBH) break;
        int a = SH_A * (SH_R - j) / SH_R;
        uint32_t *row = FB + (unsigned)yy * FBPP;
        for (int i = 0; i < w + SH_R; i++) {
            int xx = x + i;
            if ((unsigned)xx >= FBW) break;
            int aa = a;
            if (i >= w) aa = a * (SH_R - (i - w)) / SH_R;   /* taper past the corner */
            if (aa > 0) row[xx] = blend(wp_color(yy), 0x000000, aa);
        }
    }
    /* right band along the panel height */
    for (int i = 1; i <= SH_R; i++) {
        int xx = x + w + i;
        if ((unsigned)xx >= FBW) break;
        int a = SH_A * (SH_R - i) / SH_R;
        for (int j = 0; j < h; j++) {
            int yy = y + j;
            if ((unsigned)yy >= FBH) continue;
            FB[(unsigned)yy * FBPP + xx] = blend(wp_color(yy), 0x000000, a);
        }
    }
}

/* a frosted-glass rounded rectangle: tint blended over the wallpaper (no
 * read-back), with rounded corners and a faint top edge highlight. */
static void glass_panel(int x, int y, int w, int h, uint32_t tint, int alpha, int rad) {
    int rr = rad * rad;
    for (int j = 0; j < h; j++) {
        int yy = y + j;
        if ((unsigned)yy >= FBH) continue;
        uint32_t base = blend(wp_color(yy), tint, alpha);
        /* a touch brighter near the top of the panel = soft sheen */
        int sheen = (j < h / 3) ? (h / 3 - j) * 10 / (h / 3 + 1) : 0;
        uint32_t col = sheen ? blend(base, 0x9fc7ff, sheen) : base;
        for (int i = 0; i < w; i++) {
            if (rad > 0) {
                int cx = -1, cy = -1;
                if (i < rad && j < rad) { cx = rad - i; cy = rad - j; }
                else if (i >= w - rad && j < rad) { cx = i - (w - rad) + 1; cy = rad - j; }
                else if (i < rad && j >= h - rad) { cx = rad - i; cy = j - (h - rad) + 1; }
                else if (i >= w - rad && j >= h - rad) { cx = i - (w - rad) + 1; cy = j - (h - rad) + 1; }
                if (cx >= 0 && cx * cx + cy * cy > rr) continue;   /* outside corner */
            }
            px(x + i, yy, col);
        }
    }
}

static void hline(int x, int y, int w, uint32_t c) {
    for (int i = 0; i < w; i++) px(x + i, y, c);
}

/* dark navy glass: the background the AA edges blend toward. Every glyph in
 * the compositor sits on dark glass (top bar, console panel, agents panel),
 * so one constant is a close enough bg for the thin anti-aliasing band - and
 * it means draw_char needs NO framebuffer read-back (slow on the bare-metal test PC's
 * uncached FB) and no per-caller bg argument. */
#define GLASSBG 0x0e1a30

/* sample the 8x16 1bpp glyph at integer texel (x,y): 256 if the bit is set,
 * else 0. Out-of-bounds reads as 0 so edges anti-alias against empty space. */
static int glyph_bit(const unsigned char *g, int x, int y) {
    if ((unsigned)x >= 8 || (unsigned)y >= 16) return 0;
    return (g[y] & (0x80 >> x)) ? 256 : 0;
}

/* one glyph, scaled by SC with bilinear-coverage anti-aliasing. The 1bpp
 * glyph is treated as a coverage field, bilinearly upsampled to SC; a steep
 * ramp turns that into a CRISP stroke with a ~1px soft edge (not a 3px blur),
 * and edge pixels are alpha-blended fg-over-glass. Interior pixels are opaque
 * fg; fully-empty pixels are skipped (so the real panel bg shows through and
 * only the thin AA band blends toward GLASSBG). All software, no read-back. */
static void draw_char(int x0, int y0, unsigned char ch, uint32_t fg) {
    if (ch <= ' ' || ch < FONT_FIRST || ch > FONT_LAST) return;
    const unsigned char *g = &font8x16[(ch - FONT_FIRST) * 16];
    int W = 8 * SC, H = 16 * SC;
    for (int dy = 0; dy < H; dy++) {
        int v = ((2 * dy + 1) << 7) / SC - 128;   /* source y in 1/256 texels */
        int yt = v >> 8, fy = v & 255;
        for (int dx = 0; dx < W; dx++) {
            int u = ((2 * dx + 1) << 7) / SC - 128;
            int xt = u >> 8, fx = u & 255;
            int top = (glyph_bit(g, xt, yt)     * (256 - fx)
                     + glyph_bit(g, xt + 1, yt) * fx) >> 8;
            int bot = (glyph_bit(g, xt, yt + 1)     * (256 - fx)
                     + glyph_bit(g, xt + 1, yt + 1) * fx) >> 8;
            int cov = (top * (256 - fy) + bot * fy) >> 8;   /* 0..256 */
            cov = (cov - 96) * 4;                            /* steep -> crisp */
            if (cov <= 0) continue;                          /* bg shows through */
            if (cov >= 250) px(x0 + dx, y0 + dy, fg);
            else px(x0 + dx, y0 + dy, blend(GLASSBG, fg, cov));
        }
    }
}

static void draw_text(int x, int y, const char *s, uint32_t fg) {
    while (*s) { draw_char(x, y, (unsigned char)*s, fg); x += CELLW; s++; }
}

/* ---- software-3D accent: a rotating neon wireframe icosahedron ---------
 * Pure CPU, Q12 fixed point (no FPU/libm in ring-3). It lives in the right
 * wallpaper margin and redraws its own small box each frame, so the rest of
 * the desktop stays still and cheap. This is the "GPU" TannX OS has on bare
 * metal: the CPU draws it, and it looks the same on the bare-metal test PC as in QEMU.
 * (SPIN_CX/CY/R/ON, ICO_E and ICO_NE live in struct gui - see the top.) */

/* icosahedron: 12 vertices (golden ratio phi ~ 1.618), normalised so the
 * circumradius is 1000 - then projected vertices stay within SPIN_R of the
 * centre and the erase box covers them (1000 and 1618 scaled by 1000/1902). */
static const short ICO[12][3] = {
    {0,526,851},{0,526,-851},{0,-526,851},{0,-526,-851},
    {526,851,0},{526,-851,0},{-526,851,0},{-526,-851,0},
    {851,0,526},{851,0,-526},{-851,0,526},{-851,0,-526},
};

static int iabs(int v) { return v < 0 ? -v : v; }

static void line(int x0, int y0, int x1, int y1, uint32_t c) {
    int dx = iabs(x1 - x0), dy = -iabs(y1 - y0);
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx + dy, e2;
    for (;;) {
        px(x0, y0, c); px(x0 + 1, y0, c);     /* 2px = a touch of glow weight */
        if (x0 == x1 && y0 == y1) break;
        e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

static uint32_t dim(uint32_t c, int bri) {     /* scale a colour by bri/255 */
    int r = ((c >> 16) & 0xff) * bri / 255;
    int g = ((c >> 8) & 0xff) * bri / 255;
    int b = (c & 0xff) * bri / 255;
    return (uint32_t)((r << 16) | (g << 8) | b);
}

/* are vertices i,j one edge apart? (edge length^2 ~ 1.1e6) */
static int adjacent(int i, int j) {
    int dx = ICO[i][0]-ICO[j][0], dy = ICO[i][1]-ICO[j][1], dz = ICO[i][2]-ICO[j][2];
    int d2 = dx*dx + dy*dy + dz*dz;
    return d2 > 900000 && d2 < 1300000;
}

static void spin_init(void) {
    ICO_NE = 0;
    for (int i = 0; i < 12; i++)
        for (int j = i + 1; j < 12; j++)
            if (adjacent(i, j) && ICO_NE < 30) {
                ICO_E[ICO_NE][0] = i; ICO_E[ICO_NE][1] = j; ICO_NE++;
            }
    /* the 20 faces: every triple of mutually-adjacent vertices */
    ICO_NF = 0;
    for (int i = 0; i < 12; i++)
        for (int j = i + 1; j < 12; j++)
            for (int k = j + 1; k < 12; k++)
                if (adjacent(i, j) && adjacent(j, k) && adjacent(i, k) && ICO_NF < 20) {
                    ICO_F[ICO_NF][0] = i; ICO_F[ICO_NF][1] = j; ICO_F[ICO_NF][2] = k;
                    ICO_NF++;
                }
}

/* flat-fill a 2D triangle with a solid colour (edge-function rasteriser, no
 * z-buffer needed - we backface-cull and the icosahedron is convex, so the
 * visible front faces tile the screen without overlap). */
static int min3(int a, int b, int c) { int m = a < b ? a : b; return m < c ? m : c; }
static int max3(int a, int b, int c) { int m = a > b ? a : b; return m > c ? m : c; }
static void fill_tri(int x0, int y0, int x1, int y1, int x2, int y2, uint32_t col) {
    int minx = min3(x0,x1,x2), maxx = max3(x0,x1,x2);
    int miny = min3(y0,y1,y2), maxy = max3(y0,y1,y2);
    for (int y = miny; y <= maxy; y++) {
        for (int x = minx; x <= maxx; x++) {
            int w0 = (x1-x0)*(y-y0) - (y1-y0)*(x-x0);
            int w1 = (x2-x1)*(y-y1) - (y2-y1)*(x-x1);
            int w2 = (x0-x2)*(y-y2) - (y0-y2)*(x-x2);
            if ((w0 >= 0 && w1 >= 0 && w2 >= 0) || (w0 <= 0 && w1 <= 0 && w2 <= 0))
                px(x, y, col);
        }
    }
}

static void draw_spinner(int ang) {
    if (!SPIN_ON) return;
    int sx2[12], sy2[12], sz2[12];
    int ca = COS(ang), sa = SIN(ang);          /* spin about Y */
    int cb = COS(ang / 2), sb = SIN(ang / 2);  /* slow precession about X */
    for (int i = 0; i < 12; i++) {
        int x = ICO[i][0], y = ICO[i][1], z = ICO[i][2];
        int x1 = (x * ca + z * sa) >> 12;
        int z1 = (z * ca - x * sa) >> 12;
        int y2 = (y * cb - z1 * sb) >> 12;
        int z2 = (y * sb + z1 * cb) >> 12;
        sx2[i] = SPIN_CX + x1 * SPIN_R / 1000;
        sy2[i] = SPIN_CY + y2 * SPIN_R / 1000;
        sz2[i] = z2;                            /* -1618..1618 depth */
    }
    /* erase: repaint the wallpaper in the spinner's bounding box, with a soft
     * radial glow toward the centre so the gem floats on a halo. The glow is a
     * quadratic falloff (no sqrt) blended into the wallpaper - the box is
     * already swept each frame, so the halo is nearly free. */
    int hs = SPIN_R + 6;
    int gr2 = (SPIN_R + 4) * (SPIN_R + 4);
    for (int y = SPIN_CY - hs; y <= SPIN_CY + hs; y++) {
        if ((unsigned)y >= FBH) continue;
        int dy = y - SPIN_CY;
        uint32_t base = wp_color(y);
        uint32_t *row = FB + (unsigned)y * FBPP;
        for (int x = SPIN_CX - hs; x <= SPIN_CX + hs; x++) {
            if ((unsigned)x >= FBW) continue;
            int dx = x - SPIN_CX, d2 = dx*dx + dy*dy;
            uint32_t c = base;
            if (d2 < gr2) {
                int a = 70 * (gr2 - d2) / gr2;        /* 0..70 toward the centre */
                c = blend(base, 0x1a5a72, a);
            }
            row[x] = c;
        }
    }
    int boost = g_busy ? 60 : 0;                /* P4: the "GPU" glows while thinking */
    /* P5: fill the front-facing faces -> a solid shaded gem. Backface cull by
     * centroid depth (the icosahedron is centred + convex, so its outward face
     * normal ~ the centroid direction): a face is visible iff its centroid is
     * on the camera side (z>0). Flat-shade by that depth (head-on = brighter)
     * for a soft volumetric look; the neon edges then glow on top. */
    int fz[20];                                  /* per-face centroid depth */
    for (int f = 0; f < ICO_NF; f++) {
        int a = ICO_F[f][0], b = ICO_F[f][1], c = ICO_F[f][2];
        int cz = (sz2[a] + sz2[b] + sz2[c]) / 3;
        fz[f] = cz;
        if (cz <= 0) continue;                   /* back face - hidden */
        int bri = 45 + cz * 160 / 1618 + boost;  /* 45..205(+boost) */
        if (bri > 255) bri = 255;
        fill_tri(sx2[a],sy2[a], sx2[b],sy2[b], sx2[c],sy2[c], dim(0x14607e, bri));
    }
    /* neon edges, but only the visible ones: an edge shows iff a face it
     * borders is front-facing (else it's a hidden back edge under the gem). */
    for (int e = 0; e < ICO_NE; e++) {
        int a = ICO_E[e][0], b = ICO_E[e][1], vis = 0;
        for (int f = 0; f < ICO_NF && !vis; f++) {
            unsigned char *F = ICO_F[f];
            int ha = (F[0]==a||F[1]==a||F[2]==a), hb = (F[0]==b||F[1]==b||F[2]==b);
            if (ha && hb && fz[f] > 0) vis = 1;
        }
        if (!vis) continue;
        int avgz = (sz2[a] + sz2[b]) / 2;
        int bri = 90 + (avgz + 1000) * 165 / 2000 + boost;
        if (bri > 255) bri = 255;
        line(sx2[a], sy2[a], sx2[b], sy2[b], dim(ACCENT, bri));
    }
    /* bright nodes at the FRONT vertices only */
    for (int i = 0; i < 12; i++) {
        if (sz2[i] <= 0) continue;
        int bri = 130 + sz2[i] * 125 / 1618;
        uint32_t c = dim(0x9fe8ff, bri > 255 ? 255 : bri);
        for (int dy = -1; dy <= 1; dy++)
            for (int dx = -1; dx <= 1; dx++) px(sx2[i]+dx, sy2[i]+dy, c);
    }
}

/* the static scene: wallpaper, top bar, console glass panel. Drawn once. */
static void draw_agents(void);           /* defined below init_layout */
static void draw_status(uint32_t up);    /* top-bar chip, defined below */

static void draw_static(void) {
    draw_wallpaper();
    /* top bar: near-opaque dark glass with an accent underline */
    glass_panel(0, 0, (int)FBW, TOPBAR, 0x0a1220, 220, 0);
    hline(0, TOPBAR - 1, (int)FBW, ACCENT);
    hline(0, TOPBAR - 2, (int)FBW, 0x0c2a3a);
    panel_shadow(0, 0, (int)FBW, TOPBAR);        /* the bar casts onto the wallpaper */
    draw_text(CELLW, (TOPBAR - CELLH) / 2, "TannX", TITLECOL);
    draw_text(CELLW + 12 * CELLW, (TOPBAR - CELLH) / 2, "Dark Glass", ACCENT2);
    /* console panel: frosted glass, rounded, floating on a soft shadow */
    panel_shadow(PANX, PANY, PANW, PANH);
    glass_panel(PANX, PANY, PANW, PANH, 0x0e1a30, 150, CELLH);
    draw_agents();                       /* live agent roster in the right margin */
    draw_status(sys_uptime());           /* top-bar agent-count chip */
}

/* gridcache (last rendered grid) + cur_cx/cur_cy live in struct gui (top) */

/* a CP437 block/shade cell (the boot logo): nearest-neighbour scaled, no
 * anti-aliasing so blocks tile seamlessly; a non-black VGA background colour
 * fills the unset pixels (half blocks carry two colours). */
static void draw_block(int x0, int y0, unsigned char ch, unsigned char at) {
    int gi = font_cp437_map[ch - 0x80];
    if (!gi) return;
    const unsigned char *g = font_extra[gi - 1];
    uint32_t fg = vga_pal[at & 0x0f];
    int bgi = (at >> 4) & 7;
    uint32_t bg = vga_pal[bgi];
    for (int dy = 0; dy < CELLH; dy++) {
        unsigned bits = g[dy * 16 / CELLH];
        for (int dx = 0; dx < CELLW; dx++) {
            if (bits & (0x80 >> (dx * 8 / CELLW))) px(x0 + dx, y0 + dy, fg);
            else if (bgi) px(x0 + dx, y0 + dy, bg);
        }
    }
}

/* one console cell: glass background (panel tint over the wallpaper, which
 * erases the old glyph) plus the glyph in its VGA colour */
static void draw_cell(int r, int c, unsigned char ch, unsigned char at) {
    int x0 = COX + c * CELLW, y0 = COY + r * CELLH;
    int bgi = (at >> 4) & 7;             /* a VGA background (e.g. the logo's */
    for (int j = 0; j < CELLH; j++) {    /*   OS badge) paints over the glass */
        int yy = y0 + j;
        if ((unsigned)yy >= FBH) continue;
        uint32_t bg = bgi ? vga_pal[bgi] : blend(wp_color(yy), 0x0e1a30, 150);
        uint32_t *row = FB + (unsigned)yy * FBPP;
        for (int i = 0; i < CELLW; i++)
            if ((unsigned)(x0 + i) < FBW) row[x0 + i] = bg;
    }
    if (ch >= 0x80)
        draw_block(x0, y0, ch, at);
    else if (ch >= FONT_FIRST && ch <= FONT_LAST && ch != ' ')
        draw_char(x0, y0, ch, vga_pal[at & 0x0f]);
}

/* redraw ONLY the cells that changed since last frame - so typing costs one
 * cell, not a full repaint of the test PC's slow uncached framebuffer */
static int draw_console(const unsigned char *con) {
    const unsigned char *grid = con + 4;
    int changed = 0;
    for (int r = 0; r < 25; r++)
        for (int c = 0; c < 80; c++) {
            int k = (r * 80 + c) * 2;
            if (grid[k] != gridcache[k] || grid[k + 1] != gridcache[k + 1]) {
                draw_cell(r, c, grid[k], grid[k + 1]);
                gridcache[k] = grid[k]; gridcache[k + 1] = grid[k + 1];
                changed++;
            }
        }
    int ncx = con[0], ncy = con[1];
    if (ncx != cur_cx || ncy != cur_cy) {            /* erase the old underline */
        if (cur_cx >= 0 && cur_cx < 80 && cur_cy < 25) {
            int k = (cur_cy * 80 + cur_cx) * 2;
            draw_cell(cur_cy, cur_cx, gridcache[k], gridcache[k + 1]);
        }
        cur_cx = ncx; cur_cy = ncy;
    }
    if (ncx < 80 && ncy < 25) {
        int x0 = COX + ncx * CELLW, y0 = COY + ncy * CELLH;
        for (int t = 0; t < SC; t++) hline(x0, y0 + CELLH - 1 - t, CELLW, ACCENT);
    }
    return changed;                  /* how much the console moved = OS activity */
}

/* the top-bar accent line "breathes", and brightens when the OS is busy -
 * a calm idle pulse, a lively glow while agents/output stream. */
static void draw_accent(uint32_t up, int active) {
    int think = g_busy;                                /* P4: an agent is working */
    int phase = (int)((up * (think ? 12 : 6)) & 255);  /* faster pulse while thinking */
    int glow = 150 + (SIN(phase) * (think ? 95 : 70) >> 12);
    if (active || think) glow += 35;
    if (glow > 255) glow = 255;
    uint32_t c = dim(ACCENT, glow);
    for (int t = 0; t < SC; t++) hline(0, TOPBAR - 1 - t, (int)FBW, c);
}

/* the live clock in the top bar, right-aligned (uptime as mm:ss) */
static void draw_clock(uint32_t secs) {
    char buf[8];
    uint32_t m = (secs / 60) % 100, s = secs % 60;
    buf[0] = '0' + (m / 10) % 10; buf[1] = '0' + m % 10; buf[2] = ':';
    buf[3] = '0' + s / 10; buf[4] = '0' + s % 10; buf[5] = 0;
    int w = 5 * CELLW;
    int x = (int)FBW - w - CELLW, y = (TOPBAR - CELLH) / 2;
    /* clear the clock area to top-bar glass, then draw */
    for (int j = -2; j < CELLH + 2; j++) {
        int yy = y + j;
        if ((unsigned)yy >= FBH) continue;
        uint32_t bg = blend(wp_color(yy), 0x0a1220, 220);
        for (int i = -CELLW; i < w + CELLW; i++)
            if ((unsigned)(x + i) < FBW) FB[(unsigned)yy * FBPP + x + i] = bg;
    }
    draw_text(x, y, buf, ACCENT);
}

static void dot(int cx, int cy, int r, uint32_t c);   /* defined with the AGENTS panel */

/* top-bar status chip: the live count of working agents + a "thinking" pulse
 * when any of them is busy, read straight from SYS_AGENTS. The AGENTS panel
 * lists them in detail; this is the glanceable summary next to the clock. The
 * chip text/dot brighten and pulse while the OS is actually working (P4). */
static void draw_status(uint32_t up) {
    unsigned char ag[192];
    if (sys_agents(ag) < 0) return;
    int n = 0, busy = 0;
    for (int s = 0; s < 8; s++) {
        if (!ag[s * 8]) continue;
        if (ag[s * 8 + 1] == 4) continue;            /* a program (gui/game/llmscript) */
        n++;
        if (ag[s * 8 + 2] == 1) busy = 1;            /* status 1 = running a task */
    }
    g_busy = busy;                                    /* P4: drives the accent/spinner pulse */
    char buf[12]; int i = 0;
    buf[i++]='A'; buf[i++]='G'; buf[i++]='E'; buf[i++]='N'; buf[i++]='T'; buf[i++]='S'; buf[i++]=' ';
    if (n >= 10) buf[i++] = '0' + (n / 10) % 10;
    buf[i++] = '0' + n % 10; buf[i] = 0;
    int chh = CELLH + CELLW / 2, chy = (TOPBAR - chh) / 2;
    int xr = (int)FBW - 7 * CELLW;                    /* right edge, left of the clock */
    int cw = ((int)strlen(buf)) * CELLW + CELLW;
    int x = xr - cw;
    if (x < 20 * CELLW) return;                       /* would hit the title: skip */
    /* clear the strip back to top-bar glass (above the accent line) */
    for (int yy = chy - 2; yy < chy + chh + 2 && yy < TOPBAR - 2; yy++) {
        if ((unsigned)yy >= FBH) continue;
        uint32_t bg = blend(wp_color(yy), 0x0a1220, 220);
        uint32_t *row = FB + (unsigned)yy * FBPP;
        for (int xx = x - CELLW; xx <= xr; xx++)
            if ((unsigned)xx < FBW) row[xx] = bg;
    }
    /* a pulsing dot when busy, calm grey when idle */
    int ph = (int)((up * 8) & 255);
    int glow = busy ? 150 + (SIN(ph) * 90 >> 12) : 70;     /* 60..240 pulse / dim */
    uint32_t accent = busy ? dim(ACCENT, glow > 255 ? 255 : glow) : 0x3a4760;
    glass_panel(x, chy, cw, chh, 0x14233f, 200, chh / 3);
    dot(x + CELLW / 2 + CELLW / 4, chy + chh / 2, CELLW / 5, accent);
    draw_text(x + CELLW, chy + CELLW / 4, buf, busy ? 0xe8eefc : 0xc8d2e0);
}

/* ---- the live AGENTS panel: "the agents do the work", made visible ------ */
static const char *typ_name(int t) {
    switch (t) {
        case 0: return "math";  case 1: return "scan";  case 2: return "count";
        case 3: return "prime"; case 5: return "ask";   default: return "agent";
    }
}
static void dot(int cx, int cy, int r, uint32_t c) {     /* small status dot */
    for (int dy = -r; dy <= r; dy++)
        for (int dx = -r; dx <= r; dx++)
            if (dx*dx + dy*dy <= r*r) px(cx + dx, cy + dy, c);
}
static void draw_uint(int x, int y, uint32_t v, uint32_t col) {
    char b[12]; int i = 0;
    if (!v) b[i++] = '0';
    while (v && i < 11) { b[i++] = '0' + (int)(v % 10); v /= 10; }
    for (int j = i - 1; j >= 0; j--) { draw_char(x, y, (unsigned char)b[j], col); x += CELLW; }
}

/* one glass panel in the right margin (above the spinner) listing every
 * working agent: a status dot (lit = running), its type, and its result. */
static void draw_agents(void) {
    unsigned char ag[192];
    if (sys_agents(ag) < 0) return;
    int pad = CELLH / 2;
    int agx = PANX + PANW + pad;
    int agw = (int)FBW - agx - pad;
    int agy = TOPBAR + pad;
    int agh = SPIN_CY - SPIN_R - CELLH - agy;
    if (agw < 7 * CELLW || agh < 4 * CELLH) return;       /* no room */
    panel_shadow(agx, agy, agw, agh);
    glass_panel(agx, agy, agw, agh, 0x0e1a30, 150, pad);
    draw_text(agx + pad, agy + pad, "AGENTS", ACCENT2);
    int row = 0, maxrows = (agh - 2 * CELLH) / CELLH;
    for (int s = 0; s < 8 && row < maxrows; s++) {
        if (!ag[s * 8]) continue;                          /* slot free */
        int typ = ag[s * 8 + 1];
        if (typ == 4) continue;                            /* a program (gui/game) */
        int status = ag[s * 8 + 2];                        /* 1 = busy */
        int tidx = ag[s * 8 + 3];
        int y = agy + pad + (row + 1) * CELLH + CELLH / 4;
        dot(agx + pad + CELLW / 2, y + CELLH / 2, CELLW / 3,
            status ? ACCENT : 0x3a4760);
        draw_text(agx + 2 * CELLW, y, typ_name(typ), 0xc8d2e0);
        if (tidx < 8) {                                    /* its task's result */
            int b = 64 + tidx * 16;                        /* bound tidx
                                  to 0-7 (was only != 0xff) - the tasks_tbl half
                                  of the 192-byte snapshot has just 8 slots, so a
                                  larger index would read past the buffer */
            if (ag[b + 2] == 2) {                          /* task status = done */
                uint32_t res = ag[b+12] | (ag[b+13]<<8) | (ag[b+14]<<16) | ((uint32_t)ag[b+15]<<24);
                draw_uint(agx + 8 * CELLW, y, res, 0x86efac);
            }
        }
        row++;
    }
    if (!row)
        draw_text(agx + pad, agy + pad + CELLH + CELLH/4, "idle", 0x55617a);
}

/* (re)acquire the framebuffer and recompute the layout. Called at start AND
 * after a foreground game exits: every ring-3 program is the same image at
 * 0x400000, so a game's crt0 re-zeroes the shared .bss - including our globals
 * (FB, FBW, the layout, spin tables). We step aside while the game runs (the
 * fg_prog flag is set before its crt0 runs, so we're not drawing during the
 * wipe), then rebuild here. Returns 0 on success, -1 if there is no FB. */
static int init_layout(void) {
    /* Prefer virtio-gpu (QEMU): render into its user-RAM backing and present
     * each frame - a real "GPU" path. Falls back to the firmware framebuffer
     * (the bare-metal test PC and every non-virtio boot) when there is no virtio-gpu. */
    int vw, vh;
    uint32_t *vfb = vgpu_setup(&vw, &vh);
    if (vfb) {
        FB = vfb; FBW = vw; FBH = vh; FBPP = vw; vgpu_on = 1;
    } else {
        fb_t fb;
        if (fb_get(&fb) < 0) { FBW = 0; return -1; }
        FB = fb.base; FBW = fb.w; FBH = fb.h; FBPP = fb.ppsl; vgpu_on = 0;
    }
    SC = 1;
    while (SC < 4 && 80 * 8 * (SC + 1) <= (int)FBW - 120
                  && 25 * 16 * (SC + 1) <= (int)FBH - 200) SC++;
    CELLW = 8 * SC; CELLH = 16 * SC;
    TOPBAR = CELLH * 2;
    PANW = 80 * CELLW + 2 * CELLH;
    PANH = 25 * CELLH + 2 * CELLH;
    PANX = ((int)FBW - PANW) / 2;
    PANY = TOPBAR + ((int)FBH - TOPBAR - PANH) / 2;
    if (PANY < TOPBAR + CELLH) PANY = TOPBAR + CELLH;
    COX = PANX + CELLH; COY = PANY + CELLH;
    spin_init();
    int rmargin = (int)FBW - (PANX + PANW);
    SPIN_CX = (PANX + PANW + (int)FBW) / 2;
    SPIN_CY = (int)FBH / 2;
    SPIN_R = rmargin / 2 - 18;
    { int vr = ((int)FBH - TOPBAR) / 2 - 18; if (SPIN_R > vr) SPIN_R = vr; }
    SPIN_ON = (SPIN_R >= 40);
    return 0;
}

int gui_main(void) {
    if (init_layout() < 0) return -1;
    memset(gridcache, 0, 4000);          /* struct gui is at a fixed RAM addr, */
    cur_cx = cur_cy = -1;                 /*   not zeroed for us - initialise it */
    g_busy = 0;
    unsigned char *con = G->con;          /* in the fixed state region, NOT on the
                                           * 4 KB stack (it would overflow it) */
    draw_static();
    uint32_t last_sec = 0xffffffff, last_act = 0, last_present = 0xffffffff;
    int ang = -1, was_fg = 0;

    for (;;) {
        sys_console(con);
        if (con[2]) {                       /* a foreground game owns the screen: */
            was_fg = 1;                      /*   step aside so it has the FB to itself */
            sys_yield();
            continue;
        }
        if (was_fg) {                        /* the game just exited - reclaim the screen */
            was_fg = 0;
            /* the game is the same user.bin image at 0x400000, so its crt0 zeroed
             * the shared .bss - including vgpu.c's state (vg_fb/desc/used16/...) and
             * possibly its malloc'd backing. On the firmware FB only FBW (in the
             * fixed struct gui) matters; on virtio-gpu we MUST re-run vgpu_setup or
             * vgpu_present() sees vg_fb==0 and the scanout stays frozen. */
            if (!FBW || vgpu_on) init_layout();
            memset(gridcache, 0, 4000);      /*   force every console cell to redraw */
            cur_cx = cur_cy = -1;
            draw_static();
            last_sec = 0xffffffff;           /*   force the clock to redraw too */
        }
        int changed = draw_console(con);    /* diff-based: only changed cells redraw */
        uint32_t up = sys_uptime();
        if (changed) last_act = up;          /* the console moved -> the OS is busy */
        int active = (up - last_act) < 9;    /* ...for the next ~0.5 s */
        draw_accent(up, active);             /* breathing accent line, brighter when busy */
        uint32_t secs = up / 18;
        if (secs != last_sec) {
            draw_clock(secs); draw_agents(); draw_status(up);
            last_sec = secs;
        }
        /* rotation tied to real time (not frame count), and we ALWAYS yield
         * below - so even when a redraw on the test PC's slow uncached framebuffer
         * takes more than a tick, the compositor never hogs the CPU and the
         * shell keeps taking commands. */
        /* P4: the icosahedron spins twice as fast while an agent works - a
         * clear live "the OS is thinking" cue (motion, not just brightness). */
        int na = (int)((up * (g_busy ? 6 : 3)) & 255);
        if (SPIN_ON && na != ang) { ang = na; draw_spinner(ang); }
        /* on virtio-gpu, push the rendered frame to the scanout (~18 fps; the
         * firmware-FB path needs no present - writes land on screen directly) */
        if (vgpu_on && up != last_present) { vgpu_present(); last_present = up; }
        sys_yield();
    }
    return 0;
}
