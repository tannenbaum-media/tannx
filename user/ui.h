/* ui.h - the small full-screen toolkit shared by the TannX ring-3
 * programs (chat, edit, sysmon): brand palette, the 8x16 console font at an
 * integer scale picked from the resolution, rounded panels, text with and
 * without an opaque background, and ONE key reader that turns the kernel's
 * key ring into a flat key code set.
 *
 * Keys: the kernel delivers printable ASCII as is, control codes (Ctrl+S =
 * 0x13 ...) when the program holds the keyboard (SYS_KBGRAB), and the
 * navigation keys as 0x80|scancode - both from the PS/2 E0 path and from
 * the serial ESC-[ decoder, so the same program works on a real keyboard
 * and over a serial terminal (the headless tests). */
#ifndef AGENTOS_UI_H
#define AGENTOS_UI_H
#include "libc.h"

/* ---- key codes out of ui_key() ------------------------------------ */
#define UI_UP     0xC8
#define UI_DOWN   0xD0
#define UI_LEFT   0xCB
#define UI_RIGHT  0xCD
#define UI_HOME   0xC7
#define UI_END    0xCF
#define UI_PGUP   0xC9
#define UI_PGDN   0xD1
#define UI_DEL    0xD3
#define UI_ESC    0x1B
#define UI_ENTER  0x0D
#define UI_BS     0x08
#define UI_TAB    0x09
#define UI_CTRL(c) ((c) & 0x1F)        /* UI_CTRL('S') == 0x13 */

/* ---- the TannX palette (xRGB; the framebuffer is BGRx) ------- */
#define C_BG      0x0A1614u      /* deep forest background              */
#define C_SURF    0x122823u      /* panel surface                       */
#define C_SURF2   0x183530u      /* raised surface / selected row       */
#define C_LINE    0x214A40u      /* borders, separators                 */
#define C_ACCENT  0x2DD4BFu      /* teal accent                         */
#define C_ACCDIM  0x1A8C7Du      /* accent, dimmed                      */
#define C_ACCINK  0x062320u      /* ink on an accent surface            */
#define C_TEXT    0xE6F2EEu      /* primary text                        */
#define C_MUTED   0x7FA399u      /* secondary text                      */
#define C_FAINT   0x3F6A60u      /* tertiary text / gutters             */
#define C_WARN    0xF2C14Eu      /* amber                               */
#define C_ERR     0xF26D6Du      /* red                                 */
#define C_OK      0x7CE38Bu      /* green                               */

/* ---- geometry -------------------------------------------------------- */
extern fb_t ui_fb;
extern int  ui_sc;               /* glyph scale (1 or 2)                */
#define UI_CW (8 * ui_sc)        /* one text cell                       */
#define UI_CH (16 * ui_sc)
#define UI_W  ((int)ui_fb.w)
#define UI_H  ((int)ui_fb.h)
#define UI_COLS (UI_W / UI_CW)
#define UI_ROWS (UI_H / UI_CH)

int  ui_init(void);              /* framebuffer + keyboard grab; 0 ok / -1 */
void ui_fill(int x, int y, int w, int h, uint32_t col);
void ui_round(int x, int y, int w, int h, int r, uint32_t col);
void ui_frame(int x, int y, int w, int h, int r, uint32_t col); /* 1px outline */
void ui_hline(int x, int y, int w, uint32_t col);
void ui_vline(int x, int y, int h, uint32_t col);
uint32_t ui_blend(uint32_t dst, uint32_t src, int a);           /* a = 0..256 */
uint32_t ui_dim(uint32_t c, int bri);                           /* bri = 0..255 */

/* text: sc = glyph scale (ui_sc for body text, ui_sc+1 for big numbers) */
void ui_text(int x, int y, const char *s, uint32_t col);
void ui_textn(int x, int y, const char *s, int n, uint32_t col);
void ui_text_s(int x, int y, const char *s, int sc, uint32_t col);
void ui_text_bg(int x, int y, const char *s, int n, uint32_t col, uint32_t bg);
int  ui_text_w(const char *s, int sc);                          /* pixel width */

/* a pill/chip: rounded surface with a dot and a label, returns its width */
int  ui_chip(int x, int y, const char *label, uint32_t dot, uint32_t bg, uint32_t fg);

/* ---- input ------------------------------------------------------------ */
int  ui_key(void);               /* next key (see UI_*) or 0            */

/* ---- tiny formatting (this libc has no sprintf) ----------------------- */
int  ui_utoa(char *d, uint32_t v);                  /* decimal, returns len */
int  ui_itoa(char *d, int v);
int  ui_cat(char *d, const char *s);                /* strcpy, returns len  */
int  ui_hms(char *d, uint32_t secs);                /* "hh:mm:ss"            */

#endif /* AGENTOS_UI_H */
