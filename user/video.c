/* video.c - the TannX OS ring-3 video program (Phases 1-3).
 *
 * Compiled by gcc, runs in ring 3 on the hand-asm kernel, talks to it
 * only through INT 0x30. It plays a raw-RGB clip streamed from disk
 * (the real video path) and falls back to an animated rectangle when no
 * clip is present (e.g. the diskless PXE boot) so it always shows life.
 *
 * Disk layout (the Makefile appends a clip built by user/mkvideo.py):
 *   LBA VIDEO_LBA      header  : magic "AVID", frame_count, w, h, fps
 *   LBA VIDEO_LBA+1..  frames  : w*h BGRx pixels each, sector-aligned
 */
#include "libc.h"
#include "jpeg.h"

#define VIDEO_LBA   1024
#define AVID_MAGIC  0x44495641u          /* "AVID" raw-RGB clip          */
#define MJPG_MAGIC  0x47504A4Du          /* "MJPG" baseline-JPEG clip    */

typedef struct { uint32_t magic, count, w, h, fps; } vid_hdr;

/* decode/scratch buffers (in .bss, zeroed by crt0 - user space is huge) */
#define VID_MAXW 320
#define VID_MAXH 240
static uint8_t  jpegbuf[32 * 1024];      /* one compressed frame         */
static uint32_t rgbbuf[VID_MAXW * VID_MAXH];

/* The PIT runs at ~18.2 Hz, so sys_uptime() ticks ~18 times a second. */
#define TICKS_PER_SEC 18

/* ---- the Phase-1 fallback: a rectangle bouncing across the screen --- */
static void rectangle_demo(fb_t *fb) {
    const int RW = 120, RH = 90;
    int prev_x = -1, prev_y = (int)fb->h / 2 - RH / 2;
    uint32_t frames = 0;
    for (;;) {
        if (sys_getkey() == KEY_ESC) return;
        uint32_t t = sys_uptime();
        int span = (int)fb->w - RW; if (span < 1) span = 1;
        int phase = (int)(t * 6) % (2 * span);
        int x = phase < span ? phase : (2 * span - phase);
        int y = (int)fb->h / 2 - RH / 2;
        if (prev_x >= 0) fb_fillrect(fb, prev_x, prev_y, RW, RH, 0x00101018);
        uint32_t col = 0x00203040u + (t & 0xff) * 0x00010203u;
        fb_fillrect(fb, x, y, RW, RH, col);
        prev_x = x; prev_y = y;
        if ((frames++ & 0x3f) == 0) printf("[video] frame %u at x=%d\r\n", frames, x);
        sys_yield();
    }
}

/* ---- the raw-RGB player -------------------------------------------- */
static void play(fb_t *fb, const vid_hdr *h) {
    uint32_t fw = h->w, fh = h->h, count = h->count;
    uint32_t fps = h->fps ? h->fps : 10;
    uint32_t secs = (fw * fh * 4 + 511) / 512;        /* sectors per frame */
    uint32_t *frame = malloc(secs * 512);
    if (!frame) { printf("[video] out of memory for a %ux%u frame\r\n", fw, fh); return; }

    /* integer nearest-neighbour scale to fit the screen, centred */
    uint32_t sx = fb->w / fw, sy = fb->h / fh;
    uint32_t sc = sx < sy ? sx : sy; if (!sc) sc = 1;
    uint32_t ox = (fb->w - fw * sc) / 2;
    uint32_t oy = (fb->h - fh * sc) / 2;
    uint32_t tpf = TICKS_PER_SEC / fps; if (!tpf) tpf = 1;

    printf("[video] %ux%u x%u centred, %u frames, %u tick(s)/frame\r\n",
           fw, fh, sc, count, tpf);

    for (;;) {                                          /* loop the clip */
        for (uint32_t f = 0; f < count; f++) {
            if (sys_read_sectors(VIDEO_LBA + 1 + f * secs, secs, frame) < 0) {
                printf("[video] read error on frame %u\r\n", f);
                return;
            }
            fb_blit_scaled(fb, frame, fw, fh, ox, oy, sc);
            uint32_t t0 = sys_uptime();
            while (sys_uptime() - t0 < tpf) {
                if (sys_getkey() == KEY_ESC) { printf("[video] stopped\r\n"); return; }
                sys_yield();
            }
        }
    }
}

/* ---- the M-JPEG player: decode each baseline-JPEG frame, then blit -- */
static void play_mjpeg(fb_t *fb, const uint8_t *hdrsec) {
    const vid_hdr *vh = (const vid_hdr *)hdrsec;
    const uint32_t *tbl = (const uint32_t *)(hdrsec + 20);   /* (sect_off,size) pairs */
    uint32_t count = vh->count, fps = vh->fps ? vh->fps : 8;
    /* the frame table lives in the single 512-B header sector after the 20-B
     * head, so it holds at most (512-20)/8 = 61 (off,size) pairs. count comes
     * straight off the untrusted clip - clamp it or the loop reads past hdr[]. */
    if (count > (512 - 20) / 8) count = (512 - 20) / 8;
    uint32_t tpf = TICKS_PER_SEC / fps; if (!tpf) tpf = 1;
    printf("[video] %u JPEG frames %ux%u @ %u fps, %u tick(s)/frame\r\n",
           count, vh->w, vh->h, fps, tpf);

    for (;;) {
        for (uint32_t f = 0; f < count; f++) {
            uint32_t off = tbl[f * 2], size = tbl[f * 2 + 1];
            uint32_t nsec = (size + 511) / 512;
            if (!size || nsec * 512 > sizeof(jpegbuf)) continue;
            if (sys_read_sectors(VIDEO_LBA + 1 + off, nsec, jpegbuf) < 0) {
                printf("[video] read error on frame %u\r\n", f); return;
            }
            int w, h;
            /* the decoder rejects frames larger than VID_MAXW x VID_MAXH itself
             * (never writes past rgbbuf) and degenerate 0x0 frames (SOI straight
             * to SOS with ncomp=0); w/h >= 1 below is belt-and-braces for the
             * fb->w / w divide (#DE). */
            int rc = jpeg_decode(jpegbuf, (int)size, rgbbuf, VID_MAXW, VID_MAXH, &w, &h);
            if (rc == JPEG_OK && w >= 1 && h >= 1) {
                if (f == 0) printf("[video] decoded frame 0 OK (%dx%d)\r\n", w, h);
                uint32_t sx = fb->w / w, sy = fb->h / h;
                uint32_t sc = sx < sy ? sx : sy; if (!sc) sc = 1;
                fb_blit_scaled(fb, rgbbuf, w, h, (fb->w - w * sc) / 2,
                               (fb->h - h * sc) / 2, sc);
            } else if (f == 0) {
                printf("[video] JPEG decode failed (rc=%d) - is it baseline?\r\n", rc);
                return;
            }
            uint32_t t0 = sys_uptime();
            while (sys_uptime() - t0 < tpf) {
                if (sys_getkey() == KEY_ESC) { printf("[video] stopped\r\n"); return; }
                sys_yield();
            }
        }
    }
}

int video_main(void) {
    printf("[video] hello from ring3 C - uptime=%u ticks\r\n", sys_uptime());

    fb_t fb;
    if (fb_get(&fb) < 0) {
        printf("[video] no framebuffer (serial-only boot) - idling\r\n");
        for (;;) sys_yield();
    }
    printf("[video] framebuffer %ux%u ppsl=%u base=%x\r\n",
           fb.w, fb.h, fb.ppsl, (uint32_t)fb.base);

    /* Look for a clip on disk: prefer the compressed M-JPEG clip, then a
     * raw-RGB clip, else the rectangle demo (e.g. the diskless PXE boot). */
    static uint8_t hdr[512];
    vid_hdr *h = (vid_hdr *)hdr;
    if (sys_read_sectors(VIDEO_LBA, 1, hdr) == 1 && h->w && h->h && h->count) {
        if (h->magic == MJPG_MAGIC) {
            printf("[video] clip on disk: %u frames %ux%u (M-JPEG)\r\n",
                   h->count, h->w, h->h);
            play_mjpeg(&fb, hdr);
            return 0;
        }
        if (h->magic == AVID_MAGIC) {
            printf("[video] clip on disk: %u frames %ux%u (raw RGB)\r\n",
                   h->count, h->w, h->h);
            play(&fb, h);
            return 0;
        }
    }
    printf("[video] no clip on disk - rectangle demo\r\n");
    rectangle_demo(&fb);
    return 0;
}
