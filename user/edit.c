/* edit.c - 'run edit <file>': a small full-screen text editor.
 *
 * nano-like: arrows, Home/End, PgUp/PgDn, Backspace/Delete, Enter, Tab
 * (4 spaces), Ctrl+S saves, Ctrl+Q quits (twice if there are unsaved
 * changes). A status bar shows the file, the storage it lives on, Ln/Col,
 * size and the modified flag; a gutter numbers the lines.
 *
 * Storage: the first FAT volume found, probed in the order virtio-blk, NVMe,
 * USB stick (the ring-3 drivers in vblk.c / nvme.c / xhci.c expose a small
 * file API for this). With no FAT volume the file lives in an AgentFS slot
 * instead ('edit slot5', default slot 6): 480 bytes, needs 'diskon', the
 * same 'A''F' format as 'save'/'script' - so a script can be written in the
 * editor and run with 'script <slot>'.
 *
 * The buffer is one flat array (inserts memmove the tail; fine for the
 * 32 KB a FAT file may have here). Rows are redrawn only when they change:
 * typing inside a line repaints that line and the status bar, everything
 * else repaints the text area.
 *
 * Serial markers (test-edit.sh): "edit: opened ...", "edit: new file ...",
 * "edit: saved <n> bytes -> <name> (<store>)", "edit: quit". */
#include "ui.h"

int vblk_fat(void);
int vblk_file(const char *name, uint8_t *buf, int cap);
int vblk_savefile(const char *name, const uint8_t *data, int len);
int nvme_fat(void);
int nvme_file(const char *name, uint8_t *buf, int cap);
int nvme_savefile(const char *name, const uint8_t *data, int len);
int usb_fat(void);
int usb_file(const char *name, uint8_t *buf, int cap);
int usb_savefile(const char *name, const uint8_t *data, int len);

#define BUF_MAX   32768
#define SLOT_MAX  480
#define TABW      4
#define GUTTER    5                       /* cells: 4 digits + space */

enum { ST_SLOT = 0, ST_VBLK, ST_NVME, ST_USB };
static const char *st_name[] = { "slot", "virtio-blk", "nvme", "usb" };

static char buf[BUF_MAX + 1];
static int  len, cur, top, want_col;      /* cursor offset, first shown line, sticky column */
static int  modified, store, slot, quit_armed, title_mod;
static char name[48];
static char status_msg[64];
static uint32_t status_until, last_beat;
static int  rows, cols;                   /* text cells available */
static int  cap;                          /* byte cap for this storage */
static int  cur_line, cur_col, nlines;

/* ---- buffer geometry ---------------------------------------------------- */
static int line_start(int line) {         /* offset of line n (0-based) */
    int i = 0, l = 0;
    while (l < line && i < len) { if (buf[i] == '\n') l++; i++; }
    return i;
}
static int line_end(int off) { while (off < len && buf[off] != '\n') off++; return off; }
static void locate(void) {                /* cur -> cur_line/cur_col, nlines */
    cur_line = 0; cur_col = 0; nlines = 1;
    int ls = 0;
    for (int i = 0; i < len; i++) if (buf[i] == '\n') { nlines++; if (i < cur) { cur_line++; ls = i + 1; } }
    cur_col = cur - ls;
}

/* ---- storage ------------------------------------------------------------- */
static int probe_store(void) {
    if (name[0] == 's' && name[1] == 'l' && name[2] == 'o' && name[3] == 't'
        && name[4] >= '0' && name[4] <= '7' && !name[5]) { slot = name[4] - '0'; return ST_SLOT; }
    if (vblk_fat()) return ST_VBLK;
    if (nvme_fat()) return ST_NVME;
    if (usb_fat())  return ST_USB;
    return ST_SLOT;
}
static int load_file(void) {
    int n = -1;
    if (store == ST_SLOT) {
        static uint8_t sec[512];
        if (sys_read_sectors(257 + slot, 1, sec) == 1 && sec[0] == 'A' && sec[1] == 'F') {
            n = sec[2]; if (n > SLOT_MAX) n = SLOT_MAX;
            memcpy(buf, sec + 3, n);
        }
    } else if (store == ST_VBLK) n = vblk_file(name, (uint8_t *)buf, BUF_MAX);
    else if (store == ST_NVME)   n = nvme_file(name, (uint8_t *)buf, BUF_MAX);
    else                         n = usb_file(name, (uint8_t *)buf, BUF_MAX);
    if (n < 0) return -1;
    /* normalise CRLF -> LF, strip NULs */
    int o = 0;
    for (int i = 0; i < n; i++) { if (buf[i] == '\r' || buf[i] == 0) continue; buf[o++] = buf[i]; }
    len = o;
    return o;
}
static int save_file(void) {
    if (store == ST_SLOT) {
        static uint8_t sec[512];
        memset(sec, 0, 512);
        sec[0] = 'A'; sec[1] = 'F'; sec[2] = (uint8_t)len;
        memcpy(sec + 3, buf, len);
        return sys_write_slot(slot, sec);
    }
    if (store == ST_VBLK) return vblk_savefile(name, (const uint8_t *)buf, len);
    if (store == ST_NVME) return nvme_savefile(name, (const uint8_t *)buf, len);
    return usb_savefile(name, (const uint8_t *)buf, len);
}

/* ---- drawing --------------------------------------------------------------- */
static void set_status(const char *s, int ticks) {
    ui_cat(status_msg, s);
    status_until = sys_uptime() + (uint32_t)ticks;
}

static void draw_title(void) {
    ui_fill(0, 0, UI_W, UI_CH + UI_CH / 2, C_SURF);
    ui_fill(0, 0, UI_W, 2, C_ACCENT);
    int ty = UI_CH / 4 + 1;
    ui_text(UI_CW, ty, "TannX edit", C_ACCENT);
    char s[96]; int n = ui_cat(s, name);
    if (modified) n += ui_cat(s + n, " *");
    ui_text(UI_CW * 19, ty, s, C_TEXT);
    n = ui_cat(s, "on ");
    n += ui_cat(s + n, st_name[store]);
    if (store == ST_SLOT) { n += ui_cat(s + n, " "); n += ui_utoa(s + n, (uint32_t)slot); n += ui_cat(s + n, " (480 B, diskon)"); }
    else n += ui_cat(s + n, " FAT");
    ui_text(UI_W - UI_CW * (strlen(s) + 1), ty, s, C_MUTED);
}

static void draw_status(void) {
    int y = UI_H - UI_CH * 2;
    ui_fill(0, y - UI_CH / 2, UI_W, UI_CH * 2 + UI_CH / 2, C_SURF);
    ui_hline(0, y - UI_CH / 2, UI_W, C_LINE);
    locate();
    char s[96]; int n = ui_cat(s, "Ln ");
    n += ui_utoa(s + n, (uint32_t)cur_line + 1); n += ui_cat(s + n, "/");
    n += ui_utoa(s + n, (uint32_t)nlines); n += ui_cat(s + n, "  Col ");
    n += ui_utoa(s + n, (uint32_t)cur_col + 1); n += ui_cat(s + n, "  ");
    n += ui_utoa(s + n, (uint32_t)len); n += ui_cat(s + n, " B");
    if (modified) n += ui_cat(s + n, "  modified");
    ui_text(UI_CW, y, s, modified ? C_WARN : C_MUTED);
    if (status_msg[0] && sys_uptime() < status_until) {
        ui_text(UI_W - UI_CW * (strlen(status_msg) + 1), y, status_msg, C_ACCENT);
    }
    int hy = y + UI_CH;
    ui_text(UI_CW, hy, "^S", C_ACCENT);     ui_text(UI_CW * 4, hy, "save", C_MUTED);
    ui_text(UI_CW * 10, hy, "^Q", C_ACCENT); ui_text(UI_CW * 13, hy, "quit", C_MUTED);
    ui_text(UI_CW * 19, hy, "PgUp/PgDn", C_ACCENT); ui_text(UI_CW * 29, hy, "page", C_MUTED);
    ui_text(UI_CW * 35, hy, "Home/End", C_ACCENT);  ui_text(UI_CW * 44, hy, "line", C_MUTED);
    ui_text(UI_CW * 50, hy, "Tab", C_ACCENT);       ui_text(UI_CW * 54, hy, "4 spaces", C_MUTED);
}

/* paint screen row r (0..rows-1) = buffer line top+r */
static void draw_row(int r, int off) {
    int y = UI_CH * 2 + r * UI_CH;
    int line = top + r;
    int is_cur = (off >= 0 && line == cur_line);
    uint32_t bg = is_cur ? C_SURF : C_BG;
    ui_fill(0, y, UI_W, UI_CH, bg);
    if (off < 0 || off > len) {                 /* past the end of the buffer */
        ui_text(UI_CW * (GUTTER - 2), y, "~", C_FAINT);
        return;
    }
    char num[8]; int n = ui_utoa(num, (uint32_t)line + 1);
    ui_text(UI_CW * (GUTTER - 1 - n), y, num, is_cur ? C_ACCDIM : C_FAINT);
    int e = line_end(off);
    int x = UI_CW * GUTTER;
    int n_show = e - off; if (n_show > cols) n_show = cols;
    ui_textn(x, y, buf + off, n_show, C_TEXT);
    if (e - off > cols) ui_text(UI_W - UI_CW, y, ">", C_ACCENT);
    if (is_cur) {
        int cx = x + cur_col * UI_CW;
        if (cur_col < cols) {
            ui_fill(cx, y, UI_CW, UI_CH, C_ACCENT);
            if (cur < len && buf[cur] != '\n') ui_textn(cx, y, buf + cur, 1, C_ACCINK);
        }
    }
}

static void draw_text(void) {
    int off = line_start(top);
    for (int r = 0; r < rows; r++) {
        int line = top + r;
        if (line >= nlines) { draw_row(r, line == nlines ? len + 1 : -1); continue; }
        draw_row(r, off);
        off = line_end(off) + 1;
    }
}

/* keep the cursor on screen; returns 1 if the view scrolled (full repaint) */
static int ensure_visible(void) {
    locate();
    int old = top;
    if (cur_line < top) top = cur_line;
    if (cur_line >= top + rows) top = cur_line - rows + 1;
    if (top < 0) top = 0;
    return top != old;
}

/* ---- editing ----------------------------------------------------------------- */
static int insert(const char *s, int n) {
    if (len + n > cap) { set_status(store == ST_SLOT ? "slot full (480 B)" : "buffer full", 54); return 0; }
    for (int i = len - 1; i >= cur; i--) buf[i + n] = buf[i];
    memcpy(buf + cur, s, n);
    len += n; cur += n; modified = 1; quit_armed = 0;
    return 1;
}
static void erase(int at, int n) {
    if (at < 0 || at + n > len) return;
    for (int i = at; i + n < len; i++) buf[i] = buf[i + n];
    len -= n; modified = 1; quit_armed = 0;
}
static void move_line(int delta) {        /* up/down keeping the wanted column */
    locate();
    int target = cur_line + delta;
    if (target < 0) target = 0;
    if (target >= nlines) target = nlines - 1;
    if (target == cur_line) { cur = delta < 0 ? 0 : len; return; }
    int ls = line_start(target), le = line_end(ls);
    int c = want_col; if (c > le - ls) c = le - ls;
    cur = ls + c;
}

int edit_main(const char *arg) {
    const char *p = arg + 4; while (*p == ' ') p++;
    int n = 0;
    while (p[n] && p[n] != ' ' && n < 47) { name[n] = p[n]; n++; }
    name[n] = 0;
    if (!n) ui_cat(name, "NOTE.TXT");
    if (ui_init() < 0) { print("edit: no framebuffer - boot with a VBE/GOP mode\r\n"); return 0; }

    slot = 6;
    store = probe_store();
    cap = store == ST_SLOT ? SLOT_MAX : BUF_MAX;
    int got = load_file();
    if (got >= 0) printf("edit: opened %s (%d bytes) via %s\r\n", name, got, st_name[store]);
    else { len = 0; printf("edit: new file %s via %s\r\n", name, st_name[store]); }
    if (store == ST_SLOT) printf("edit: no FAT volume - using AgentFS slot %d (480 B, needs diskon)\r\n", slot);
    buf[len] = 0;

    rows = (UI_H - UI_CH * 2 - UI_CH * 2 - UI_CH / 2) / UI_CH;
    cols = UI_COLS - GUTTER - 1;
    cur = 0; top = 0; want_col = 0;
    locate();
    ui_fill(0, 0, UI_W, UI_H, C_BG);
    draw_title(); draw_text(); draw_status();
    last_beat = sys_uptime();

    for (;;) {
        int k = ui_key();
        if (!k) {
            uint32_t now = sys_uptime();
            if (now - last_beat > 18) { sys_progress(0); last_beat = now; }
            if (status_msg[0] && now >= status_until) { status_msg[0] = 0; draw_status(); }
            sys_yield();
            continue;
        }
        int full = 0, old_line;
        locate(); old_line = cur_line;
        switch (k) {
        case UI_CTRL('Q'): case UI_CTRL('C'):
            if (modified && !quit_armed) { quit_armed = 1; set_status("unsaved - ^Q again to discard", 90); draw_status(); break; }
            print("edit: quit\r\n");
            return 0;
        case UI_CTRL('S'): {
            int r = save_file();
            if (r == 0) {
                modified = 0;
                printf("edit: saved %d bytes -> %s (%s)\r\n", len, name, st_name[store]);
                set_status("saved", 54);
            } else {
                printf("edit: save FAILED (%d) -> %s (%s)\r\n", r, name, st_name[store]);
                set_status(store == ST_SLOT ? "save failed: run diskon first" : "save failed (FAT)", 90);
            }
            draw_title(); draw_status();
            break;
        }
        case UI_LEFT:  if (cur > 0) cur--; want_col = -1; break;
        case UI_RIGHT: if (cur < len) cur++; want_col = -1; break;
        case UI_UP:    move_line(-1); break;
        case UI_DOWN:  move_line(1); break;
        case UI_PGUP:  move_line(-(rows - 1)); top -= rows - 1; if (top < 0) top = 0; full = 1; break;
        case UI_PGDN:  move_line(rows - 1); top += rows - 1; if (top > nlines - 1) top = nlines - 1; full = 1; break;
        case UI_HOME:  cur = line_start(cur_line); want_col = -1; break;
        case UI_END:   cur = line_end(cur); want_col = -1; break;
        case UI_BS:
            if (cur > 0) { int nl = buf[cur - 1] == '\n'; erase(cur - 1, 1); cur--; full = nl; }
            want_col = -1; break;
        case UI_DEL:
            if (cur < len) { int nl = buf[cur] == '\n'; erase(cur, 1); full = nl; }
            want_col = -1; break;
        case UI_ENTER: insert("\n", 1); full = 1; want_col = -1; break;
        case UI_TAB:   insert("    ", TABW); want_col = -1; break;
        case UI_ESC: break;
        default:
            if (k >= 32 && k < 127) { char c = (char)k; insert(&c, 1); want_col = -1; }
        }
        locate();
        if (want_col < 0) want_col = cur_col;
        if (ensure_visible()) full = 1;
        if (full) { draw_text(); }
        else if (cur_line != old_line) {
            /* two rows change: the old current line loses its highlight */
            int r0 = old_line - top, r1 = cur_line - top;
            if (r0 >= 0 && r0 < rows) draw_row(r0, old_line < nlines ? line_start(old_line) : len + 1);
            if (r1 >= 0 && r1 < rows) draw_row(r1, line_start(cur_line));
        } else {
            draw_row(cur_line - top, line_start(cur_line));
        }
        draw_status();
        if (modified != title_mod) { title_mod = modified; draw_title(); }
    }
}
