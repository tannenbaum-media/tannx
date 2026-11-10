/* fetch.c - 'fetch' / 'run fetch': a neofetch-style system card for
 * TannX OS, ring 3.
 *
 * Left: the boot banner's fir in teal half-block art (CP437 0xDB/0xDC/0xDF,
 * generated into fetch_logo.h by user/mkfetchlogo.py). Right: what
 * the OS knows about itself - version, kernel, uptime, boot path, CPU
 * (cpuid, no kernel help needed), RAM, display, agents and tasks, NIC,
 * disk - then the tagline and the 16-colour palette strip.
 *
 * Everything goes out through SYS_WRITE, so it renders the same on the VGA
 * text console and the VBE/GOP framebuffer console, and lands on COM1 as
 * UTF-8 (putc converts the CP437 blocks). Colour is the console's own
 * 0x01 <attr> escape, which SYS_WRITE honours like the kernel's puts_attr;
 * the attribute the shell was using comes back from SYS_SYSINFO and is
 * restored at the end so the prompt keeps its colour.
 *
 * Not a daemon: prints and exits. Deliberately free of the framebuffer
 * primitives so it keeps working in text mode. */
#include "libc.h"

/* VGA attributes. 2/3/9 are re-programmed to the house teals by the kernel
 * (logo_palette): 2 = dark teal 0x2a6b60, 3 = light teal 0x6fc6b4,
 * 9 = accent 0x2dd4bf. 6 = brown, 7 = grey, 8 = dark grey, 15 = white. */
#define A_TEAL_D  0x02
#define A_TEAL_L  0x03
#define A_ACCENT  0x09
#define A_TRUNK   0x06
#define A_GREY    0x07
#define A_DIM     0x08
#define A_WHITE   0x0f

#include "fetch_logo.h"    /* the boot banner's fir as (char, attr) cells */
#define LOGO_W   FLOGO_W       /* text columns the logo occupies (25)       */
#define LOGO_ROWS FLOGO_ROWS   /* text rows (13)                            */
#define GAP      3             /* columns between logo and the facts        */

/* ---- output buffer: one write per line keeps serial/console in step --- */
static char  line[200];
static int   ll;

static void lput(char c)            { if (ll < (int)sizeof(line) - 1) line[ll++] = c; }
static void lattr(int a)            { lput(0x01); lput((char)a); }
static void lstr(const char *s)     { while (*s) lput(*s++); }
static void lflush(void)            { line[ll] = 0; sys_write(line, ll); ll = 0; }
static void lrep(char c, int n)     { while (n-- > 0) lput(c); }
static void ldec(uint32_t v) {
    char b[12]; int i = 0;
    if (!v) b[i++] = '0';
    while (v) { b[i++] = '0' + (char)(v % 10); v /= 10; }
    while (i) lput(b[--i]);
}
static void ldec2(uint32_t v)       { lput('0' + (char)(v / 10 % 10)); lput('0' + (char)(v % 10)); }
static void lhex2(uint32_t v) {
    const char *h = "0123456789abcdef";
    lput(h[(v >> 4) & 15]); lput(h[v & 15]);
}

/* ---- the fir: the boot banner's tree (logo/mklogo.py rasteriser), folded
 * into CP437 half blocks by user/mkfetchlogo.py -> fetch_logo.h ----------- */
/* emit text row r of the logo; blank past the logo (the facts run longer) */
static void logo_row(int r) {
    int cur = -1;
    if (r >= LOGO_ROWS) { lrep(' ', LOGO_W); return; }
    for (int x = 0; x < LOGO_W; x++) {
        int ch = flogo[r][x][0], attr = flogo[r][x][1];
        if (ch == 0x20) { lput(' '); continue; }
        if (attr != cur) { lattr(attr); cur = attr; }
        lput((char)ch);
    }
    lattr(A_GREY);
}

/* ---- facts ------------------------------------------------------------ */
static inline void cpuid(uint32_t leaf, uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d) {
    __asm__ volatile("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d) : "a"(leaf), "c"(0));
}

static char cpu_brand[52];
static void read_cpu(void) {
    uint32_t a, b, c, d, max;
    cpuid(0x80000000u, &max, &b, &c, &d);
    char raw[49]; int n = 0;
    if (max >= 0x80000004u) {
        for (uint32_t l = 0x80000002u; l <= 0x80000004u; l++) {
            cpuid(l, &a, &b, &c, &d);
            uint32_t r[4] = { a, b, c, d };
            for (int i = 0; i < 4; i++)
                for (int k = 0; k < 4; k++) raw[n++] = (char)(r[i] >> (8 * k));
        }
    } else {                                      /* vendor string fallback */
        cpuid(0, &a, &b, &c, &d);
        uint32_t r[3] = { b, d, c };
        for (int i = 0; i < 3; i++)
            for (int k = 0; k < 4; k++) raw[n++] = (char)(r[i] >> (8 * k));
    }
    raw[n] = 0;
    /* trim, collapse runs of spaces, drop the trailing junk */
    int o = 0, sp = 1;
    for (int i = 0; i < n && raw[i]; i++) {
        char ch = raw[i];
        if (ch < ' ' || ch > '~') continue;
        if (ch == ' ') { if (sp) continue; sp = 1; } else sp = 0;
        if (o < 50) cpu_brand[o++] = ch;
    }
    while (o && cpu_brand[o - 1] == ' ') o--;
    cpu_brand[o] = 0;
    if (!o) { const char *u = "unknown x86"; while (*u) cpu_brand[o++] = *u++; cpu_brand[o] = 0; }
}

static const char *nic_name(int id) {
    switch (id) {
        case 1: return "RTL8139"; case 2: return "e1000";
        case 3: return "RTL8168"; case 4: return "virtio-net";
        default: return 0;
    }
}
static const char *typ_name(int t) {
    switch (t) {
        case 0: return "math";  case 1: return "scan";  case 2: return "count";
        case 3: return "prime"; case 5: return "ask";   case 6: return "gcd";
        default: return "agent";
    }
}

/* one fact line: label in accent, value in white; `pad` right-pads the label */
static void label(const char *k) {
    lattr(A_ACCENT); lstr(k); lattr(A_DIM); lput(':');
    int n = strlen(k) + 1; while (n++ < 10) lput(' ');
    lattr(A_WHITE);
}

int fetch_main(void) {
    unsigned char si[64];
    unsigned char ag[192];
    unsigned char mac[8];
    uint32_t fbi[4];
    static unsigned char sect[512];

    memset(si, 0, sizeof si);
    int have_si = sys_sysinfo(si) == 0;
    uint32_t ram   = *(uint32_t *)(si + 0);
    uint32_t mhz   = *(uint32_t *)(si + 4);
    uint32_t cores = *(uint32_t *)(si + 8);
    int shell_attr = have_si ? si[12] : A_GREY;
    int boot = si[13], nic = si[14], armed = si[15];
    uint32_t kbytes = *(uint32_t *)(si + 16);
    uint32_t ticks  = have_si ? *(uint32_t *)(si + 20) : sys_uptime();
    const char *ver = "v?";                        /* "AgentOS/32 v2.87 " -> "v2.87" */
    for (int i = 24; i < 62; i++)
        if (si[i] == 'v' && si[i + 1] >= '0' && si[i + 1] <= '9') { ver = (const char *)si + i; break; }
    for (int i = 24; i < 64; i++) if (si[i] == ' ') si[i] = 0;

    read_cpu();
    int have_fb = sys_fbinfo(fbi) == 0 && fbi[0] != 0;
    int have_ag = sys_agents(ag) == 0;
    int have_mac = sys_net_mac(mac) == 0;

    int agents = 0, busy = 0, done = 0, running = 0, waiting = 0;
    char roster[64]; int rl = 0;
    if (have_ag) {
        for (int s = 0; s < 8; s++) {
            if (!ag[s * 8] || ag[s * 8 + 1] == 4) continue;   /* free / a program */
            agents++;
            if (ag[s * 8 + 2] == 1) busy++;
            done += ag[s * 8 + 4] | (ag[s * 8 + 5] << 8);
            const char *t = typ_name(ag[s * 8 + 1]);
            if (rl + strlen(t) + 2 < (int)sizeof roster) {
                if (rl) roster[rl++] = ' ';
                while (*t) roster[rl++] = *t++;
            }
        }
        for (int t = 0; t < 8; t++) {
            if (!ag[64 + t * 16]) continue;
            int st = ag[64 + t * 16 + 2];
            if (st == 1) running++; else if (st == 0) waiting++;
        }
    }
    roster[rl] = 0;

    int disk = -1;                                 /* -1 none, 0 foreign, 1 ours */
    if (sys_read_sectors(256, 1, sect) >= 0) {
        static const char m[] = "AGENTOS-MEDIUM";
        disk = memcmp(sect, m, 14) == 0;
    }

    uint32_t secs = ticks * 10 / 182;              /* PIT at 18.2 Hz */
    uint32_t hh = secs / 3600, mm = secs / 60 % 60, ss = secs % 60;

    /* ---- render: logo rows left, one fact line each to the right. The shell
     * launcher (do_fetch) waits for us like 'wait', so the prompt comes after
     * the card; a 'run fetch' prompt may interleave - cosmetic only. ---- */
    lattr(A_GREY); lstr("\r\n"); lflush();
    for (int r = 0; r < 15; r++) {                 /* 15 fact rows, 13 logo rows */
        logo_row(r);
        lrep(' ', GAP);
        switch (r) {                               /* each value <= 54 columns */
        case 0:
            lattr(A_ACCENT); lstr("agents"); lattr(A_DIM); lput('@');
            lattr(A_ACCENT); lstr("tannx");
            break;
        case 1:
            lattr(A_DIM); lrep('-', 18);
            break;
        case 2:
            label("OS"); lstr("TannX OS "); lstr(ver); lstr(" i386");
            break;
        case 3:
            label("Kernel"); lstr("agentos32 "); lstr(ver);
            lattr(A_GREY); lstr(" (GNU as, "); ldec((kbytes + 1023) / 1024); lstr("/128 KB)");
            break;
        case 4:
            label("Uptime");
            if (hh) { ldec(hh); lstr("h "); }
            ldec2(mm); lstr("m "); ldec2(ss); lput('s');
            lattr(A_GREY); lstr(", ticks "); ldec(ticks);
            break;
        case 5:
            label("Boot");
            lstr(boot == 2 ? "PXE (diskless)" : boot == 1 ? "UEFI (GOP)" : "BIOS (ATA)");
            lattr(A_GREY); lstr(", shell tannx> + scripts");
            break;
        case 6:
            label("CPU"); lstr(cpu_brand);
            lattr(A_GREY);
            if (cores > 1) { lstr(" x"); ldec(cores); }
            if (mhz) { lstr(" @ "); ldec(mhz); lstr(" MHz"); }
            break;
        case 7:
            label("Memory");
            if (ram) { ldec(ram >> 20); lstr(" MB usable"); lattr(A_GREY); lstr(" (E820)"); }
            else lstr("unknown");
            break;
        case 8:
            label("Display");
            if (have_fb) {
                ldec(fbi[1]); lput('x'); ldec(fbi[2]); lstr("x32 framebuffer");
                lattr(A_GREY); lstr(", console 80x25");
            } else {
                lstr("VGA text 80x25"); lattr(A_GREY); lstr(" (no framebuffer)");
            }
            break;
        case 9:
            label("Agents");
            if (!have_ag) { lstr("n/a"); break; }
            ldec(agents); lstr(agents == 1 ? " agent" : " agents");
            if (busy) { lstr(", "); ldec(busy); lstr(" busy"); }
            if (rl) { lattr(A_GREY); lstr(" ("); lstr(roster); lput(')'); }
            break;
        case 10:
            label("Tasks");
            if (!have_ag) { lstr("n/a"); break; }
            ldec(done); lstr(" done");
            lattr(A_GREY); lstr(", "); ldec(running); lstr(" running, ");
            ldec(waiting); lstr(" waiting");
            break;
        case 11:
            label("Network");
            if (have_mac && nic_name(nic)) {
                lstr(nic_name(nic)); lput(' ');
                for (int i = 0; i < 6; i++) { if (i) lput(':'); lhex2(mac[i]); }
                lattr(A_GREY); lstr(mac[6] ? ", link up" : ", no link");
            } else if (have_mac && mac[6]) {
                lstr("NIC ");
                for (int i = 0; i < 6; i++) { if (i) lput(':'); lhex2(mac[i]); }
            } else {
                lstr("none"); lattr(A_GREY); lstr(" (ring-3 TCP/IP stack idle)");
            }
            break;
        case 12:
            label("Disk");
            if (disk == 1) { lstr("TannX medium"); lattr(A_GREY); lstr(" (marker at LBA 256"); lstr(armed ? ", diskon)" : ")"); }
            else if (disk == 0) { lstr("foreign disk"); lattr(A_GREY); lstr(" (never written)"); }
            else { lstr("none"); lattr(A_GREY); lstr(" (RAM-backed slots)"); }
            break;
        case 13:
            label("Userland"); lstr("ring-3 C, INT 0x30 gate");
            lattr(A_GREY); lstr(", 24 syscalls");
            break;
        case 14:
            label("Roster"); lstr("math scan count prime gcd ask");
            lattr(A_GREY); lstr(" + wish, llm");
            break;
        }
        lattr(A_GREY); lstr("\r\n"); lflush();
    }

    /* tagline + palette strip under the card */
    lrep(' ', LOGO_W + GAP);
    lattr(A_TEAL_L); lstr("Plant a wish. "); lattr(A_WHITE); lstr("The agents grow it.");
    lattr(A_GREY); lstr("\r\n"); lflush();
    lrep(' ', LOGO_W + GAP);
    for (int c = 0; c < 8; c++) { lattr(c ? c : A_DIM); lrep((char)0xDB, 3); }
    lattr(A_GREY); lstr("\r\n"); lflush();
    lrep(' ', LOGO_W + GAP);
    for (int c = 8; c < 16; c++) { lattr(c); lrep((char)0xDB, 3); }
    lattr(A_GREY); lstr("\r\n"); lflush();
    lattr(shell_attr); lstr("\r\n"); lflush();     /* hand the colour back to the shell */
    return 0;
}
