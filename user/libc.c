/* libc.c - TannX OS ring-3 C library. All kernel interaction is a single
 * INT 0x30 with EAX = syscall number, args in EBX/ECX/EDX, return in EAX
 * (see agentos32.S syscall_isr). Freestanding: -ffreestanding -nostdlib. */
#include "libc.h"

/* ---- raw syscalls ------------------------------------------------- *
 * INT 0x30 returns its result in EAX; the kernel preserves EBX-EBP but
 * NOT EAX/flags. So every wrapper takes an "=a" output (even the void
 * ones, discarded) and clobbers "memory","cc" - otherwise gcc assumes
 * EAX still holds the input number across the trap and miscompiles
 * callers that interleave several syscalls (e.g. printf). */
void sys_exit(int code) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(4), "b"(code) : "memory", "cc");
    (void)r;
    __builtin_unreachable();
}
int sys_write(const char *buf, int len) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(5), "b"(buf), "c"(len) : "memory", "cc");
    return r;
}
void sys_putc(int c) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(6), "b"(c) : "memory", "cc");
    (void)r;
}
int sys_fbinfo(uint32_t *dst16) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(7), "b"(dst16) : "memory", "cc");
    return r;
}
int sys_getkey(void) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(8) : "memory", "cc");
    return r;
}
uint32_t sys_uptime(void) {
    uint32_t r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(9) : "memory", "cc");
    return r;
}
int sys_read_sectors(uint32_t lba, uint32_t count, void *dst) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(10), "b"(lba), "c"(count), "d"(dst) : "memory", "cc");
    return r;
}
void *sys_sbrk(int incr) {
    void *r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(11), "b"(incr) : "memory", "cc");
    return r;
}
void sys_yield(void) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(0) : "memory", "cc");
    (void)r;
}
int sys_net_tx(const void *buf, int len) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(12), "b"(buf), "c"(len) : "memory", "cc");
    return r;
}
int sys_net_rx(void *buf, int maxlen) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(13), "b"(buf), "c"(maxlen) : "memory", "cc");
    return r;
}
int sys_net_mac(void *buf7) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(14), "b"(buf7) : "memory", "cc");
    return r;
}
int sys_write_slot(int slot, const void *src512) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(15), "b"(slot), "c"(src512) : "memory", "cc");
    return r;
}
uint32_t sys_pci(uint32_t cfgaddr, uint32_t val, int wr) {
    uint32_t r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(16), "b"(cfgaddr), "c"(val), "d"(wr) : "memory", "cc");
    return r;
}
uint32_t sys_mmio_map(uint32_t phys) {
    uint32_t r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(17), "b"(phys) : "memory", "cc");
    return r;
}

/* PCI config space over sys_pci - the drivers walk the bus with a packed
 * bdf (bus 0, dev = bdf>>3, fn = bdf&7). reg is dword-aligned by the mask. */
#define PCI_ADDR(bus, dev, fn, reg) \
    (0x80000000u | ((bus) << 16) | ((dev) << 11) | ((fn) << 8) | ((reg) & 0xfc))
uint32_t pci_rd(int bdf, int reg) {
    return sys_pci(PCI_ADDR(0, bdf >> 3, bdf & 7, reg), 0, 0);
}
void pci_wr(int bdf, int reg, uint32_t v) {
    sys_pci(PCI_ADDR(0, bdf >> 3, bdf & 7, reg), v, 1);
}
uint8_t pci_rd8(int bdf, int reg) {          /* byte from a dword read */
    return (uint8_t)(pci_rd(bdf, reg & 0xfc) >> ((reg & 3) * 8));
}

/* scan bus 0 for the first present function whose class/subclass/prog-if
 * (config dword 0x08, minus the revision byte) matches `class` under `mask`
 * - e.g. pci_find_class(0x0c0330, 0xffffff) = xHCI, (0x040300, 0xffff00) =
 * any HDA audio regardless of prog-if. Returns the packed bdf, or -1. */
int pci_find_class(uint32_t class, uint32_t mask) {
    for (int b = 0; b < 0x100; b++) {
        uint32_t id = pci_rd(b, 0);
        if (id == 0xffffffffu || id == 0) continue;
        if ((((pci_rd(b, 0x08) >> 8) & mask)) == class) return b;
    }
    return -1;
}

/* scan bus 0 for the first function with this exact (device<<16)|vendor id
 * (config dword 0x00) - the virtio devices match by id. bdf, or -1. */
int pci_find_id(uint32_t id) {
    for (int b = 0; b < 0x100; b++) {
        if (pci_rd(b, 0) == id) return b;
    }
    return -1;
}

/* map BAR[index] of a device into an uncached user page via sys_mmio_map.
 * Returns the mapped virtual address, or 0 on failure (a mapped BAR is always
 * high RAM, never 0). Prints a tag-prefixed message on refusal. */
uint32_t pci_map_bar(int bdf, int index, const char *tag) {
    uint32_t bar = pci_rd(bdf, 0x10 + index * 4) & ~0xfu;
    uint32_t va = sys_mmio_map(bar);
    if (va == 0xffffffffu) { printf("%s: BAR%d map refused (%x)\r\n", tag, index, bar); return 0; }
    return va;
}
int sys_claim(void) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(1) : "memory", "cc");
    return r;
}
void sys_progress(int pct) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(2), "b"(pct) : "memory", "cc");
    (void)r;
}
void sys_finish(int result) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(3), "b"(result) : "memory", "cc");
    (void)r;
}
uint32_t sys_task_info(int idx) {
    uint32_t r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(18), "b"(idx) : "memory", "cc");
    return r;
}
int sys_console(void *buf4004) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(19), "b"(buf4004) : "memory", "cc");
    return r;
}
int sys_agents(void *buf192) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(20), "b"(buf192) : "memory", "cc");
    return r;
}
int sys_atp(void *buf52) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(21), "b"(buf52) : "memory", "cc");
    return r;
}
int sys_setmission(const void *buf, int len) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(22), "b"(buf), "c"(len) : "memory", "cc");
    return r;
}
int sys_sysinfo(void *buf64) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(23), "b"(buf64) : "memory", "cc");
    return r;
}
/* 24 = KBGRAB: hold the keyboard (fg_prog) + the FB gate until this program exits */
int sys_kbgrab(void) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(24) : "memory", "cc");
    return r;
}

int sys_fgrab(int on) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r) : "a"(25), "b"(on) : "memory", "cc");
    return r;
}
int sys_shell(const char *line, int len) {
    int r;
    __asm__ volatile("int $0x30" : "=a"(r)
                     : "a"(26), "b"(line), "c"(len) : "memory", "cc");
    return r;
}

/* ---- string / memory --------------------------------------------- */
void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = d; const uint8_t *sp = s;
    while (n--) *dp++ = *sp++;
    return d;
}
void *memset(void *d, int c, size_t n) {
    uint8_t *dp = d;
    while (n--) *dp++ = (uint8_t)c;
    return d;
}
int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *pa = a, *pb = b;
    while (n--) { if (*pa != *pb) return *pa - *pb; pa++; pb++; }
    return 0;
}
int strlen(const char *s) {
    int n = 0;
    while (s[n]) n++;
    return n;
}

/* ---- output ------------------------------------------------------- */
void print(const char *s) {
    sys_write(s, strlen(s));
}

static void print_uint(unsigned int v, int base, int upper) {
    char buf[12];
    const char *digs = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int i = 0;
    if (v == 0) { sys_putc('0'); return; }
    while (v) { buf[i++] = digs[v % base]; v /= base; }
    while (i--) sys_putc(buf[i]);
}

void printf(const char *fmt, ...) {
    __builtin_va_list ap;
    __builtin_va_start(ap, fmt);
    for (const char *p = fmt; *p; p++) {
        if (*p != '%') { sys_putc(*p); continue; }
        p++;
        switch (*p) {
        case 'd': {
            int v = __builtin_va_arg(ap, int);
            if (v < 0) { sys_putc('-'); print_uint((unsigned)(-v), 10, 0); }
            else print_uint((unsigned)v, 10, 0);
            break;
        }
        case 'u': print_uint(__builtin_va_arg(ap, unsigned), 10, 0); break;
        case 'x': print_uint(__builtin_va_arg(ap, unsigned), 16, 0); break;
        case 'X': print_uint(__builtin_va_arg(ap, unsigned), 16, 1); break;
        case 'c': sys_putc(__builtin_va_arg(ap, int)); break;
        case 's': print(__builtin_va_arg(ap, const char *)); break;
        case '%': sys_putc('%'); break;
        case '\0': p--; break;          /* trailing '%' - don't run off */
        default: sys_putc('%'); sys_putc(*p); break;
        }
    }
    __builtin_va_end(ap);
}

/* ---- heap: a plain bump allocator over sbrk (no free) ------------- */
void *malloc(size_t n) {
    n = (n + 15) & ~((size_t)15);       /* 16-byte align */
    void *p = sys_sbrk((int)n);
    if (p == (void *)-1) return 0;
    return p;
}

/* 4 KB-aligned zeroed RAM (identity-mapped, so va == phys = DMA-able) - the
 * common allocation the block/DMA drivers need for rings, buffers and sector
 * scratch. Over-allocates a page so the aligned block always fits. 0 on OOM. */
void *zpage(uint32_t n) {
    uint32_t p = (uint32_t)malloc(n + 4096);
    if (!p) return 0;
    p = (p + 0xfffu) & ~0xfffu;
    memset((void *)p, 0, n);
    return (void *)p;
}

/* ---- framebuffer -------------------------------------------------- */
int fb_get(fb_t *fb) {
    uint32_t info[4];
    if (sys_fbinfo(info) < 0) return -1;
    fb->base = (uint32_t *)info[0];
    fb->w    = info[1];
    fb->h    = info[2];
    fb->ppsl = info[3];
    return 0;
}
void fb_putpixel(fb_t *fb, int x, int y, uint32_t color) {
    if ((unsigned)x >= fb->w || (unsigned)y >= fb->h) return;
    fb->base[(unsigned)y * fb->ppsl + (unsigned)x] = color;
}
void fb_fillrect(fb_t *fb, int x, int y, int w, int h, uint32_t color) {
    for (int j = 0; j < h; j++) {
        int yy = y + j;
        if ((unsigned)yy >= fb->h) break;
        uint32_t *row = fb->base + (unsigned)yy * fb->ppsl;
        for (int i = 0; i < w; i++) {
            int xx = x + i;
            if ((unsigned)xx < fb->w) row[xx] = color;
        }
    }
}

/* draw a string in a caller-supplied 8x8 block font, scaled by sc, advancing
 * 7*sc per char. `chars` is the glyph char set, `data[k]` its 8-byte bitmap;
 * an unknown char falls back to data[0]. (The snake/invaders HUD renderer -
 * each game keeps its own font, this is just the shared drawing.) */
void fb_text(fb_t *fb, int x, int y, const char *s, int sc, uint32_t col,
             const char *chars, const uint8_t (*data)[8]) {
    for (int i = 0; s[i]; i++) {
        const uint8_t *g = data[0];
        for (int k = 0; chars[k]; k++)
            if (chars[k] == s[i]) { g = data[k]; break; }
        int cx = x + i * 7 * sc;
        for (int r = 0; r < 8; r++)
            for (int b = 0; b < 8; b++)
                if (g[r] & (0x80 >> b))
                    fb_fillrect(fb, cx + b * sc, y + r * sc, sc, sc, col);
    }
}
void fb_blit_scaled(fb_t *fb, const uint32_t *src, int sw, int sh,
                    int ox, int oy, int sc) {
    if (sc < 1) sc = 1;
    for (int y = 0; y < sh; y++) {
        const uint32_t *srow = src + (unsigned)y * sw;
        for (int ys = 0; ys < sc; ys++) {
            int dy = oy + y * sc + ys;
            if ((unsigned)dy >= fb->h) return;
            uint32_t *drow = fb->base + (unsigned)dy * fb->ppsl + ox;
            for (int x = 0; x < sw; x++) {
                uint32_t px = srow[x];
                for (int xs = 0; xs < sc; xs++) {
                    int dx = ox + x * sc + xs;
                    if ((unsigned)dx < fb->w) drow[x * sc + xs] = px;
                }
            }
        }
    }
}
