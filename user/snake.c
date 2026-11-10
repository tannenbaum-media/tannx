/* snake.c - the TannX OS snake game, now a ring-3 C program.
 *
 * Faithful port of the kernel easter egg (former do_snake in agentos32.S):
 * same 80x25 logical grid, same speed curve max(1, 3 - len/16) ticks/step,
 * +10 points per food, the same 25173/13849 LCG food placement, and
 * die-on-wall/die-on-self rules. The difference is it draws straight into
 * the framebuffer (SYS_FBINFO) instead of VGA text cells, and only talks to
 * the kernel through INT 0x30 - so it costs the kernel nothing.
 *
 * Launch: 'run snake'. Controls: WASD to steer, P pause, Q/Esc quit.
 * (Arrow keys can't reach ring 3 - the kernel only feeds printable ASCII to
 *  the SYS_GETKEY ring - so WASD is the steering, same as serial play.)
 *
 * Sound (the eat/die PC-speaker blips) is intentionally absent for now:
 * ring 3 can't touch port 0x61, and there is no SYS_BEEP yet. It comes back
 * once the kernel asm games are removed and that space buys the syscall.
 */
#include "libc.h"

/* ---- the logical board: identical geometry to the kernel game --------- */
#define GW 80
#define GH 25
/* frame ring: row 2 and row 24, col 0 and col 79 (rows 2..24).
 * interior play area: rows 3..23, cols 1..78. */
#define PLAY_R0 3
#define PLAY_R1 23
#define PLAY_C0 1
#define PLAY_C1 78

enum { EMPTY = 0, WALL = 1, SNAKE = 2, FOOD = 3 };

static unsigned char board[GW * GH];

/* body ring buffer of cell indices, exactly like snake_buf (256 entries) */
static uint16_t body[256];
static int      b_head, b_tail, s_len, s_dir, s_score;
static int      head_col, head_row;

/* ---- colours (xRGB, the framebuffer is BGRx so 0x00RRGGBB is correct) - */
#define COL_BG      0x00101018u      /* interior                          */
#define COL_OUT     0x00000000u      /* outside the grid                  */
#define COL_WALL    0x00AA5500u      /* brown frame  (VGA attr 0x6)       */
#define COL_SNAKE   0x0055FF55u      /* bright green (attr 0xA)           */
#define COL_HEAD    0x00AAFFAAu      /* lighter green head                */
#define COL_FOOD    0x00FF5555u      /* bright red   (attr 0xC)           */
#define COL_SCORE   0x0055FF55u      /* "SCORE" label - green             */
#define COL_LEN     0x00FFFF55u      /* "LEN"  label - yellow             */
#define COL_NUM     0x00FFFFFFu      /* digits - white                    */
#define COL_TITLE   0x0055FF55u

/* ---- a tiny 8x8 font, only the glyphs the HUD/title need -------------- */
static const char FONT_CHARS[] = " 0123456789SCORELN:AKEPTQU.WDIMVG";
static const uint8_t FONT_DATA[][8] = {
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
    {0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0},            /* L */
    {0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0},            /* N */
    {0x00,0x18,0x18,0x00,0x00,0x18,0x18,0},            /* : */
    {0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0},            /* A */
    {0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0},            /* K */
    {0x7E,0x60,0x60,0x7C,0x60,0x60,0x7E,0},            /* E (dup index for word) */
    {0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0},            /* P */
    {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0},            /* T */
    {0x3C,0x66,0x66,0x66,0x6E,0x3C,0x06,0},            /* Q */
    {0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0},            /* U */
    {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0},            /* . */
    {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0},            /* W */
    {0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0},            /* D */
    {0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0},            /* I */
    {0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0},            /* M */
    {0x66,0x66,0x66,0x66,0x3C,0x3C,0x18,0},            /* V */
    {0x3C,0x66,0x60,0x6E,0x66,0x66,0x3C,0},            /* G */
};

/* ---- framebuffer geometry (filled by snake_main) --------------------- */
static fb_t fb;
static int  cs;            /* cell size in pixels                         */
static int  ox, oy;        /* top-left of the grid inside the screen      */

/* HUD text via the shared 8x8 renderer in libc, with our own font table */
#define draw_str(x, y, s, sc, col) \
    fb_text(&fb, (x), (y), (s), (sc), (col), FONT_CHARS, FONT_DATA)

/* write a 0-padded 5-digit decimal of v into buf[0..4] */
static void dec5(char *buf, int v) {
    for (int i = 4; i >= 0; i--) { buf[i] = '0' + (v % 10); v /= 10; }
    buf[5] = 0;
}

/* ---- one cell -> one block in the framebuffer ------------------------ */
static void draw_cell(int col, int row) {
    int px = ox + col * cs, py = oy + row * cs;
    unsigned char k = board[row * GW + col];
    uint32_t bg = (row >= 2 && row <= 24 && col >= 0 && col <= 79)
                  ? COL_BG : COL_OUT;
    if (k == WALL) { fb_fillrect(&fb, px, py, cs, cs, COL_WALL); return; }
    fb_fillrect(&fb, px, py, cs, cs, bg);
    if (k == SNAKE) {
        uint32_t c = (col == head_col && row == head_row) ? COL_HEAD : COL_SNAKE;
        fb_fillrect(&fb, px + 1, py + 1, cs - 2, cs - 2, c);
    } else if (k == FOOD) {
        int q = cs / 4;
        fb_fillrect(&fb, px + q, py + q, cs - 2 * q, cs - 2 * q, COL_FOOD);
    }
}

/* ---- HUD: SCORE and LEN, redrawn only when they change --------------- */
static void draw_hud(void) {
    int sc = cs / 8; if (sc < 1) sc = 1;
    int y = oy + cs / 2;
    /* clear the HUD strip (rows 0..1 of the grid) */
    fb_fillrect(&fb, ox, oy, GW * cs, cs * 2, COL_OUT);
    char num[6];
    int x = ox + cs;
    draw_str(x, y, "SCORE", sc, COL_SCORE); x += 6 * 7 * sc;
    dec5(num, s_score);
    draw_str(x, y, num, sc, COL_NUM);       x += 6 * 7 * sc;
    draw_str(x, y, "LEN", sc, COL_LEN);     x += 4 * 7 * sc;
    dec5(num, s_len);
    draw_str(x, y, num, sc, COL_NUM);
}

/* ---- LCG food placement, identical to the kernel rand16 -------------- */
static uint32_t rnd_seed;
static uint32_t rand16(void) {
    rnd_seed = (rnd_seed * 25173 + 13849) & 0xFFFF;
    return rnd_seed;
}
static void place_food(void) {
    for (;;) {
        int row = 3  + (int)(rand16() % 21);     /* 3..23 */
        int col = 1  + (int)(rand16() % 78);     /* 1..78 */
        if (board[row * GW + col] == EMPTY) {
            board[row * GW + col] = FOOD;
            draw_cell(col, row);
            return;
        }
    }
}

/* ---- board setup ----------------------------------------------------- */
static void build_walls(void) {
    memset(board, EMPTY, sizeof(board));
    for (int c = 0; c <= 79; c++) { board[2 * GW + c] = WALL; board[24 * GW + c] = WALL; }
    for (int r = 2; r <= 24; r++) { board[r * GW + 0] = WALL; board[r * GW + 79] = WALL; }
}

static void redraw_all(void) {
    fb_fillrect(&fb, 0, 0, (int)fb.w, (int)fb.h, COL_OUT);
    for (int r = 2; r <= 24; r++)
        for (int c = 0; c <= 79; c++)
            draw_cell(c, r);
    draw_hud();
}

/* ---- a centred line of text (title / game over) ---------------------- */
static void banner(const char *s, int row, uint32_t col) {
    int sc = cs / 6; if (sc < 1) sc = 1;
    int w = strlen(s) * 7 * sc;
    int x = ox + (GW * cs - w) / 2;
    int y = oy + row * cs;
    draw_str(x, y, s, sc, col);
}

/* ---- title screen: ~3 s, any key (or timeout) starts ----------------- */
static int title_screen(void) {
    redraw_all();
    banner("SNAKE", 9, COL_TITLE);
    banner("WASD STEER  P PAUSE  Q QUIT", 12, COL_NUM);
    banner("SPACE TO START", 14, COL_LEN);
    uint32_t t0 = sys_uptime();
    for (;;) {
        int k = sys_getkey();
        if (k == 'q' || k == KEY_ESC) return 0;     /* quit from title */
        if (k == ' ' || k == 'w' || k == 'a' || k == 's' || k == 'd') break;
        if (sys_uptime() - t0 >= 54) break;          /* ~3 s auto-start */
        sys_yield();
    }
    return 1;
}

/* ---- direction change with the kernel's reverse-prevention ----------- */
static void steer(int k) {
    int nd = -1;
    if (k == 'w') nd = 0;
    else if (k == 's') nd = 1;
    else if (k == 'a') nd = 2;
    else if (k == 'd') nd = 3;
    if (nd < 0) return;
    /* can't reverse onto the same axis (0/1 vertical, 2/3 horizontal) */
    if ((s_dir | 1) == (nd | 1)) return;
    s_dir = nd;
}

int snake_main(void) {
    print("snake: ready\r\n");

    if (fb_get(&fb) < 0) {
        /* No framebuffer (serial-only boot): still run the simulation so the
         * game is testable headless; just skip every draw. */
        fb.base = 0; fb.w = GW; fb.h = GH; fb.ppsl = GW;
        cs = 0; ox = oy = 0;
    } else {
        int sx = (int)fb.w / GW, sy = (int)fb.h / GH;
        cs = sx < sy ? sx : sy; if (cs < 2) cs = 2;
        ox = ((int)fb.w - GW * cs) / 2;
        oy = ((int)fb.h - GH * cs) / 2;
    }

    rnd_seed = sys_uptime() ^ 0xACE1;

    if (cs && !title_screen()) { print("snake: quit. Score: 0\r\n"); return 0; }

play_again:
    build_walls();
    b_head = b_tail = 0;
    s_len = 1; s_dir = 3; s_score = 0;
    head_col = 40; head_row = 12;
    board[head_row * GW + head_col] = SNAKE;
    body[b_head++] = (uint16_t)(head_row * GW + head_col);
    if (cs) redraw_all();
    place_food();

    int dx[4] = {  0,  0, -1,  1 };
    int dy[4] = { -1,  1,  0,  0 };

    for (;;) {
        /* pace: max(1, 3 - len/16) ticks per step, polling input meanwhile */
        int delay = 3 - s_len / 16; if (delay < 1) delay = 1;
        uint32_t t0 = sys_uptime();
        for (;;) {
            int k = sys_getkey();
            if (k == 'q' || k == KEY_ESC) {
                printf("snake: quit. Score: %d\r\n", s_score);
                return 0;
            }
            if (k == 'p') {                          /* pause */
                if (cs) banner("PAUSED", 11, COL_LEN);
                for (;;) {
                    int p = sys_getkey();
                    if (p == 'p' || p == ' ') break;
                    if (p == 'q' || p == KEY_ESC) {
                        printf("snake: quit. Score: %d\r\n", s_score);
                        return 0;
                    }
                    sys_yield();
                }
                if (cs) redraw_all();            /* repaint over "PAUSED" */
                t0 = sys_uptime();
            }
            else if (k) steer(k);
            if (sys_uptime() - t0 >= (uint32_t)delay) break;
            sys_yield();
        }

        int nc = head_col + dx[s_dir];
        int nr = head_row + dy[s_dir];
        unsigned char hit = board[nr * GW + nc];
        if (hit == WALL || hit == SNAKE) {           /* crash */
            if (cs) banner("GAME OVER", 11, COL_FOOD);
            printf("snake: game over. Score: %d\r\n", s_score);
            /* offer a replay; auto-exit after ~3 s with no key */
            uint32_t te = sys_uptime();
            for (;;) {
                int k = sys_getkey();
                if (k == ' ') goto play_again;
                if (k == 'q' || k == KEY_ESC || sys_uptime() - te >= 54) {
                    printf("snake: quit. Score: %d\r\n", s_score);
                    return 0;
                }
                sys_yield();
            }
        }

        int grow = (hit == FOOD);
        int ocol = head_col, orow = head_row;        /* old head -> body */
        /* advance head */
        head_col = nc; head_row = nr;
        int hcell = nr * GW + nc;
        board[hcell] = SNAKE;
        body[b_head] = (uint16_t)hcell;
        b_head = (b_head + 1) & 255;
        if (cs) { draw_cell(nc, nr); draw_cell(ocol, orow); }

        if (grow) {
            if (s_len < 250) s_len++;
            s_score += 10;
            if (cs) draw_hud();
            place_food();
        } else {
            /* erase the tail */
            int tcell = body[b_tail];
            b_tail = (b_tail + 1) & 255;
            board[tcell] = EMPTY;
            if (cs) draw_cell(tcell % GW, tcell / GW);
        }
    }
}
