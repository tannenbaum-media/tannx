/* chat.c - 'run chat': a full-screen conversation with the model.
 *
 * The same wire as 'llm': the ring-3 TCP stack in net.c posts each prompt to
 * the host proxy (llm-proxy.py, /llm) and the answer comes back as text. The
 * difference is the surface: message bubbles (you on the right, the agent on
 * the left), a scrollback, an input line, and a status chip that says whether
 * the proxy is reachable and whether it is the --mock proxy of the tests
 * (its answers start with AGENTOS-LLM-MOCK).
 *
 * Keys: Enter sends, PgUp/PgDn (or Up/Down with an empty line) scroll,
 * Left/Right/Home/End edit the line, /clear empties the conversation,
 * Esc (ESC ESC on a serial terminal), Ctrl+Q or Ctrl+C quit.
 *
 * Serial markers (test-chat.sh): "chat: ready", "chat: you> ...",
 * "chat: ai> ...", "chat: quit". */
#include "ui.h"

int llm_connect(void);
int llm_ask(const char *prompt, char *out, int cap);

#define MSG_MAX   64
#define TXT_MAX   16384
#define IN_MAX    240
#define ANS_MAX   2048
#define WRAP_MAX  96                 /* lines per message after wrapping */

enum { WHO_YOU = 0, WHO_AI = 1, WHO_SYS = 2 };

static char txt[TXT_MAX];
static int  txt_len;
static struct { int off, len; uint8_t who; uint32_t at; } msgs[MSG_MAX];
static int  nmsg;

static char input[IN_MAX + 1];
static int  in_len, in_cur;
static int  scroll;                  /* text rows scrolled up from the bottom */
static int  proxy;                   /* 0 offline, 1 connected, 2 mock, 3 thinking */
static char answer[ANS_MAX];
static uint32_t last_beat;

/* layout (pixels) */
static int hdr_h, area_y, area_h, inp_y, inp_h, bub_w;

static void layout(void) {
    hdr_h  = UI_CH * 3;
    inp_h  = UI_CH * 2;
    inp_y  = UI_H - inp_h - UI_CH * 2;           /* above the hint row */
    area_y = hdr_h;
    area_h = inp_y - UI_CH / 2 - area_y;
    bub_w  = (UI_COLS * 62) / 100;               /* bubble text width in cells */
    if (bub_w < 20) bub_w = 20;
    if (bub_w > 110) bub_w = 110;
}

/* ---- the conversation store ------------------------------------------ */
static void add_msg(int who, const char *s, int n) {
    if (nmsg == MSG_MAX || txt_len + n > TXT_MAX) {      /* drop the oldest half */
        int keep = nmsg / 2, base = msgs[nmsg - keep].off;
        for (int i = 0; i < keep; i++) { msgs[i] = msgs[nmsg - keep + i]; msgs[i].off -= base; }
        memcpy(txt, txt + base, txt_len - base);
        txt_len -= base; nmsg = keep;
        if (txt_len + n > TXT_MAX) n = TXT_MAX - txt_len;
    }
    msgs[nmsg].off = txt_len; msgs[nmsg].len = n; msgs[nmsg].who = (uint8_t)who;
    msgs[nmsg].at = sys_uptime() / 18;
    memcpy(txt + txt_len, s, n);
    txt_len += n; nmsg++;
}

/* word-wrap s[0..n) into rows of at most w cells; fills starts/lens, returns rows */
static int wrap(const char *s, int n, int w, int *st, int *ln, int max) {
    int rows = 0, i = 0;
    while (i < n && rows < max) {
        int start = i, end = i, last_sp = -1;
        while (end < n && s[end] != '\n' && end - start < w) {
            if (s[end] == ' ') last_sp = end;
            end++;
        }
        int next;
        if (end < n && s[end] == '\n') { next = end + 1; }
        else if (end - start < w) { next = end; }            /* end of text */
        else if (last_sp > start) { end = last_sp; next = last_sp + 1; }
        else next = end;                                      /* hard break */
        st[rows] = start; ln[rows] = end - start; rows++;
        i = next;
        if (i == n && n > 0 && s[n - 1] == '\n' && rows < max) { st[rows] = n; ln[rows] = 0; rows++; }
    }
    if (rows == 0 && rows < max) { st[0] = 0; ln[0] = 0; rows = 1; }
    return rows;
}

/* ---- drawing ----------------------------------------------------------- */
static void draw_header(void) {
    ui_fill(0, 0, UI_W, hdr_h, C_SURF);
    ui_hline(0, hdr_h - 1, UI_W, C_LINE);
    ui_fill(0, 0, UI_W, 2, C_ACCENT);
    int ty = (hdr_h - UI_CH) / 2;
    /* a little fir mark */
    int mx = UI_CW, my = ty;
    for (int r = 0; r < UI_CH; r++) {
        int hw = (r * (UI_CW / 2 + 1)) / UI_CH + 1;
        if (r > UI_CH - UI_CH / 5) hw = 1;
        ui_fill(mx + UI_CW / 2 - hw, my + r, hw * 2, 1, r > UI_CH - UI_CH / 5 ? C_ACCDIM : C_ACCENT);
    }
    ui_text(UI_CW * 3, ty, "TannX Chat", C_TEXT);
    ui_text(UI_CW * 3 + UI_CW * 17, ty, "Plant a wish. The agents grow it.", C_MUTED);
    const char *lab = proxy == 2 ? "proxy: mock" : proxy == 1 ? "proxy: connected"
                    : proxy == 3 ? "proxy: thinking" : "proxy: offline";
    uint32_t dot = proxy == 2 ? C_WARN : proxy == 1 ? C_OK : proxy == 3 ? C_ACCENT : C_ERR;
    int cw = (UI_CW * 2 + UI_CW / 2 + 2 + UI_CW / 2 + ui_text_w(lab, ui_sc));
    ui_chip(UI_W - cw - UI_CW, (hdr_h - (UI_CH + UI_CH / 2)) / 2, lab, dot, C_SURF2, C_TEXT);
}

static void draw_hint(void) {
    int y = UI_H - UI_CH - UI_CH / 2;
    ui_fill(0, inp_y + inp_h, UI_W, UI_H - inp_y - inp_h, C_BG);
    ui_text(UI_CW, y, "Enter", C_ACCENT);  ui_text(UI_CW * 7, y, "send", C_MUTED);
    ui_text(UI_CW * 14, y, "PgUp/PgDn", C_ACCENT); ui_text(UI_CW * 24, y, "scroll", C_MUTED);
    ui_text(UI_CW * 33, y, "/clear", C_ACCENT); ui_text(UI_CW * 40, y, "reset", C_MUTED);
    ui_text(UI_CW * 48, y, "Esc", C_ACCENT); ui_text(UI_CW * 52, y, "quit", C_MUTED);
}

static void draw_input(void) {
    int x = UI_CW, w = UI_W - UI_CW * 2;
    ui_fill(0, inp_y - UI_CH / 2, UI_W, inp_h + UI_CH / 2, C_BG);
    ui_round(x, inp_y, w, inp_h, UI_CH / 2, C_SURF);
    ui_frame(x, inp_y, w, inp_h, UI_CH / 2, proxy == 3 ? C_WARN : C_ACCENT);
    int tx = x + UI_CW, ty = inp_y + (inp_h - UI_CH) / 2;
    int maxc = (w - UI_CW * 2) / UI_CW - 1;
    ui_text(tx, ty, ">", C_ACCENT);
    tx += UI_CW * 2; maxc -= 2;
    if (in_len == 0) {
        ui_text(tx + UI_CW, ty, proxy == 3 ? "the agent is thinking ..." : "type a message for the agent", C_FAINT);
    }
    int from = in_cur - maxc + 1; if (from < 0) from = 0;   /* keep the cursor visible */
    int show = in_len - from; if (show > maxc) show = maxc;
    ui_textn(tx, ty, input + from, show, C_TEXT);
    if (proxy != 3) ui_fill(tx + (in_cur - from) * UI_CW, ty, UI_CW / 4 + 1, UI_CH, C_ACCENT);
}

static int st[WRAP_MAX], ln[WRAP_MAX];

/* draw one bubble whose top-left is (y) in area space; rows already wrapped */
static void draw_bubble(int m, int y, int rows) {
    int who = msgs[m].who;
    int pad = UI_CW;
    int widest = 0;
    for (int r = 0; r < rows; r++) if (ln[r] > widest) widest = ln[r];
    if (widest < 1) widest = 1;
    int bw = widest * UI_CW + pad * 2;
    int bh = rows * UI_CH + UI_CH;
    int bx = who == WHO_YOU ? UI_W - UI_CW * 2 - bw : UI_CW * 2;
    if (who == WHO_SYS) bx = (UI_W - bw) / 2;
    uint32_t bg = who == WHO_YOU ? C_ACCENT : who == WHO_AI ? C_SURF2 : C_SURF;
    uint32_t fg = who == WHO_YOU ? C_ACCINK : who == WHO_AI ? C_TEXT : C_MUTED;
    /* name + time label above the bubble */
    char lab[32]; int n = ui_cat(lab, who == WHO_YOU ? "you  " : who == WHO_AI ? "agent  " : "");
    if (who != WHO_SYS) ui_hms(lab + n, msgs[m].at);
    int ly = y - UI_CH;
    int lx = who == WHO_YOU ? bx + bw - ui_text_w(lab, ui_sc) : bx;
    if (ly >= area_y && ly + UI_CH <= area_y + area_h) ui_text(lx, ly, lab, C_FAINT);
    /* the bubble, clipped to the message area */
    int top = y < area_y ? area_y : y;
    int bot = y + bh > area_y + area_h ? area_y + area_h : y + bh;
    if (bot <= top) return;
    if (top == y && bot == y + bh) ui_round(bx, y, bw, bh, UI_CH / 2, bg);
    else ui_fill(bx, top, bw, bot - top, bg);
    for (int r = 0; r < rows; r++) {
        int ry = y + UI_CH / 2 + r * UI_CH;
        if (ry < area_y || ry + UI_CH > area_y + area_h) continue;
        ui_textn(bx + pad, ry, txt + msgs[m].off + st[r], ln[r], fg);
    }
}

static int total_rows;      /* conversation height in text rows (for scrolling) */

static void draw_area(void) {
    ui_fill(0, area_y, UI_W, area_h, C_BG);
    /* lay the bubbles out bottom-up: the newest sits just above the input */
    int gap = UI_CH / 2;
    int bottom = area_y + area_h - gap + scroll * UI_CH;
    total_rows = 0;
    for (int m = nmsg - 1; m >= 0; m--) {
        int rows = wrap(txt + msgs[m].off, msgs[m].len, bub_w, st, ln, WRAP_MAX);
        int bh = rows * UI_CH + UI_CH;
        int y = bottom - bh;
        total_rows += rows + 2;
        if (y + bh > area_y) draw_bubble(m, y, rows);
        bottom = y - UI_CH - gap;                  /* label row + gap */
        if (bottom < area_y - UI_CH * 4 && m < nmsg - 1 && y < area_y) {
            /* everything above is off-screen; keep counting rows cheaply */
            for (int k = m - 1; k >= 0; k--) total_rows += msgs[k].len / bub_w + 3;
            break;
        }
    }
    if (nmsg == 0) {
        const char *w1 = "Plant a wish.";
        const char *w2 = "The agents grow it.";
        int cy = area_y + area_h / 2 - UI_CH * 2;
        ui_text_s((UI_W - ui_text_w(w1, ui_sc + 1)) / 2, cy, w1, ui_sc + 1, C_ACCENT);
        ui_text_s((UI_W - ui_text_w(w2, ui_sc + 1)) / 2, cy + UI_CH * 2, w2, ui_sc + 1, C_MUTED);
    }
    if (scroll > 0) {
        char s[24]; int n = ui_cat(s, "scrolled -"); ui_utoa(s + n, (uint32_t)scroll);
        ui_text(UI_W - UI_CW * (strlen(s) + 2), area_y + UI_CH / 2, s, C_FAINT);
    }
}

static void draw_all(void) {
    draw_header();
    draw_area();
    draw_input();
    draw_hint();
}

/* ---- serial echo (so the headless test and a serial terminal see the talk) */
static void serial_line(const char *tag, const char *s, int n) {
    print(tag);
    int shown = n > 160 ? 160 : n;
    for (int i = 0; i < shown; i++) sys_putc(s[i] == '\n' ? ' ' : s[i]);
    if (n > shown) print(" ...");
    print("\r\n");
}

static void send_prompt(void) {
    input[in_len] = 0;
    if (in_len == 6 && memcmp(input, "/clear", 6) == 0) {
        nmsg = 0; txt_len = 0; scroll = 0; in_len = in_cur = 0;
        add_msg(WHO_SYS, "conversation cleared", 20);
        draw_all();
        return;
    }
    add_msg(WHO_YOU, input, in_len);
    serial_line("chat: you> ", input, in_len);
    scroll = 0;
    proxy = proxy ? 3 : 0;
    draw_all();
    if (proxy == 0) {
        const char *e = "No network: the kernel found no NIC or no link. The chat needs the host proxy (llm-proxy.py).";
        add_msg(WHO_SYS, e, strlen(e));
    } else {
        int n = llm_ask(input, answer, ANS_MAX);
        /* tidy: drop CRs and trailing newlines, tabs -> spaces */
        int o = 0;
        for (int i = 0; i < n; i++) {
            char c = answer[i];
            if (c == '\r') continue;
            if (c == '\t') c = ' ';
            answer[o++] = c;
        }
        while (o > 0 && (answer[o - 1] == '\n' || answer[o - 1] == ' ')) o--;
        answer[o] = 0;
        if (o <= 0) {
            const char *e = "No answer from the proxy - is llm-proxy.py running on the host?";
            add_msg(WHO_SYS, e, strlen(e));
            proxy = 1;
        } else {
            add_msg(WHO_AI, answer, o);
            serial_line("chat: ai> ", answer, o);
            proxy = (o >= 16 && memcmp(answer, "AGENTOS-LLM-MOCK", 16) == 0) ? 2 : 1;
        }
    }
    in_len = in_cur = 0;
    draw_all();
}

int chat_main(void) {
    if (ui_init() < 0) { print("chat: no framebuffer - boot with a VBE/GOP mode\r\n"); return 0; }
    print("chat: bringing the network up ...\r\n");
    proxy = llm_connect() ? 1 : 0;
    printf("chat: ready (proxy: %s)\r\n", proxy ? "connected" : "offline");
    layout();
    draw_all();
    last_beat = sys_uptime();
    for (;;) {
        int k = ui_key();
        if (!k) {
            uint32_t now = sys_uptime();
            if (now - last_beat > 18) { sys_progress(0); last_beat = now; }   /* watchdog heartbeat */
            sys_yield();
            continue;
        }
        int page = (area_h / UI_CH) / 2; if (page < 1) page = 1;
        int max_scroll = total_rows - area_h / UI_CH + 2; if (max_scroll < 0) max_scroll = 0;
        switch (k) {
        case UI_ESC: case UI_CTRL('Q'): case UI_CTRL('C'):
            print("chat: quit\r\n");
            return 0;
        case UI_ENTER:
            if (in_len) send_prompt();
            break;
        case UI_PGUP: scroll += page; if (scroll > max_scroll) scroll = max_scroll; draw_area(); break;
        case UI_PGDN: scroll -= page; if (scroll < 0) scroll = 0; draw_area(); break;
        case UI_UP:   if (!in_len) { if (scroll < max_scroll) scroll++; draw_area(); } break;
        case UI_DOWN: if (!in_len) { if (scroll > 0) scroll--; draw_area(); } break;
        case UI_LEFT:  if (in_cur > 0) in_cur--; draw_input(); break;
        case UI_RIGHT: if (in_cur < in_len) in_cur++; draw_input(); break;
        case UI_HOME:  in_cur = 0; draw_input(); break;
        case UI_END:   in_cur = in_len; draw_input(); break;
        case UI_BS:
            if (in_cur > 0) {
                memcpy(input + in_cur - 1, input + in_cur, in_len - in_cur);
                in_cur--; in_len--; draw_input();
            }
            break;
        case UI_DEL:
            if (in_cur < in_len) {
                memcpy(input + in_cur, input + in_cur + 1, in_len - in_cur - 1);
                in_len--; draw_input();
            }
            break;
        default:
            if (k >= 32 && k < 127 && in_len < IN_MAX) {
                for (int i = in_len; i > in_cur; i--) input[i] = input[i - 1];
                input[in_cur++] = (char)k; in_len++;
                draw_input();
            }
        }
    }
}
