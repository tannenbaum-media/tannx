/* appmain.c - the entry the kernel jumps to. 'run <arg>' leaves the arg
 * string at USER_ARG; we dispatch to the right app. No arg / anything but
 * "net" -> the video player (the default, what test-pxe/test-run check). */
#include "libc.h"

int video_main(void);
int net_main(void);
int llm_main(const char *arg);
int llmscript_main(const char *arg);
int offload_main(const char *arg);
int hda_main(void);
int askd_main(void);
int snake_main(void);
int invaders_main(void);
int gui_main(void);
int fetch_main(void);
int forest_main(void);
int tour_main(void);   /* 'run tour'  - the guided tour (user/tour.c) */
int www_main(const char *arg);   /* 'run www <url>' - text browser (user/www.c) */
int files_main(void);  /* 'run files' - FAT file manager (user/files.c) */
int shot_main(const char *arg);  /* 'run shot [name]' - screenshot (user/shot.c) */
int cast_main(const char *arg);  /* 'run cast [play <url>]' - Chromecast (user/cast.c) */
int rain_main(void);   /* 'run rain'  - agent rain screensaver (user/rain.c) */
int vgpu_main(void);
int nvme_main(void);
int httpd_main(void);
int xhci_main(void);
int vblk_main(void);
int chat_main(void);
int edit_main(const char *arg);
int sysmon_main(void);
int rec_main(const char *arg);
int synth_main(const char *arg);
int voice_main(const char *arg);
int chime_main(const char *arg);
int vblk_file(const char *name, uint8_t *buf, int cap);
int vblk_savefile(const char *name, const uint8_t *data, int len);
extern int (*httpd_file)(const char *name, uint8_t *buf, int cap);
extern int (*httpd_savefile)(const char *name, const uint8_t *data, int len);

#define USER_ARG ((const char *)0x007FF000)

/* security probe (audit finding 1): a ring-3 program must NOT be able to map kernel
 * RAM via sys_mmio_map. The kernel heap relocates to 64 MB on boxes with >=96
 * MB RAM (highmem_init), so 'run mmcheck' tries to map it and reports refusal.
 * Device BARs sit in the PCI hole ABOVE RAM and still map - the driver tests
 * (vgpu/nvme/usb/vblk) prove that half. */
static int mmcheck_main(void) {
    uint32_t r = sys_mmio_map(0x04000000);   /* heap_base after highmem relocation */
    if (r == 0xffffffffu) print("mmcheck: kernel-heap map REFUSED (isolation ok)\r\n");
    else printf("mmcheck: kernel-heap map ALLOWED = %x (ISOLATION BREAK)\r\n", r);
    return 0;
}

/* security probe (audit finding 5): the syscall gate is an interrupt gate, which does
 * NOT clear DF. If a ring-3 program sets DF and enters a rep movs/stos syscall,
 * an isr WITHOUT `cld` would copy BACKWARDS out of the sc_chkbuf window into
 * kernel RAM. This probe sets DF, then enters sys_setmission (22, a rep stosb +
 * rep movsb handler) in ONE asm block, then reads the mission back. With the fix
 * the mission round-trips ('DFPROBE'); without it the kernel .data is corrupted. */
static int dfcheck_main(void) {
    static const char m[] = "DFPROBE";
    int r;
    __asm__ volatile("std; int $0x30; cld"     /* DF=1 across the syscall, restore for C */
        : "=a"(r) : "a"(22), "b"(m), "c"(7) : "memory", "cc");
    static char atp[52];
    sys_atp(atp);
    printf("dfcheck: DF=1 setmission r=%d mission='%s' (cld in syscall_isr)\r\n", r, atp + 4);
    return 0;
}

int main(void) {
    const char *a = USER_ARG;
    if (a[0] == 'n' && a[1] == 'e' && a[2] == 't')   /* 'run net'      */
        return net_main();
    if (a[0] == 'l' && a[1] == 'l' && a[2] == 'm' && a[3] == 's')
        return llmscript_main(a);                    /* 'llmscript <slot> <task>' */
    if (a[0] == 'l' && a[1] == 'l' && a[2] == 'm')   /* 'llm <prompt>' */
        return llm_main(a);
    if (a[0] == 'o' && a[1] == 'f' && a[2] == 'f')   /* 'offload <job>' */
        return offload_main(a);
    if (a[0] == 'h' && a[1] == 'd' && a[2] == 'a')   /* 'hda' (2b sound) */
        return hda_main();
    if (a[0] == 'a' && a[1] == 's' && a[2] == 'k')   /* 'spawn ask' daemon */
        return askd_main();
    if (a[0] == 's' && a[1] == 'n' && a[2] == 'a')   /* 'run snake'    */
        return snake_main();
    if (a[0] == 'i' && a[1] == 'n' && a[2] == 'v')   /* 'run invaders' */
        return invaders_main();
    if (a[0] == 'g' && a[1] == 'u' && a[2] == 'i')   /* 'gui' compositor */
        return gui_main();
    if (a[0] == 'f' && a[1] == 'e' && a[2] == 't')   /* 'fetch' system card */
        return fetch_main();
    if (a[0] == 'f' && a[1] == 'o' && a[2] == 'r')   /* 'forest' live agent forest */
        return forest_main();
    if (a[0] == 'v' && a[1] == 'g' && a[2] == 'p')   /* 'vgpu' probe */
        return vgpu_main();
    if (a[0] == 'n' && a[1] == 'v' && a[2] == 'm')   /* 'nvme' driver */
        return nvme_main();
    if (a[0] == 'h' && a[1] == 't' && a[2] == 't') { /* 'httpd' server */
        httpd_file = vblk_file;                      /* serve GET /file/<name> off the VM disk */
        httpd_savefile = vblk_savefile;              /* accept POST /file/<name> uploads */
        return httpd_main();
    }
    if (a[0] == 'u' && a[1] == 's' && a[2] == 'b')   /* 'usb' xHCI driver */
        return xhci_main();
    if (a[0] == 'v' && a[1] == 'b' && a[2] == 'l')   /* 'vblk' virtio-blk disk */
        return vblk_main();
    if (a[0] == 'c' && a[1] == 'h' && a[2] == 'a')   /* 'run chat' LLM chat UI */
        return chat_main();
    if (a[0] == 'e' && a[1] == 'd' && a[2] == 'i')   /* 'run edit <file>' text editor */
        return edit_main(a);
    if (a[0] == 's' && a[1] == 'y' && a[2] == 's')   /* 'run sysmon' system monitor */
        return sysmon_main();
    if (a[0] == 'r' && a[1] == 'e' && a[2] == 'c')   /* 'run rec [test|demo]' recorder */
        return rec_main(a[3] == ' ' ? a + 4 : a + 3);
    if (a[0] == 's' && a[1] == 'y' && a[2] == 'n')   /* 'run synth [demo]' synthesizer */
        return synth_main(a[5] == ' ' ? a + 6 : a + 5);
    if (a[0] == 'v' && a[1] == 'o' && a[2] == 'i')   /* 'run voice [secs] [test]' voice wish */
        return voice_main(a[5] == ' ' ? a + 6 : a + 5);
    if ((a[0] == 'b' && a[1] == 'e' && a[2] == 'e') || (a[0] == 'c' && a[1] == 'h' && a[2] == 'i'))
        return chime_main(a);                        /* 'run beep' / 'run chime' (HDA system sounds) */
    if (a[0] == 't' && a[1] == 'o' && a[2] == 'u')   /* 'run tour' guided tour */
        return tour_main();
    if (a[0] == 'w' && a[1] == 'w' && a[2] == 'w')   /* 'run www <url>' text browser */
        return www_main(a);
    if (a[0] == 'f' && a[1] == 'i' && a[2] == 'l')   /* 'run files' file manager */
        return files_main();
    if (a[0] == 's' && a[1] == 'h' && a[2] == 'o')   /* 'run shot [name]' screenshot */
        return shot_main(a);
    if (a[0] == 'c' && a[1] == 'a' && a[2] == 's')   /* 'run cast [play <url>]' Chromecast */
        return cast_main(a);
    if (a[0] == 'r' && a[1] == 'a' && a[2] == 'i')   /* 'run rain' agent rain screensaver */
        return rain_main();
    if (a[0] == 'm' && a[1] == 'm' && a[2] == 'c')   /* 'run mmcheck' isolation probe */
        return mmcheck_main();
    if (a[0] == 'd' && a[1] == 'f' && a[2] == 'c')   /* 'run dfcheck' DF/cld probe (audit finding 5) */
        return dfcheck_main();
    return video_main();
}
