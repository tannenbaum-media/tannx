/* cast.c - 'run cast [url | play <url>]': stream YouTube or media to a
 * Chromecast through the host proxy (proxy_ext.py /cast/*: pychromecast or
 * the catt CLI on the host, a simulated "Living Room TV" with --mock).
 *
 *   run cast                 the app: devices, URL line, now-playing card
 *   run cast <url>           the app, starts playing <url> on the first device
 *   run cast play <url>      one-shot from the shell: play, print the status
 *
 * App keys: 1-9 pick a device, u/g enter a URL, space pause/resume, +/-
 * volume, s stop, r rescan devices, q/ESC quit. The now-playing card polls
 * /cast/status every ~2 s. Wire format (plain text): POST /cast/<op> with
 * "<device>\n<arg>"; replies are "key=value" lines (state, title, pos, dur,
 * vol) or "error: ...". Serial markers: "cast: devices N", "cast: <reply
 * first line>", "cast: quit". */
#include "dui.h"

int proxy_post(const char *path, const char *body, char *out, int cap, int timeout);

#define NDEV 8
static char devname[NDEV][40], devmodel[NDEV][32], devhost[NDEV][24];
static int  ndev, cur;
static char reply[2048];
static char st_state[24], st_title[96]; static int st_pos, st_dur, st_vol;
static char urlbuf[240];
static char msg[120];                  /* last message line */
static uint32_t msg_t;

static const char *kv(const char *key) {
    static char val[96];
    const char *p = reply; int kl = dui_strlen(key);
    while (*p) {
        if (dui_startswith(p, key) && p[kl] == '=') {
            p += kl + 1; int n = 0;
            while (*p && *p != '\r' && *p != '\n' && n < 95) val[n++] = *p++;
            val[n] = 0; return val;
        }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }
    val[0] = 0; return val;
}
static void parse_status(void) {
    dui_strcpy(st_state, kv("state"), 24);
    dui_strcpy(st_title, kv("title"), 96);
    st_pos = dui_atoi(kv("pos")); st_dur = dui_atoi(kv("dur")); st_vol = dui_atoi(kv("vol"));
}
static void first_line(char *d, int cap) {
    int n = 0; while (reply[n] && reply[n] != '\r' && reply[n] != '\n' && n < cap - 1) { d[n] = reply[n]; n++; } d[n] = 0;
}
/* POST /cast/<op> "<device>\n<arg>" */
static int cast_op(const char *op, const char *arg) {
    char path[32]; dui_strcpy(path, "/cast/", 8); dui_strcpy(path + 6, op, 24);
    static char body[300];
    dui_strcpy(body, ndev ? devname[cur] : "", 40);
    int n = dui_strlen(body); body[n++] = '\n'; dui_strcpy(body + n, arg ? arg : "", 250);
    int got = proxy_post(path, body, reply, sizeof reply, 36);   /* 2 s/segment: the reply is small and quick */
    if (!got) dui_strcpy(reply, "error: no answer from the host proxy (./llm-proxy.py)", sizeof reply);
    if (!dui_startswith(reply, "error")) parse_status();
    if (dui_startswith(op, "status") && !dui_startswith(reply, "error")) return 1;   /* polls stay quiet */
    first_line(msg, sizeof msg); msg_t = sys_uptime();
    printf("cast: %s\r\n", msg);
    return got && !dui_startswith(reply, "error");
}
static void scan_devices(void) {
    ndev = 0;
    char path[] = "/cast/devices";
    int got = proxy_post(path, "", reply, sizeof reply, 108);   /* mDNS discovery takes a few seconds */
    const char *p = reply;
    while (got && *p && ndev < NDEV && !dui_startswith(p, "error")) {
        int f = 0, n = 0; char *dst[3] = { devname[ndev], devmodel[ndev], devhost[ndev] }; int cap[3] = { 40, 32, 24 };
        while (*p && *p != '\r' && *p != '\n') {
            if (*p == '|') { dst[f][n] = 0; if (f < 2) f++; n = 0; }
            else if (n < cap[f] - 1) dst[f][n++] = *p;
            p++;
        }
        dst[f][n] = 0;
        if (devname[ndev][0]) ndev++;
        while (*p == '\r' || *p == '\n') p++;
    }
    if (!got) dui_strcpy(msg, "no answer from the host proxy - start ./llm-proxy.py", sizeof msg);
    else if (dui_startswith(reply, "error")) first_line(msg, sizeof msg);
    else { dui_strcpy(msg, "devices found", sizeof msg); }
    msg_t = sys_uptime();
    if (cur >= ndev) cur = 0;
    printf("cast: devices %d\r\n", ndev);
}

static void fmt_time(char *d, int s) {
    char *e = dui_utoa(d, (uint32_t)(s / 60)); *e++ = ':'; *e++ = (char)('0' + (s / 10) % 6); *e++ = (char)('0' + s % 10); *e = 0;
}

static void draw_np(void);
static int scanning;            /* first scan running: no 'not found' yet */
static void draw(void) {
    dui_clear(DUI_BG);
    dui_header("cast  -  Chromecast", "via llm-proxy.py /cast");
    int lx = 2 * DUI.cw, ly = 4 * DUI.ch, lw = 36 * DUI.cw, lh = (DUI.rows - 6) * DUI.ch;
    dui_panel(lx, ly, lw, lh, DUI_PANEL, DUI_LINE);
    dui_text(3, 5, "DEVICES", DUI_ACCENT);
    dui_text(3, 6, "1-9 selects   r rescans", DUI_DIM);
    for (int i = 0; i < ndev; i++) {
        int row = 8 + i * 3;
        if (i == cur) { dui_fill(lx + 2, row * DUI.ch - DUI.sc * 2, lw - 4, 2 * DUI.ch + 4 * DUI.sc, DUI_PANEL2); dui_fill(lx + 2, row * DUI.ch - DUI.sc * 2, 3 * DUI.sc, 2 * DUI.ch + 4 * DUI.sc, DUI_ACCENT); }
        char l[48]; l[0] = (char)('1' + i); l[1] = ' '; l[2] = ' '; dui_strcpy(l + 3, devname[i], 34);
        dui_text(4, row, l, i == cur ? DUI_ACCENT2 : DUI_TEXT);
        dui_strcpy(l, devmodel[i], 24); int n = dui_strlen(l); dui_strcpy(l + n, "  ", 3); dui_strcpy(l + n + 2, devhost[i], 20);
        dui_text(7, row + 1, l, DUI_MUTED);
    }
    if (!ndev && scanning) dui_text(3, 8, "scanning ...", DUI_WARN);
    else if (!ndev) {
        dui_text(3, 8, "no Chromecast found", DUI_WARN);
        dui_text(3, 10, "On the host:", DUI_MUTED);
        dui_text(3, 11, "  pip install pychromecast", DUI_TEXT);
        dui_text(3, 12, "  ./llm-proxy.py", DUI_TEXT);
        dui_text(3, 13, "in the same LAN as the TV", DUI_MUTED);
        dui_text(3, 14, "(--mock simulates one)", DUI_DIM);
    }
    draw_np();
    dui_footer("u url   space pause/resume   +/- volume   s stop   1-9 device   r rescan   q quit");
}

/* the now-playing card alone (what the 2 s status poll repaints - no flicker) */
static void draw_np(void) {
    int lx = 2 * DUI.cw, ly = 4 * DUI.ch, lw = 36 * DUI.cw, lh = (DUI.rows - 6) * DUI.ch;
    int rx = lx + lw + 2 * DUI.cw, ry = ly, rw = (int)DUI.fb.w - rx - 2 * DUI.cw, rh = lh;
    dui_panel(rx, ry, rw, rh, DUI_PANEL, DUI_LINE);
    int rc = rx / DUI.cw + 1;
    dui_text(rc, 5, "NOW PLAYING", DUI_ACCENT);
    const char *dev = ndev ? devname[cur] : "-";
    dui_text(rc, 6, dev, DUI_MUTED);
    int playing = dui_startswith(st_state, "PLAYING"), paused = dui_startswith(st_state, "PAUSED");
    /* a big state badge */
    dui_fill(rx + DUI.cw, 8 * DUI.ch, (dui_strlen(st_state[0] ? st_state : "IDLE") + 2) * DUI.cw, DUI.ch + 4 * DUI.sc,
            playing ? DUI_ACCENT : paused ? DUI_WARN : DUI_LINE);
    dui_textpx(rx + 2 * DUI.cw, 8 * DUI.ch + 2 * DUI.sc, st_state[0] ? st_state : "IDLE", DUI.sc, playing || paused ? DUI_BG : DUI_MUTED);
    char t[100]; dui_strcpy(t, st_title[0] ? st_title : "(nothing playing - press u for a URL)", 100);
    int maxc = rw / DUI.cw - 3; if (dui_strlen(t) > maxc && maxc > 3) t[maxc] = 0;
    if (dui_strlen(t) * 2 + 2 < rw / DUI.cw) dui_text_big(rc, 10, t, DUI_TEXT); else dui_text(rc, 10, t, DUI_TEXT);
    /* progress */
    char a[16], b[16]; fmt_time(a, st_pos); fmt_time(b, st_dur);
    dui_text(rc, 13, a, DUI_MUTED); dui_text(rc + maxc - dui_strlen(b), 13, b, DUI_MUTED);
    dui_bar(rx + DUI.cw, 14 * DUI.ch + DUI.ch / 3, rw - 2 * DUI.cw, DUI.ch / 3, st_dur ? st_pos * 1000 / st_dur : 0, DUI_ACCENT);
    /* volume */
    dui_text(rc, 16, "VOLUME", DUI_DIM);
    char v[8]; dui_utoa(v, (uint32_t)st_vol); dui_text(rc + 8, 16, v, DUI_TEXT);
    dui_bar(rx + DUI.cw, 17 * DUI.ch + DUI.ch / 3, (rw - 2 * DUI.cw) / 2, DUI.ch / 3, st_vol * 10, DUI_ACCENT2);
    /* url line */
    dui_text(rc, 19, "URL", DUI_DIM);
    dui_fill(rx + 5 * DUI.cw, 19 * DUI.ch, rw - 6 * DUI.cw, DUI.ch, DUI_PANEL2);
    char u[120]; dui_strcpy(u, urlbuf, 120); if (dui_strlen(u) > maxc - 6 && maxc > 8) u[maxc - 6] = 0;
    dui_textpx(rx + 5 * DUI.cw + DUI.cw / 2, 19 * DUI.ch, u, DUI.sc, DUI_TEXT);
    /* message */
    if (msg[0]) dui_text(rc, 21, msg, dui_startswith(msg, "error") ? DUI_BAD : DUI_OK);
}

static void play(const char *u) {
    if (!u[0]) return;
    dui_strcpy(urlbuf, u, sizeof urlbuf);
    if (!ndev) { dui_strcpy(msg, "error: no device - r to rescan", sizeof msg); return; }
    cast_op("play", u);
}

int cast_main(const char *arg) {
    const char *a = arg + 4; while (*a == ' ') a++;
    char first[240]; dui_strcpy(first, a, sizeof first);
    { int n = dui_strlen(first); while (n && first[n - 1] == ' ') first[--n] = 0; }
    if (dui_startswith(first, "play ")) {                /* one-shot from the shell */
        const char *u = first + 5; while (*u == ' ') u++;
        scan_devices();
        if (!ndev) { printf("cast: %s\r\n", msg); return 0; }
        printf("cast: device %s\r\n", devname[cur]);
        cast_op("play", u);
        char *p = reply; while (*p) { if (*p == '\n') { print("\r\n"); } else if (*p != '\r') sys_putc(*p); p++; }
        return 0;
    }
    if (dui_init() < 0) { print("cast: needs a framebuffer (boot with -vga std)\r\n"); return 0; }
    sys_fgrab(1);
    dui_flush_keys();
    scanning = 1; draw();         /* (drawing "scanning" over the "not found" */
    scan_devices();               /*  text garbled both) */
    scanning = 0;
    if (ndev) cast_op("status", "");
    if (first[0]) play(first);
    draw();
    uint32_t lastpoll = sys_uptime();
    for (;;) {
        int k = 0;
        while (!(k = sys_getkey())) {
            if (sys_uptime() - lastpoll >= 36 && ndev) { lastpoll = sys_uptime(); cast_op("status", ""); draw_np(); }
            sys_progress(50); sys_yield();
        }
        if (k == 'q' || k == DUI_KEY_ESC) break;
        if (k >= '1' && k <= '9') { if (k - '1' < ndev) { cur = k - '1'; cast_op("status", ""); } }
        else if (k == 'r') { scan_devices(); if (ndev) cast_op("status", ""); }
        else if (k == 'u' || k == 'g') {
            int rc = (2 * DUI.cw + 36 * DUI.cw + 2 * DUI.cw) / DUI.cw + 1;
            int kk = dui_readline(rc + 5, 19, DUI.cols - rc - 8, urlbuf, sizeof urlbuf);
            if (kk == DUI_KEY_ENTER) play(urlbuf);
        }
        else if (k == ' ') { if (dui_startswith(st_state, "PLAYING")) cast_op("pause", ""); else cast_op("resume", ""); }
        else if (k == '+' || k == '=') cast_op("volume", "+");
        else if (k == '-') cast_op("volume", "-");
        else if (k == 's') cast_op("stop", "");
        draw();
        lastpoll = sys_uptime();
    }
    dui_clear(DUI_BG);
    sys_fgrab(0);
    print("cast: quit\r\n");
    return 0;
}
