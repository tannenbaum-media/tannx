/* sysmon.c - 'run sysmon': a live system monitor on the framebuffer.
 *
 * Everything on screen comes through syscalls a ring-3 program may make:
 * SYS_AGENTS (the agent roster and the task table), SYS_UPTIME, SYS_NET_MAC
 * (NIC + link), SYS_NET_RX (frames the NIC queued), SYS_SBRK (the ring-3
 * heap break). The CPU graph is measured, not reported, from the monitor's
 * own tick deltas: the kernel round-robins the runnable threads one timer
 * tick each, so whenever the monitor reads the tick counter and sees it
 * jump by N, it held one tick and N-1 went elsewhere. One of those belongs
 * to the shell (thread 0, always runnable); the rest is the agents' share.
 * Note for the next session: an IDLE agent holds its slot too - its
 * SYS_YIELD is sti;hlt, which parks the core until the next tick instead of
 * handing the rest of the tick on - so the share moves when agents are
 * spawned, and the bar colour (bright = at least one agent busy) tells work
 * from parking. Measured: 3 agents -> 60 % whether they compute or idle.
 *
 * rx counters: the monitor drains the kernel's receive queue to count
 * frames and bytes, so while it runs a background httpd/askd would miss
 * frames - a monitor, not something to leave running beside a server.
 *
 * q, Esc, Ctrl+Q or Ctrl+C quit. Serial markers (test-sysmon.sh):
 * "sysmon: ready", a "sysmon: up=.. agents=.. busy=..% rx=.." line every
 * two seconds, "sysmon: quit". */
#include "ui.h"

#define NSAMP 120
#define REFRESH 9                        /* ticks between refreshes (~0.5 s) */

static uint8_t tbl[192];                 /* agents_tbl(64) + tasks_tbl(128) */
static int  samp[NSAMP], acts[NSAMP], nsamp;
static uint32_t rx_frames, rx_bytes, last_done;
static uint8_t  frame[1600];
static int  busy_now, act_now;

static const char *type_name(int t) {
    static const char *n[] = { "math", "scan", "count", "prime", "prog", "ask", "gcd", "fault" };
    return (t >= 0 && t < 8) ? n[t] : "?";
}

/* ---- the measurements -------------------------------------------------- */
static uint32_t tk_mine, tk_total;       /* ticks the monitor held / ticks seen */
static int any_busy;
static void tick_seen(uint32_t jump) { tk_total += jump; tk_mine++; }
static void sample_cpu(void) {
    /* the shell takes as many ticks as we do (one per round); the rest is the agents' */
    int share = 0;
    if (tk_total > 2 * tk_mine) share = (int)(((tk_total - 2 * tk_mine) * 100) / tk_total);
    if (share > 100) share = 100;
    busy_now = share;
    tk_mine = tk_total = 0;
    any_busy = 0;
    for (int i = 0; i < 8; i++) if (tbl[i * 8] && tbl[i * 8 + 2] == 1 && tbl[i * 8 + 1] != 4) any_busy = 1;
    /* activity: tasks completed since the last sample */
    uint32_t done = 0;
    for (int i = 0; i < 8; i++) done += tbl[i * 8 + 4] | (tbl[i * 8 + 5] << 8);
    act_now = (int)(done - last_done); last_done = done;
    if (nsamp == NSAMP) { for (int i = 1; i < NSAMP; i++) { samp[i-1] = samp[i]; acts[i-1] = acts[i]; } nsamp--; }
    samp[nsamp] = any_busy ? share : -share; acts[nsamp] = act_now; nsamp++;   /* sign = busy flag */
}
static void drain_net(void) {
    for (int i = 0; i < 64; i++) {
        int n = sys_net_rx(frame, sizeof frame);
        if (n <= 0) break;
        rx_frames++; rx_bytes += (uint32_t)n;
    }
}

/* ---- drawing helpers ------------------------------------------------------ *
 * The chrome (panels, titles, column headers, axis labels) is painted ONCE by
 * draw_static; each refresh repaints only the cells that change (values,
 * rows, the graph box). At 2560x1600 a full-panel repaint takes long enough
 * for a screendump to catch it half done, and it flickers. */
static void panel(int x, int y, int w, int h, const char *title) {
    ui_round(x, y, w, h, UI_CH / 2, C_SURF);
    ui_frame(x, y, w, h, UI_CH / 2, C_LINE);
    if (title) {
        ui_text(x + UI_CW, y + UI_CH / 2, title, C_ACCENT);
        ui_hline(x + UI_CW, y + UI_CH / 2 + UI_CH + 2, w - UI_CW * 2, C_LINE);
    }
}
static void bar(int x, int y, int w, int h, int pct, uint32_t col) {
    ui_fill(x, y, w, h, C_BG);
    int fw = (w * pct) / 100; if (fw > w) fw = w;
    if (fw > 0) ui_fill(x, y, fw, h, col);
}
/* text on a panel surface: the cell run is cleared to the surface first */
static void cell_text(int x, int y, const char *s, int cells, uint32_t col) {
    ui_fill(x, y, cells * UI_CW, UI_CH, C_SURF);
    ui_textn(x, y, s, cells, col);
}

/* ---- the screen ------------------------------------------------------------- */
static int hdr_h, tiles_y, tiles_h, tile_w, mid_y, mid_h, graph_y, graph_h;
static int ag_x, ag_w, tq_x, tq_w, gx, gy, gw, gh;
#define TILE_GAP UI_CW
#define N_TILES 5

static void layout(void) {
    hdr_h   = UI_CH * 3;
    tiles_y = hdr_h + UI_CH / 2;
    tiles_h = UI_CH * 5;
    tile_w  = (UI_W - TILE_GAP * (N_TILES + 1)) / N_TILES;
    mid_y   = tiles_y + tiles_h + UI_CH / 2;
    mid_h   = UI_CH * 13;                /* title 2 + header 1.25 + 8 rows + hint */
    graph_y = mid_y + mid_h + UI_CH / 2;
    graph_h = UI_H - graph_y - UI_CH * 2;
    if (graph_h < UI_CH * 5) {               /* small screens: shrink the tables */
        int over = UI_CH * 5 - graph_h;
        mid_h -= over; graph_y -= over; graph_h = UI_CH * 5;
    }
    ag_x = UI_CW; ag_w = (UI_W - UI_CW * 3) * 55 / 100;
    tq_x = ag_x + ag_w + UI_CW; tq_w = UI_W - tq_x - UI_CW;
    gx = UI_CW * 6; gy = graph_y + UI_CH * 2; gw = UI_W - UI_CW * 8; gh = graph_h - UI_CH * 3;
}

static int tile_x(int i) { return TILE_GAP + i * (tile_w + TILE_GAP); }
static const char *tile_label[N_TILES] = { "AGENTS", "TASK QUEUE", "AGENT CPU SHARE", "USER HEAP", "NETWORK" };

static void draw_static(void) {
    ui_fill(0, 0, UI_W, UI_H, C_BG);
    /* header */
    ui_fill(0, 0, UI_W, hdr_h, C_SURF);
    ui_fill(0, 0, UI_W, 2, C_ACCENT);
    ui_hline(0, hdr_h - 1, UI_W, C_LINE);
    int ty = (hdr_h - UI_CH) / 2;
    ui_text(UI_CW, ty, "TannX sysmon", C_TEXT);
    ui_text(UI_CW * 20, ty, "live system monitor - agents, tasks, cpu, net", C_MUTED);
    /* tiles */
    for (int i = 0; i < N_TILES; i++) {
        panel(tile_x(i), tiles_y, tile_w, tiles_h, 0);
        ui_text(tile_x(i) + UI_CW, tiles_y + UI_CH / 2, tile_label[i], C_MUTED);
    }
    /* tables */
    panel(ag_x, mid_y, ag_w, mid_h, "AGENTS");
    ui_text(ag_x + UI_CW, mid_y + UI_CH * 2 + UI_CH / 4, "ID  TYPE   STATE  TASK  DONE   PROGRESS", C_FAINT);
    panel(tq_x, mid_y, tq_w, mid_h, "TASK QUEUE");
    ui_text(tq_x + UI_CW, mid_y + UI_CH * 2 + UI_CH / 4, "#  TYPE   STATE    INPUT        RESULT", C_FAINT);
    /* graph */
    panel(UI_CW, graph_y, UI_W - UI_CW * 2, graph_h, "AGENT CPU SHARE / ACTIVITY");
    ui_text(UI_CW * 2, gy - UI_CH / 2, "100", C_FAINT);
    ui_text(UI_CW * 2, gy + gh / 2 - UI_CH / 2, " 50", C_FAINT);
    ui_text(UI_CW * 2, gy + gh - UI_CH / 2, "  0", C_FAINT);
    /* footer */
    int y = UI_H - UI_CH - UI_CH / 2;
    ui_text(UI_CW, y, "q", C_ACCENT); ui_text(UI_CW * 3, y, "quit", C_MUTED);
    ui_text(UI_CW * 9, y, "share = timer ticks the scheduler gives the agents (bright bars: working, dim: parked in hlt)   rx counted by draining the NIC queue", C_FAINT);
}

static void draw_header(void) {
    char s[32]; int n = ui_cat(s, "up ");
    ui_hms(s + n, sys_uptime() / 18);
    int cw = UI_CW * 2 + UI_CW / 2 + 2 + UI_CW / 2 + ui_text_w(s, ui_sc);
    ui_fill(UI_W - UI_CW * 20, 2, UI_CW * 20, hdr_h - 3, C_SURF);
    ui_chip(UI_W - cw - UI_CW, (hdr_h - (UI_CH + UI_CH / 2)) / 2, s, C_ACCENT, C_SURF2, C_TEXT);
}

/* tile i: big value (scale+1) and a sub line, repainted over the surface */
static void tile_value(int i, const char *value, const char *sub, uint32_t vcol) {
    int x = tile_x(i) + UI_CW, vy = tiles_y + UI_CH / 2 + UI_CH, sy = tiles_y + tiles_h - UI_CH - UI_CH / 2;
    ui_fill(x, vy, tile_w - UI_CW * 2, UI_CH * 2, C_SURF);
    ui_text_s(x, vy, value, ui_sc + 1, vcol);
    cell_text(x, sy, sub, (tile_w - UI_CW * 2) / UI_CW, C_FAINT);
}

static void draw_tiles(void) {
    char v[32], sub[48]; int n;
    /* agents */
    int active = 0, busy = 0;
    for (int i = 0; i < 8; i++) if (tbl[i * 8]) { active++; if (tbl[i * 8 + 2]) busy++; }
    n = ui_utoa(v, (uint32_t)active); ui_cat(v + n, " / 8");
    n = ui_utoa(sub, (uint32_t)busy); ui_cat(sub + n, " busy");
    tile_value(0, v, sub, busy ? C_ACCENT : C_TEXT);
    /* tasks */
    int wait = 0, run = 0, done = 0, err = 0;
    for (int i = 0; i < 8; i++) {
        const uint8_t *t = tbl + 64 + i * 16;
        if (!t[0]) continue;
        if (t[2] == 0) wait++; else if (t[2] == 1) run++; else if (t[2] == 2) done++; else err++;
    }
    n = ui_utoa(v, (uint32_t)(wait + run)); ui_cat(v + n, " open");
    n = ui_utoa(sub, (uint32_t)done); n += ui_cat(sub + n, " done, ");
    n += ui_utoa(sub + n, (uint32_t)err); ui_cat(sub + n, " error");
    tile_value(1, v, sub, wait + run ? C_WARN : C_TEXT);
    /* cpu */
    n = ui_utoa(v, (uint32_t)busy_now); ui_cat(v + n, " %");
    ui_cat(sub, any_busy ? "of the ticks - working" : busy_now ? "of the ticks - parked" : "no agent holds the cpu");
    uint32_t cc = any_busy ? C_ACCENT : C_MUTED;
    tile_value(2, v, sub, cc);
    bar(tile_x(2) + UI_CW, tiles_y + tiles_h - UI_CH - UI_CH / 2 - 4, tile_w - UI_CW * 2, 2, busy_now, cc);
    /* memory */
    uint32_t brk = (uint32_t)sys_sbrk(0);
    uint32_t used = brk > 0x800000u ? brk - 0x800000u : 0;
    n = ui_utoa(v, used / 1024); ui_cat(v + n, " KB");
    ui_cat(sub, "ring-3 heap, arena 4-32 MB");
    tile_value(3, v, sub, C_TEXT);
    /* network */
    uint8_t mac[7]; int have = sys_net_mac(mac) == 0;
    if (have) { n = ui_utoa(v, rx_frames); ui_cat(v + n, " rx"); }
    else ui_cat(v, "no NIC");
    if (have) {
        n = ui_utoa(sub, rx_bytes / 1024); n += ui_cat(sub + n, " KB  link ");
        ui_cat(sub + n, mac[6] ? "up" : "down");
    } else ui_cat(sub, "kernel found no NIC");
    tile_value(4, v, sub, have && mac[6] ? C_OK : C_MUTED);
}

static void draw_agents(void) {
    int x = ag_x, w = ag_w;
    int y = mid_y + UI_CH * 3 + UI_CH / 4;
    int pbw = w - UI_CW * 42; if (pbw < UI_CW * 6) pbw = UI_CW * 6;
    for (int i = 0; i < 8; i++, y += UI_CH) {
        const uint8_t *a = tbl + i * 8;
        char row[64]; int n;
        int busy = a[0] && a[2] == 1;
        ui_fill(x + 2, y, w - 4, UI_CH, busy ? C_SURF2 : C_SURF);
        if (!a[0]) {
            n = ui_cat(row, "["); n += ui_utoa(row + n, (uint32_t)i); n += ui_cat(row + n, "]  -      idle slot");
            ui_text(x + UI_CW, y, row, C_FAINT);
            continue;
        }
        n = ui_cat(row, "["); n += ui_utoa(row + n, (uint32_t)i); n += ui_cat(row + n, "]  ");
        n += ui_cat(row + n, type_name(a[1]));
        while (n < 11) row[n++] = ' ';
        n += ui_cat(row + n, busy ? "busy   " : "idle   ");
        if (a[3] == 0xff) n += ui_cat(row + n, "-     ");
        else { n += ui_cat(row + n, "#"); n += ui_utoa(row + n, a[3]); while (n < 24) row[n++] = ' '; }
        n += ui_utoa(row + n, (uint32_t)(a[4] | (a[5] << 8)));
        row[n] = 0;
        ui_text(x + UI_CW, y, row, busy ? C_TEXT : C_MUTED);
        int pct = a[6] | (a[7] << 8); if (pct > 100) pct = 100;
        bar(x + UI_CW * 32, y + UI_CH / 2 - 2, pbw, 4, busy ? pct : 0, C_ACCENT);
        if (busy) { char p[8]; int m = ui_utoa(p, (uint32_t)pct); ui_cat(p + m, "%"); ui_text(x + UI_CW * 32 + pbw + UI_CW / 2, y, p, C_ACCENT); }
    }
}

static void draw_tasks(void) {
    int x0 = tq_x, w = tq_w;
    int y = mid_y + UI_CH * 3 + UI_CH / 4;
    int any = 0;
    for (int i = 0; i < 8; i++, y += UI_CH) {
        const uint8_t *t = tbl + 64 + i * 16;
        ui_fill(x0 + 2, y, w - 4, UI_CH, t[0] && t[2] == 1 ? C_SURF2 : C_SURF);
        if (!t[0]) { ui_text(x0 + UI_CW, y, "-", C_FAINT); continue; }
        any++;
        static const char *stn[] = { "waiting", "running", "done", "ERROR" };
        uint32_t col = t[2] == 1 ? C_ACCENT : t[2] == 2 ? C_TEXT : t[2] == 3 ? C_ERR : C_WARN;
        char row[64]; int n = ui_utoa(row, (uint32_t)i); n += ui_cat(row + n, "  ");
        n += ui_cat(row + n, type_name(t[1]));
        while (n < 10) row[n++] = ' ';
        n += ui_cat(row + n, stn[t[2] & 3]);
        while (n < 19) row[n++] = ' ';
        if (t[1] == 1) { n += ui_cat(row + n, "0x"); /* scan: address */
            uint32_t a = t[4] | (t[5] << 8) | (t[6] << 16) | ((uint32_t)t[7] << 24);
            const char *hx = "0123456789abcdef"; for (int s = 28; s >= 0; s -= 4) row[n++] = hx[(a >> s) & 15]; }
        else { n += ui_utoa(row + n, (uint32_t)(t[4] | (t[5] << 8)));
            if (t[1] == 0 || t[1] == 6) { row[n++] = ' '; row[n++] = t[8] ? (char)t[8] : ','; row[n++] = ' ';
                n += ui_utoa(row + n, (uint32_t)(t[6] | (t[7] << 8))); } }
        while (n < 32) row[n++] = ' ';
        if (t[2] == 2) n += ui_itoa(row + n, (int)(t[12] | (t[13] << 8) | (t[14] << 16) | ((uint32_t)t[15] << 24)));
        else n += ui_cat(row + n, "-");
        row[n] = 0;
        ui_textn(x0 + UI_CW, y, row, w / UI_CW - 2, col);
    }
    cell_text(x0 + UI_CW, mid_y + mid_h - UI_CH - UI_CH / 4,
              any ? "" : "queue empty - try: spawn prime; task prime 60000", w / UI_CW - 2, C_FAINT);
}

static void draw_graph(void) {
    char s[64]; int n = ui_cat(s, "agents hold ");
    n += ui_utoa(s + n, (uint32_t)busy_now); n += ui_cat(s + n, any_busy ? "% (working)   tasks done per sample " : "% (parked)   tasks done per sample ");
    n += ui_utoa(s + n, (uint32_t)act_now);
    cell_text(UI_W - UI_CW * 62, graph_y + UI_CH / 2, "", 60, C_MUTED);
    ui_text(UI_W - UI_CW * (strlen(s) + 2), graph_y + UI_CH / 2, s, C_MUTED);
    ui_fill(gx, gy, gw, gh, C_BG);
    for (int p = 25; p <= 75; p += 25) {
        int yy = gy + gh - (gh * p) / 100;
        for (int i = 0; i < gw; i += 6) ui_fill(gx + i, yy, 3, 1, C_LINE);
    }
    int bw = gw / NSAMP; if (bw < 2) bw = 2;
    int x0 = gx + gw - nsamp * bw;                     /* newest at the right edge */
    for (int i = 0; i < nsamp; i++) {
        int v = samp[i] < 0 ? -samp[i] : samp[i], working = samp[i] > 0;
        int bh = (gh * v) / 100;
        uint32_t col = working ? C_ACCENT : ui_dim(C_ACCENT, 70);   /* bright = agents computing */
        if (bh > 0) ui_fill(x0 + i * bw, gy + gh - bh, bw - 1, bh, ui_dim(col, i == nsamp - 1 ? 255 : 200));
        else ui_fill(x0 + i * bw, gy + gh - 1, bw - 1, 1, C_ACCDIM);
        if (acts[i] > 0) {                             /* a completed task: a mark on top */
            int mh = acts[i] * 3; if (mh > gh / 4) mh = gh / 4;
            ui_fill(x0 + i * bw, gy + 2, bw - 1, mh, C_OK);
        }
    }
}

static void refresh(void) {
    drain_net();
    draw_header();
    draw_tiles();
    draw_agents();
    draw_tasks();
    draw_graph();
}

int sysmon_main(void) {
    if (ui_init() < 0) { print("sysmon: no framebuffer - boot with a VBE/GOP mode\r\n"); return 0; }
    print("sysmon: ready\r\n");
    layout();
    draw_static();
    sys_agents(tbl);
    refresh();
    uint32_t t_last = sys_uptime(), seen = t_last, next_log = t_last + 36;
    for (;;) {
        int k = ui_key();
        if (k == 'q' || k == 'Q' || k == UI_ESC || k == UI_CTRL('Q') || k == UI_CTRL('C')) {
            print("sysmon: quit\r\n");
            return 0;
        }
        uint32_t now = sys_uptime();
        if (now != seen) { tick_seen(now - seen); seen = now; }
        if (now - t_last >= REFRESH) {
            sys_progress(0);                            /* watchdog heartbeat */
            sys_agents(tbl);
            sample_cpu();
            refresh();
            if ((int)(now - next_log) >= 0) {
                int active = 0; for (int i = 0; i < 8; i++) if (tbl[i * 8]) active++;
                printf("sysmon: up=%us agents=%d share=%d%% %s rx=%u\r\n", now / 18, active, busy_now,
                       any_busy ? "working" : "parked", rx_frames);
                next_log = now + 36;
            }
            t_last = seen = sys_uptime();               /* the draw time is nobody's tick */
        }
    }
}
