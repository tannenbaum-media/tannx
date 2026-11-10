/* files.c - 'run files': a file manager for the FAT volume.
 *
 * Mounts the first FAT volume it finds (virtio-blk, USB stick, NVMe) through
 * the shared FAT layer and shows the root directory with sizes, the free
 * space, a viewer for text files (hex for binaries) and delete with a y/n
 * confirmation. Keys: j/k (or w/s) move, Enter/o open, d delete, r refresh,
 * q/ESC quit; in the viewer j/k space/b scroll, q back.
 * Serial markers: "files: FATnn on <dev> ...", "files: open X", "files:
 * deleted X", "files: quit". */
#include "dui.h"
#include "fatfs.h"

int vblk_mount(void); int usb_mount(void); int nvme_mount(void);

#define MAXE 96
typedef struct { char name[13]; uint32_t size; int dir; } ent_t;
static ent_t ents[MAXE];
static int   nents, sel, top;
static const char *dev;
static uint32_t free_kb, total_kb;
static uint8_t *fbuf;                  /* viewer buffer */
#define FBUF_CAP (256 * 1024)

static void add_ent(const char *name, uint32_t size, int isdir) {
    if (nents >= MAXE) return;
    dui_strcpy(ents[nents].name, name, 13);
    ents[nents].size = size; ents[nents].dir = isdir;
    nents++;
}
static void rescan(void) {
    nents = 0;
    fat_list(add_ent);
    fat_space(&free_kb, &total_kb);
    if (sel >= nents) sel = nents ? nents - 1 : 0;
}

static char *fmt_size(char *d, uint32_t sz) {
    char *e;
    if (sz >= 1024 * 1024) { e = dui_utoa(d, sz / (1024 * 1024)); dui_strcpy(e, " MB", 4); }
    else if (sz >= 1024)   { e = dui_utoa(d, sz / 1024); dui_strcpy(e, " KB", 4); }
    else                   { e = dui_utoa(d, sz); dui_strcpy(e, " B", 3); }
    return d;
}

static int ends(const char *nm, const char *suf) {
    int n = dui_strlen(nm), k = dui_strlen(suf);
    return n >= k && dui_startswith(nm + n - k, suf);
}
static const char *kind(const ent_t *e) {
    if (e->dir) return "folder";
    if (ends(e->name, ".TXT") || ends(e->name, ".MD") || ends(e->name, ".LOG")) return "text";
    if (ends(e->name, ".BMP")) return "image";
    if (ends(e->name, ".BIN") || ends(e->name, ".IMG")) return "binary";
    return "file";
}
static int is_text(const uint8_t *b, int n);
static int pv_len = -1;                /* preview of ents[sel]: bytes in fbuf, -1 none */
static void load_preview(void) {
    if (!fbuf) fbuf = malloc(FBUF_CAP);
    pv_len = (fbuf && nents && !ents[sel].dir) ? fat_file(ents[sel].name, fbuf, 4096) : -1;
}

#define LIST_ROW 4
static void draw_list(void) {
    dui_clear(DUI_BG);
    dui_header("files  -  FAT volume", dev);
    /* left: the file list card */
    int lx = 2, ly = LIST_ROW, lw = DUI.cols * 45 / 100, lh = DUI.rows - LIST_ROW - 2;
    dui_panel(lx * DUI.cw, ly * DUI.ch, lw * DUI.cw, lh * DUI.ch, DUI_PANEL, DUI_LINE);
    { char t[40]; char *e = t; dui_strcpy(e, "FILES   ", 9); e += 8; e = dui_utoa(e, (uint32_t)nents); dui_strcpy(e, " entries", 9);
      dui_text(lx + 1, ly + 1, t, DUI_ACCENT); }
    dui_text(lx + 2, ly + 3, "NAME", DUI_DIM); dui_text(lx + lw - 20, ly + 3, "SIZE", DUI_DIM); dui_text(lx + lw - 10, ly + 3, "TYPE", DUI_DIM);
    dui_hline((lx + 1) * DUI.cw, (ly + 4) * DUI.ch - DUI.sc, (lw - 2) * DUI.cw, DUI_LINE);
    int listrows = lh - 6;
    if (sel < top) top = sel;
    if (sel >= top + listrows) top = sel - listrows + 1;
    for (int i = 0; i < listrows; i++) {
        int k = top + i; if (k >= nents) break;
        int row = ly + 4 + i;
        if (k == sel) { dui_fill((lx + 1) * DUI.cw, row * DUI.ch, (lw - 2) * DUI.cw, DUI.ch, DUI_PANEL2);
                        dui_fill((lx + 1) * DUI.cw, row * DUI.ch, 3 * DUI.sc, DUI.ch, DUI_ACCENT); }
        dui_text(lx + 2, row, ents[k].name, k == sel ? DUI_ACCENT2 : DUI_TEXT);
        if (!ents[k].dir) { char sz[20]; fmt_size(sz, ents[k].size); dui_text(lx + lw - 16 - dui_strlen(sz), row, sz, DUI_TEXT); }
        dui_text(lx + lw - 10, row, kind(&ents[k]), DUI_MUTED);
    }
    if (!nents) dui_text(lx + 2, ly + 5, "(empty - 'run shot' puts a screenshot here)", DUI_MUTED);

    /* right: volume card + preview card */
    int rx = lx + lw + 2, rw = DUI.cols - 2 - rx;
    dui_panel(rx * DUI.cw, ly * DUI.ch, rw * DUI.cw, 6 * DUI.ch, DUI_PANEL, DUI_LINE);
    dui_text(rx + 1, ly + 1, "VOLUME", DUI_ACCENT);
    { char t[80]; char *e = t; dui_strcpy(e, "FAT", 4); e += 3; e = dui_utoa(e, (uint32_t)fat_bits()); dui_strcpy(e, " on ", 5); e += 4; dui_strcpy(e, dev, 20);
      dui_text(rx + 1, ly + 2, t, DUI_TEXT);
      e = t; e = dui_utoa(e, total_kb - free_kb); dui_strcpy(e, " KB used   ", 12); e += 11; e = dui_utoa(e, free_kb); dui_strcpy(e, " KB free   ", 12); e += 11;
      e = dui_utoa(e, total_kb); dui_strcpy(e, " KB total", 10);
      dui_text(rx + 1, ly + 4, t, DUI_MUTED); }
    { uint32_t used = total_kb - free_kb;                 /* 32-bit math: no __udivdi3 in this libc */
      dui_bar((rx + 1) * DUI.cw, (ly + 3) * DUI.ch + DUI.ch / 3, (rw - 2) * DUI.cw, DUI.ch / 3,
             total_kb ? (int)((used >> 4) * 1000 / ((total_kb >> 4) + 1)) : 0, DUI_ACCENT); }
    int py = ly + 7, ph = lh - 7;
    dui_panel(rx * DUI.cw, py * DUI.ch, rw * DUI.cw, ph * DUI.ch, DUI_PANEL, DUI_LINE);
    dui_text(rx + 1, py + 1, "PREVIEW", DUI_ACCENT);
    if (nents) {
        const ent_t *e = &ents[sel];
        char t[80]; dui_strcpy(t, e->name, 13); char *q = t + dui_strlen(t); dui_strcpy(q, "   ", 4); q += 3;
        if (!e->dir) { fmt_size(q, e->size); q += dui_strlen(q); dui_strcpy(q, "   ", 4); q += 3; }
        dui_strcpy(q, kind(e), 10);
        dui_text(rx + 1, py + 2, t, DUI_TEXT);
        int w = rw - 2, maxr = ph - 5, r = 0;
        if (pv_len > 0 && is_text(fbuf, pv_len)) {
            int i = 0;
            while (i < pv_len && r < maxr) {
                char line[160]; int k = 0;
                while (i < pv_len && fbuf[i] != '\n' && k < w && k < 159) { char c = (char)fbuf[i++]; line[k++] = (c == '\r' || c == '\t') ? ' ' : c; }
                if (i < pv_len && fbuf[i] == '\n') i++;
                line[k] = 0;
                dui_text(rx + 1, py + 4 + r++, line, DUI_MUTED);
            }
        } else if (pv_len > 0) {
            static const char hx[] = "0123456789abcdef";
            for (int off = 0; off < pv_len && r < maxr && off < 256; off += 16, r++) {
                char line[80]; int k = 0;
                for (int b = 0; b < 16; b++) {
                    if (off + b < pv_len) { line[k++] = hx[fbuf[off + b] >> 4]; line[k++] = hx[fbuf[off + b] & 15]; } else { line[k++] = ' '; line[k++] = ' '; }
                    line[k++] = ' ';
                }
                line[k++] = ' ';
                for (int b = 0; b < 16 && off + b < pv_len; b++) { uint8_t c = fbuf[off + b]; line[k++] = (c >= 32 && c < 127) ? (char)c : '.'; }
                line[k] = 0;
                dui_text(rx + 1, py + 4 + r, line, DUI_MUTED);
            }
            if (ends(e->name, ".BMP") && pv_len >= 26) {
                char d[48]; char *q2 = d; dui_strcpy(q2, "BMP image ", 11); q2 += 10;
                q2 = dui_utoa(q2, *(const uint32_t *)(fbuf + 18)); *q2++ = 'x'; q2 = dui_utoa(q2, *(const uint32_t *)(fbuf + 22));
                dui_strcpy(q2, " px, ", 6); q2 += 5; q2 = dui_utoa(q2, (uint32_t)fbuf[28]); dui_strcpy(q2, " bpp", 5);
                dui_text(rx + 1, py + 3, d, DUI_ACCENT2);
            }
        } else if (e->dir) dui_text(rx + 1, py + 4, "(a folder - this manager shows the root only)", DUI_MUTED);
    }
    dui_footer("j/k move   Enter open   d delete   r refresh   q quit");
}

static int is_text(const uint8_t *b, int n) {
    int bad = 0;
    for (int i = 0; i < n; i++) if (b[i] != '\r' && b[i] != '\n' && b[i] != '\t' && (b[i] < 32 || b[i] > 126)) bad++;
    return n == 0 || bad * 10 < n;
}

static void viewer(int idx) {
    ent_t *en = &ents[idx];
    if (!fbuf) fbuf = malloc(FBUF_CAP);
    if (!fbuf) return;
    int n = fat_file(en->name, fbuf, FBUF_CAP);
    if (n < 0) return;
    printf("files: open %s (%d bytes)\r\n", en->name, n);
    int text = is_text(fbuf, n < 4096 ? n : 4096);
    int rows = DUI.rows - 5, width = DUI.cols - 4, top2 = 0, total;
    /* line starts for text */
    static int starts[4000]; int nl = 0;
    if (text) {
        int i = 0;
        while (i < n && nl < 4000) {
            starts[nl++] = i;
            int c = 0;
            while (i < n && fbuf[i] != '\n' && c < width) { i++; c++; }
            if (i < n && fbuf[i] == '\n') i++;
        }
        total = nl;
    } else total = (n + 15) / 16;
    for (;;) {
        dui_clear(DUI_BG);
        char t[64]; dui_strcpy(t, en->name, 13); char *e = t + dui_strlen(t); dui_strcpy(e, text ? "  (text)" : "  (hex)", 10);
        dui_header(t, dev);
        for (int r = 0; r < rows; r++) {
            int li = top2 + r; if (li >= total) break;
            char line[200];
            if (text) {
                int i = starts[li], k = 0;
                while (i < n && fbuf[i] != '\n' && k < width && k < 199) { char c = (char)fbuf[i++]; line[k++] = (c == '\r' || c == '\t') ? ' ' : c; }
                line[k] = 0;
                dui_text(2, 4 + r, line, DUI_TEXT);
            } else {
                static const char hx[] = "0123456789abcdef";
                int off = li * 16, k = 0;
                for (int s = 28; s >= 0; s -= 4) line[k++] = hx[(off >> s) & 15];
                line[k++] = ' '; line[k++] = ' ';
                for (int b = 0; b < 16; b++) {
                    if (off + b < n) { line[k++] = hx[fbuf[off + b] >> 4]; line[k++] = hx[fbuf[off + b] & 15]; }
                    else { line[k++] = ' '; line[k++] = ' '; }
                    line[k++] = ' ';
                }
                line[k++] = ' ';
                for (int b = 0; b < 16 && off + b < n; b++) { uint8_t c = fbuf[off + b]; line[k++] = (c >= 32 && c < 127) ? (char)c : '.'; }
                line[k] = 0;
                dui_text(2, 4 + r, line, DUI_TEXT);
            }
        }
        char f[100]; e = f; dui_strcpy(e, "j/k space/b scroll   q back      line ", 40); e += dui_strlen(e);
        e = dui_utoa(e, (uint32_t)(total ? top2 + 1 : 0)); *e++ = '/'; dui_utoa(e, (uint32_t)total);
        dui_footer(f);
        int k = dui_getkey();
        if (k == 'q' || k == DUI_KEY_ESC) break;
        if ((k == 'j' || k == 's') && top2 + 1 < total) top2++;
        else if ((k == 'k' || k == 'w') && top2 > 0) top2--;
        else if (k == ' ' || k == 'f') { top2 += rows - 1; if (top2 >= total) top2 = total ? total - 1 : 0; }
        else if (k == 'b') { top2 -= rows - 1; if (top2 < 0) top2 = 0; }
    }
}

int files_main(void) {
    if (dui_init() < 0) { print("files: needs a framebuffer (boot with -vga std)\r\n"); return 0; }
    print("files: looking for a FAT volume (virtio-blk, USB, NVMe) ...\r\n");
    if (vblk_mount()) dev = "virtio-blk";
    else if (usb_mount()) dev = "USB";
    else if (nvme_mount()) dev = "NVMe";
    if (!dev) {
        print("files: no FAT volume. QEMU: -drive id=vd,file=disk.img,if=none,format=raw -device virtio-blk-pci,drive=vd\r\n"
              "       (mkfs.fat -F 16 disk.img on the host first)\r\n");
        return 0;
    }
    sys_fgrab(1);
    dui_flush_keys();
    rescan(); load_preview();
    printf("files: FAT%d on %s, %d entries, %u KB free of %u KB\r\n", fat_bits(), dev, nents, free_kb, total_kb);
    draw_list();
    for (;;) {
        int k = dui_getkey();
        if (k == 'q' || k == DUI_KEY_ESC) break;
        if ((k == 'j' || k == 's' || k == 'n') && sel + 1 < nents) sel++;
        else if ((k == 'k' || k == 'w' || k == 'p') && sel > 0) sel--;
        else if ((k == DUI_KEY_ENTER || k == '\n' || k == 'o') && nents && !ents[sel].dir) viewer(sel);
        else if (k == 'r') rescan();
        else if (k == 'd' && nents && !ents[sel].dir) {
            char q[64]; dui_strcpy(q, "Delete ", 8); dui_strcpy(q + 7, ents[sel].name, 13);
            dui_strcpy(q + dui_strlen(q), "?  y = yes, any other key = no", 32);
            dui_fill(0, (DUI.rows - 1) * DUI.ch, (int)DUI.fb.w, DUI.ch, 0x3A1F1Fu);
            dui_text(1, DUI.rows - 1, q, DUI_WARN);
            int c = dui_getkey();
            if (c == 'y' || c == 'Y') {
                int r = fat_delete(ents[sel].name);
                if (r == 0) printf("files: deleted %s\r\n", ents[sel].name);
                else printf("files: delete %s failed (%d)\r\n", ents[sel].name, r);
                rescan();
            }
        }
        load_preview();
        draw_list();
    }
    dui_clear(DUI_BG);
    sys_fgrab(0);
    print("files: quit\r\n");
    return 0;
}
