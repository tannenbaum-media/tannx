/* audio.c - the shared Intel HDA engine for the sound apps (ring 3).
 *
 * user/hda.c is the one-shot driver test ('hda': play a tone, print LPIB).
 * This file is the reusable engine behind the recorder, the synthesizer,
 * the voice wish and the system sounds: the same bring-up (SYS_PCI +
 * SYS_MMIO_MAP, immediate command interface, no CORB/RIRB), plus
 *
 *   - a cyclic OUTPUT ring: AU_NCHUNK BDL entries of AU_CHUNK frames; the
 *     app renders chunks a few entries ahead of LPIB (low latency: AU_LEAD
 *     chunks = ~32 ms), the DMA engine loops the BDL forever;
 *   - a cyclic INPUT ring on the first input stream descriptor: the codec's
 *     ADC streams the microphone/line-in into it, the app consumes chunks
 *     as LPIB passes them;
 *   - codec discovery of BOTH paths: DAC + output pin, ADC + input pin
 *     (mic preferred over line-in by the pin's default config), the ADC's
 *     connection select pointed at that pin, input amp unmuted at 0 dB.
 *
 * Everything is polled (LPIB), nothing needs an interrupt. The gate cannot
 * hear, so tests assert DMA progress (LPIB) and the samples the engine
 * actually produced/consumed (peaks printed by the apps).
 *
 * QEMU: -device intel-hda -device hda-duplex,audiodev=a0 (line-out + line-in)
 *       or hda-micro (speaker + microphone). With -audiodev none the input
 *       is silence at the right rate (DMA still runs); the apps' 'test'
 *       mode injects au_test_pattern() so headless runs see real samples.
 * Real hardware: a codec on the bare-metal test PC speaks the same verbs; the
 *       mic path is UNTESTED on silicon (see docs/BARE-METAL.md). */
#include "audio.h"
#include "sintab.h"

static volatile uint8_t *mmio;
static int sd_out, sd_in;                    /* stream descriptor register bases */
static int out_wr, in_rd, out_on, in_on;
int16_t *au_out_ring, *au_in_ring;
int au_out_underruns, au_in_overruns;
int au_cad, au_afg, au_dac, au_opin, au_adc, au_ipin;

static uint32_t rd32(int o)             { return *(volatile uint32_t *)(mmio + o); }
static void     wr32(int o, uint32_t v) { *(volatile uint32_t *)(mmio + o) = v; }
static uint16_t rd16(int o)             { return *(volatile uint16_t *)(mmio + o); }
static void     wr16(int o, uint16_t v) { *(volatile uint16_t *)(mmio + o) = v; }
static uint8_t  rd8(int o)              { return *(volatile uint8_t *)(mmio + o); }
static void     wr8(int o, uint8_t v)   { *(volatile uint8_t *)(mmio + o) = v; }

/* poll until (reg8 & mask) == want, yielding now and then; 0 on timeout */
static int wait8(int o, int mask, int want) {
    for (int t = 0; t < 200000; t++) {
        if ((rd8(o) & mask) == want) return 1;
        if ((t & 0x3ff) == 0x3ff) sys_yield();
    }
    return 0;
}

/* one codec verb over the Immediate Command interface (0x60/0x64/0x68) */
static uint32_t verb(int nid, uint32_t v) {
    wait8(0x68, 1, 0);                                   /* !ICB */
    wr16(0x68, 2);                                       /* clear stale IRV */
    wr32(0x60, ((uint32_t)au_cad << 28) | ((uint32_t)nid << 20) | v);
    wr16(0x68, 1);                                       /* ICB: go */
    wait8(0x68, 2, 2);                                   /* IRV */
    return rd32(0x64);
}
#define PARAM(nid, p) verb(nid, 0xF0000u | (p))

/* reset one stream descriptor and point it at a cyclic ring */
static void sd_setup(int sd, uint32_t *bdl, const void *ring, int stream_no) {
    wr8(sd + 0, 1);  wait8(sd, 1, 1);                    /* SRST in */
    wr8(sd + 0, 0);  wait8(sd, 1, 0);                    /* SRST out */
    for (int i = 0; i < AU_NCHUNK; i++) {
        bdl[i * 4 + 0] = (uint32_t)ring + i * AU_CHUNK_BYTES;
        bdl[i * 4 + 1] = 0;
        bdl[i * 4 + 2] = AU_CHUNK_BYTES;
        bdl[i * 4 + 3] = 0;                              /* no IOC: we poll LPIB */
    }
    wr32(sd + 0x18, (uint32_t)bdl);                      /* BDPL */
    wr32(sd + 0x1C, 0);                                  /* BDPU */
    wr32(sd + 0x08, AU_RING_BYTES);                      /* CBL */
    wr16(sd + 0x0C, AU_NCHUNK - 1);                      /* LVI */
    wr16(sd + 0x12, 0x0011);                             /* 48 kHz / 16-bit / 2 ch */
    wr8(sd + 2, (uint8_t)(stream_no << 4));              /* stream number */
}

int au_has_in(void) { return au_adc && au_ipin; }

int au_init(int verbose) {
    if (mmio) return 0;                                  /* already up */
    int bdf = pci_find_class(0x040300, 0xffff00);
    if (bdf < 0) {
        if (verbose) print("audio: no HDA controller (QEMU: -device intel-hda -device hda-duplex,audiodev=a0)\r\n");
        return -1;
    }
    pci_wr(bdf, 4, pci_rd(bdf, 4) | 6);                  /* MEM + bus master */
    uint32_t va = pci_map_bar(bdf, 0, "audio");
    if (!va) return -1;
    mmio = (volatile uint8_t *)va;

    wr32(0x08, 0); { int t = 0; while (t++ < 100000 && (rd32(0x08) & 1)) ; }   /* CRST */
    wr32(0x08, 1); { int t = 0; while (t++ < 100000 && !(rd32(0x08) & 1)) ; }
    for (volatile int i = 0; i < 300000; i++) ;          /* codec wake-up */
    uint16_t codecs = rd16(0x0E);                        /* STATESTS */
    if (!codecs) { if (verbose) print("audio: no codec answered\r\n"); mmio = 0; return -1; }
    au_cad = 0;
    while (!(codecs & (1 << au_cad))) au_cad++;

    /* the AFG, then every widget: DAC, ADC and the two pins */
    uint32_t sub = PARAM(0, 0x04);
    int n0 = (sub >> 16) & 0xff, nn = sub & 0xff;
    au_afg = n0;
    for (int i = 0; i < nn; i++)
        if ((PARAM(n0 + i, 0x05) & 0xff) == 0x01) { au_afg = n0 + i; break; }
    verb(au_afg, 0x70500);                               /* AFG to D0 */
    sub = PARAM(au_afg, 0x04);
    int w0 = (sub >> 16) & 0xff, wn = sub & 0xff;
    au_dac = au_adc = au_opin = au_ipin = 0;
    int ipin_mic = 0;
    for (int i = 0; i < wn; i++) {
        int nid = w0 + i;
        int type = (PARAM(nid, 0x09) >> 20) & 0xf;
        if (type == 0x0 && !au_dac) au_dac = nid;       /* audio output (DAC)  */
        if (type == 0x1 && !au_adc) au_adc = nid;       /* audio input (ADC)   */
        if (type == 0x4) {                              /* pin complex         */
            uint32_t pc = PARAM(nid, 0x0C);
            if ((pc & 0x10) && !au_opin) au_opin = nid; /* output capable      */
            if (pc & 0x20) {                            /* input capable       */
                int dev = (verb(nid, 0xF1C00) >> 20) & 0xf;   /* default device */
                int mic = (dev == 0xA);
                if (!au_ipin || (mic && !ipin_mic)) { au_ipin = nid; ipin_mic = mic; }
            }
        }
    }
    if (verbose)
        printf("audio: codec %x cad %d afg %d dac %d out-pin %d adc %d in-pin %d%s\r\n",
               PARAM(0, 0x00), au_cad, au_afg, au_dac, au_opin, au_adc, au_ipin,
               ipin_mic ? " (mic)" : "");
    if (!au_dac || !au_opin) { if (verbose) print("audio: no output path on this codec\r\n"); }

    /* playback path */
    if (au_dac && au_opin) {
        verb(au_dac, 0x70500); verb(au_opin, 0x70500);   /* D0 */
        verb(au_opin, 0x70740);                          /* pin: OUT enable  */
        verb(au_opin, 0x70c02);                          /* EAPD on          */
        verb(au_dac, 0x3B000 | (PARAM(au_dac, 0x12) & 0x7f));    /* out amp: unmute, 0 dB */
        verb(au_opin, 0x3B000 | (PARAM(au_opin, 0x12) & 0x7f));
        verb(au_dac, 0x20011);                           /* fmt 48k/16/2     */
        verb(au_dac, 0x70610);                           /* stream 1, ch 0   */
    }
    /* capture path: pin IN enable, ADC connection select -> that pin */
    if (au_adc && au_ipin) {
        verb(au_adc, 0x70500); verb(au_ipin, 0x70500);
        verb(au_ipin, 0x70720);                          /* pin: IN enable   */
        int cl = PARAM(au_adc, 0x0E) & 0x7f, sel = -1;
        for (int i = 0; i < cl && sel < 0; i += 4) {
            uint32_t e = verb(au_adc, 0xF0200 | i);
            for (int k = 0; k < 4 && i + k < cl; k++)
                if (((e >> (8 * k)) & 0xff) == (uint32_t)au_ipin) sel = i + k;
        }
        if (sel >= 0) verb(au_adc, 0x70100 | sel);
        verb(au_adc, 0x37000 | ((sel > 0 ? sel : 0) << 8) | (PARAM(au_adc, 0x0D) & 0x7f));
                                                         /* in amp (that input): unmute, 0 dB */
        verb(au_ipin, 0x37000 | (PARAM(au_ipin, 0x0D) & 0x7f));
        verb(au_adc, 0x20011);                           /* fmt 48k/16/2     */
        verb(au_adc, 0x70620);                           /* stream 2, ch 0   */
    }

    /* rings + BDLs (128-byte aligned, identity-mapped = DMA-able) */
    uint8_t *mem = zpage(2 * AU_RING_BYTES + 2 * 256);
    if (!mem) { print("audio: out of memory\r\n"); mmio = 0; return -1; }
    au_out_ring = (int16_t *)mem;
    au_in_ring  = (int16_t *)(mem + AU_RING_BYTES);
    uint32_t *bdl_out = (uint32_t *)(mem + 2 * AU_RING_BYTES);
    uint32_t *bdl_in  = (uint32_t *)(mem + 2 * AU_RING_BYTES + 256);
    int iss = (rd16(0x00) >> 8) & 0xf;                   /* GCAP.ISS */
    sd_in  = 0x80;
    sd_out = 0x80 + iss * 0x20;
    if (au_dac && au_opin) sd_setup(sd_out, bdl_out, au_out_ring, 1);
    if (au_adc && au_ipin && iss) sd_setup(sd_in, bdl_in, au_in_ring, 2);
    else au_adc = 0;
    return 0;
}

/* ---- output ring ----------------------------------------------------- */
uint32_t au_out_lpib(void) { return mmio ? rd32(sd_out + 4) : 0; }
void au_out_start(void) {
    if (!mmio || out_on) return;
    out_wr = AU_LEAD;                                    /* chunks 0..LEAD-1 are "rendered" (silent) */
    wr8(sd_out + 0, 2);                                  /* RUN */
    out_on = 1;
}
void au_out_stop(void) {
    if (!mmio || !out_on) return;
    wr8(sd_out + 0, 0);
    out_on = 0;
    memset(au_out_ring, 0, AU_RING_BYTES);
}
/* chunk index the app should render now (the one AU_LEAD entries ahead of
 * the DMA read position), or -1 when the ring is already filled that far */
int au_out_next(void) {
    if (!out_on) return -1;
    int cur = (int)(au_out_lpib() / AU_CHUNK_BYTES) & (AU_NCHUNK - 1);
    int ahead = (out_wr - cur) & (AU_NCHUNK - 1);
    if (ahead == 0) { au_out_underruns++; out_wr = (cur + 1) & (AU_NCHUNK - 1); ahead = 1; }
    if (ahead > AU_LEAD) return -1;
    int k = out_wr;
    out_wr = (out_wr + 1) & (AU_NCHUNK - 1);
    return k;
}

/* ---- input ring ------------------------------------------------------ */
uint32_t au_in_lpib(void) { return mmio && au_adc ? rd32(sd_in + 4) : 0; }
void au_in_start(void) {
    if (!mmio || !au_adc || in_on) return;
    in_rd = 0;
    wr8(sd_in + 0, 2);
    in_on = 1;
}
void au_in_stop(void) {
    if (!mmio || !in_on) return;
    wr8(sd_in + 0, 0);
    in_on = 0;
}
/* the oldest chunk the DMA engine has completely written and the app has
 * not consumed yet, or -1. Falling a whole ring behind skips to the newest. */
int au_in_next(void) {
    if (!in_on) return -1;
    int cur = (int)(au_in_lpib() / AU_CHUNK_BYTES) & (AU_NCHUNK - 1);
    int avail = (cur - in_rd) & (AU_NCHUNK - 1);
    if (avail == 0) return -1;
    if (avail == AU_NCHUNK - 1) { au_in_overruns++; in_rd = (cur + 1) & (AU_NCHUNK - 1); }
    int k = in_rd;
    in_rd = (in_rd + 1) & (AU_NCHUNK - 1);
    return k;
}

/* ---- helpers --------------------------------------------------------- */
/* 32-bit phase increment for hz at AU_RATE (= hz * 2^32 / 48000) without a
 * 64-bit divide: ring 3 links no libgcc, so no __udivdi3 */
uint32_t au_phase_inc(int hz) {
    uint32_t q = ((uint32_t)hz << 16) / AU_RATE, r = ((uint32_t)hz << 16) % AU_RATE;
    return (q << 16) + ((r << 16) / AU_RATE);
}
/* Q15 sine from the 256-entry Q12 table, linearly interpolated: good enough
 * that the sine voice has no audible table steps (8-bit index + 8-bit frac). */
int16_t au_sine(uint32_t phase) {
    int i = phase >> 24, f = (phase >> 16) & 0xff;
    int a = sintab[i], b = sintab[(i + 1) & 255];
    int v = (a + (((b - a) * f) >> 8)) * 8;             /* Q12 -> Q15 */
    return (int16_t)(v > 32767 ? 32767 : v);             /* 4096*8 would wrap */
}

/* blocking tone, up to one ring (~330 ms): the whole tone is rendered into
 * the ring first, the stream started, and we wait for LPIB to pass its end.
 * (The first version paced chunk by chunk with sys_yield between them -
 * every yield parks a thread for up to two 55 ms ticks, so a 110 ms note
 * took 2 s. Paid for while chasing a "DMA stall" that never existed.)
 * 5 ms fade in/out so it never clicks. vol 0..32767. */
void au_tone(int hz, int ms, int vol) {
    if (!mmio || !au_dac) return;
    int total = AU_RATE / 1000 * ms, fade = AU_RATE / 200;
    if (total > (AU_NCHUNK - 1) * AU_CHUNK) total = (AU_NCHUNK - 1) * AU_CHUNK;
    uint32_t ph = 0, inc = au_phase_inc(hz);
    au_out_stop();                                       /* stopped + zeroed ring */
    for (int i = 0; i < total; i++) {
        int env = vol;
        if (i < fade) env = vol * i / fade;
        else if (i > total - fade) env = vol * (total - i) / fade;
        int s = (au_sine(ph) * env) >> 15;
        ph += inc;
        au_out_ring[2 * i] = au_out_ring[2 * i + 1] = (int16_t)s;
    }
    au_out_start();
    uint32_t t0 = sys_uptime(), end = (uint32_t)total * 4;
    while (au_out_lpib() < end && sys_uptime() - t0 < 36) ;   /* busy: a yield costs 110 ms */
    au_out_stop();
}

void au_wav_header(uint8_t *h, int rate, int ch, uint32_t bytes) {
    static const char tag[] = "RIFF....WAVEfmt ";
    memcpy(h, tag, 16);
    uint32_t v[] = { 36 + bytes, 16, 1 | ((uint32_t)ch << 16), (uint32_t)rate,
                     (uint32_t)rate * ch * 2, (ch * 2) | (16u << 16), 0x61746164u, bytes };
    memcpy(h + 4,  &v[0], 4);
    memcpy(h + 16, &v[1], 4); memcpy(h + 20, &v[2], 4); memcpy(h + 24, &v[3], 4);
    memcpy(h + 28, &v[4], 4); memcpy(h + 32, &v[5], 4); memcpy(h + 36, &v[6], 4);
    memcpy(h + 40, &v[7], 4);
}

/* a deterministic stand-in for a microphone: a 440 Hz tone with a slow
 * tremolo and a bit of pseudo-noise, so level meters and waveforms move the
 * way a real signal would. t counts chunks (sets the tremolo phase). */
void au_test_pattern(int16_t *s, int frames, uint32_t *phase, int t) {
    uint32_t inc = au_phase_inc(440), n = (uint32_t)t * 2654435761u;
    int trem = 12000 + ((au_sine((uint32_t)t << 25) * 9000) >> 15);     /* 3000..21000 */
    for (int i = 0; i < frames; i++) {
        n = n * 1103515245u + 12345u;
        int v = ((au_sine(*phase) * trem) >> 15) + (int)((n >> 20) & 0x3ff) - 512;
        *phase += inc;
        s[2 * i] = s[2 * i + 1] = (int16_t)v;
    }
}
