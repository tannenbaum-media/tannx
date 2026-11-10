/* libc.h - the minimal C library exposed to TannX OS ring-3 programs.
 * Everything ultimately rides INT 0x30 (the one DPL-3 gate). Kept tiny
 * and freestanding: no host headers, no allocator beyond a bump sbrk. */
#ifndef AGENTOS_LIBC_H
#define AGENTOS_LIBC_H

typedef unsigned int   uint32_t;
typedef int            int32_t;
typedef unsigned short uint16_t;
typedef short          int16_t;
typedef unsigned char  uint8_t;
typedef unsigned int   size_t;

/* ---- raw syscalls (INT 0x30, ABI v2) ------------------------------ */
void      sys_exit(int code);
int       sys_write(const char *buf, int len);   /* -> bytes / -1     */
void      sys_putc(int c);
int       sys_fbinfo(uint32_t *dst16);           /* [base,w,h,ppsl]   */
int       sys_getkey(void);                      /* ASCII / 0 (none)  */
uint32_t  sys_uptime(void);                      /* timer ticks       */
int       sys_read_sectors(uint32_t lba, uint32_t count, void *dst);
void     *sys_sbrk(int incr);                    /* old break / (void*)-1 */
void      sys_yield(void);
int       sys_net_tx(const void *buf, int len);  /* send raw frame -> len/-1 */
int       sys_net_rx(void *buf, int maxlen);     /* recv one frame -> len/0  */
int       sys_net_mac(void *buf7);               /* [0..5]=MAC [6]=link; 0/-1 */
int       sys_write_slot(int slot, const void *src512); /* AgentFS slot; needs diskon; 0/-1 */
uint32_t  sys_pci(uint32_t cfgaddr, uint32_t val, int wr); /* PCI config dword r/w */
uint32_t  sys_mmio_map(uint32_t phys);           /* map 4MB PCD user page -> addr/-1 */
uint32_t  pci_rd(int bdf, int reg);              /* PCI config dword read (packed bdf) */
void      pci_wr(int bdf, int reg, uint32_t v);  /* PCI config dword write             */
uint8_t   pci_rd8(int bdf, int reg);             /* one byte out of a config dword      */
int       pci_find_class(uint32_t class, uint32_t mask); /* scan bus 0 by class -> bdf/-1 */
int       pci_find_id(uint32_t id);              /* scan bus 0 by (dev<<16)|vendor -> bdf/-1 */
uint32_t  pci_map_bar(int bdf, int index, const char *tag); /* map BAR -> va / 0 on refusal */
int       sys_claim(void);                       /* agent ABI: task idx / -1  */
void      sys_progress(int pct);                 /* + watchdog heartbeat      */
void      sys_finish(int result);                /* task done, result long    */
uint32_t  sys_task_info(int idx);                /* task a | b<<16            */
int       sys_console(void *buf4004);            /* [cur_x,cur_y,0,0]+80x25 grid */
int       sys_agents(void *buf192);              /* agents_tbl(64)+tasks_tbl(128) */
int       sys_atp(void *buf52);                  /* [round:4][mission:48] autopilot */
int       sys_setmission(const void *buf, int len); /* set mission telemetry */
int       sys_sysinfo(void *buf64);              /* [ram,mhz,cores,attr/boot/nic/diskon,kbytes,ticks,ver] */
int       sys_kbgrab(void);                      /* 24: own keyboard + FB until exit */
int       sys_fgrab(int on);                     /* 25: 1 = KBGRAB, own the keyboard (keys -> getkey ring only), 0: release+repaint */
int       sys_shell(const char *line, int len);  /* 26: type a command line into the shell (<= 60 chars); 0/-1 */

/* ---- string / memory --------------------------------------------- */
void  *memcpy(void *d, const void *s, size_t n);
void  *memset(void *d, int c, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
int    strlen(const char *s);

/* ---- output ------------------------------------------------------- */
void   print(const char *s);                     /* WRITE strlen(s)   */
void   printf(const char *fmt, ...);             /* %d %u %x %c %s %% */

/* ---- heap (bump allocator over sbrk) ------------------------------ */
void  *malloc(size_t n);
void  *zpage(uint32_t n);   /* 4 KB-aligned, zeroed, DMA-able (va == phys) */

/* ---- framebuffer -------------------------------------------------- */
typedef struct { uint32_t *base; uint32_t w, h, ppsl; } fb_t;
int    fb_get(fb_t *fb);                          /* 0 ok / -1         */
void   fb_putpixel(fb_t *fb, int x, int y, uint32_t color);
void   fb_fillrect(fb_t *fb, int x, int y, int w, int h, uint32_t color);
/* draw a string in an 8x8 block font (caller's chars+data), scaled by sc */
void   fb_text(fb_t *fb, int x, int y, const char *s, int sc, uint32_t col,
               const char *chars, const uint8_t (*data)[8]);
/* blit a sw*sh BGRx image to (ox,oy), nearest-neighbour scaled by sc */
void   fb_blit_scaled(fb_t *fb, const uint32_t *src, int sw, int sh,
                      int ox, int oy, int sc);

/* key codes */
#define KEY_ESC 27

#endif /* AGENTOS_LIBC_H */
