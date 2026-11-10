/* vblk.c - virtio-blk block driver in ring-3 C (the cloud/VM disk).
 *
 * virtio-blk is the disk every cloud VM and hypervisor presents; together
 * with virtio-net it makes TannX OS a first-class VM/cloud guest. Ring-3
 * can't do port I/O (IOPL 0 -> #GP), so this drives the MODERN (virtio-1.0)
 * MMIO interface - the exact pattern user/vgpu.c uses: PCI-cap walk to the
 * config regions in the BAR, the device-init handshake, one request virtqueue
 * in user RAM (identity-mapped = DMA-able), and the block request protocol
 * (a 3-descriptor chain: header / data / status). Polls the used ring.
 *
 * QEMU: -device virtio-blk-pci,drive=.. (1af4:1001 transitional).
 */
#include "libc.h"
#include "fatfs.h"
#include "virtio.h"

typedef unsigned long long uint64_t;   /* libc.h is 32-bit; blk fields are 64-bit */

/* virtqueue state, plumbed from virtio_init() so blk_rw() keeps its hot path */
static volatile uint8_t *cc;      /* common cfg (for CCxx)  */
static volatile uint8_t *notify;  /* notify base */
static volatile uint8_t *devcfg;  /* device cfg (block capacity etc.) */
static uint32_t notify_mult;
static struct vq_desc *desc;
static volatile uint16_t *avail, *used16;
static int qsz;
static uint16_t avail_idx, last_used, q_notify_off;
#define CC32(o) (*(volatile uint32_t *)(cc + (o)))
#define CC16(o) (*(volatile uint16_t *)(cc + (o)))
#define CC8(o)  (*(volatile uint8_t  *)(cc + (o)))

static uint8_t *hdr;    /* request header (device-readable)  */
static uint8_t *sts;    /* status byte    (device-writable)  */

/* one block request: 3-desc chain header/data/status. write=1 -> OUT (write
 * to disk), 0 -> IN (read). Returns the virtio-blk status (0 = OK) or -1. */
static int blk_rw_n(uint64_t sector, uint8_t *data, uint32_t nsec, int write) {
    ((uint32_t *)hdr)[0] = write ? 1u : 0u;     /* type: 0=IN(read) 1=OUT(write) */
    ((uint32_t *)hdr)[1] = 0;                    /* reserved */
    *(uint64_t *)(hdr + 8) = sector;
    sts[0] = 0xff;
    desc[0].addr = (uint32_t)hdr;  desc[0].len = 16; desc[0].flags = VQ_NEXT;             desc[0].next = 1;
    desc[1].addr = (uint32_t)data; desc[1].len = 512 * nsec;
    desc[1].flags = VQ_NEXT | (write ? 0 : VQ_WRITE);                                     desc[1].next = 2;
    desc[2].addr = (uint32_t)sts;  desc[2].len = 1;  desc[2].flags = VQ_WRITE;            desc[2].next = 0;
    avail[2 + (avail_idx % qsz)] = 0;            /* head descriptor = 0 */
    avail_idx++;
    avail[1] = avail_idx;
    *(volatile uint16_t *)(notify + q_notify_off * notify_mult) = 0;
    for (int t = 0; t < 4000000; t++) {
        if (used16[1] != last_used) { last_used = used16[1]; return sts[0]; }
        /* busy-poll first: QEMU completes in microseconds, so most requests
         * return here without ever yielding (a yield costs a whole timer tick,
         * which made multi-request writes glacial). Only fall back to yielding
         * for a genuinely slow/real device. */
        if (t > 200000 && (t & 0x3fff) == 0) { sys_progress(50); sys_yield(); }
    }
    return -1;
}

static int blk_rw(uint64_t sector, uint8_t *data, int write) { return blk_rw_n(sector, data, 1, write); }

static int vblk_up(void) {
    int bdf = pci_find_id(0x10011af4);               /* virtio-blk (transitional) */
    if (bdf < 0) bdf = pci_find_id(0x10421af4);       /* ...or modern (1.0) id      */
    if (bdf < 0) { print("vblk: no virtio-blk (QEMU: -device virtio-blk-pci,drive=..)\r\n"); return 0; }
    printf("vblk: found %x at dev %d fn %d\r\n", pci_rd(bdf, 0), bdf >> 3, bdf & 7);

    /* shared virtio bring-up; blk_rw() posts a 3-descriptor chain, so qsz >= 1
     * suffices (the chain uses distinct descriptors, not a full ring). */
    struct virtio_dev vd;
    if (!virtio_init(&vd, bdf, 1, "vblk")) return 0;
    cc = vd.cc; notify = vd.notify; devcfg = vd.devcfg; notify_mult = vd.notify_mult;
    desc = vd.desc; avail = vd.avail; used16 = vd.used16; qsz = vd.qsz;
    q_notify_off = vd.q_notify_off; avail_idx = vd.avail_idx; last_used = vd.last_used;
    hdr = malloc(64);                             /* request header (dev-readable) */
    sts = malloc(64);                             /* status byte (dev-writable)    */
    if (!hdr || !sts) { print("vblk: OOM\r\n"); return 0; }

    if (devcfg) {
        uint32_t lo = *(volatile uint32_t *)devcfg, hi = *(volatile uint32_t *)(devcfg + 4);
        printf("vblk: capacity %u sectors (%u MB)\r\n", lo, (uint32_t)(((uint64_t)lo | ((uint64_t)hi<<32)) / 2048));
    }
    return 1;
}

/* the shared FAT layer reads the disk through this */
static int vblk_rb(uint32_t lba, uint8_t *buf) { return blk_rw(lba, buf, 0) == 0 ? 0 : 1; }
static int vblk_wb(uint32_t lba, uint8_t *buf) { return blk_rw(lba, buf, 1) == 0 ? 0 : 1; }
static int vblk_wbn(uint32_t lba, const uint8_t *buf, uint32_t n) { return blk_rw_n(lba, (uint8_t *)buf, n, 1) == 0 ? 0 : 1; }

/* vblk save <file> <slot>: write an AgentFS slot's content out as a FAT16 file
 * (the inverse of 'vblk load <file> <slot>'). So a script/data the OS built can
 * be saved to a stick/disk a PC reads. */
static int vblk_save(const char *fn, int slot) {
    if (!fn || !*fn || *fn == ' ') { print("vblk: usage: vblk save <file> <slot>\r\n"); return 0; }
    if (slot < 0 || slot > 7) { print("vblk: slot must be 0-7\r\n"); return 0; }
    static uint8_t sec[512];
    if (sys_read_sectors(257 + slot, 1, sec) != 1 || sec[0] != 'A' || sec[1] != 'F') {
        print("vblk: empty/bad slot - 'save <slot> <text>' first\r\n"); return 0;
    }
    fat_use(vblk_rb); fat_use_write(vblk_wb);
    int r = fat_save(fn, sec + 3, sec[2]);
    if (r == 0) printf("vblk: wrote slot %d (%d bytes) -> %s\r\n", slot, sec[2], fn);
    else printf("vblk: save failed (%d): need a FAT16/32 disk, free space\r\n", r);
    return 0;
}

/* vblk copy <src> <dst>: copy a file on the disk (exercises the multi-cluster
 * write path for a multi-KB source). */
static int vblk_copy(const char *src, const char *dst) {
    if (!src || !*src || !dst || !*dst || *dst == ' ') { print("vblk: usage: vblk copy <src> <dst>\r\n"); return 0; }
    fat_use(vblk_rb); fat_use_write(vblk_wb);
    int r = fat_copy(src, dst);
    if (r == 0) print("vblk: copied (the destination is a FAT cluster chain)\r\n");
    else printf("vblk: copy failed (%d): FAT16/32 disk, src exists, free space?\r\n", r);
    return 0;
}

/* the HTTP file server (user/net.c) reads files off the VM disk through this -
 * brings virtio-blk up once, then serves from its FAT filesystem. Registered
 * by appmain so net.bin (no block drivers) still links. */
static int vblk_ready = 0;
static int vblk_ensure(void) {   /* bring the disk up once + register reader/writer */
    if (!vblk_ready) { if (!vblk_up()) return 0; fat_use(vblk_rb); fat_use_write(vblk_wb); vblk_ready = 1; }
    return 1;
}
int vblk_file(const char *name, uint8_t *buf, int cap) {
    if (!vblk_ensure()) return -1;
    return fat_file(name, buf, cap);
}
/* is a FAT volume mounted on the virtio-blk disk? (the editor's storage probe) */
int vblk_fat(void) {
    if (pci_find_id(0x10011af4) < 0 && pci_find_id(0x10421af4) < 0) return 0;  /* quiet: no device */
    return vblk_ensure() && fat_present();
}
/* POST /file/<name> upload target: write the body to the VM disk (httpd_savefile) */
int vblk_savefile(const char *name, const uint8_t *data, int len) {
    if (!vblk_ensure()) return -1;
    return fat_save(name, data, (uint32_t)len);
}

/* destructive scratch self-test: write a pattern to sector 0, read it back */
static int vblk_test(void) {
    uint8_t *data = malloc(512);
    if (!data) { print("vblk: buffer OOM\r\n"); return 0; }
    for (int i = 0; i < 512; i++) data[i] = (uint8_t)(i ^ 0x69);
    if (blk_rw(0, data, 1) != 0) { print("vblk: write sector 0 failed\r\n"); return 0; }
    memset(data, 0, 512);
    if (blk_rw(0, data, 0) != 0) { print("vblk: read sector 0 failed\r\n"); return 0; }
    int good = 1;
    for (int i = 0; i < 512; i++) if (data[i] != (uint8_t)(i ^ 0x69)) { good = 0; break; }
    if (good) print("vblk: write+read sector 0 verified - virtio-blk works\r\n");
    else      print("vblk: VERIFY FAILED - read back wrong data\r\n");
    return 0;
}

static int kwmatch(const char *p, const char *kw) {
    while (*kw) { if (*p != *kw) return 0; p++; kw++; }
    return *p == 0 || *p == ' ';
}
static const char *next_arg(const char *p) {
    while (*p && *p != ' ') p++; while (*p == ' ') p++; return p;
}

/* vblk [test|ls|cat <f>|load <f> <slot>|save <f> <slot>]; bare = info (auto-ls).
 * save writes AgentFS slot <slot> out as a FAT16 file <f> (first write path). */
int vblk_main(void) {
    print("vblk: virtio-blk driver (cloud/VM disk)\r\n");
    const char *arg = (const char *)0x007FF000;
    const char *p = arg + 4; while (*p == ' ') p++;   /* past "vblk" */
    const char *fn = 0, *fn2 = 0; int mode = 0, slot = 0;
    if      (kwmatch(p, "test")) mode = 1;
    else if (kwmatch(p, "ls"))   mode = 4;
    else if (kwmatch(p, "cat"))  { mode = 5; fn = next_arg(p); }
    else if (kwmatch(p, "load")) { mode = 6; fn = next_arg(p);
        const char *s = next_arg(fn);
        slot = (*s >= '0' && *s <= '9') ? *s - '0' : -1; }
    else if (kwmatch(p, "save")) { mode = 7; fn = next_arg(p);
        const char *s = next_arg(fn);
        slot = (*s >= '0' && *s <= '9') ? *s - '0' : -1; }
    else if (kwmatch(p, "copy")) { mode = 8; fn = next_arg(p); fn2 = next_arg(fn); }

    if (!vblk_up()) return 0;
    if (mode == 1) return vblk_test();               /* explicit, destructive */
    if (mode == 7) return vblk_save(fn, slot);        /* explicit write */
    if (mode == 8) return vblk_copy(fn, fn2);
    fat_use(vblk_rb);
    if (mode == 4) return fat_ls();
    if (mode == 5) return fat_cat(fn);
    if (mode == 6) return fat_load(fn, slot);
    if (fat_present()) fat_ls();
    else print("vblk: raw block device (no FAT) - 'vblk test' to verify R/W\r\n");
    return 0;
}

/* bring the device up and register it with the FAT layer, for the apps that
 * just want "a FAT volume" (run files, run shot). 1 = mounted a FAT. */
int vblk_mount(void) {
    static int up;
    if (!up) { if (!vblk_up()) return 0; up = 1; }
    fat_use(vblk_rb); fat_use_write(vblk_wb); fat_use_write_n(vblk_wbn);
    return fat_present();
}
