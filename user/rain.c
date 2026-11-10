/* rain.c - 'run rain': the agent rain screensaver.
 *
 * Columns of glyphs fall through the brand teal like rain through a forest
 * canopy; every column occasionally carries a WORD from the running system:
 * the live agent types and task results read through SYS_AGENTS each second
 * ("prime", "=541", "done", "ERROR"), the wish vocabulary ("wish", "grow",
 * "forest", "ring3"). A small glass chip in the corner shows the agent count,
 * tasks done and uptime. Any key exits. Cheap on purpose: per step a column
 * touches three cells (new head, old head recoloured, tail erased), nothing
 * is redrawn wholesale. Serial: "rain: ready", "rain: quit after N frames". */
#include "dui.h"

#define MAXCOLS 320
typedef struct {
    int y;            /* head row (may be negative while waiting to enter) */
    int len;          /* trail length */
    int speed;        /* ticks per step */
    int phase;        /* tick counter */
    const char *word; /* word being dropped, or 0 */
    int widx;         /* next char of the word */
} col_t;
static col_t cols[MAXCOLS];
#define MAXROWS 128
static char glyph_at[MAXCOLS][MAXROWS];   /* what is drawn where, for recolouring the trail */
static uint32_t rnd_state = 0x9E3779B9u;
static uint32_t rnd(void) { rnd_state = rnd_state * 1103515245u + 12345u; return rnd_state >> 8; }

static const char *const words[] = { "wish", "grow", "forest", "agent", "ring3", "spawn", "task",
                                     "plant", "claim", "finish", "yield", "INT30", "GAS", "llm" };
static const char *const tnames[] = { "math", "scan", "count", "prime", "prog", "ask", "gcd", "fault" };
static char live[8][16];               /* words from the agent table */
static int  nlive, agents_awake, tasks_done;

static const char glyphs[] = "01abcdefghijklmnopqrstuvwxyz<>{}[]()=+*/#@$%&;:.,~^|";

/* shade k of the trail (0 = head) */
static uint32_t shade(int k, int len) {
    if (k == 0) return 0xE8FFFAu;
    if (k == 1) return DUI_ACCENT2;
    int t = k * 4 / (len ? len : 1);   /* 0..3 */
    static const uint32_t s[4] = { DUI_ACCENT, 0x1FA394u, 0x157A6Fu, 0x0E4F49u };
    return s[t > 3 ? 3 : t];
}

static int chip_x0, chip_y0, chip_x1, chip_y1;   /* the info chip (cells) - rain skips it */
static int in_chip(int cx, int cy) { return cx >= chip_x0 && cx < chip_x1 && cy >= chip_y0 && cy < chip_y1; }

static void cell(int cx, int cy, char c, uint32_t col) {
    if (cy < 0 || cy >= DUI.rows || in_chip(cx, cy)) return;
    dui_fill(cx * DUI.cw, cy * DUI.ch, DUI.cw, DUI.ch, DUI_BG);
    if (c && c != ' ') { char s[2] = { c, 0 }; dui_text(cx, cy, s, col); }
}

static void read_agents(void) {
    static unsigned char tbl[192];
    nlive = 0; agents_awake = 0; tasks_done = 0;
    if (sys_agents(tbl) != 0) return;
    for (int i = 0; i < 8; i++) {
        const unsigned char *a = tbl + i * 8;
        if (a[0]) { agents_awake++; if (a[1] < 8 && nlive < 8) dui_strcpy(live[nlive++], tnames[a[1]], 16); }
    }
    for (int i = 0; i < 8 && nlive < 8; i++) {
        const unsigned char *t = tbl + 64 + i * 16;
        if (!t[0]) continue;
        if (t[2] == 2) { tasks_done++; char *w = live[nlive++]; w[0] = '='; dui_utoa(w + 1, *(const uint32_t *)(t + 12)); }
        else if (t[2] == 3 && nlive < 8) dui_strcpy(live[nlive++], "ERROR", 16);
    }
}

static const char *pick_word(void) {
    uint32_t r = rnd() % 10;
    if (r < 4 && nlive) return live[rnd() % (uint32_t)nlive];
    if (r < 7) return words[rnd() % (sizeof words / sizeof words[0])];
    return 0;
}

static void reset_col(col_t *c, int first) {
    c->y = first ? -(int)(rnd() % (uint32_t)DUI.rows) : -(int)(rnd() % 12) - 1;
    c->len = 5 + (int)(rnd() % (uint32_t)(DUI.rows / 2 + 4));
    c->speed = 1 + (int)(rnd() % 4);
    c->phase = 0;
    c->word = pick_word(); c->widx = 0;
}

static void draw_chip(void) {
    int x = chip_x0 * DUI.cw, y = chip_y0 * DUI.ch, w = (chip_x1 - chip_x0) * DUI.cw, h = (chip_y1 - chip_y0) * DUI.ch;
    dui_panel(x, y, w, h, DUI_PANEL, DUI_LINE);
    dui_fill(x, y, 3 * DUI.sc, h, DUI_ACCENT);
    dui_logo(x + 2 * DUI.cw, y + (h - 20 * DUI.sc) / 2, DUI.sc);
    dui_text(chip_x0 + 4, chip_y0 + 1, "TannX OS", DUI_ACCENT);
    char l[64]; char *e = l;
    e = dui_utoa(e, (uint32_t)agents_awake); dui_strcpy(e, " agents awake   ", 17); e += 16;
    e = dui_utoa(e, (uint32_t)tasks_done); dui_strcpy(e, " tasks done", 12);
    dui_text(chip_x0 + 4, chip_y0 + 2, l, DUI_TEXT);
    uint32_t s = sys_uptime() / 18; e = l;
    dui_strcpy(e, "up ", 4); e += 3;
    e = dui_utoa(e, s / 3600); *e++ = ':'; *e++ = (char)('0' + (s / 600) % 6); *e++ = (char)('0' + (s / 60) % 10);
    *e++ = ':'; *e++ = (char)('0' + (s / 10) % 6); *e++ = (char)('0' + s % 10);
    dui_strcpy(e, "    any key exits", 18);
    dui_text(chip_x0 + 4, chip_y0 + 3, l, DUI_MUTED);
}

int rain_main(void) {
    if (dui_init() < 0) { print("rain: needs a framebuffer (boot with -vga std)\r\n"); return 0; }
    sys_fgrab(1);
    dui_flush_keys();
    rnd_state ^= sys_uptime() * 2654435761u;
    int ncols = DUI.cols; if (ncols > MAXCOLS) ncols = MAXCOLS;
    chip_x1 = DUI.cols - 2; chip_x0 = chip_x1 - 40; if (chip_x0 < 0) chip_x0 = 0;
    chip_y1 = DUI.rows - 1; chip_y0 = chip_y1 - 5;
    dui_clear(DUI_BG);
    read_agents();
    for (int i = 0; i < ncols; i++) reset_col(&cols[i], 1);
    draw_chip();
    print("rain: ready\r\n");
    uint32_t frames = 0, t0 = sys_uptime(), lastinfo = t0;
    for (;;) {
        if (sys_getkey()) break;
        uint32_t now = sys_uptime();
        if (now - lastinfo >= 18) { lastinfo = now; read_agents(); draw_chip(); }
        for (int i = 0; i < ncols; i++) {
            col_t *c = &cols[i];
            if (++c->phase < c->speed) continue;
            c->phase = 0;
            /* the old head becomes trail; two more cells down the trail fade a shade */
            int y0 = c->y;
            if (y0 >= 0 && y0 < DUI.rows) cell(i, y0, glyph_at[i][y0], shade(1, c->len));
            int y3 = y0 - 3, yh = y0 - c->len / 2;
            if (y3 >= 0 && y3 < DUI.rows) cell(i, y3, glyph_at[i][y3], shade(3, c->len));
            if (yh >= 0 && yh < DUI.rows && yh != y3) cell(i, yh, glyph_at[i][yh], shade(c->len * 3 / 4, c->len));
            c->y++;
            int tail = c->y - c->len;
            if (tail >= 0 && tail < DUI.rows) cell(i, tail, 0, DUI_BG);
            if (c->y >= 0 && c->y < DUI.rows) {
                char g;
                if (c->word && c->word[c->widx]) g = c->word[c->widx++];
                else g = glyphs[rnd() % (sizeof glyphs - 1)];
                if (c->word && !c->word[c->widx]) c->word = 0;
                if (c->y < MAXROWS) glyph_at[i][c->y] = g;
                cell(i, c->y, g, shade(0, c->len));
            }
            if (tail >= DUI.rows) reset_col(c, 0);
        }
        frames++;
        /* ~30 steps/s: one tick is ~55 ms, so run two sub-steps per tick */
        uint32_t t = sys_uptime();
        while (sys_uptime() == t) { sys_progress(50); sys_yield(); }
    }
    dui_clear(DUI_BG);
    sys_fgrab(0);
    printf("rain: quit after %u frames (%u s)\r\n", frames, (sys_uptime() - t0) / 18);
    return 0;
}
