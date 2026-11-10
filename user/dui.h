/* dui.h - the small framebuffer toolkit the TannX apps share (tour,
 * www, files, cast, rain). One brand palette, the 8x16 console font scaled
 * to the screen, a text grid in cells, panels, an input line, key helpers.
 * Everything draws straight into the firmware framebuffer via libc's fb_*;
 * there is no back buffer (see gui.c for why). */
#ifndef AGENTOS_UI_H
#define AGENTOS_UI_H
#include "libc.h"

/* ---- brand palette (BGRx = 0x00RRGGBB) -------------------------------- */
#define DUI_BG      0x0A1614u     /* page background: dark teal-green          */
#define DUI_PANEL   0x122823u     /* card / panel                               */
#define DUI_PANEL2  0x183630u     /* a lighter panel (selection, input)         */
#define DUI_LINE    0x1F4A40u     /* borders, rules                             */
#define DUI_ACCENT  0x2DD4BFu     /* brand teal accent                          */
#define DUI_ACCENT2 0x5EEAD4u     /* lighter accent (hover, highlights)         */
#define DUI_TEXT    0xE6F4F1u     /* body text                                  */
#define DUI_MUTED   0x7FA69Bu     /* secondary text                             */
#define DUI_DIM     0x3F6B61u     /* hints, disabled                            */
#define DUI_WARN    0xFBBF24u     /* amber                                      */
#define DUI_BAD     0xF87171u     /* red                                        */
#define DUI_OK      0x86EFACu     /* green                                      */

typedef struct {
    fb_t fb;
    int  sc;            /* font scale: 1 on <= 1600 px wide, 2 above           */
    int  cw, ch;        /* cell size in px (8*sc x 16*sc)                      */
    int  cols, rows;    /* text grid                                           */
    int  last_r0;       /* console row the last dui_run_shell started at        */
} dui_t;

extern dui_t DUI;

int  dui_init(void);                          /* 0 ok / -1 no framebuffer (text mode) */
void dui_clear(uint32_t col);                 /* whole screen                      */
void dui_fill(int x, int y, int w, int h, uint32_t col);
void dui_frame(int x, int y, int w, int h, uint32_t col);        /* 1px outline  */
void dui_panel(int x, int y, int w, int h, uint32_t fill, uint32_t edge); /* card */
void dui_hline(int x, int y, int w, uint32_t col);
/* text in grid cells (cx, cy) -> pixels via DUI.cw/DUI.ch; sc multiplies DUI.sc */
void dui_text(int cx, int cy, const char *s, uint32_t col);
void dui_text_big(int cx, int cy, const char *s, uint32_t col);  /* 2x the grid font */
void dui_textn(int cx, int cy, const char *s, int n, uint32_t col);   /* n chars, pads with spaces */
void dui_textpx(int x, int y, const char *s, int sc, uint32_t col);   /* pixel position */
int  dui_textw(const char *s);                /* width in cells                    */
void dui_logo(int x, int y, int sc);          /* the fir-tree mark, sc = px per unit */
void dui_header(const char *app, const char *hint);  /* top bar: logo + name + hint  */
void dui_footer(const char *keys);            /* bottom bar: key hints              */
void dui_bar(int x, int y, int w, int h, int permille, uint32_t col); /* progress */

/* keys: sys_getkey() is non-blocking and ASCII-only (no arrows in ring 3) */
#define DUI_KEY_ENTER 13
#define DUI_KEY_BS    8
#define DUI_KEY_ESC   27
int  dui_getkey(void);                        /* blocking (yields), returns ASCII  */
int  dui_poll(void);                          /* non-blocking, 0 = none            */
void dui_flush_keys(void);
/* edit a line at cell (cx,cy), width w cells; returns the key that ended it
 * (Enter/ESC). buf keeps its content on ESC. Redraws itself. */
int  dui_readline(int cx, int cy, int w, char *buf, int cap);
void dui_sleep(int ticks);

/* console shadow: run a shell command via SYS_SHELL and collect its output
 * lines (what readline echoed + what the command printed) once the prompt is
 * back. Returns the number of lines in out[]. maxwait in ticks (~18/s). */
#define DUI_CON_LINES 12
int  dui_run_shell(const char *cmd, char out[DUI_CON_LINES][81], int maxwait, int settle);
int  dui_console_rows(int from, char out[DUI_CON_LINES][81]);   /* re-read rows from..cursor */
/* settle: extra ticks to wait after the prompt is back, for output that agents
 * print asynchronously (task results, a killed agent's fault line). */

/* small helpers the apps keep needing */
int  dui_strlen(const char *s);
void dui_strcpy(char *d, const char *s, int cap);
int  dui_startswith(const char *s, const char *p);
char *dui_utoa(char *d, uint32_t v);          /* decimal, returns the end pointer */
int  dui_atoi(const char *s);

#endif /* AGENTOS_UI_H */
