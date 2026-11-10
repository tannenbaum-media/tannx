/* virtio.c - the shared virtio-1.0 PCI bring-up (see virtio.h). Extracted
 * verbatim from the identical setup that vgpu.c and vblk.c each carried. */
#include "virtio.h"

#define CC32(o) (*(volatile uint32_t *)(v->cc + (o)))
#define CC16(o) (*(volatile uint16_t *)(v->cc + (o)))
#define CC8(o)  (*(volatile uint8_t  *)(v->cc + (o)))

int virtio_init(struct virtio_dev *v, int bdf, int min_qsz, const char *tag) {
    pci_wr(bdf, 4, pci_rd(bdf, 4) | 6);          /* MEM + bus master */

    /* -- walk the virtio PCI caps: common / notify / device config ----- */
    int common_bar = -1, notify_bar = -1, dev_bar = -1;
    uint32_t common_off = 0, notify_off = 0, dev_off = 0;
    uint8_t cap = pci_rd8(bdf, 0x34); int guard = 0;
    while (cap && guard++ < 48) {
        uint8_t cid = pci_rd8(bdf, cap), nxt = pci_rd8(bdf, cap + 1);
        if (cid == 0x09) {
            uint8_t cfgtype = pci_rd8(bdf, cap + 3), barno = pci_rd8(bdf, cap + 4);
            uint32_t off = pci_rd(bdf, cap + 8);
            if (cfgtype == 1) { common_bar = barno; common_off = off; }
            else if (cfgtype == 2) { notify_bar = barno; notify_off = off; v->notify_mult = pci_rd(bdf, cap + 16); }
            else if (cfgtype == 4) { dev_bar = barno; dev_off = off; }
        }
        cap = nxt;
    }
    if (common_bar < 0 || notify_bar < 0) { printf("%s: missing virtio caps\r\n", tag); return 0; }

    uint32_t va = pci_map_bar(bdf, common_bar, tag);   /* notify/dev are offsets in the same BAR */
    if (!va) return 0;
    v->cc = (volatile uint8_t *)(va + common_off);
    v->notify = (volatile uint8_t *)(va + notify_off);
    v->devcfg = (dev_bar >= 0) ? (volatile uint8_t *)(va + dev_off) : 0;
    printf("%s: mapped BAR%d @%x; %d queues\r\n", tag, common_bar, va, CC16(18));

    /* -- device-init handshake (ACK|DRIVER|VERSION_1|FEATURES_OK|DRIVER_OK) -- */
    CC8(20) = 0; (void)CC8(20);                  /* reset */
    CC8(20) = 1; CC8(20) = 1 | 2;                /* ACKNOWLEDGE | DRIVER */
    CC32(0) = 1; uint32_t fhi = CC32(4);         /* device features, word 1 (bit32+) */
    CC32(8) = 1; CC32(12) = (fhi & 1);           /* accept VIRTIO_F_VERSION_1 (bit32) */
    CC32(8) = 0; CC32(12) = 0;                    /* no low features */
    CC8(20) = 1 | 2 | 8;                          /* FEATURES_OK */
    if (!(CC8(20) & 8)) { printf("%s: FEATURES_OK rejected\r\n", tag); return 0; }

    /* -- virtqueue 0 in user RAM (identity-mapped = DMA-able) ----------- */
    CC16(22) = 0;                                 /* queue_select = 0 */
    v->qsz = CC16(24);
    if (v->qsz < min_qsz || v->qsz > 1024) { printf("%s: bad queue size %d\r\n", tag, v->qsz); return 0; }
    v->q_notify_off = CC16(30);
    int qsz = v->qsz;
    v->desc   = malloc(16 * qsz);
    v->avail  = malloc(6 + 2 * qsz);
    v->used16 = malloc(6 + 8 * qsz);
    if (!v->desc || !v->avail || !v->used16) { printf("%s: OOM\r\n", tag); return 0; }
    memset(v->desc, 0, 16 * qsz);
    memset((void *)v->avail, 0, 6 + 2 * qsz);
    memset((void *)v->used16, 0, 6 + 8 * qsz);
    CC32(32) = (uint32_t)v->desc;   CC32(36) = 0; /* queue_desc   */
    CC32(40) = (uint32_t)v->avail;  CC32(44) = 0; /* queue_driver */
    CC32(48) = (uint32_t)v->used16; CC32(52) = 0; /* queue_device */
    CC16(28) = 1;                                 /* queue_enable */
    CC8(20) = 1 | 2 | 8 | 4;                       /* DRIVER_OK */
    v->avail_idx = 0; v->last_used = 0;
    return 1;
}
