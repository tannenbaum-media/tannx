/* virtio.h - shared modern (virtio-1.0) PCI transport for the ring-3 drivers.
 *
 * vgpu.c and vblk.c both bring a virtio device up the same way: enable the
 * PCI command bits, walk the vendor capabilities to the config regions in the
 * MMIO BAR, run the device-init handshake (ACK/DRIVER/VERSION_1/FEATURES_OK/
 * DRIVER_OK), and set up split virtqueue 0 in identity-mapped (DMA-able) user
 * RAM. virtio_init() does all of that; each driver keeps its own device-ID
 * match and its own request protocol (the descriptor chains differ). */
#ifndef VIRTIO_H
#define VIRTIO_H
#include "libc.h"

/* split-virtqueue descriptor (64-bit addr field; libc.h is otherwise 32-bit) */
struct vq_desc { unsigned long long addr; uint32_t len; uint16_t flags; uint16_t next; };
#define VQ_NEXT  1
#define VQ_WRITE 2

/* everything virtio_init() discovers/allocates - the caller plumbs these into
 * its own driver state and drives virtqueue 0 with them. */
struct virtio_dev {
    volatile uint8_t *cc;        /* common config region (BAR + common_off)   */
    volatile uint8_t *notify;    /* notify region base                        */
    volatile uint8_t *devcfg;    /* device-specific config (0 if none)        */
    uint32_t notify_mult;        /* notify_off_multiplier                     */
    struct vq_desc *desc;        /* queue 0: descriptor table                 */
    volatile uint16_t *avail;    /*          available ring                   */
    volatile uint16_t *used16;   /*          used ring (byte-indexed)         */
    int qsz;                     /*          queue size                       */
    uint16_t avail_idx;          /*          our running available index      */
    uint16_t last_used;          /*          last seen used.idx               */
    uint16_t q_notify_off;       /*          queue_notify_off                 */
};

/* bring the virtio device at `bdf` up: enable, cap-walk, map the BAR, run the
 * init handshake, allocate + program virtqueue 0, and set DRIVER_OK. min_qsz
 * rejects a queue too small for the caller's chain; tag prefixes any error.
 * Fills *v. Returns 1 on success, 0 on failure. */
int virtio_init(struct virtio_dev *v, int bdf, int min_qsz, const char *tag);

#endif
