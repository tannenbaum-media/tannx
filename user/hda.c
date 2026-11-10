/* hda.c - Intel HD Audio driver in ring-3 C.
 *
 * The kernel stays tiny: it only lends us PCI config access (SYS_PCI)
 * and an uncached user mapping of the controller's MMIO BAR
 * (SYS_MMIO_MAP). Everything else - reset, codec discovery over the
 * IMMEDIATE command interface (no CORB/RIRB rings needed), widget
 * setup, BDL, stream DMA - happens here. User memory is identity-
 * mapped physical, so our malloc'd buffers are DMA-able as-is.
 *
 * QEMU: -device intel-hda -device hda-output,audiodev=...
 * Headless-verifiable like the AC97 driver: LPIB (link position in
 * buffer) is printed mid-play, so the gate asserts the DMA engine
 * really streams samples. A real codec on the bare-metal test PC speaks the
 * same protocol. */
#include "libc.h"

static volatile uint8_t *mmio;

static uint32_t rd32(int off)            { return *(volatile uint32_t *)(mmio + off); }
static void     wr32(int off, uint32_t v){ *(volatile uint32_t *)(mmio + off) = v; }
static uint16_t rd16(int off)            { return *(volatile uint16_t *)(mmio + off); }
static void     wr16(int off, uint16_t v){ *(volatile uint16_t *)(mmio + off) = v; }
static uint8_t  rd8(int off)             { return *(volatile uint8_t *)(mmio + off); }
static void     wr8(int off, uint8_t v)  { *(volatile uint8_t *)(mmio + off) = v; }

static void spin(int loops) { for (volatile int i = 0; i < loops; i++) ; }

/* one codec verb over the Immediate Command interface (regs 0x60/0x64/
 * 0x68) - QEMU and real ICH support it; saves the whole CORB/RIRB setup */
static uint32_t verb(int cad, int nid, uint32_t v) {
    int t;
    for (t = 0; t < 100000 && (rd16(0x68) & 1); t++) if ((t & 0x3ff) == 0x3ff) sys_yield();   /* !ICB */
    wr16(0x68, 2);                                       /* clear stale IRV */
    wr32(0x60, ((uint32_t)cad << 28) | ((uint32_t)nid << 20) | v);
    wr16(0x68, 1);                                       /* ICB: go */
    for (t = 0; t < 100000 && !(rd16(0x68) & 2); t++) if ((t & 0x3ff) == 0x3ff) sys_yield();  /* IRV */
    return rd32(0x64);
}
#define GET_PARAM(cad, nid, p)  verb(cad, nid, 0xF0000u | (p))

int hda_main(void) {
    print("HDA: ring-3 driver (2b)\r\n");

    /* -- find the controller: class 04.03 (audio device), any prog-if -- */
    int bdf = pci_find_class(0x040300, 0xffff00);
    if (bdf < 0) { print("HDA: no controller (QEMU: -device intel-hda -device hda-output)\r\n"); return 0; }
    uint32_t id = pci_rd(bdf, 0);
    printf("HDA: %x:%x @dev %d\r\n", id & 0xffff, id >> 16, bdf >> 3);

    uint32_t cmd = pci_rd(bdf, 4);
    pci_wr(bdf, 4, cmd | 6);                             /* MEM + master */
    uint32_t va = pci_map_bar(bdf, 0, "HDA");
    if (!va) return 0;
    mmio = (volatile uint8_t *)va;
    printf("HDA: BAR0 %x mapped\r\n", va);

    /* -- controller reset (GCTL.CRST) -------------------------------- */
    wr32(0x08, 0);                                       /* assert reset */
    { int t; for (t = 0; t < 100000 && (rd32(0x08) & 1); t++) if ((t & 0x3ff) == 0x3ff) sys_yield(); }
    wr32(0x08, 1);                                       /* deassert */
    { int t; for (t = 0; t < 100000 && !(rd32(0x08) & 1); t++) if ((t & 0x3ff) == 0x3ff) sys_yield(); }
    spin(300000);                                        /* codec wake-up */
    uint16_t codecs = rd16(0x0E);                        /* STATESTS bits */
    if (!codecs) { print("HDA: no codec answered\r\n"); return 0; }
    int cad = 0;
    while (!(codecs & (1 << cad))) cad++;

    /* -- walk the codec: find the AFG, then a DAC and an output pin -- */
    uint32_t vid = GET_PARAM(cad, 0, 0x00);
    uint32_t sub = GET_PARAM(cad, 0, 0x04);              /* nodes under root */
    int afg = (sub >> 16) & 0xff, nafg = sub & 0xff;
    int fn = afg, i;
    for (i = 0; i < nafg; i++)                            /* type 0x01 = AFG */
        if ((GET_PARAM(cad, afg + i, 0x05) & 0xff) == 0x01) { fn = afg + i; break; }
    sub = GET_PARAM(cad, fn, 0x04);
    int wstart = (sub >> 16) & 0xff, wcount = sub & 0xff;
    int dac = 0, pin = 0;
    for (i = 0; i < wcount; i++) {
        uint32_t caps = GET_PARAM(cad, wstart + i, 0x09);
        int type = (caps >> 20) & 0xf;
        if (type == 0x0 && !dac) dac = wstart + i;       /* audio output */
        if (type == 0x4 && !pin) pin = wstart + i;       /* pin complex */
    }
    printf("HDA: codec %x cad %d afg %d dac %d pin %d\r\n", vid, cad, fn, dac, pin);
    if (!dac || !pin) { print("HDA: no output path on this codec\r\n"); return 0; }

    /* -- power up + route: pin out-enable, amps unmuted, fmt + stream - */
    verb(cad, fn,  0x70500);                  /* AFG power state D0 */
    verb(cad, dac, 0x70500);
    verb(cad, pin, 0x70500);
    verb(cad, pin, 0x70740);                  /* pin widget control: OUT */
    verb(cad, pin, 0x70c02);                  /* EAPD on (real codecs) */
    verb(cad, dac, 0x3B03F);                  /* amp: out, L+R, unmute, gain 0x3f */
    verb(cad, pin, 0x3B03F);
    verb(cad, dac, 0x20000 | 0x0011);         /* converter fmt 48k/16/2ch */
    verb(cad, dac, 0x70610);                  /* stream 1, channel 0 */

    /* -- tone: 1 s 440 Hz square, 48 kHz 16-bit stereo --------------- */
    int frames = 48000, bytes = frames * 4;
    uint8_t *raw = malloc(bytes + 256);
    uint8_t *braw = malloc(64 + 256);          /* BDL: 128-byte aligned */
    if (!raw || !braw) { print("hda: out of memory\r\n"); return 0; }
    int16_t *pcm = (int16_t *)(((uint32_t)raw + 127) & ~127u);
    int16_t amp = 0x3000; int half = 54, ph = half;
    for (i = 0; i < frames; i++) {
        pcm[2 * i] = amp; pcm[2 * i + 1] = amp;
        if (--ph == 0) { amp = (int16_t)-amp; ph = half; }
    }
    uint32_t *bdl = (uint32_t *)(((uint32_t)braw + 127) & ~127u);
    bdl[0] = (uint32_t)pcm;            bdl[1] = 0;
    bdl[2] = (uint32_t)bytes / 2;      bdl[3] = 0;       /* entry 0: 0.5 s */
    bdl[4] = (uint32_t)pcm + bytes / 2; bdl[5] = 0;
    bdl[6] = (uint32_t)bytes / 2;      bdl[7] = 1;       /* entry 1 + IOC */

    /* -- output stream descriptor: first one after the input streams - */
    int iss = (rd16(0x00) >> 8) & 0xf;                   /* GCAP.ISS */
    int sd = 0x80 + iss * 0x20;
    wr8(sd + 0, 1);                                      /* SRST */
    { int t; for (t = 0; t < 100000 && !(rd8(sd) & 1); t++) if ((t & 0x3ff) == 0x3ff) sys_yield(); }
    wr8(sd + 0, 0);
    { int t; for (t = 0; t < 100000 && (rd8(sd) & 1); t++) if ((t & 0x3ff) == 0x3ff) sys_yield(); }
    wr32(sd + 0x18, (uint32_t)bdl);                      /* BDPL */
    wr32(sd + 0x1C, 0);                                  /* BDPU */
    wr32(sd + 0x08, (uint32_t)bytes);                    /* CBL */
    wr16(sd + 0x0C, 1);                                  /* LVI: 2 entries */
    wr16(sd + 0x12, 0x0011);                             /* SDFMT 48k/16/2 */
    wr8(sd + 2, 0x10);                                   /* stream number 1 */
    print("HDA: playing 440 Hz, 1 s, 48 kHz 16-bit stereo ...\r\n");
    wr8(sd + 0, 2);                                      /* RUN */

    uint32_t t0 = sys_uptime();
    while (sys_uptime() - t0 < 9) sys_yield();           /* ~0.5 s */
    printf("HDA: progress lpib=%u of %u\r\n", rd32(sd + 4), (uint32_t)bytes);
    t0 = sys_uptime();
    while (sys_uptime() - t0 < 36) {                     /* wait for the end */
        if (rd8(sd + 3) & 4) break;                      /* SDSTS.BCIS */
        sys_yield();
    }
    wr8(sd + 0, 0);                                      /* stop DMA */
    printf("HDA: done, sts=%x lpib=%u\r\n", rd8(sd + 3), rd32(sd + 4));
    return 0;
}
