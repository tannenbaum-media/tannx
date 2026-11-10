/* nvme.c - NVMe block driver in ring-3 C (real-hardware storage).
 *
 * Modern x86 mini-PCs (N100/NUC/Beelink) ship an NVMe SSD and no SATA, so
 * AHCI alone leaves them diskless. This finds an NVMe controller (PCI class
 * 0x010802), maps BAR0, brings the controller up (admin queue pair + enable),
 * creates one I/O queue pair, and proves a 512-byte LBA write+read round-trip.
 *
 * Same contract as vgpu.c: the kernel only lends PCI config access (SYS_PCI)
 * and an uncached user mapping of the BAR (SYS_MMIO_MAP, va == phys). DMA
 * buffers + queues live in identity-mapped user RAM, so they are DMA-able as
 * malloc'd (page-aligned here - NVMe needs 4 KB alignment). Ring-3 takes no
 * interrupts, so we POLL the completion queue's phase tag (the vgpu/HDA way).
 *
 * Headless: qemu -device nvme,drive=... ; the bare-metal test PC has no NVMe, but this is the
 * storage path for real mini-PC hardware and the persistence path for a server.
 */
#include "libc.h"
#include "fatfs.h"

typedef unsigned long long uint64_t;   /* libc.h is 32-bit; LBAs/PRPs are 64-bit */

/* ---- controller registers (BAR0) ------------------------------------ */
static volatile uint8_t *bar;
#define REG32(off) (*(volatile uint32_t *)(bar + (off)))
#define R_CAP   0x00      /* capabilities (64-bit): MQES, DSTRD ... */
#define R_CC    0x14      /* controller config: EN, IOSQES, IOCQES  */
#define R_CSTS  0x1c      /* status: RDY (bit0), CFS (bit1)          */
#define R_AQA   0x24      /* admin queue attributes (sizes)          */
#define R_ASQ   0x28      /* admin SQ base (64-bit)                  */
#define R_ACQ   0x30      /* admin CQ base (64-bit)                  */
#define R_DB    0x1000    /* doorbell registers start here           */

static uint32_t db_bytes;             /* doorbell stride = 4 << CAP.DSTRD */

/* a submission/completion queue pair (admin = qid 0, I/O = qid 1) */
struct nvq {
    uint32_t *sq;                     /* submission queue (64 B entries) */
    volatile uint32_t *cq;            /* completion queue (16 B entries) */
    int depth;
    uint16_t sqt;                     /* our submission tail   */
    uint16_t cqh;                     /* our completion head   */
    uint8_t phase;                    /* expected CQE phase tag (starts 1) */
    int qid;
    uint16_t cid;                     /* running command identifier */
};
static struct nvq adminq, ioq;

/* submit a 16-dword command, ring the SQ doorbell, poll the CQ for the
 * matching completion (phase tag flip). Returns the NVMe status field
 * (0 = success), or -1 on timeout. Synchronous: one command outstanding. */
static int nv_cmd(struct nvq *q, uint32_t cmd[16]) {
    uint16_t cid = q->cid++;
    cmd[0] = (cmd[0] & 0xffffu) | ((uint32_t)cid << 16);   /* CDW0: opcode | CID */
    uint32_t *slot = q->sq + (uint32_t)q->sqt * 16;
    for (int i = 0; i < 16; i++) slot[i] = cmd[i];
    q->sqt = (uint16_t)((q->sqt + 1) % q->depth);
    REG32(R_DB + (2 * q->qid) * db_bytes) = q->sqt;        /* SQ tail doorbell */
    for (int t = 0; t < 4000000; t++) {
        volatile uint32_t *cqe = q->cq + (uint32_t)q->cqh * 4;
        uint32_t dw3 = cqe[3];                             /* CID|phase|status */
        if (((dw3 >> 16) & 1u) == q->phase) {              /* new entry arrived */
            int status = (int)((dw3 >> 17) & 0x7ffu);
            uint16_t ccid = (uint16_t)(cqe[3] & 0xffffu);  /* which command it answers */
            q->cqh = (uint16_t)(q->cqh + 1);
            if (q->cqh == q->depth) { q->cqh = 0; q->phase ^= 1; }
            REG32(R_DB + (2 * q->qid + 1) * db_bytes) = q->cqh; /* CQ head doorbell */
            if (ccid != cid) continue;                     /* stale completion from a
                                                            * timed-out command - drain
                                                            * it, keep waiting for ours */
            return status;
        }
        if (t > 200000 && (t & 0x3fff) == 0) { sys_progress(50); sys_yield(); }
    }
    return -1;
}

static int nvme_up(void) {
    /* -- find an NVMe controller: PCI class 0x010802 ------------------- */
    int bdf = pci_find_class(0x010802, 0xffffff);    /* NVM Express */
    if (bdf < 0) { print("nvme: no NVMe controller (QEMU: -device nvme,drive=..)\r\n"); return 0; }
    printf("nvme: found controller at dev %d fn %d (%x)\r\n", bdf >> 3, bdf & 7, pci_rd(bdf, 0));
    pci_wr(bdf, 4, pci_rd(bdf, 4) | 6);          /* MEM space + bus master */

    uint32_t va = pci_map_bar(bdf, 0, "nvme");
    if (!va) return 0;
    bar = (volatile uint8_t *)va;

    uint32_t cap_lo = REG32(R_CAP), cap_hi = REG32(R_CAP + 4);
    db_bytes = 4u << (cap_hi & 0xf);             /* CAP.DSTRD (bits 35:32) */
    printf("nvme: mapped BAR0 @%x; mqes=%d dstrd=%d\r\n",
           va, (cap_lo & 0xffff) + 1, cap_hi & 0xf);

    /* -- reset: clear EN, wait CSTS.RDY = 0 --------------------------- */
    REG32(R_CC) = 0;
    for (int t = 0; t < 2000000 && (REG32(R_CSTS) & 1); t++) sys_yield();

    /* -- admin queue pair (depth 8) ----------------------------------- */
    int ad = 8;
    adminq.sq = zpage(ad * 64); adminq.cq = zpage(ad * 16);
    adminq.depth = ad; adminq.sqt = 0; adminq.cqh = 0; adminq.phase = 1;
    adminq.qid = 0; adminq.cid = 0;
    if (!adminq.sq || !adminq.cq) { print("nvme: admin queue OOM\r\n"); return 0; }
    REG32(R_AQA)     = ((uint32_t)(ad - 1) << 16) | (ad - 1);
    REG32(R_ASQ)     = (uint32_t)adminq.sq; REG32(R_ASQ + 4) = 0;
    REG32(R_ACQ)     = (uint32_t)adminq.cq; REG32(R_ACQ + 4) = 0;

    /* -- enable: IOCQES=4 (16B), IOSQES=6 (64B), MPS=0 (4KB), EN=1 ----- */
    REG32(R_CC) = (4u << 20) | (6u << 16) | 1u;
    int ok = 0;
    for (int t = 0; t < 2000000; t++) {
        uint32_t s = REG32(R_CSTS);
        if (s & 2) { print("nvme: controller fatal (CSTS.CFS)\r\n"); return 0; }
        if (s & 1) { ok = 1; break; }
        sys_yield();
    }
    if (!ok) { print("nvme: controller not ready (CSTS.RDY timeout)\r\n"); return 0; }
    print("nvme: controller enabled (RDY)\r\n");

    /* -- I/O queue pair (depth 8, qid 1) ------------------------------ */
    int id = 8;
    ioq.sq = zpage(id * 64); ioq.cq = zpage(id * 16);
    ioq.depth = id; ioq.sqt = 0; ioq.cqh = 0; ioq.phase = 1; ioq.qid = 1; ioq.cid = 0;
    if (!ioq.sq || !ioq.cq) { print("nvme: io queue OOM\r\n"); return 0; }

    uint32_t cmd[16];
    /* Create I/O Completion Queue (opcode 0x05): PRP1 = CQ, PC=1, IEN=0 */
    memset(cmd, 0, 64);
    cmd[0] = 0x05; cmd[6] = (uint32_t)ioq.cq;
    cmd[10] = ((uint32_t)(id - 1) << 16) | 1; cmd[11] = 1;
    if (nv_cmd(&adminq, cmd) != 0) { print("nvme: create I/O CQ failed\r\n"); return 0; }
    /* Create I/O Submission Queue (opcode 0x01): PRP1 = SQ, CQID=1, PC=1 */
    memset(cmd, 0, 64);
    cmd[0] = 0x01; cmd[6] = (uint32_t)ioq.sq;
    cmd[10] = ((uint32_t)(id - 1) << 16) | 1; cmd[11] = (1u << 16) | 1;
    if (nv_cmd(&adminq, cmd) != 0) { print("nvme: create I/O SQ failed\r\n"); return 0; }
    print("nvme: I/O queue pair ready\r\n");
    return 1;
}

/* read/write one 512-byte LBA via the I/O queue (NLB=0 = 1 block). 0 = OK. */
static int nvme_block(uint32_t lba, uint8_t *buf, int write) {
    uint32_t cmd[16]; memset(cmd, 0, 64);
    cmd[0] = write ? 0x01u : 0x02u;               /* write / read */
    cmd[1] = 1;                                   /* NSID */
    cmd[6] = (uint32_t)buf;                       /* PRP1 */
    cmd[10] = lba;                                /* SLBA low */
    return nv_cmd(&ioq, cmd);
}
static int nvme_rb(uint32_t lba, uint8_t *buf) { return nvme_block(lba, buf, 0); }
static int nvme_wb(uint32_t lba, uint8_t *buf) { return nvme_block(lba, buf, 1); }

/* nvme save <file> <slot>: write an AgentFS slot out as a FAT16 file on the NVMe
 * disk (inverse of nvme load). */
static int nvme_save(const char *fn, int slot) {
    if (!fn || !*fn || *fn == ' ') { print("nvme: usage: nvme save <file> <slot>\r\n"); return 0; }
    if (slot < 0 || slot > 7) { print("nvme: slot must be 0-7\r\n"); return 0; }
    static uint8_t sec[512];
    if (sys_read_sectors(257 + slot, 1, sec) != 1 || sec[0] != 'A' || sec[1] != 'F') {
        print("nvme: empty/bad slot - 'save <slot> <text>' first\r\n"); return 0;
    }
    fat_use(nvme_rb); fat_use_write(nvme_wb);
    int r = fat_save(fn, sec + 3, sec[2]);
    if (r == 0) printf("nvme: wrote slot %d (%d bytes) -> %s\r\n", slot, sec[2], fn);
    else printf("nvme: save failed (%d): need a FAT16/32 disk, free space\r\n", r);
    return 0;
}

/* nvme copy <src> <dst>: duplicate a file on the disk (multi-cluster capable) */
static int nvme_copy(const char *src, const char *dst) {
    if (!src || !*src || !dst || !*dst || *dst == ' ') { print("nvme: usage: nvme copy <src> <dst>\r\n"); return 0; }
    fat_use(nvme_rb); fat_use_write(nvme_wb);
    int r = fat_copy(src, dst);
    if (r == 0) print("nvme: copied\r\n");
    else printf("nvme: copy failed (%d): FAT16 disk, src exists, free space?\r\n", r);
    return 0;
}

/* the file API for other programs (user/edit.c): bring the controller up once,
 * then read/write FAT files. nvme_fat() probes quietly when there is no NVMe. */
static int nvme_ready;
static int nvme_ensure(void) {
    if (!nvme_ready) { if (!nvme_up()) return 0; fat_use(nvme_rb); fat_use_write(nvme_wb); nvme_ready = 1; }
    return 1;
}
int nvme_fat(void) {
    if (pci_find_class(0x010802, 0xffffff) < 0) return 0;
    return nvme_ensure() && fat_present();
}
int nvme_file(const char *name, uint8_t *buf, int cap) {
    if (!nvme_ensure()) return -1;
    return fat_file(name, buf, cap);
}
int nvme_savefile(const char *name, const uint8_t *data, int len) {
    if (!nvme_ensure()) return -1;
    return fat_save(name, data, (uint32_t)len);
}

/* destructive scratch self-test: write a pattern to LBA 0 and read it back */
static int nvme_test(void) {
    uint8_t *buf = zpage(4096);
    if (!buf) { print("nvme: DMA buffer OOM\r\n"); return 0; }
    for (int i = 0; i < 512; i++) buf[i] = (uint8_t)(i ^ 0x5a);
    if (nvme_block(0, buf, 1) != 0) { print("nvme: write LBA 0 failed\r\n"); return 0; }
    memset(buf, 0, 512);
    if (nvme_block(0, buf, 0) != 0) { print("nvme: read LBA 0 failed\r\n"); return 0; }
    int good = 1;
    for (int i = 0; i < 512; i++) if (buf[i] != (uint8_t)(i ^ 0x5a)) { good = 0; break; }
    if (good) print("nvme: write+read LBA 0 verified - 512 bytes match\r\n");
    else      print("nvme: VERIFY FAILED - read back wrong data\r\n");
    return 0;
}

static int kwmatch(const char *p, const char *kw) {
    while (*kw) { if (*p != *kw) return 0; p++; kw++; }
    return *p == 0 || *p == ' ';
}
static const char *next_arg(const char *p) {
    while (*p && *p != ' ') p++; while (*p == ' ') p++; return p;
}

/* nvme [test|ls|cat <f>|load <f> <slot>]; bare = info (read-only + auto-ls) */
int nvme_main(void) {
    print("nvme: NVMe block driver\r\n");
    const char *arg = (const char *)0x007FF000;
    const char *p = arg + 4; while (*p == ' ') p++;   /* past "nvme" */
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

    if (!nvme_up()) return 0;
    if (mode == 1) return nvme_test();               /* explicit, destructive */
    if (mode == 7) return nvme_save(fn, slot);
    if (mode == 8) return nvme_copy(fn, fn2);
    fat_use(nvme_rb);
    if (mode == 4) return fat_ls();
    if (mode == 5) return fat_cat(fn);
    if (mode == 6) return fat_load(fn, slot);
    if (fat_present()) fat_ls();
    else print("nvme: raw block device (no FAT) - 'nvme test' to verify R/W\r\n");
    return 0;
}

/* bring the device up and register it with the FAT layer, for the apps that
 * just want "a FAT volume" (run files, run shot). 1 = mounted a FAT. */
int nvme_mount(void) {
    static int up;
    if (!up) { if (!nvme_up()) return 0; up = 1; }
    fat_use(nvme_rb); fat_use_write(nvme_wb);
    return fat_present();
}
