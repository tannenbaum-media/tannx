/* invaders.c - TannX OS space invaders, now a ring-3 C program.
 *
 * Faithful port of the kernel game (former do_invaders in agentos32.S):
 * 32 aliens (4x8) in a formation that speeds up as they thin out, a player
 * ship on row 23, a 6-shot bullet pool, alien bombs, a bonus UFO, eroding
 * bunkers, the spread-shot power-up that morphs the ship sprite, extra-life
 * pickups, lives, waves and the same scoring. Same 80x25 logical grid as the
 * kernel for byte-identical mechanics - but it renders the real 8x16 sprite
 * bitmaps scaled up to fill 1:2 cells, straight into the framebuffer.
 *
 * Launch: 'run invaders'. Controls: A/D move, SPACE fire, P pause, Q quit.
 * (Arrows can't reach ring 3 - the kernel only feeds printable ASCII to the
 *  SYS_GETKEY ring - so A/D/SPACE is the control set, as on serial.)
 *
 * Sound (the kernel's PC-speaker blips) is intentionally absent for now:
 * ring 3 can't touch port 0x61 and there is no SYS_BEEP syscall yet. It
 * returns once the kernel asm games are removed and that space buys it.
 */
#include "libc.h"

#define GW 80
#define GH 25
#define SHIP_ROW 23

/* ---- VGA palette (attr low nibble -> xRGB; FB is BGRx so 0x00RRGGBB ok) */
static const uint32_t PAL[16] = {
    0x00000000,0x000000AA,0x0000AA00,0x0000AAAA,
    0x00AA0000,0x00AA00AA,0x00AA5500,0x00AAAAAA,
    0x00555555,0x000000FF,0x0000FF00,0x0000FFFF,
    0x00FF0000,0x00FF00FF,0x00FFFF00,0x00FFFFFF,
};
/* note: kernel attrs are BGR-ish nibbles (1=blue,4=red); the PAL above keeps
 * the classic VGA colours: 0xB cyan, 0xD magenta, 0xA green, 0xE yellow,
 * 0xC red, 0xF white. */

/* ---- 8x16 sprite bitmaps (MSB = leftmost), lifted from the kernel ----- */
static const uint8_t SPR_ALIEN[16] =
  {0x00,0x00,0x42,0x24,0x3C,0x7E,0xDB,0xFF,0xFF,0x66,0x24,0x42,0x81,0x00,0x00,0x00};
static const uint8_t SPR_SHIP[16] =
  {0x00,0x00,0x18,0x18,0x3C,0x3C,0x7E,0x7E,0xFF,0xFF,0xFF,0xDB,0xDB,0x99,0x00,0x00};
static const uint8_t SPR_SHIPP[16] =
  {0x00,0x18,0x18,0x3C,0x3C,0x7E,0xFF,0xFF,0xFF,0xE7,0xE7,0xC3,0xC3,0x81,0x00,0x00};
static const uint8_t SPR_BULL[16] =
  {0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18};
static const uint8_t SPR_BOMB[16] =
  {0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08,0x10,0x08};
static const uint8_t SPR_UFO[16] =
  {0x00,0x00,0x00,0x00,0x3C,0x7E,0xDB,0xFF,0xFF,0x7E,0x3C,0x18,0x00,0x00,0x00,0x00};
static const uint8_t SPR_BUNK[16] =
  {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF};
static const uint8_t SPR_PWR[16] =
  {0x00,0x00,0x3C,0x42,0x99,0xA5,0xA5,0xA5,0xA5,0xA5,0x99,0x42,0x3C,0x00,0x00,0x00};

static const uint8_t *bitmap_for(unsigned char c) {
    switch (c) {
    case 'W': return SPR_ALIEN;
    case '^': return SPR_SHIP;
    case 'Y': return SPR_SHIPP;
    case '|': return SPR_BULL;
    case 'v': return SPR_BOMB;
    case 'U': return SPR_UFO;
    case '@': return SPR_BUNK;
    case '&': return SPR_PWR;
    default:  return 0;
    }
}

/* ---- a small HUD font (digits + the few letters the HUD/title need) --- */
static const char FCHARS[] = " 0123456789SCOREWAVLINPTUDGM.:";
static const uint8_t FDATA[][8] = {
    {0,0,0,0,0,0,0,0},                                 /* ' ' */
    {0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0},            /* 0 */
    {0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0},            /* 1 */
    {0x3C,0x66,0x06,0x0C,0x18,0x30,0x7E,0},            /* 2 */
    {0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0},            /* 3 */
    {0x0C,0x1C,0x3C,0x6C,0x7E,0x0C,0x0C,0},            /* 4 */
    {0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0},            /* 5 */
    {0x1C,0x30,0x60,0x7C,0x66,0x66,0x3C,0},            /* 6 */
    {0x7E,0x06,0x0C,0x18,0x30,0x30,0x30,0},            /* 7 */
    {0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0},            /* 8 */
    {0x3C,0x66,0x66,0x3E,0x06,0x0C,0x38,0},            /* 9 */
    {0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0},            /* S */
    {0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0},            /* C */
    {0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0},            /* O */
    {0x7C,0x66,0x66,0x7C,0x6C,0x66,0x66,0},            /* R */
    {0x7E,0x60,0x60,0x7C,0x60,0x60,0x7E,0},            /* E */
    {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0},            /* W */
    {0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0},            /* A */
    {0x66,0x66,0x66,0x66,0x3C,0x3C,0x18,0},            /* V */
    {0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0},            /* L */
    {0x18,0x18,0x18,0x18,0x18,0x18,0x18,0},            /* I */
    {0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0},            /* N */
    {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0},            /* P */
    {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0},            /* T (=P glyph reuse) */
    {0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0},            /* U */
    {0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0},            /* D */
    {0x3C,0x66,0x60,0x6E,0x66,0x66,0x3C,0},            /* G */
    {0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0},            /* M */
    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0},            /* . */
    {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0},            /* : */
};

/* ---- framebuffer geometry -------------------------------------------- */
static fb_t fb;
static int  cw, chh;       /* cell width / height (1:2 like the 8x16 glyph) */
static int  ox, oy;        /* grid origin                                  */

/* compose buffers: what each cell shows now vs last frame (flicker-free)  */
static unsigned char cur[GW * GH], cur_a[GW * GH];
static unsigned char prv[GW * GH], prv_a[GW * GH];

/* ---- HUD text via the shared 8x8 renderer in libc, with our font ------ */
#define draw_str(x, y, s, sc, col) \
    fb_text(&fb, (x), (y), (s), (sc), (col), FCHARS, FDATA)

/* ---- one cell -> a scaled 8x16 sprite (or background) ---------------- */
static void draw_cell(int col, int row) {
    int px = ox + col * cw, py = oy + row * chh;
    int idx = row * GW + col;
    const uint8_t *bm = bitmap_for(cur[idx]);
    if (!bm) { fb_fillrect(&fb, px, py, cw, chh, 0x00000000u); return; }
    uint32_t fg = PAL[cur_a[idx] & 15];
    for (int y = 0; y < chh; y++) {
        uint8_t bits = bm[y * 16 / chh];
        for (int x = 0; x < cw; x++) {
            uint32_t c = (bits & (0x80 >> (x * 8 / cw))) ? fg : 0x00000000u;
            fb_putpixel(&fb, px + x, py + y, c);
        }
    }
}

/* ---- game state ------------------------------------------------------- */
static uint32_t alive;
static int inv_x, inv_y, inv_dir, score, period, timer;
static int ship_col, lives, wave, dead;
static int pb_r[6], pb_c[6], pb_cool;
static int ab_active, ab_row, ab_col, ab_timer;
static int ufo_active, ufo_col, ufo_dir, ufo_mt, ufo_timer;
static int pu_active, pu_col, pu_row, pu_type, pu_mt, spread_timer;
static unsigned char bnk[GW * GH];
static int hud_score = -1, hud_wave = -1, hud_lives = -1;

static const uint8_t ROW_ATTR[4] = {0x0B,0x0D,0x0A,0x0E};
static const int      ROW_PTS[4]  = {40,30,20,10};

/* ---- LCG, identical to the kernel rand16 ----------------------------- */
static uint32_t rnd_seed;
static uint32_t rnd(void) { rnd_seed = (rnd_seed * 25173 + 13849) & 0xFFFF; return rnd_seed; }

static int popcount(uint32_t v) { int n = 0; while (v) { n += v & 1; v >>= 1; } return n; }

/* alien i -> (row,col) cell; each alien is 3 cells apart horizontally */
static int alien_row(int i) { return inv_y + (i >> 3); }
static int alien_col(int i) { return inv_x + (i & 7) * 3; }

static void formation_bounds(int *minc, int *maxc, int *maxr) {
    int lo = 99, hi = -99, mr = -99;
    for (int i = 0; i < 32; i++) if (alive & (1u << i)) {
        int c = i & 7, r = i >> 3;
        if (c < lo) lo = c;
        if (c > hi) hi = c;
        if (r > mr) mr = r;
    }
    *minc = lo; *maxc = hi; *maxr = mr;
}

/* ---- HUD (redrawn only when a value changes) ------------------------- */
static void draw_hud(void) {
    if (score == hud_score && wave == hud_wave && lives == hud_lives) return;
    hud_score = score; hud_wave = wave; hud_lives = lives;
    int sc = cw / 8; if (sc < 1) sc = 1;
    int y = oy + chh / 2;
    fb_fillrect(&fb, ox, oy, GW * cw, chh, 0x00000000u);   /* clear row 0 */
    char num[6]; int x = ox + cw;
    draw_str(x, y, "SCORE", sc, PAL[0x0B]); x += 6 * 7 * sc;
    for (int i = 4, v = score; i >= 0; i--) { num[i] = '0' + v % 10; v /= 10; } num[5] = 0;
    draw_str(x, y, num, sc, PAL[0x0F]);     x += 6 * 7 * sc;
    draw_str(x, y, "WAVE", sc, PAL[0x0E]);  x += 5 * 7 * sc;
    for (int i = 4, v = wave; i >= 0; i--) { num[i] = '0' + v % 10; v /= 10; } num[5] = 0;
    draw_str(x, y, num, sc, PAL[0x0F]);     x += 6 * 7 * sc;
    draw_str(x, y, "LIVES", sc, PAL[0x0A]); x += 6 * 7 * sc;
    /* lives as little cyan ships */
    for (int l = 0; l < lives; l++) {
        int lx = x + l * 5 * sc;
        for (int r = 0; r < 16; r++)
            for (int b = 0; b < 8; b++)
                if (SPR_SHIP[r] & (0x80 >> b))
                    fb_fillrect(&fb, lx + b * (sc / 2 ? sc / 2 : 1),
                                y + r * (sc / 2 ? sc / 2 : 1),
                                sc / 2 ? sc / 2 : 1, sc / 2 ? sc / 2 : 1, PAL[0x0B]);
    }
}

/* ---- compose the frame and flush only the cells that changed --------- */
static void stamp(int row, int col, unsigned char ch, unsigned char at) {
    if (row < 0 || row >= GH || col < 0 || col >= GW) return;
    cur[row * GW + col] = ch; cur_a[row * GW + col] = at;
}
static void render(void) {
    memset(cur, 0, sizeof(cur)); memset(cur_a, 0, sizeof(cur_a));
    for (int i = 0; i < GW * GH; i++) if (bnk[i]) { cur[i] = '@'; cur_a[i] = 0x0A; }
    for (int i = 0; i < 32; i++) if (alive & (1u << i))
        stamp(alien_row(i), alien_col(i), 'W', ROW_ATTR[i >> 3]);
    if (ufo_active) stamp(2, ufo_col, 'U', 0x0C);
    if (pu_active)  stamp(pu_row, pu_col, '&', pu_type ? 0x0B : 0x0A);
    for (int s = 0; s < 6; s++) if (pb_r[s]) stamp(pb_r[s], pb_c[s], '|', 0x0E);
    if (ab_active)  stamp(ab_row, ab_col, 'v', 0x0C);
    stamp(SHIP_ROW, ship_col, spread_timer > 0 ? 'Y' : '^', spread_timer > 0 ? 0x0A : 0x0B);

    if (!cw) return;
    for (int r = 2; r <= SHIP_ROW; r++)
        for (int c = 0; c < GW; c++) {
            int i = r * GW + c;
            if (cur[i] != prv[i] || cur_a[i] != prv_a[i]) {
                draw_cell(c, r); prv[i] = cur[i]; prv_a[i] = cur_a[i];
            }
        }
    draw_hud();
}

/* ---- bunkers: four little blocks just above the ship ----------------- */
static void build_bunkers(void) {
    memset(bnk, 0, sizeof(bnk));
    for (int b = 0; b < 4; b++) {
        int c0 = 12 + b * 17;
        for (int r = 20; r <= 21; r++)
            for (int c = c0; c < c0 + 5; c++)
                bnk[r * GW + c] = 1;
    }
}

/* ---- wave (re)spawn -------------------------------------------------- */
static void new_wave(void) {
    alive = 0xFFFFFFFFu;
    inv_x = 28; inv_dir = 1;
    int off = wave - 1; if (off > 5) off = 5;
    inv_y = 3 + off;
    period = 2 + (32 >> 2) - (wave - 1);
    if (period < 2) period = 2;
    timer = period;
    ab_active = ufo_active = pu_active = 0;
    ufo_timer = 200 + (int)(rnd() & 127);
    for (int s = 0; s < 6; s++) pb_r[s] = 0;
}

/* ---- fire (single, or three-way when spread is active) --------------- */
static void fire(void) {
    if (pb_cool > 0) return;
    int cols[3], n = 1; cols[0] = ship_col;
    if (spread_timer > 0) { cols[1] = ship_col - 1; cols[2] = ship_col + 1; n = 3; }
    for (int k = 0; k < n; k++) {
        for (int s = 0; s < 6; s++) if (!pb_r[s]) {
            pb_r[s] = SHIP_ROW - 1; pb_c[s] = cols[k]; break;
        }
    }
    pb_cool = spread_timer > 0 ? 2 : 3;
}

/* a player bullet reached cell (r,c): hit a bunker / alien / ufo? -> 1 if consumed */
static int bullet_hit(int r, int c) {
    int i = r * GW + c;
    if (r >= 0 && r < GH && bnk[i]) { bnk[i] = 0; return 1; }
    for (int a = 0; a < 32; a++) if (alive & (1u << a))
        if (alien_row(a) == r && alien_col(a) == c) {
            alive &= ~(1u << a);
            score += ROW_PTS[a >> 3];
            if ((rnd() & 3) == 0 && !pu_active) {       /* ~25% power-up drop */
                pu_active = 1; pu_row = r; pu_col = c;
                pu_type = (int)(rnd() & 1); pu_mt = 3;
            }
            return 1;
        }
    if (ufo_active && r == 2 && c == ufo_col) {
        ufo_active = 0; score += 100; ufo_timer = 200 + (int)(rnd() & 127);
        return 1;
    }
    return 0;
}

static void lose_life(void) {
    lives--;
    ab_active = 0;
    if (lives <= 0) { dead = 1; }
}

int invaders_main(void) {
    print("invaders: ready\r\n");

    if (fb_get(&fb) < 0) {           /* serial-only boot: simulate, don't draw */
        fb.base = 0; fb.w = GW; fb.h = GH; fb.ppsl = GW; cw = chh = 0; ox = oy = 0;
    } else {
        /* 1:2 cells (8x16 sprite aspect): 80 wide, 25 tall (=50 half-rows) */
        int s = (int)fb.w / GW; int t = (int)fb.h / (GH * 2);
        cw = s < t ? s : t; if (cw < 3) cw = 3; chh = cw * 2;
        ox = ((int)fb.w - GW * cw) / 2;
        oy = ((int)fb.h - GH * chh) / 2;
    }

    rnd_seed = sys_uptime() ^ 0x1234;
    ship_col = 40; lives = 3; wave = 1; score = 0; dead = 0;
    pb_cool = 0; spread_timer = 0;
    build_bunkers();
    new_wave();
    if (cw) { fb_fillrect(&fb, 0, 0, (int)fb.w, (int)fb.h, 0x00000000u);
              memset(prv, 0xff, sizeof(prv)); render(); }

    uint32_t frame = 0;
    for (;;) {
        /* pace: one frame per tick, steering/firing polled throughout */
        uint32_t t0 = sys_uptime();
        do {
            int k = sys_getkey();
            if (k == 'q' || k == KEY_ESC) {
                printf("invaders: quit. Score: %d\r\n", score);
                return 0;
            }
            if (k == 'p') {
                if (cw) draw_str(ox + GW * cw / 2 - 60, oy + GH * chh / 2, "PAUSE", 3, PAL[0x0E]);
                for (;;) { int p = sys_getkey();
                    if (p == 'p' || p == ' ') break;
                    if (p == 'q' || p == KEY_ESC) { printf("invaders: quit. Score: %d\r\n", score); return 0; }
                    sys_yield(); }
                if (cw) { memset(prv, 0xff, sizeof(prv)); fb_fillrect(&fb,0,0,(int)fb.w,(int)fb.h,0); render(); }
                t0 = sys_uptime();
            }
            else if (k == 'a') { ship_col -= 2; if (ship_col < 1) ship_col = 1; }
            else if (k == 'd') { ship_col += 2; if (ship_col > 78) ship_col = 78; }
            else if (k == ' ') fire();
            sys_yield();
        } while (sys_uptime() - t0 < 1);

        if (pb_cool > 0) pb_cool--;
        if (spread_timer > 0) spread_timer--;

        /* player bullets: up one row/frame, collide, despawn off the top */
        for (int s = 0; s < 6; s++) if (pb_r[s]) {
            pb_r[s]--;
            if (pb_r[s] < 2) { pb_r[s] = 0; continue; }
            if (bullet_hit(pb_r[s], pb_c[s])) pb_r[s] = 0;
        }

        /* alien formation step every `period` frames */
        if (--timer <= 0) {
            int minc, maxc, maxr; formation_bounds(&minc, &maxc, &maxr);
            if (alive) {
                int nx = inv_x + inv_dir;
                if (nx + minc * 3 < 1 || nx + maxc * 3 > 78) {
                    inv_dir = -inv_dir; inv_y++;
                    if (inv_y + maxr >= SHIP_ROW) dead = 1;
                } else inv_x = nx;
                /* maybe drop a bomb from a random alive alien (~1/3) */
                if (!ab_active && (rnd() % 3) == 0) {
                    int pick = (int)(rnd() & 31);
                    for (int t = 0; t < 32; t++) {
                        int a = (pick + t) & 31;
                        if (alive & (1u << a)) {
                            ab_active = 1; ab_row = alien_row(a) + 1;
                            ab_col = alien_col(a); ab_timer = 2; break;
                        }
                    }
                }
            }
            period = 2 + (popcount(alive) >> 2) - (wave - 1);
            if (period < 2) period = 2;
            timer = period;
        }

        /* alien bomb falls one row every 2 frames */
        if (ab_active && --ab_timer <= 0) {
            ab_timer = 2; ab_row++;
            int i = ab_row * GW + ab_col;
            if (ab_row >= 0 && ab_row < GH && bnk[i]) { bnk[i] = 0; ab_active = 0; }
            else if (ab_row >= SHIP_ROW) {
                if (ab_col == ship_col) lose_life();
                ab_active = 0;
            }
        }

        /* UFO: spawns from the left, crosses the top, +100 if shot */
        if (!ufo_active) {
            if (--ufo_timer <= 0) { ufo_active = 1; ufo_col = 1; ufo_dir = 1; ufo_mt = 2; }
        } else if (--ufo_mt <= 0) {
            ufo_mt = 2; ufo_col += ufo_dir;
            if (ufo_col < 1 || ufo_col > 78) { ufo_active = 0; ufo_timer = 200 + (int)(rnd() & 127); }
        }

        /* power-up capsule drifts down; caught at the ship row -> effect */
        if (pu_active && --pu_mt <= 0) {
            pu_mt = 3; pu_row++;
            if (pu_row >= SHIP_ROW) {
                if (pu_col >= ship_col - 1 && pu_col <= ship_col + 1) {
                    if (pu_type) spread_timer = 360;          /* spread shot  */
                    else if (lives < 6) lives++;              /* extra life   */
                    score += 50;
                }
                pu_active = 0;
            }
        }

        render();

        if (!alive) { wave++; new_wave(); if (cw) { memset(prv,0xff,sizeof(prv)); render(); } }

        if (dead) {
            if (cw) draw_str(ox + GW * cw / 2 - 130, oy + GH * chh / 2, "GAME OVER", 4, PAL[0x0C]);
            printf("invaders: game over. Score: %d\r\n", score);
            uint32_t te = sys_uptime();
            for (;;) { int k = sys_getkey();
                if (k == ' ') {                               /* restart */
                    ship_col = 40; lives = 3; wave = 1; score = 0; dead = 0;
                    pb_cool = 0; spread_timer = 0;
                    hud_score = hud_wave = hud_lives = -1;
                    build_bunkers(); new_wave();
                    if (cw) { fb_fillrect(&fb,0,0,(int)fb.w,(int)fb.h,0); memset(prv,0xff,sizeof(prv)); render(); }
                    break;
                }
                if (k == 'q' || k == KEY_ESC || sys_uptime() - te >= 90) {
                    printf("invaders: quit. Score: %d\r\n", score);
                    return 0;
                }
                sys_yield();
            }
        }
        frame++;
    }
}
