/* vgpu.c - virtio-gpu 2D driver in ring-3 C.
 *
 * A full modern (virtio-1.0) virtio-gpu driver: it finds the device, walks
 * the virtio PCI capabilities to the config regions in the MMIO BAR, runs
 * the device-init handshake, sets up the control virtqueue in user RAM, and
 * drives the 2D command pipeline to put a real picture on the scanout:
 *   GET_DISPLAY_INFO -> RESOURCE_CREATE_2D -> RESOURCE_ATTACH_BACKING
 *   -> SET_SCANOUT -> TRANSFER_TO_HOST_2D -> RESOURCE_FLUSH
 *
 * The kernel only lends PCI config access (SYS_PCI) and an uncached user
 * mapping of the BAR (SYS_MMIO_MAP). User RAM is identity-mapped, so our
 * malloc'd virtqueue + framebuffer are DMA-able as-is. Ring-3 takes no
 * interrupts, so we POLL the used ring (the HDA-LPIB pattern).
 *
 * QEMU only: -device virtio-gpu-pci (the bare-metal test PC has an Intel iGPU, not virtio).
 */
#include "libc.h"
#include "virtio.h"

typedef unsigned long long uint64_t;   /* libc.h is 32-bit only; the GPU
                                        * descriptors need 64-bit addr fields */

/* the virtqueue state virtio_init() sets up (plumbed into these statics after
 * bring-up, so submit() below stays on the same hot path it always had) */
static volatile uint8_t *cc;     /* common cfg (for the CCxx accessors) */
static volatile uint8_t *notify; /* notify region base */
static uint32_t notify_mult;
static struct vq_desc *desc;
static volatile uint16_t *avail, *used16;
static int qsz;
static uint16_t avail_idx, last_used, q_notify_off;

#define CC32(off)  (*(volatile uint32_t *)(cc + (off)))
#define CC16(off)  (*(volatile uint16_t *)(cc + (off)))
#define CC8(off)   (*(volatile uint8_t  *)(cc + (off)))

/* ---- virtio-gpu command structures (packed, little-endian = x86) ----- */
typedef struct { uint32_t type, flags; uint64_t fence_id; uint32_t ctx_id, pad; }
    __attribute__((packed)) gpu_hdr;            /* 24 bytes */
typedef struct { uint32_t x, y, w, h; } __attribute__((packed)) gpu_rect;
typedef struct { gpu_rect r; uint32_t enabled, flags; }
    __attribute__((packed)) gpu_display_one;

#define CMD_GET_DISPLAY_INFO    0x0100
#define CMD_RESOURCE_CREATE_2D  0x0101
#define CMD_SET_SCANOUT         0x0103
#define CMD_RESOURCE_FLUSH      0x0104
#define CMD_TRANSFER_TO_HOST_2D 0x0105
#define CMD_ATTACH_BACKING      0x0106
#define RESP_OK_NODATA          0x1100
#define RESP_OK_DISPLAY_INFO    0x1101
#define FMT_B8G8R8X8            2               /* matches our 0x00RRGGBB FB */

static uint8_t *req;   /* request buffer  (device-readable) */
static uint8_t *resp;  /* response buffer (device-writable) */

/* submit one request/response pair on the control queue and poll for the
 * used ring to advance. Returns the response header type, or 0 on timeout. */
static uint32_t submit(int req_len, int resp_len) {
    /* snapshot the queue pointers: a foreground game is the same user.bin, so
     * its crt0 can zero this .bss mid-call (the compositor reuses us). Working
     * off locals means a concurrent wipe can't turn a deref into a #PF at ~0. */
    struct vq_desc *d = desc; volatile uint16_t *av = avail, *u = used16;
    volatile uint8_t *nb = notify; uint8_t *rq = req, *rs = resp;
    if (!d || !av || !u || !nb || !rq || !rs || qsz <= 0) return 0;
    d[0].addr = (uint32_t)rq;  d[0].len = req_len;
    d[0].flags = VQ_NEXT;      d[0].next = 1;
    d[1].addr = (uint32_t)rs;  d[1].len = resp_len;
    d[1].flags = VQ_WRITE;     d[1].next = 0;
    av[2 + (avail_idx % qsz)] = 0;             /* ring[]: head descriptor = 0 */
    avail_idx++;
    av[1] = avail_idx;                           /* publish avail.idx */
    *(volatile uint16_t *)(nb + q_notify_off * notify_mult) = 0;  /* kick queue 0 */
    for (int t = 0; t < 2000000; t++) {
        if (u[1] != last_used) {                 /* used.idx advanced */
            last_used = u[1];
            return ((gpu_hdr *)rs)->type;
        }
        if ((t & 0x3fff) == 0) { sys_progress(50); sys_yield(); }
    }
    return 0;                                     /* timeout */
}

static void hdr(uint32_t type) {
    memset(req, 0, 64);
    ((gpu_hdr *)req)->type = type;
}

static int vg_W, vg_H;            /* the active scanout size */
static int vg_scanout;            /* scanout selected from GET_DISPLAY_INFO */
static uint32_t *vg_fb;           /* the resource backing the caller renders into */

/* Set up virtio-gpu as a scanout: probe, init, control virtqueue, create a
 * resource, and attach a W x H framebuffer in user RAM as its backing. The
 * caller renders into the returned framebuffer, then calls vgpu_present() to
 * push it to the display. Returns NULL if there is no virtio-gpu (the caller
 * then falls back to the firmware framebuffer). Reusable by the compositor. */
uint32_t *vgpu_setup(int *wq, int *hq) {
    vg_fb = 0;
    /* -- find the modern virtio-gpu (1af4:1050) ----------------------- */
    int bdf = pci_find_id(0x10501af4);
    if (bdf < 0) return 0;
    printf("vgpu: found 1af4:1050 at dev %d fn %d\r\n", bdf >> 3, bdf & 7);

    /* shared virtio bring-up (cap-walk, BAR map, handshake, virtqueue 0);
     * submit() posts a 2-descriptor chain so min queue size is 2. */
    struct virtio_dev vd;
    if (!virtio_init(&vd, bdf, 2, "vgpu")) return 0;
    cc = vd.cc; notify = vd.notify; notify_mult = vd.notify_mult;
    desc = vd.desc; avail = vd.avail; used16 = vd.used16; qsz = vd.qsz;
    q_notify_off = vd.q_notify_off; avail_idx = vd.avail_idx; last_used = vd.last_used;
    req  = malloc(4096);                          /* device-readable request buf */
    resp = malloc(4096);                          /* device-writable response buf */
    if (!req || !resp) { print("vgpu: OOM\r\n"); return 0; }

    /* -- GET_DISPLAY_INFO: also proves the queue round-trips ---------- */
    int W = 1024, H = 768, scanout = 0;
    hdr(CMD_GET_DISPLAY_INFO);
    uint32_t r = submit(sizeof(gpu_hdr), 4096);
    if (r == RESP_OK_DISPLAY_INFO) {
        gpu_display_one *pm = (gpu_display_one *)(resp + sizeof(gpu_hdr));
        int active = -1, enabled = 0;
        for (int i = 0; i < 16; i++) {
            if (!pm[i].enabled) continue;
            if (pm[i].r.w < 320 || pm[i].r.w > 4096 || pm[i].r.h < 240 || pm[i].r.h > 2160)
                continue;
            if (active < 0) active = i;
            enabled++;
        }
        if (active >= 0) { scanout = active; W = pm[active].r.w; H = pm[active].r.h; }
        printf("vgpu: display info ok, scanouts=%d active=%d %dx%d\r\n",
               enabled, active < 0 ? 0 : active, W, H);
    } else {
        printf("vgpu: GET_DISPLAY_INFO -> %x (using %dx%d)\r\n", r, W, H);
    }

    /* -- a framebuffer in user RAM (identity-mapped = DMA-able) -------- */
    uint32_t *fb = malloc((uint32_t)W * H * 4);
    if (!fb) { print("vgpu: framebuffer OOM\r\n"); return 0; }
    memset(fb, 0, (uint32_t)W * H * 4);          /* black until the caller draws */

    /* -- RESOURCE_CREATE_2D (id 1) ------------------------------------ */
    hdr(CMD_RESOURCE_CREATE_2D);
    { uint32_t *p = (uint32_t *)(req + sizeof(gpu_hdr));
      p[0] = 1; p[1] = FMT_B8G8R8X8; p[2] = W; p[3] = H; }
    if (submit(sizeof(gpu_hdr) + 16, 64) != RESP_OK_NODATA) { print("vgpu: create_2d failed\r\n"); return 0; }

    /* -- RESOURCE_ATTACH_BACKING (id 1 -> our framebuffer) ------------ */
    hdr(CMD_ATTACH_BACKING);
    { uint32_t *p = (uint32_t *)(req + sizeof(gpu_hdr));
      p[0] = 1; p[1] = 1;                          /* resource_id, nr_entries */
      p[2] = (uint32_t)fb; p[3] = 0;               /* mem_entry.addr (64-bit) */
      p[4] = (uint32_t)W * H * 4; p[5] = 0; }      /* mem_entry.length, pad   */
    if (submit(sizeof(gpu_hdr) + 8 + 16, 64) != RESP_OK_NODATA) { print("vgpu: attach failed\r\n"); return 0; }

    /* -- SET_SCANOUT (selected scanout shows resource 1) -------------- */
    hdr(CMD_SET_SCANOUT);
    { gpu_rect *rc = (gpu_rect *)(req + sizeof(gpu_hdr));
      rc->x = 0; rc->y = 0; rc->w = W; rc->h = H;
      uint32_t *p = (uint32_t *)(req + sizeof(gpu_hdr) + 16);
      p[0] = scanout; p[1] = 1; }                  /* scanout_id, resource_id */
    if (submit(sizeof(gpu_hdr) + 16 + 8, 64) != RESP_OK_NODATA) { print("vgpu: set_scanout failed\r\n"); return 0; }

    vg_W = W; vg_H = H; vg_scanout = scanout; vg_fb = fb;
    printf("vgpu: set scanout %d -> resource 1\r\n", vg_scanout);
    *wq = W; *hq = H;
    return fb;
}

/* Push the backing framebuffer to the scanout: TRANSFER_TO_HOST_2D (DMA our
 * pixels into the device resource) then RESOURCE_FLUSH (show it). Call after
 * rendering a frame. No-op if vgpu_setup() did not run. */
void vgpu_present(void) {
    /* bail if our state was zeroed by a foreground game's crt0 (shared .bss) -
     * hdr()/submit() below would otherwise deref a null req/used16 and fault. */
    if (!vg_fb || !req || !resp || !used16 || !desc || !avail || !cc || !notify) return;
    int W = vg_W, H = vg_H;
    hdr(CMD_TRANSFER_TO_HOST_2D);
    { gpu_rect *rc = (gpu_rect *)(req + sizeof(gpu_hdr));
      rc->x = 0; rc->y = 0; rc->w = W; rc->h = H;
      uint32_t *p = (uint32_t *)(req + sizeof(gpu_hdr) + 16);
      p[0] = 0; p[1] = 0; p[2] = 1; p[3] = 0; }    /* offset(64)=0, resource_id=1 */
    if (submit(sizeof(gpu_hdr) + 16 + 16, 64) != RESP_OK_NODATA) return;
    hdr(CMD_RESOURCE_FLUSH);
    { gpu_rect *rc = (gpu_rect *)(req + sizeof(gpu_hdr));
      rc->x = 0; rc->y = 0; rc->w = W; rc->h = H;
      uint32_t *p = (uint32_t *)(req + sizeof(gpu_hdr) + 16);
      p[0] = 1; p[1] = 0; }                        /* resource_id */
    submit(sizeof(gpu_hdr) + 16 + 8, 64);
}

/* the `vgpu` command: stand-alone test - set up the device, draw a test
 * pattern into the backing, and present it. */
int vgpu_main(void) {
    print("vgpu: virtio-gpu 2D driver\r\n");
    int W, H;
    uint32_t *fb = vgpu_setup(&W, &H);
    if (!fb) { print("vgpu: no virtio-gpu (QEMU: -device virtio-gpu-pci)\r\n"); return 0; }
    printf("vgpu: active scanout %d = %dx%d\r\n", vg_scanout, W, H);
    for (int y = 0; y < H; y++) {
        int t = y * 255 / (H - 1);
        uint32_t bg = (uint32_t)((0x0a + 10 * t / 255) << 16
                               | (0x0e + 14 * t / 255) << 8
                               | (0x1a + 20 * t / 255));      /* Dark Glass gradient */
        uint32_t *row = fb + (uint32_t)y * W;
        for (int x = 0; x < W; x++) row[x] = bg;
        if (y > H / 3 && y < H / 3 + H / 8)
            for (int x = W / 8; x < W * 3 / 8; x++) row[x] = 0xf87171;   /* red   */
        if (y > H / 2 && y < H / 2 + H / 8)
            for (int x = W * 3 / 8; x < W * 5 / 8; x++) row[x] = 0x4ade80; /* green */
        if (y > H * 2 / 3 && y < H * 2 / 3 + H / 8)
            for (int x = W * 5 / 8; x < W * 7 / 8; x++) row[x] = 0x22d3ee; /* cyan  */
    }
    vgpu_present();
    printf("vgpu: rendered %dx%d to the virtio-gpu scanout - flush OK\r\n", W, H);
    return 0;
}
