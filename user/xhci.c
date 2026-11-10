/* xhci.c - USB Mass Storage (xHCI + MSC Bulk-Only Transport) in ring-3 C.
 *
 * Storage for mini-PCs: a USB stick from bare metal. xHCI
 * is the modern USB host controller; on top of it this speaks the Mass
 * Storage Class Bulk-Only Transport (BOT) + SCSI to read and write blocks.
 *
 * Flow: find + map the controller -> set up the TRB command/event rings and
 * the DCBAA in identity-mapped user RAM -> reset the device's port ->
 * enumerate (Enable Slot / Address Device / Get Device + Config Descriptors)
 * -> Configure Endpoint (the two bulk endpoints) + SET_CONFIGURATION ->
 * SCSI INQUIRY / READ CAPACITY / WRITE(10) / READ(10) over BOT (CBW -> data
 * -> CSW). The kernel boot-enum wedged, so this is ring-3 + on-demand (`usb`)
 * and never runs at boot. Ring-3 takes no IRQ, so we poll the event ring.
 *
 * Headless: qemu -device qemu-xhci -device usb-storage,drive=..
 */
#include "libc.h"
#include "fatfs.h"

typedef unsigned long long uint64_t;

static volatile uint8_t *cap, *op, *rt, *db;     /* register bases (byte-addressed) */
#define CAP32(o) (*(volatile uint32_t *)(cap + (o)))
#define OP32(o)  (*(volatile uint32_t *)(op  + (o)))
#define RT32(o)  (*(volatile uint32_t *)(rt  + (o)))
#define DB32(o)  (*(volatile uint32_t *)(db  + (o)))

typedef struct { uint32_t d0, d1, d2, d3; } trb;
#define RING_SZ 64


static uint64_t *dcbaa;
static trb *cmd;  static int cmd_i; static uint32_t cmd_cyc;
static volatile trb *evt;  static int evt_i; static uint32_t evt_cyc;  /* DMA-written: poll it volatile */
static int ctx_sz, slot, speed, port;
static trb *ep0;  static int ep0_i; static uint32_t ep0_cyc;
static trb *b_out, *b_in; static int bo_i, bi_i; static uint32_t bo_cyc, bi_cyc;
static int dci_out, dci_in, mps_out, mps_in;
static uint32_t cbw_tag;

static void ring_link(trb *r) {
    trb *l = &r[RING_SZ - 1];
    l->d0 = (uint32_t)r; l->d1 = 0; l->d2 = 0;
    l->d3 = (6u << 10) | (1u << 1);
}

/* push a command TRB, ring doorbell 0, poll the event ring for the Command
 * Completion event. Returns completion code (1 = success); *sl = slot id. */
static int cmd_run(uint32_t d0, uint32_t d1, uint32_t d2, uint32_t d3, int *sl) {
    trb *t = &cmd[cmd_i];
    t->d0 = d0; t->d1 = d1; t->d2 = d2; t->d3 = (d3 & ~1u) | cmd_cyc;
    if (++cmd_i >= RING_SZ - 1) { cmd[RING_SZ-1].d3 = (6u<<10)|(1u<<1)|cmd_cyc; cmd_i = 0; cmd_cyc ^= 1; }
    DB32(0) = 0;
    for (int n = 0; n < 3000000; n++) {
        volatile trb *e = &evt[evt_i];
        if ((e->d3 & 1u) == evt_cyc) {
            int cc = (int)((e->d2 >> 24) & 0xff), type = (int)((e->d3 >> 10) & 0x3f);
            if (sl) *sl = (int)((e->d3 >> 24) & 0xff);
            if (++evt_i >= RING_SZ) { evt_i = 0; evt_cyc ^= 1; }
            RT32(0x38) = (uint32_t)&evt[evt_i] | (1u << 3); RT32(0x3c) = 0;
            if (type == 33) return cc;
            /* a non-Command-Completion event (e.g. an async Port Status Change)
             * was consumed - do NOT reset n. Resetting made the 3M cap measure
             * "iterations since the last event of ANY type", so a stream of
             * stray events defeated the bound into an infinite hang AND kept n
             * under the 200000 yield gate (starving the scheduler). Counting
             * every iteration keeps it a true total budget with periodic yields. */
        }
        if (n > 200000 && (n & 0x3fff) == 0) { sys_progress(50); sys_yield(); }
    }
    return 0;
}

/* poll the event ring for a Transfer Event. 1 = success, 13 = short packet
 * (both fine for our IN transfers); anything else (incl. 0 = timeout) fails. */
static int xfer_wait(void) {
    for (int n = 0; n < 3000000; n++) {
        volatile trb *e = &evt[evt_i];
        if ((e->d3 & 1u) == evt_cyc) {
            int cc = (int)((e->d2 >> 24) & 0xff), type = (int)((e->d3 >> 10) & 0x3f);
            if (++evt_i >= RING_SZ) { evt_i = 0; evt_cyc ^= 1; }
            RT32(0x38) = (uint32_t)&evt[evt_i] | (1u << 3); RT32(0x3c) = 0;
            if (type == 32) return cc;
            /* consumed a non-Transfer event - do NOT reset n (see cmd_run):
             * resetting turned the 3M cap into a defeatable per-event timer
             * that a stray-event stream could hang on. */
        }
        if (n > 200000 && (n & 0x3fff) == 0) { sys_progress(50); sys_yield(); }
    }
    return 0;
}

/* a control transfer on EP0: Setup [-> Data] -> Status. s0/s1 carry the 8
 * setup bytes (immediate). dir_in = data stage direction; len 0 = no data. */
static int ctrl_xfer(uint32_t s0, uint32_t s1, uint8_t *buf, int len, int dir_in) {
    int trt = len ? (dir_in ? 3 : 2) : 0;
    /* wrap the EP0 ring before placing this transfer's up-to-3 contiguous TRBs
     * (mirrors bulk()). Today enumeration uses ~12 TRBs so this never fires, but
     * without it a driver doing >~21 control transfers would march past the link
     * TRB at RING_SZ-1 and overflow the ring's heap page. */
    if (ep0_i + 3 >= RING_SZ - 1) {
        ep0[RING_SZ-1].d3 = (6u<<10)|(1u<<1)|ep0_cyc;   /* arm link TRB, current cycle */
        ep0_i = 0; ep0_cyc ^= 1;
    }
    trb *t = &ep0[ep0_i++];
    t->d0 = s0; t->d1 = s1; t->d2 = 8;
    t->d3 = (2u << 10) | (1u << 6) | ((uint32_t)trt << 16) | ep0_cyc;
    if (len) {
        trb *d = &ep0[ep0_i++];
        d->d0 = (uint32_t)buf; d->d1 = 0; d->d2 = (uint32_t)len;
        d->d3 = (3u << 10) | ((dir_in ? 1u : 0u) << 16) | ep0_cyc;
    }
    trb *st = &ep0[ep0_i++];
    int sdir = len ? (dir_in ? 0 : 1) : 1;                 /* status opposite of data */
    st->d0 = 0; st->d1 = 0; st->d2 = 0;
    st->d3 = (4u << 10) | ((uint32_t)sdir << 16) | (1u << 5) | ep0_cyc;
    DB32(slot * 4) = 1;
    int cc = xfer_wait();
    return (cc == 1 || cc == 13) ? 1 : 0;
}

/* one bulk transfer (a Normal TRB) on a ring, ring the endpoint doorbell. */
static int bulk(trb *ring, int *idx, uint32_t *cyc, int dci, uint32_t buf, int len) {
    trb *t = &ring[*idx];
    t->d0 = buf; t->d1 = 0; t->d2 = (uint32_t)len;
    t->d3 = (1u << 10) | (1u << 5) | *cyc;                 /* Normal, IOC */
    if (++(*idx) >= RING_SZ - 1) { ring[RING_SZ-1].d3 = (6u<<10)|(1u<<1)|*cyc; *idx = 0; *cyc ^= 1; }
    DB32(slot * 4) = (uint32_t)dci;
    int cc = xfer_wait();
    return (cc == 1 || cc == 13) ? 1 : 0;
}

static uint8_t *cbw, *csw;
/* SCSI command over Bulk-Only Transport: CBW -> [data] -> CSW. Returns the
 * CSW status (0 = good) or -1 on a transport error. */
static int scsi(const uint8_t *cdb, int cdblen, uint8_t *data, int dlen, int dir_in) {
    memset(cbw, 0, 31);
    *(uint32_t *)cbw = 0x43425355u;               /* dCBWSignature "USBC" */
    *(uint32_t *)(cbw + 4) = ++cbw_tag;
    *(uint32_t *)(cbw + 8) = (uint32_t)dlen;
    cbw[12] = dir_in ? 0x80 : 0x00;               /* bmCBWFlags */
    cbw[14] = (uint8_t)cdblen;
    memcpy(cbw + 15, cdb, cdblen);
    if (!bulk(b_out, &bo_i, &bo_cyc, dci_out, (uint32_t)cbw, 31)) return -1;
    if (dlen) {
        if (dir_in) { if (!bulk(b_in,  &bi_i, &bi_cyc, dci_in,  (uint32_t)data, dlen)) return -1; }
        else        { if (!bulk(b_out, &bo_i, &bo_cyc, dci_out, (uint32_t)data, dlen)) return -1; }
    }
    if (!bulk(b_in, &bi_i, &bi_cyc, dci_in, (uint32_t)csw, 13)) return -1;
    if (*(uint32_t *)csw != 0x53425355u) return -1;        /* dCSWSignature "USBS" */
    return csw[12];                                        /* bCSWStatus */
}

/* bring the controller up + enumerate to the point where EP0 works. 1 = ok. */
static int xhci_up(void) {
    int bdf = pci_find_class(0x0c0330, 0xffffff);   /* USB xHCI */
    if (bdf < 0) { print("xhci: no xHCI controller (QEMU: -device qemu-xhci)\r\n"); return 0; }
    printf("xhci: found controller at dev %d fn %d (%x)\r\n", bdf>>3, bdf&7, pci_rd(bdf, 0));
    pci_wr(bdf, 4, pci_rd(bdf, 4) | 6);

    uint32_t va = pci_map_bar(bdf, 0, "xhci");
    if (!va) return 0;
    cap = (volatile uint8_t *)va;
    op  = cap + (CAP32(0) & 0xff);
    rt  = cap + (CAP32(0x18) & ~0x1fu);
    db  = cap + (CAP32(0x14) & ~0x3u);
    uint32_t hcs1 = CAP32(0x04);
    int maxslots = hcs1 & 0xff, maxports = (hcs1 >> 24) & 0xff;
    ctx_sz = (CAP32(0x10) & 0x04) ? 64 : 32;
    printf("xhci: slots=%d ports=%d ctx=%d\r\n", maxslots, maxports, ctx_sz);

    OP32(0) &= ~1u;
    for (int t = 0; t < 1000000 && !(OP32(4) & 1); t++) sys_yield();
    OP32(0) |= 2u;
    for (int t = 0; t < 2000000 && ((OP32(0) & 2) || (OP32(4) & 0x800)); t++) sys_yield();

    dcbaa = zpage(2048);
    if (!dcbaa) { print("xhci: OOM\r\n"); return 0; }
    uint32_t hcs2 = CAP32(0x08);
    int spb = ((hcs2 >> 21) & 0x1f) | (((hcs2 >> 27) & 0x1f) << 5);
    if (spb > 0) { uint64_t *sp = zpage(spb * 8);
                   if (!sp) { print("xhci: OOM\r\n"); return 0; }
                   for (int i = 0; i < spb; i++) {
                       uint32_t p = (uint32_t)zpage(4096);   /* spb is HW-controlled
                                                              * (up to 1023) - a NULL
                                                              * here must not be handed
                                                              * to the controller */
                       if (!p) { print("xhci: OOM\r\n"); return 0; }
                       sp[i] = p;
                   }
                   dcbaa[0] = (uint32_t)sp; }
    OP32(0x30) = (uint32_t)dcbaa; OP32(0x34) = 0;
    OP32(0x38) = maxslots;

    cmd = zpage(RING_SZ * 16); cmd_i = 0; cmd_cyc = 1;
    evt = zpage(RING_SZ * 16); evt_i = 0; evt_cyc = 1;
    uint32_t *erst = zpage(64);
    if (!cmd || !evt || !erst) { print("xhci: OOM\r\n"); return 0; }
    ring_link(cmd);
    OP32(0x18) = (uint32_t)cmd | 1u; OP32(0x1c) = 0;
    erst[0] = (uint32_t)evt; erst[1] = 0; erst[2] = RING_SZ; erst[3] = 0;
    RT32(0x28) = 1; RT32(0x30) = (uint32_t)erst; RT32(0x34) = 0;
    RT32(0x38) = (uint32_t)evt; RT32(0x3c) = 0;
    OP32(0) |= 1u;

    port = -1;
    for (int p = 0; p < maxports; p++) if (OP32(0x400 + p * 0x10) & 1) { port = p; break; }
    if (port < 0) { print("xhci: no USB device connected (add -device usb-storage)\r\n"); return 0; }
    uint32_t psc = OP32(0x400 + port * 0x10);
    OP32(0x400 + port * 0x10) = (psc & 0xc3e0u) | (1u << 4);
    for (int t = 0; t < 1000000; t++) { if (OP32(0x400 + port * 0x10) & (1u << 21)) break; sys_yield(); }
    speed = (OP32(0x400 + port * 0x10) >> 10) & 0xf;
    int mps0 = (speed == 4) ? 512 : (speed == 2) ? 8 : 64;
    printf("xhci: device on port %d, speed %d\r\n", port + 1, speed);

    slot = 0;
    if (cmd_run(0, 0, 0, (9u << 10), &slot) != 1 || !slot) { print("xhci: Enable Slot failed\r\n"); return 0; }

    uint8_t *inctx = zpage(4096), *devctx = zpage(4096);
    ep0 = zpage(RING_SZ * 16); ep0_i = 0; ep0_cyc = 1;
    if (!inctx || !devctx || !ep0) { print("xhci: OOM\r\n"); return 0; }
    ring_link(ep0);
    *(uint32_t *)(inctx + 4) = 0x3;
    uint8_t *sc = inctx + ctx_sz;
    *(uint32_t *)(sc + 0) = (1u << 27) | ((uint32_t)speed << 20);
    *(uint32_t *)(sc + 4) = ((uint32_t)(port + 1) << 16);
    uint8_t *ec = inctx + 2 * ctx_sz;
    *(uint32_t *)(ec + 4) = (4u << 3) | (3u << 1) | ((uint32_t)mps0 << 16);
    *(uint32_t *)(ec + 8) = (uint32_t)ep0 | 1u;
    *(uint32_t *)(ec + 16) = 8;
    dcbaa[slot] = (uint32_t)devctx;
    if (cmd_run((uint32_t)inctx, 0, 0, (11u << 10) | ((uint32_t)slot << 24), 0) != 1) {
        print("xhci: Address Device failed\r\n"); return 0;
    }

    uint8_t *desc = zpage(4096);
    if (!desc) { print("xhci: OOM\r\n"); return 0; }
    if (!ctrl_xfer(0x01000680u, 18u << 16, desc, 18, 1)) { print("xhci: Get Device Descriptor failed\r\n"); return 0; }
    printf("xhci: USB device %x:%x (class %d)\r\n",
           desc[8] | (desc[9] << 8), desc[10] | (desc[11] << 8), desc[4]);

    /* -- config descriptor: find the MSC interface + bulk endpoints --- */
    uint8_t *cfg = zpage(4096);
    if (!cfg) { print("xhci: OOM\r\n"); return 0; }
    if (!ctrl_xfer(0x02000680u, 9u << 16, cfg, 9, 1)) { print("xhci: get config (9) failed\r\n"); return 0; }
    int total = cfg[2] | (cfg[3] << 8);
    if (total > 4096) total = 4096;
    if (!ctrl_xfer(0x02000680u, (uint32_t)total << 16, cfg, total, 1)) { print("xhci: get config failed\r\n"); return 0; }
    int cfgval = cfg[5];
    dci_out = dci_in = 0;
    for (int i = 0; i + 1 < total; ) {
        int len = cfg[i], typ = cfg[i + 1];
        if (!len) break;
        if (typ == 5 && (cfg[i + 3] & 0x3) == 2) {        /* endpoint, bulk */
            int addr = cfg[i + 2], ep = addr & 0xf, m = cfg[i + 4] | (cfg[i + 5] << 8);
            if (addr & 0x80) { dci_in  = 2 * ep + 1; mps_in  = m; }
            else             { dci_out = 2 * ep;     mps_out = m; }
        }
        i += len;
    }
    if (!dci_in || !dci_out) { print("xhci: no MSC bulk endpoints found\r\n"); return 0; }

    /* -- Configure Endpoint: add the two bulk endpoints to the slot --- */
    b_out = zpage(RING_SZ * 16); bo_i = 0; bo_cyc = 1;
    b_in  = zpage(RING_SZ * 16); bi_i = 0; bi_cyc = 1;
    if (!b_out || !b_in) { print("xhci: OOM\r\n"); return 0; }
    ring_link(b_out); ring_link(b_in);
    int maxdci = dci_in > dci_out ? dci_in : dci_out;
    memset(inctx, 0, 4096);
    *(uint32_t *)(inctx + 4) = 1u | (1u << dci_out) | (1u << dci_in);   /* A0 + both EPs */
    sc = inctx + ctx_sz;
    *(uint32_t *)(sc + 0) = ((uint32_t)maxdci << 27) | ((uint32_t)speed << 20);
    *(uint32_t *)(sc + 4) = ((uint32_t)(port + 1) << 16);
    uint8_t *eo = inctx + (1 + dci_out) * ctx_sz;
    *(uint32_t *)(eo + 4) = (2u << 3) | (3u << 1) | ((uint32_t)mps_out << 16);   /* bulk OUT */
    *(uint32_t *)(eo + 8) = (uint32_t)b_out | 1u;
    *(uint32_t *)(eo + 16) = mps_out;
    uint8_t *ei = inctx + (1 + dci_in) * ctx_sz;
    *(uint32_t *)(ei + 4) = (6u << 3) | (3u << 1) | ((uint32_t)mps_in << 16);    /* bulk IN */
    *(uint32_t *)(ei + 8) = (uint32_t)b_in | 1u;
    *(uint32_t *)(ei + 16) = mps_in;
    if (cmd_run((uint32_t)inctx, 0, 0, (12u << 10) | ((uint32_t)slot << 24), 0) != 1) {
        print("xhci: Configure Endpoint failed\r\n"); return 0;
    }
    /* SET_CONFIGURATION(cfgval) - no data stage */
    if (!ctrl_xfer(0x00000900u | ((uint32_t)cfgval << 16), 0, 0, 0, 0)) {
        print("xhci: SET_CONFIGURATION failed\r\n"); return 0;
    }
    cbw = zpage(4096); csw = zpage(4096);
    if (!cbw || !csw) { print("xhci: OOM\r\n"); return 0; }
    print("xhci: MSC endpoints configured\r\n");
    return 1;
}

/* read or write one 512-byte block at USB LBA via SCSI READ(10)/WRITE(10). */
static int usb_block(uint32_t lba, uint8_t *buf, int wr) {
    uint8_t cdb[16]; memset(cdb, 0, 16);
    cdb[0] = wr ? 0x2a : 0x28;
    cdb[2] = lba >> 24; cdb[3] = lba >> 16; cdb[4] = lba >> 8; cdb[5] = lba;
    cdb[8] = 1;                                   /* 1 block */
    return scsi(cdb, 10, buf, 512, wr ? 0 : 1);
}

/* `usb backup`: the diskless box loses its RAM-backed AgentFS slots on every
 * reboot. Copy the 8 slots (the LLM-written scripts) to a USB stick so they
 * survive locally - no dev-box proxy needed. */
static int usb_backup(int force) {
    uint8_t *buf = zpage(4096);
    if (!buf) { print("xhci: out of memory\r\n"); return 0; }
    /* backup raw-writes LBA 0-7 - that clobbers the boot sector of a FAT stick.
     * Refuse if LBA 0 looks like a real filesystem (FAT VBR / MBR / GPT) unless
     * the user forces it, mirroring how diskon protects a foreign disk. */
    if (!force && usb_block(0, buf, 0) == 0) {
        int fatsig = (buf[54]=='F'&&buf[55]=='A'&&buf[56]=='T') ||
                     (buf[82]=='F'&&buf[83]=='A'&&buf[84]=='T');
        int mbrsig = (buf[510]==0x55 && buf[511]==0xAA);
        if (fatsig || mbrsig) {
            print("xhci: refusing 'usb backup' - the stick has a filesystem"
                  " (LBA 0-8 would be clobbered). Use 'usb backup force' to override.\r\n");
            return 0;
        }
    }
    int ok = 0;
    for (int n = 0; n < 8; n++) {
        if (sys_read_sectors(257 + n, 1, buf) != 1) { printf("xhci: read slot %d failed\r\n", n); continue; }
        if (usb_block((uint32_t)n, buf, 1) != 0)    { printf("xhci: USB write blk %d failed\r\n", n); continue; }
        ok++;
    }
    printf("xhci: backed up %d AgentFS slots to USB\r\n", ok);
    return 0;
}

/* `usb restore`: write the slots back from the stick into the RAM-backed
 * AgentFS (needs diskon, the same latch as save/llmscript). */
static int usb_restore(void) {
    uint8_t *buf = zpage(4096);
    if (!buf) { print("xhci: out of memory\r\n"); return 0; }
    int ok = 0;
    for (int n = 0; n < 8; n++) {
        if (usb_block((uint32_t)n, buf, 0) != 0)  { printf("xhci: USB read blk %d failed\r\n", n); continue; }
        if (sys_write_slot(n, buf) != 0)          { printf("xhci: write slot %d refused (diskon?)\r\n", n); continue; }
        ok++;
    }
    printf("xhci: restored %d AgentFS slots from USB\r\n", ok);
    return 0;
}

/* the block reader the shared FAT layer (fatfs.c) calls for `usb ls/cat/load` */
static int usb_rb(uint32_t lba, uint8_t *buf) { return usb_block(lba, buf, 0); }
static int usb_wb(uint32_t lba, uint8_t *buf) { return usb_block(lba, buf, 1); }

/* usb save <file> <slot>: write an AgentFS slot out as a FAT16 file on the stick
 * (inverse of usb load). The bare-metal test PC has xHCI, so this saves to a REAL USB stick a PC
 * reads. */
static int usb_save(const char *fn, int slot) {
    if (!fn || !*fn || *fn == ' ') { print("usb: usage: usb save <file> <slot>\r\n"); return 0; }
    if (slot < 0 || slot > 7) { print("usb: slot must be 0-7\r\n"); return 0; }
    static uint8_t sec[512];
    if (sys_read_sectors(257 + slot, 1, sec) != 1 || sec[0] != 'A' || sec[1] != 'F') {
        print("usb: empty/bad slot - 'save <slot> <text>' first\r\n"); return 0;
    }
    fat_use(usb_rb); fat_use_write(usb_wb);
    int r = fat_save(fn, sec + 3, sec[2]);
    if (r == 0) printf("usb: wrote slot %d (%d bytes) -> %s\r\n", slot, sec[2], fn);
    else printf("usb: save failed (%d): need a FAT16/32 disk, free space\r\n", r);
    return 0;
}

/* usb copy <src> <dst>: duplicate a file on the stick (multi-cluster capable) */
static int usb_copy(const char *src, const char *dst) {
    if (!src || !*src || !dst || !*dst || *dst == ' ') { print("usb: usage: usb copy <src> <dst>\r\n"); return 0; }
    fat_use(usb_rb); fat_use_write(usb_wb);
    int r = fat_copy(src, dst);
    if (r == 0) print("usb: copied\r\n");
    else printf("usb: copy failed (%d): FAT16/32 stick, src exists, free space?\r\n", r);
    return 0;
}

/* the file API for other programs (user/edit.c): enumerate the stick once,
 * then read/write FAT files. usb_fat() probes quietly when there is no xHCI. */
static int usb_ready;
static int usb_ensure(void) {
    if (!usb_ready) { if (!xhci_up()) return 0; fat_use(usb_rb); fat_use_write(usb_wb); usb_ready = 1; }
    return 1;
}
int usb_fat(void) {
    if (pci_find_class(0x0c0330, 0xffffff) < 0) return 0;
    return usb_ensure() && fat_present();
}
int usb_file(const char *name, uint8_t *buf, int cap) {
    if (!usb_ensure()) return -1;
    return fat_file(name, buf, cap);
}
int usb_savefile(const char *name, const uint8_t *data, int len) {
    if (!usb_ensure()) return -1;
    return fat_save(name, data, (uint32_t)len);
}

/* destructive scratch self-test: write a pattern to LBA 0 and read it back */
static int usb_test(void) {
    uint8_t *data = zpage(4096); uint8_t cdb[16];
    for (int i = 0; i < 512; i++) data[i] = (uint8_t)(i ^ 0x3c);
    memset(cdb, 0, 16); cdb[0] = 0x2a; cdb[8] = 1;
    if (scsi(cdb, 10, data, 512, 0) != 0) { print("xhci: WRITE(10) failed\r\n"); return 0; }
    memset(data, 0, 512);
    memset(cdb, 0, 16); cdb[0] = 0x28; cdb[8] = 1;
    if (scsi(cdb, 10, data, 512, 1) != 0) { print("xhci: READ(10) failed\r\n"); return 0; }
    int good = 1;
    for (int i = 0; i < 512; i++) if (data[i] != (uint8_t)(i ^ 0x3c)) { good = 0; break; }
    if (good) print("xhci: write+read LBA 0 verified - USB mass storage works\r\n");
    else      print("xhci: VERIFY FAILED - read back wrong data\r\n");
    return 0;
}

/* read-only INQUIRY + READ CAPACITY (shared banner) */
static void usb_inquiry(void) {
    uint8_t *data = zpage(4096); uint8_t cdb[16];
    memset(cdb, 0, 16); cdb[0] = 0x12; cdb[4] = 36;
    if (scsi(cdb, 6, data, 36, 1) == 0) {
        char v[9], pr[17]; int i;
        for (i = 0; i < 8; i++)  v[i]  = data[8 + i];  v[8]  = 0;
        for (i = 0; i < 16; i++) pr[i] = data[16 + i]; pr[16] = 0;
        printf("xhci: INQUIRY '%s' '%s'\r\n", v, pr);
    }
    memset(cdb, 0, 16); cdb[0] = 0x25;
    if (scsi(cdb, 10, data, 8, 1) == 0)
        printf("xhci: capacity %d blocks x %d bytes\r\n",
               ((data[0]<<24)|(data[1]<<16)|(data[2]<<8)|data[3]) + 1,
               (data[4]<<24)|(data[5]<<16)|(data[6]<<8)|data[7]);
}

static int kwmatch(const char *p, const char *kw) {
    while (*kw) { if (*p != *kw) return 0; p++; kw++; }
    return *p == 0 || *p == ' ';
}
/* skip a word then the spaces after it -> the next argument */
static const char *next_arg(const char *p) {
    while (*p && *p != ' ') p++; while (*p == ' ') p++; return p;
}

int xhci_main(void) {
    /* usb [test|ls|cat <f>|load <f> <slot>|backup|restore]; bare = read-only info */
    const char *arg = (const char *)0x007FF000;
    const char *p = arg + 3; while (*p == ' ') p++;
    const char *fn = 0, *fn2 = 0; int mode = 0, slot = 0, force = 0;
    if      (kwmatch(p, "test"))    mode = 1;
    else if (kwmatch(p, "backup")) { mode = 2; force = kwmatch(next_arg(p), "force"); }
    else if (kwmatch(p, "restore")) mode = 3;
    else if (kwmatch(p, "ls"))      mode = 4;
    else if (kwmatch(p, "cat"))   { mode = 5; fn = next_arg(p); }
    else if (kwmatch(p, "load"))  { mode = 6; fn = next_arg(p);
        const char *s = next_arg(fn);                /* the slot number after the name */
        slot = (*s >= '0' && *s <= '9') ? *s - '0' : -1; }
    else if (kwmatch(p, "save"))  { mode = 7; fn = next_arg(p);
        const char *s = next_arg(fn);
        slot = (*s >= '0' && *s <= '9') ? *s - '0' : -1; }
    else if (kwmatch(p, "copy"))  { mode = 8; fn = next_arg(p); fn2 = next_arg(fn); }

    print("xhci: USB mass-storage driver\r\n");
    if (!xhci_up()) return 0;
    if (mode == 2) return usb_backup(force);
    if (mode == 3) return usb_restore();
    if (mode == 7) return usb_save(fn, slot);
    if (mode == 8) return usb_copy(fn, fn2);
    fat_use(usb_rb);                                 /* the shared FAT layer reads via USB */
    if (mode == 4) return fat_ls();
    if (mode == 5) return fat_cat(fn);
    if (mode == 6) return fat_load(fn, slot);

    usb_inquiry();
    if (mode == 1) return usb_test();                /* explicit, destructive */
    if (fat_present()) fat_ls();
    else print("xhci: raw block device (no FAT) - 'usb test' to verify R/W\r\n");
    return 0;
}

/* bring the device up and register it with the FAT layer, for the apps that
 * just want "a FAT volume" (run files, run shot). 1 = mounted a FAT. */
int usb_mount(void) {
    static int up;
    if (!up) { if (!xhci_up()) return 0; up = 1; }
    fat_use(usb_rb); fat_use_write(usb_wb);
    return fat_present();
}
