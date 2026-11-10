/* aui.h - the small framebuffer UI kit shared by the sound apps (recorder,
 * synthesizer, voice wish). Brand style of TannX OS: deep teal-green
 * ground, soft panels, one mint accent. Scales with the framebuffer. */
#ifndef AGENTOS_AUI_H
#define AGENTOS_AUI_H
#include "libc.h"

#define AUI_BG      0x0A1614u     /* ground                       */
#define AUI_PANEL   0x122823u     /* panel fill                   */
#define AUI_PANEL2  0x18332Bu     /* raised panel / chip          */
#define AUI_BORDER  0x234D40u     /* hairline                     */
#define AUI_ACCENT  0x2DD4BFu     /* mint accent                  */
#define AUI_ACCENT2 0x14B8A6u     /* deeper mint                  */
#define AUI_TEXT    0xE6F4F1u
#define AUI_MUTED   0x7FA69Bu
#define AUI_DIM     0x3F6B60u
#define AUI_WARN    0xF5B041u
#define AUI_DANGER  0xF06464u

extern fb_t aui_fb;
extern int  aui_sc;               /* pixel scale: 1 (<=1024 px wide) .. 3 */
#define AUI_CW (8 * aui_sc)        /* glyph cell width / height at scale 1 */
#define AUI_CH (16 * aui_sc)
/* content starts here: below the title bar AND the strip the kernel keeps
 * repainting every second (its status line + desktop stats, y ~64..140 at
 * 1600p) - the apps simply leave that band to the kernel */
#define AUI_TOP (AUI_CH + 44 * aui_sc)

int  aui_begin(void);             /* 0 ok / -1 no framebuffer */
void aui_rect(int x, int y, int w, int h, uint32_t col);
void aui_panel(int x, int y, int w, int h, uint32_t fill, uint32_t border);  /* rounded */
void aui_text(int x, int y, const char *s, int scale, uint32_t col);
void aui_textc(int cx, int y, const char *s, int scale, uint32_t col);        /* centred */
void aui_line(int x0, int y0, int x1, int y1, uint32_t col);
void aui_chip(int x, int y, int w, const char *s, int active);               /* -> height AUI_CH+8*sc */
uint32_t aui_mix(uint32_t a, uint32_t b, int t256);                          /* a..b by t/256 */
char *aui_num(char *dst, int v);                                              /* decimal, -> end */
char *aui_str(char *dst, const char *s);
void aui_meter(int x, int y, int w, int h, int level, int peak);              /* 0..32767 */
void aui_footer(const char *hints);                                           /* bottom bar */
void aui_title(const char *app, const char *sub);                             /* top bar */
#endif
