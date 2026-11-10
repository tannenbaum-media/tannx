/* shot.c - 'run shot [name]': a screenshot of the framebuffer as a BMP.
 *
 * The screen is copied FIRST (into the sbrk heap, box-filter downscaled so the
 * file stays <= ~3 MB: a 2560x1600 desktop becomes 1280x800), then written
 * as a 24-bit bottom-up BMP to the first FAT volume that mounts (virtio-blk,
 * USB stick, NVMe) as SHOTnnnn.BMP - or <name>.BMP. Without a FAT volume the
 * file is uploaded to the host proxy (POST /shot) which saves it as PNG, so
 * 'make run32' users can share a shot with nothing but the proxy running.
 * Prints the filename. Serial marker: "shot: saved ..." / "shot: sent ...". */
#include "dui.h"
#include "fatfs.h"

int vblk_mount(void); int usb_mount(void); int nvme_mount(void);
int proxy_upload(const char *path, const uint8_t *data, uint32_t len, char *out, int cap);

static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }
static void put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }

/* capture: returns the BMP in a heap buffer, *len its size; 0 on failure */
static uint8_t *capture(uint32_t *len, int *ow, int *oh) {
    fb_t fb;
    if (fb_get(&fb) < 0 || !fb.base) return 0;
    int s = 1;
    while ((fb.w / s) * (fb.h / s) * 3u > 3u * 1024 * 1024 && s < 8) s++;
    int w = (int)fb.w / s, h = (int)fb.h / s;
    uint32_t rowb = ((uint32_t)w * 3 + 3) & ~3u;
    uint32_t size = 54 + rowb * (uint32_t)h;
    uint8_t *bmp = malloc(size);
    if (!bmp) return 0;
    memset(bmp, 0, 54);
    bmp[0] = 'B'; bmp[1] = 'M';
    put32(bmp + 2, size); put32(bmp + 10, 54);
    put32(bmp + 14, 40); put32(bmp + 18, (uint32_t)w); put32(bmp + 22, (uint32_t)h);
    put16(bmp + 26, 1); put16(bmp + 28, 24);
    put32(bmp + 34, rowb * (uint32_t)h);
    put32(bmp + 38, 2835); put32(bmp + 42, 2835);
    int ss = s * s;
    for (int y = 0; y < h; y++) {
        uint8_t *dst = bmp + 54 + (uint32_t)(h - 1 - y) * rowb;
        for (int x = 0; x < w; x++) {
            uint32_t r = 0, g = 0, b = 0;
            for (int j = 0; j < s; j++) {
                const uint32_t *row = fb.base + (uint32_t)(y * s + j) * fb.ppsl + (uint32_t)x * s;
                for (int i = 0; i < s; i++) { uint32_t p = row[i]; r += (p >> 16) & 0xff; g += (p >> 8) & 0xff; b += p & 0xff; }
            }
            dst[x * 3] = (uint8_t)(b / ss); dst[x * 3 + 1] = (uint8_t)(g / ss); dst[x * 3 + 2] = (uint8_t)(r / ss);
        }
        if ((y & 63) == 0) sys_progress(y * 50 / (h ? h : 1));
    }
    *len = size; *ow = w; *oh = h;
    return bmp;
}

/* SHOT0001.BMP .. SHOT9999.BMP: the first name not on the volume */
static void pick_name(char *out) {
    static uint8_t probe[16];
    for (int n = 1; n < 10000; n++) {
        dui_strcpy(out, "SHOT0000.BMP", 13);
        int v = n; for (int i = 7; i >= 4; i--) { out[i] = (char)('0' + v % 10); v /= 10; }
        if (fat_file(out, probe, 16) < 0) return;
    }
}

int shot_main(const char *arg) {
    const char *a = arg + 4; while (*a == ' ') a++;
    uint32_t len = 0; int w = 0, h = 0;
    uint8_t *bmp = capture(&len, &w, &h);
    if (!bmp) { print("shot: no framebuffer (text mode) or out of memory\r\n"); return 0; }
    printf("shot: captured %dx%d (%u bytes)\r\n", w, h, len);

    const char *dev = 0;
    print("shot: looking for a FAT volume (virtio-blk, USB, NVMe) ...\r\n");
    if (vblk_mount()) dev = "virtio-blk";
    else if (usb_mount()) dev = "USB";
    else if (nvme_mount()) dev = "NVMe";
    if (dev) {
        char name[16];
        if (*a && *a != ' ') {
            int n = 0, dot = 0;
            for (; a[n] && a[n] != ' ' && n < 12; n++) {
                char c = a[n]; if (c >= 'a' && c <= 'z') c -= 32;   /* 8.3 names are upper case */
                name[n] = c; if (c == '.') dot = 1;
            }
            name[n] = 0;
            if (!dot && n <= 8) dui_strcpy(name + n, ".BMP", 5);
        } else pick_name(name);
        printf("shot: writing %s (%u KB) ...\r\n", name, len / 1024);
        int r = fat_save(name, bmp, len);
        if (r == 0) printf("shot: saved %s (%dx%d, %u bytes) on the %s FAT volume\r\n", name, w, h, len, dev);
        else printf("shot: save failed (%d) - FAT16/32 volume, free space, 8.3 name?\r\n", r);
        return 0;
    }
    print("shot: no FAT volume - sending to the host proxy (POST /shot) ...\r\n");
    static char reply[200];
    if (proxy_upload("/shot", bmp, len, reply, sizeof reply) && dui_startswith(reply, "saved")) {
        printf("shot: sent %dx%d - the proxy %s\r\n", w, h, reply);
        return 0;
    }
    if (reply[0]) printf("shot: proxy said: %s\r\n", reply);
    print("shot: nowhere to put it. Attach a FAT disk (QEMU: -drive id=vd,file=disk.img,if=none,format=raw\r\n"
          "      -device virtio-blk-pci,drive=vd) or run ./llm-proxy.py on the host.\r\n");
    return 0;
}
