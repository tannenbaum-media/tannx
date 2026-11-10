/* www.c - 'run www <url>': a text-mode web browser.
 *
 * The OS has no TLS, so the page comes through the host proxy: POST /fetch
 * with the URL as the body (proxy_ext.py fetches it over HTTPS on the host,
 * strips the HTML to text, numbers the links, caps the size and refuses
 * private / loopback targets). The reply format is
 *     TITLE: <title>
 *     URL: <final url>
 *     <text with inline [n] link marks>
 *     --LINKS--
 *     n <url>
 * We word-wrap the text to the screen, paint the [n] marks in the accent
 * colour, and keep a small history for 'back'.
 *
 * Keys: j/k line, space/f page down, b page up, <number> Enter follow link,
 * h or Backspace back, g address line, r reload, q/ESC quit.
 * Serial markers: "www: fetching <url>", "www: <n> lines, <m> links",
 * "www: title <t>", "www: quit". */
#include "dui.h"

int proxy_post(const char *path, const char *body, char *out, int cap, int timeout);

#define PAGE_CAP   32768
#define MAX_LINES  2400
#define MAX_LINKS  100
#define URL_CAP    240
#define HIST       8

static char  page[PAGE_CAP];
static char  title[128];
static char  url[URL_CAP];
static char  hist[HIST][URL_CAP];
static int   histn;
static const char *lines[MAX_LINES];  /* start of each wrapped line in page[] */
static short linelen[MAX_LINES];
static int   nlines;
static char  links[MAX_LINKS][URL_CAP];
static int   nlinks;
static int   top;                      /* first visible line */
static char  numbuf[8];                /* link number being typed */
static int   numlen;
static int   status_err;

static int rows0, rows1, width;        /* page area rows and text width */
static int colx, linkx;                /* text column x, links panel x (cells) */

/* split the proxy reply into title / text lines / links */
static void parse_page(void) {
    nlines = 0; nlinks = 0; title[0] = 0;
    char *p = page;
    if (dui_startswith(p, "TITLE: ")) {
        char *e = p + 7; int n = 0;
        while (*e && *e != '\r' && *e != '\n') { if (n < 127) title[n++] = *e; e++; }
        title[n] = 0;
        while (*e == '\r' || *e == '\n') e++;
        p = e;
    }
    if (dui_startswith(p, "URL: ")) {
        char *e = p + 5; int n = 0;
        while (*e && *e != '\r' && *e != '\n') { if (n < URL_CAP - 1) url[n++] = *e; e++; }
        url[n] = 0;
        while (*e == '\r' || *e == '\n') e++;
        p = e;
    }
    /* wrap paragraphs to `width` */
    while (*p && nlines < MAX_LINES) {
        if (dui_startswith(p, "--LINKS--")) break;
        const char *s = p;
        int n = 0, lastsp = -1;
        while (p[n] && p[n] != '\r' && p[n] != '\n' && n < width) {
            if (p[n] == ' ') lastsp = n;
            n++;
        }
        if (p[n] && p[n] != '\r' && p[n] != '\n' && lastsp > 0) n = lastsp;
        lines[nlines] = s; linelen[nlines] = (short)n; nlines++;
        p += n;
        while (*p == ' ') p++;
        if (*p == '\r') p++;
        if (*p == '\n') p++;
    }
    if (dui_startswith(p, "--LINKS--")) {
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
        while (*p && nlinks < MAX_LINKS) {
            int idx = dui_atoi(p);
            while (*p >= '0' && *p <= '9') p++;
            while (*p == ' ') p++;
            int n = 0;
            while (*p && *p != '\r' && *p != '\n') { if (n < URL_CAP - 1) links[nlinks][n++] = *p; p++; }
            links[nlinks][n] = 0;
            if (idx == nlinks + 1 && n) nlinks++;
            while (*p == '\r' || *p == '\n') p++;
        }
    }
}

static int fetch(const char *u) {
    dui_strcpy(url, u, URL_CAP);
    printf("www: fetching %s\r\n", url);
    status_err = 0;
    int got = proxy_post("/fetch", url, page, PAGE_CAP, 72);   /* 4 s/segment; the proxy itself gives up after 15 s */
    if (!got) {
        dui_strcpy(page, "TITLE: no answer\nURL: \n\nThe host proxy did not answer.\n"
                        "Start it on the host:   ./llm-proxy.py   (or --mock)\n"
                        "and make sure QEMU has a NIC (the default user network is enough).\n", PAGE_CAP);
        status_err = 1;
    } else if (dui_startswith(page, "error:")) status_err = 1;
    parse_page();
    top = 0; numlen = 0; numbuf[0] = 0;
    printf("www: %d lines, %d links\r\n", nlines, nlinks);
    if (title[0]) printf("www: title %s\r\n", title);
    return got;
}

/* draw one wrapped line, painting [n] link marks in the accent colour */
static void draw_line(int row, const char *s, int n) {
    int x = colx, i = 0;
    while (i < n) {
        if (s[i] == '[') {
            int j = i + 1; while (j < n && s[j] >= '0' && s[j] <= '9') j++;
            if (j < n && s[j] == ']' && j > i + 1) {
                char m[8]; int k = 0;
                for (int t = i; t <= j && k < 7; t++) m[k++] = s[t];
                m[k] = 0;
                dui_text(x, row, m, DUI_ACCENT);
                x += k; i = j + 1; continue;
            }
        }
        char c[2] = { s[i], 0 };
        uint32_t col = DUI_TEXT;
        if (i == 0 && s[0] == '#') col = DUI_ACCENT2;
        if (c[0] != ' ') dui_text(x, row, c, col);
        x++; i++;
    }
}

static void draw_links(void) {
    if (linkx <= 0) return;
    int x = linkx * DUI.cw, y = (rows0 - 1) * DUI.ch, w = (DUI.cols - 1 - linkx) * DUI.cw, h = (rows1 - rows0 + 1) * DUI.ch;
    dui_panel(x, y, w, h, DUI_PANEL, DUI_LINE);
    dui_text(linkx + 1, rows0 - 1, "LINKS", DUI_ACCENT);
    dui_text(linkx + 7, rows0 - 1, "number + Enter", DUI_DIM);
    int maxw = (DUI.cols - 1 - linkx) - 7;
    for (int i = 0; i < nlinks && i < rows1 - rows0 - 1; i++) {
        char n[8]; n[0] = '['; char *e = dui_utoa(n + 1, (uint32_t)(i + 1)); *e++ = ']'; *e = 0;
        dui_text(linkx + 1, rows0 + 1 + i, n, DUI_ACCENT);
        const char *u = links[i];
        if (dui_startswith(u, "https://")) u += 8; else if (dui_startswith(u, "http://")) u += 7;
        char t[120]; dui_strcpy(t, u, 120); if (dui_strlen(t) > maxw && maxw > 4) { t[maxw - 2] = '.'; t[maxw - 1] = '.'; t[maxw] = 0; }
        dui_text(linkx + 6, rows0 + 1 + i, t, DUI_MUTED);
    }
}

static void draw_page(void) {
    dui_fill(0, rows0 * DUI.ch, (linkx > 0 ? linkx - 1 : DUI.cols) * DUI.cw, (rows1 - rows0) * DUI.ch, DUI_BG);
    for (int r = 0; r < rows1 - rows0; r++) {
        int li = top + r;
        if (li >= nlines) break;
        int heading = linelen[li] > 0 && lines[li][0] == '#';
        if (heading) {                               /* "## Title" -> accent, no hashes */
            const char *s = lines[li]; int n = linelen[li];
            while (n && *s == '#') { s++; n--; }
            while (n && *s == ' ') { s++; n--; }
            char buf[200]; int k = 0; while (k < n && k < 199) { buf[k] = s[k]; k++; } buf[k] = 0;
            dui_text(colx, rows0 + r, buf, DUI_ACCENT2);
            dui_hline(colx * DUI.cw, (rows0 + r + 1) * DUI.ch - DUI.sc, k * DUI.cw, DUI_LINE);
        } else draw_line(rows0 + r, lines[li], linelen[li]);
    }
}

static void draw_chrome(void) {
    dui_clear(DUI_BG);
    dui_header("www  -  text browser", "via llm-proxy.py /fetch");
    /* address line */
    int y = 3 * DUI.ch;
    dui_fill(0, y, (int)DUI.fb.w, DUI.ch + DUI.ch / 2, DUI_PANEL);
    dui_text(1, 3, "URL", DUI_MUTED);
    dui_fill(5 * DUI.cw, y + DUI.sc * 2, (DUI.cols - 6) * DUI.cw, DUI.ch, DUI_PANEL2);
    char u[200]; dui_strcpy(u, url, 200);
    if (dui_strlen(u) > DUI.cols - 8) u[DUI.cols - 8] = 0;
    dui_textpx(5 * DUI.cw + DUI.cw / 2, y + DUI.sc * 2, u, DUI.sc, status_err ? DUI_BAD : DUI_TEXT);
    dui_hline(0, y + DUI.ch + DUI.ch / 2 - 1, (int)DUI.fb.w, DUI_LINE);
    /* title row */
    char t[200]; dui_strcpy(t, title[0] ? title : "(untitled)", 200);
    if (dui_strlen(t) > DUI.cols - 4) t[DUI.cols - 4] = 0;
    dui_text(colx, 5, t, DUI_ACCENT2);
    dui_hline(colx * DUI.cw, 6 * DUI.ch - DUI.sc * 2, dui_strlen(t) * DUI.cw, DUI_ACCENT);
}

static void draw_footer(void) {
    char f[160];
    char *e = f;
    if (numlen) { dui_strcpy(e, "follow link: ", 20); e += 13; dui_strcpy(e, numbuf, 8); e += numlen; dui_strcpy(e, "_   ", 5); e += 4; }
    else { dui_strcpy(e, "j/k space/b scroll   <n>+Enter link   h back   g url   r reload   q quit   ", 80); e += dui_strlen(e); }
    dui_strcpy(e, "line ", 6); e += 5; e = dui_utoa(e, (uint32_t)(nlines ? top + 1 : 0));
    *e++ = '/'; e = dui_utoa(e, (uint32_t)nlines);
    dui_strcpy(e, "  links ", 9); e += 8; dui_utoa(e, (uint32_t)nlinks);
    dui_footer(f);
}

static void redraw(void) { draw_chrome(); draw_page(); draw_links(); draw_footer(); }

static void push_hist(const char *u) {
    if (histn == HIST) { for (int i = 1; i < HIST; i++) dui_strcpy(hist[i - 1], hist[i], URL_CAP); histn--; }
    dui_strcpy(hist[histn++], u, URL_CAP);
}

int www_main(const char *arg) {
    const char *a = arg + 3; while (*a == ' ') a++;
    if (dui_init() < 0) { print("www: needs a framebuffer (boot with -vga std)\r\n"); return 0; }
    sys_fgrab(1);
    dui_flush_keys();
    rows0 = 7; rows1 = DUI.rows - 1;
    /* a reading column (<= 100 cells) with the links panel beside it when the
     * screen is wide enough, else the full width and no panel */
    colx = 2; width = DUI.cols - 4; linkx = 0;
    if (DUI.cols >= 120) { width = DUI.cols - 4 - 44; if (width > 100) width = 100; linkx = colx + width + 3; }
    char input[URL_CAP]; dui_strcpy(input, a, URL_CAP);
    { int n = dui_strlen(input); while (n && input[n - 1] == ' ') input[--n] = 0; }
    if (!input[0]) {
        dui_strcpy(url, "", URL_CAP); redraw();
        dui_text(colx, rows0, "Type a URL and press Enter (ESC quits).", DUI_MUTED);
        int k = dui_readline(5, 3, DUI.cols - 6, input, URL_CAP);
        if (k == DUI_KEY_ESC || !input[0]) { sys_fgrab(0); print("www: quit\r\n"); return 0; }
    }
    redraw();
    dui_text(colx, rows0, "fetching ...", DUI_WARN);
    fetch(input); push_hist(url);
    redraw();
    for (;;) {
        int k = dui_getkey();
        int pageh = rows1 - rows0;
        if (k == 'q' || k == DUI_KEY_ESC) break;
        if (k >= '0' && k <= '9') {
            if (numlen < 3) { numbuf[numlen++] = (char)k; numbuf[numlen] = 0; }
            draw_footer(); continue;
        }
        if (k == DUI_KEY_ENTER || k == '\n') {
            if (numlen) {
                int n = dui_atoi(numbuf); numlen = 0; numbuf[0] = 0;
                if (n >= 1 && n <= nlinks) {
                    char u[URL_CAP]; dui_strcpy(u, links[n - 1], URL_CAP);
                    redraw(); dui_text(colx, rows0, "fetching ...", DUI_WARN);
                    fetch(u); push_hist(url); redraw();
                } else draw_footer();
            }
            continue;
        }
        if (k == DUI_KEY_BS || k == 127) { if (numlen) { numbuf[--numlen] = 0; draw_footer(); continue; } k = 'h'; }
        if (k == 'j' || k == 's') { if (top + 1 < nlines) top++; }
        else if (k == 'k' || k == 'w') { if (top > 0) top--; }
        else if (k == ' ' || k == 'f') { top += pageh - 1; if (top >= nlines) top = nlines ? nlines - 1 : 0; }
        else if (k == 'b') { top -= pageh - 1; if (top < 0) top = 0; }
        else if (k == 'h') {
            if (histn > 1) { histn--; char u[URL_CAP]; dui_strcpy(u, hist[histn - 1], URL_CAP);
                redraw(); dui_text(colx, rows0, "fetching ...", DUI_WARN); fetch(u); redraw(); }
            continue;
        }
        else if (k == 'r') { char u[URL_CAP]; dui_strcpy(u, url, URL_CAP); redraw(); fetch(u); redraw(); continue; }
        else if (k == 'g') {
            char u[URL_CAP]; dui_strcpy(u, url, URL_CAP);
            int kk = dui_readline(5, 3, DUI.cols - 6, u, URL_CAP);
            if (kk == DUI_KEY_ENTER && u[0]) { redraw(); dui_text(colx, rows0, "fetching ...", DUI_WARN); fetch(u); push_hist(url); }
            redraw(); continue;
        }
        else continue;
        draw_page(); draw_footer();
    }
    dui_clear(DUI_BG);
    sys_fgrab(0);
    print("www: quit\r\n");
    return 0;
}
