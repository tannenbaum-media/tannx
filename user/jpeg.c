/* jpeg.c - Baseline JPEG decoder for TannX OS. Written from ITU-T T.81.
 * Copyright (c) 2026 Tannenbaum Media, GPL-3.0-or-later.
 *
 * Scope: baseline sequential DCT (SOF0, plus SOF1 at 8 bits), Huffman
 * coded, 1 component (grayscale) or 3 components (YCbCr as in JFIF),
 * one interleaved scan, sampling factors 1..4 per axis, DRI/RSTn restart
 * intervals, 8- or 16-bit quantisation tables. Output is 0x00RRGGBB.
 *
 * Structure (T.81 chapter references in brackets):
 *   - marker loop [B.2]        : SOF/DHT/DQT/DRI/SOS, everything else skipped
 *   - canonical Huffman [C.2]  : per-length maxcode table + 8-bit fast lookup
 *   - bit reader [F.2.2.5]     : 0xFF00 unstuffing, stops at markers, pads 0s
 *   - block decode [F.2.2]     : DC prediction, run/size AC, dequantisation
 *   - separable integer IDCT   : even/odd split of the 8-point matrix,
 *                                 12-bit fixed point, columns then rows
 *   - MCU emit [A.2.3]         : chroma replication + YCbCr -> RGB [JFIF]
 * Each MCU is decoded into a small scratch tile and written straight into
 * the caller's buffer, so there are no per-image scratch planes: memory use
 * is constant (~8 KB of .bss) whatever the image size.
 *
 * Robustness: every table id, sampling factor, segment length, Huffman code
 * and coefficient index is range-checked; bits consumed past the end of the
 * entropy data (truncated frame) are detected and reported. The decoder
 * never reads outside the input and writes only within max_w*max_h words.
 *
 * Host self-test: gcc -DJPEG_HOST_TEST -O2 -Wall user/jpeg.c -o jpeg
 *                 ./jpeg in.jpg out.ppm   (see test-jpeg.sh) */
#include "jpeg.h"

#ifdef JPEG_HOST_TEST
#  include <string.h>
#  include <stdio.h>
#  include <stdlib.h>
#endif

/* ---- limits ---------------------------------------------------------- */
#define MAX_COMP       3
#define MAX_HV         4                 /* sampling factor per axis */
#define TILE           (8 * MAX_HV)      /* scratch tile edge per component */
#define MAX_BLOCKS_MCU 10                /* T.81 B.2.3: sum(Hi*Vi) <= 10 */

/* ---- tables ----------------------------------------------------------- */
typedef struct {
    uint16_t fast[256];   /* 8-bit lookahead: (len << 8) | symbol, 0 = longer */
    int32_t  maxcode[17]; /* largest code of each length, -1 if none  [F.2.2.3] */
    int32_t  valoff[17];  /* symbol index = code + valoff[len] */
    uint8_t  sym[256];    /* symbols in code order */
    uint8_t  defined;
} huff_t;

typedef struct {
    uint16_t q[64];       /* quantiser values in zigzag order */
    uint8_t  defined;
} quant_t;

typedef struct {
    uint8_t id, h, v, tq; /* from SOF */
    uint8_t td, ta;       /* from SOS */
    int32_t dcpred;
    uint8_t xmap[TILE];   /* tile pixel x -> component sample x (replication) */
    uint8_t ymap[TILE];
} comp_t;

typedef struct {
    const uint8_t *p, *end;   /* entropy-coded data cursor */
    uint32_t acc;             /* bit accumulator, MSB first */
    int nbits;                /* valid bits in acc */
    int padbits;              /* zero bits fed after end / marker */
    int at_marker;            /* stopped in front of a marker */
} bits_t;

typedef struct {
    int w, h, ncomp, hmax, vmax, restart;
    int have_sof;
    comp_t  c[MAX_COMP];
    huff_t  dc[4], ac[4];
    quant_t qt[4];
    bits_t  br;
    uint8_t tile[MAX_COMP][TILE * TILE];  /* decoded samples of one MCU */
    int32_t coef[64];                     /* one block's coefficients */
} dec_t;

static dec_t D;   /* static scratch: ring-3 stacks are small, .bss is free */

static const uint8_t zigzag[64] = {           /* zigzag index -> natural [A.3.6] */
     0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 };

static int be16(const uint8_t *p) { return (p[0] << 8) | p[1]; }

static int clamp8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

/* ---- Huffman table construction [C.2] -------------------------------- */
static int huff_build(huff_t *t, const uint8_t *counts, const uint8_t *syms, int total)
{
    int code = 0, k = 0, len;
    memset(t->fast, 0, sizeof t->fast);
    memcpy(t->sym, syms, total);
    for (len = 1; len <= 16; len++) {
        int n = counts[len - 1];
        if (n == 0) { t->maxcode[len] = -1; t->valoff[len] = 0; }
        else {
            if (code + n > (1 << len)) return JPEG_ERR_SYNTAX;   /* over-subscribed */
            t->valoff[len] = k - code;               /* valptr - mincode */
            if (len <= 8) {                          /* fill the lookahead */
                int i;
                for (i = 0; i < n; i++) {
                    int c = code + i, j, reps = 1 << (8 - len);
                    for (j = 0; j < reps; j++)
                        t->fast[(c << (8 - len)) + j] = (uint16_t)((len << 8) | syms[k + i]);
                }
            }
            code += n; k += n;
            t->maxcode[len] = code - 1;
        }
        code <<= 1;
    }
    t->defined = 1;
    return JPEG_OK;
}

/* ---- bit reader [F.2.2.5] ------------------------------------------- */
static void bits_fill(bits_t *b)
{
    while (b->nbits <= 24) {
        uint32_t byte = 0;
        if (b->at_marker || b->p >= b->end) { b->padbits += 8; }
        else {
            byte = *b->p;
            if (byte == 0xFF) {
                /* FF 00 is a stuffed data FF; FF xx (xx != 0) is a marker */
                if (b->p + 1 < b->end && b->p[1] == 0x00) b->p += 2;
                else { b->at_marker = 1; byte = 0; b->padbits += 8; }
            } else b->p++;
        }
        b->acc = (b->acc << 8) | byte;
        b->nbits += 8;
    }
}

static inline uint32_t bits_peek(bits_t *b, int n)
{
    if (b->nbits < n) bits_fill(b);
    return (b->acc >> (b->nbits - n)) & ((1u << n) - 1);
}

static inline int bits_get(bits_t *b, int n)
{
    int v = (int)bits_peek(b, n);
    b->nbits -= n;
    return v;
}

/* RECEIVE + EXTEND [F.2.2.1]: n magnitude bits -> signed value */
static inline int bits_extend(bits_t *b, int n)
{
    int v = bits_get(b, n);
    if (v < (1 << (n - 1))) v -= (1 << n) - 1;
    return v;
}

/* DECODE [F.2.2.3]: next Huffman symbol or -1 */
static inline int huff_decode(bits_t *b, const huff_t *t)
{
    uint32_t look = bits_peek(b, 16);
    uint16_t f = t->fast[look >> 8];
    int len;
    if (f) { b->nbits -= f >> 8; return f & 0xFF; }
    for (len = 9; len <= 16; len++) {
        int32_t code = (int32_t)(look >> (16 - len));
        if (code <= t->maxcode[len]) {
            b->nbits -= len;
            return t->sym[(code + t->valoff[len]) & 0xFF];
        }
    }
    return -1;
}

/* ---- inverse DCT ------------------------------------------------------ */
/* 8-point 1-D IDCT, f(x) = sum_u C(u)/2 F(u) cos((2x+1)u pi/16), split into
 * the even (u=0,2,4,6) and odd (u=1,3,5,7) halves: the even half gives
 * E[x], the odd half O[x] for x=0..3, and f(x)=E[x]+O[x], f(7-x)=E[x]-O[x].
 * Constants are cos(n pi/16)/2 in 12-bit fixed point. The u=0 term has
 * C(0)=1/sqrt(2) and cos(0)=1, the u=4 term has C(4)=1 and cos(.)=+-1/sqrt(2),
 * so both share the factor 1/(2 sqrt 2) = C4. */
#define C1 2009   /* cos(1pi/16)/2 * 4096 */
#define C2 1892
#define C3 1703
#define C4 1448   /* 1/(2 sqrt 2) * 4096 */
#define C5 1138
#define C6  784
#define C7  400

/* in: 8 values at stride `s`; out: 8 values at stride 1, scaled by `shift` */
static void idct_1d(const int32_t *in, int s, int32_t *out, int shift, int bias)
{
    int32_t f0 = in[0], f1 = in[s], f2 = in[2*s], f3 = in[3*s];
    int32_t f4 = in[4*s], f5 = in[5*s], f6 = in[6*s], f7 = in[7*s];
    int32_t t0 = (f0 + f4) * C4 + bias, t1 = (f0 - f4) * C4 + bias;
    int32_t t2 = f2 * C2 + f6 * C6, t3 = f2 * C6 - f6 * C2;
    int32_t e0 = t0 + t2, e1 = t1 + t3, e2 = t1 - t3, e3 = t0 - t2;
    int32_t o0 = f1 * C1 + f3 * C3 + f5 * C5 + f7 * C7;
    int32_t o1 = f1 * C3 - f3 * C7 - f5 * C1 - f7 * C5;
    int32_t o2 = f1 * C5 - f3 * C1 + f5 * C7 + f7 * C3;
    int32_t o3 = f1 * C7 - f3 * C5 + f5 * C3 - f7 * C1;
    out[0] = (e0 + o0) >> shift; out[7] = (e0 - o0) >> shift;
    out[1] = (e1 + o1) >> shift; out[6] = (e1 - o1) >> shift;
    out[2] = (e2 + o2) >> shift; out[5] = (e2 - o2) >> shift;
    out[3] = (e3 + o3) >> shift; out[4] = (e3 - o3) >> shift;
}

/* 2-D IDCT of D.coef (natural order, dequantised, |v| <= 32767) into an
 * 8x8 tile of 8-bit samples at `dst` with row stride TILE. */
static void idct_block(int32_t *coef, uint8_t *dst)
{
    int32_t tmp[64], row[8];
    int i, j;
    /* pass 1: columns, keep 3 fractional bits (>> 9 of the 12-bit scale);
     * the column of a block is very often DC-only, so shortcut it */
    for (i = 0; i < 8; i++) {
        int32_t *c = coef + i;
        if (!(c[8] | c[16] | c[24] | c[32] | c[40] | c[48] | c[56])) {
            int32_t v = (c[0] * C4) >> 9;
            for (j = 0; j < 8; j++) tmp[j * 8 + i] = v;
        } else {
            int32_t col[8];
            idct_1d(c, 8, col, 9, 0);
            for (j = 0; j < 8; j++) {
                int32_t v = col[j];              /* clamp keeps pass 2 in int32 */
                tmp[j * 8 + i] = v > 32767 ? 32767 : v < -32768 ? -32768 : v;
            }
        }
    }
    /* pass 2: rows; 3 + 12 fractional bits -> >> 15, +128 level shift [A.3.1] */
    for (i = 0; i < 8; i++) {
        idct_1d(tmp + i * 8, 1, row, 15, (128 << 15) + (1 << 14));
        for (j = 0; j < 8; j++) dst[i * TILE + j] = (uint8_t)clamp8(row[j]);
    }
}

/* ---- one 8x8 block: entropy decode + dequantise + IDCT [F.2.2] -------- */
static int decode_block(comp_t *c, uint8_t *dst)
{
    bits_t *b = &D.br;
    const huff_t *dc = &D.dc[c->td], *ac = &D.ac[c->ta];
    const uint16_t *q = D.qt[c->tq].q;
    int32_t *coef = D.coef;
    int k, t, v;

    memset(coef, 0, sizeof(D.coef));
    t = huff_decode(b, dc);
    if (t < 0 || t > 11) return JPEG_ERR_SYNTAX;        /* 8-bit DC: SSSS <= 11 */
    c->dcpred += t ? bits_extend(b, t) : 0;
    if (c->dcpred > 32767) c->dcpred = 32767;           /* corrupt streams only */
    if (c->dcpred < -32768) c->dcpred = -32768;
    v = c->dcpred * q[0];
    coef[0] = v > 32767 ? 32767 : v < -32768 ? -32768 : v;

    for (k = 1; k < 64; k++) {
        int rs = huff_decode(b, ac), r, s;
        if (rs < 0) return JPEG_ERR_SYNTAX;
        r = rs >> 4; s = rs & 15;
        if (s == 0) {
            if (r != 15) break;                         /* EOB */
            k += 15;                                    /* ZRL: 16 zeros */
            continue;
        }
        k += r;
        if (k > 63) return JPEG_ERR_SYNTAX;
        v = bits_extend(b, s) * q[k];
        coef[zigzag[k]] = v > 32767 ? 32767 : v < -32768 ? -32768 : v;
    }
    idct_block(coef, dst);
    return JPEG_OK;
}

/* ---- MCU -> RGB [A.2.3, JFIF colour transform] ------------------------ */
static void emit_mcu(uint32_t *out, int mx, int my)
{
    int tw = D.hmax * 8, th = D.vmax * 8;
    int x0 = mx * tw, y0 = my * th, px, py;
    for (py = 0; py < th; py++) {
        int y = y0 + py;
        uint32_t *row;
        if (y >= D.h) break;
        row = out + (uint32_t)y * D.w;
        if (D.ncomp == 1) {
            const uint8_t *l = D.tile[0] + py * TILE;
            for (px = 0; px < tw && x0 + px < D.w; px++)
                row[x0 + px] = l[px] * 0x010101u;
        } else {
            const uint8_t *ly = D.tile[0] + D.c[0].ymap[py] * TILE;
            const uint8_t *lb = D.tile[1] + D.c[1].ymap[py] * TILE;
            const uint8_t *lr = D.tile[2] + D.c[2].ymap[py] * TILE;
            for (px = 0; px < tw && x0 + px < D.w; px++) {
                int Y  = ly[D.c[0].xmap[px]];
                int cb = lb[D.c[1].xmap[px]] - 128;
                int cr = lr[D.c[2].xmap[px]] - 128;
                int r = clamp8(Y + ((91881 * cr) >> 16));                /* 1.402  */
                int g = clamp8(Y - ((22554 * cb + 46802 * cr) >> 16));   /* .34414 .71414 */
                int bl = clamp8(Y + ((116130 * cb) >> 16));              /* 1.772  */
                row[x0 + px] = (uint32_t)(r << 16 | g << 8 | bl);
            }
        }
    }
}

/* ---- restart marker between intervals [B.2.1.2, F.2.2.5] -------------- */
static int do_restart(void)
{
    bits_t *b = &D.br;
    int i;
    b->acc = 0; b->nbits = 0; b->padbits = 0; b->at_marker = 0;   /* byte align */
    while (b->p + 1 < b->end && b->p[0] == 0xFF && b->p[1] == 0xFF)
        b->p++;                                                    /* fill bytes */
    if (b->p + 1 >= b->end || b->p[0] != 0xFF || (b->p[1] & 0xF8) != 0xD0)
        return JPEG_ERR_SYNTAX;
    b->p += 2;
    for (i = 0; i < D.ncomp; i++) D.c[i].dcpred = 0;
    return JPEG_OK;
}

/* ---- the scan: all MCUs, interleaved [A.2.3] -------------------------- */
static int decode_scan(uint32_t *out, const uint8_t *data, const uint8_t *end)
{
    int tw = D.hmax * 8, th = D.vmax * 8;
    int mcux = (D.w + tw - 1) / tw, mcuy = (D.h + th - 1) / th;
    int mx, my, i, bx, by, n = 0, rc;
    bits_t *b = &D.br;

    memset(b, 0, sizeof *b);
    b->p = data; b->end = end;
    for (i = 0; i < D.ncomp; i++) {
        comp_t *c = &D.c[i];
        int k;
        c->dcpred = 0;
        for (k = 0; k < TILE; k++) {
            c->xmap[k] = (uint8_t)(k * c->h / D.hmax);
            c->ymap[k] = (uint8_t)(k * c->v / D.vmax);
        }
    }
    for (my = 0; my < mcuy; my++) {
        for (mx = 0; mx < mcux; mx++, n++) {
            if (D.restart && n && n % D.restart == 0 && (rc = do_restart()) < 0)
                return rc;
            for (i = 0; i < D.ncomp; i++) {
                comp_t *c = &D.c[i];
                for (by = 0; by < c->v; by++)
                    for (bx = 0; bx < c->h; bx++)
                        if ((rc = decode_block(c, D.tile[i] + by * 8 * TILE + bx * 8)) < 0)
                            return rc;
            }
            emit_mcu(out, mx, my);
        }
    }
    /* bits taken beyond the real data mean the frame was truncated */
    if (b->padbits > b->nbits) return JPEG_ERR_SYNTAX;
    return JPEG_OK;
}

/* ---- marker segments [B.2.2 - B.2.4] ---------------------------------- */
static int parse_sof(const uint8_t *s, int n, int max_w, int max_h)
{
    int i, sum = 0;
    if (D.have_sof || n < 6) return JPEG_ERR_SYNTAX;
    if (s[0] != 8) return JPEG_ERR_UNSUPPORTED;            /* 12-bit precision */
    D.h = be16(s + 1); D.w = be16(s + 3); D.ncomp = s[5];
    if (n != 6 + 3 * D.ncomp || D.w < 1 || D.h < 1) return JPEG_ERR_SYNTAX;
    if (D.ncomp == 4 || D.ncomp == 2) return JPEG_ERR_UNSUPPORTED; /* CMYK etc. */
    if (D.ncomp != 1 && D.ncomp != 3) return JPEG_ERR_SYNTAX;
    if (D.w > max_w || D.h > max_h) return JPEG_ERR_TOO_LARGE;
    D.hmax = D.vmax = 1;
    for (i = 0; i < D.ncomp; i++) {
        comp_t *c = &D.c[i];
        c->id = s[6 + 3 * i]; c->h = s[7 + 3 * i] >> 4; c->v = s[7 + 3 * i] & 15;
        c->tq = s[8 + 3 * i];
        if (D.ncomp == 1) c->h = c->v = 1;   /* single component: MCU = 1 block [A.2.2] */
        if (c->h < 1 || c->h > MAX_HV || c->v < 1 || c->v > MAX_HV || c->tq > 3)
            return JPEG_ERR_SYNTAX;
        sum += c->h * c->v;
        if (c->h > D.hmax) D.hmax = c->h;
        if (c->v > D.vmax) D.vmax = c->v;
    }
    if (sum > MAX_BLOCKS_MCU) return JPEG_ERR_SYNTAX;
    D.have_sof = 1;
    return JPEG_OK;
}

static int parse_dht(const uint8_t *s, int n)
{
    while (n >= 17) {
        int tc = s[0] >> 4, th = s[0] & 15, total = 0, i, rc;
        if (tc > 1 || th > 3) return JPEG_ERR_SYNTAX;
        for (i = 1; i <= 16; i++) total += s[i];
        if (total > 256 || n < 17 + total) return JPEG_ERR_SYNTAX;
        rc = huff_build(tc ? &D.ac[th] : &D.dc[th], s + 1, s + 17, total);
        if (rc < 0) return rc;
        s += 17 + total; n -= 17 + total;
    }
    return n ? JPEG_ERR_SYNTAX : JPEG_OK;
}

static int parse_dqt(const uint8_t *s, int n)
{
    while (n > 0) {
        int pq = s[0] >> 4, tq = s[0] & 15, i, size;
        if (pq > 1 || tq > 3) return JPEG_ERR_SYNTAX;
        size = 1 + 64 * (pq + 1);
        if (n < size) return JPEG_ERR_SYNTAX;
        for (i = 0; i < 64; i++) {
            int v = pq ? be16(s + 1 + 2 * i) : s[1 + i];
            D.qt[tq].q[i] = (uint16_t)(v > 32767 ? 32767 : v);  /* keeps products in int32 */
        }
        D.qt[tq].defined = 1;
        s += size; n -= size;
    }
    return JPEG_OK;
}

static int parse_sos(const uint8_t *s, int n)
{
    int ns, i, j;
    if (!D.have_sof || n < 1) return JPEG_ERR_SYNTAX;
    ns = s[0];
    if (n != 1 + 2 * ns + 3) return JPEG_ERR_SYNTAX;
    if (ns != D.ncomp) return JPEG_ERR_UNSUPPORTED;      /* non-interleaved scans */
    for (i = 0; i < ns; i++) {
        int id = s[1 + 2 * i], t = s[2 + 2 * i];
        comp_t *c = 0;
        for (j = 0; j < i; j++)                          /* component listed twice */
            if (s[1 + 2 * j] == id) return JPEG_ERR_SYNTAX;
        for (j = 0; j < D.ncomp; j++)
            if (D.c[j].id == id) c = &D.c[j];
        if (!c) return JPEG_ERR_SYNTAX;                  /* not in the frame */
        c->td = t >> 4; c->ta = t & 15;
        if (c->td > 3 || c->ta > 3) return JPEG_ERR_SYNTAX;
        if (!D.dc[c->td].defined || !D.ac[c->ta].defined || !D.qt[c->tq].defined)
            return JPEG_ERR_SYNTAX;
    }
    /* Ss, Se, Ah/Al must be 0, 63, 0 for sequential DCT [B.2.3] */
    if (s[1 + 2 * ns] != 0 || s[2 + 2 * ns] != 63 || s[3 + 2 * ns] != 0)
        return JPEG_ERR_UNSUPPORTED;
    return JPEG_OK;
}

/* ---- entry point ------------------------------------------------------ */
int jpeg_decode(const uint8_t *data, int len, uint32_t *out,
                int max_w, int max_h, int *w, int *h)
{
    int pos = 2, rc;
    *w = *h = 0;
    if (!data || len < 4 || max_w < 1 || max_h < 1) return JPEG_ERR_SYNTAX;
    if (data[0] != 0xFF || data[1] != 0xD8) return JPEG_ERR_SYNTAX;   /* SOI */
    memset(&D, 0, sizeof D);

    for (;;) {
        int m, seglen;
        const uint8_t *seg;
        while (pos + 1 < len && data[pos] == 0xFF && data[pos + 1] == 0xFF)
            pos++;                                              /* fill bytes */
        if (pos + 2 > len || data[pos] != 0xFF) return JPEG_ERR_SYNTAX;
        m = data[pos + 1]; pos += 2;
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) continue; /* no payload */
        if (m == 0xD9) return JPEG_ERR_SYNTAX;                  /* EOI before any scan */
        if (pos + 2 > len) return JPEG_ERR_SYNTAX;
        seglen = be16(data + pos) - 2;
        if (seglen < 0 || pos + 2 + seglen > len) return JPEG_ERR_SYNTAX;
        seg = data + pos + 2; pos += 2 + seglen;
        switch (m) {
        case 0xC0: case 0xC1:                                   /* baseline / ext. seq. */
            if ((rc = parse_sof(seg, seglen, max_w, max_h)) < 0) return rc;
            break;
        case 0xC2: case 0xC3: case 0xC5: case 0xC6: case 0xC7:
        case 0xC9: case 0xCA: case 0xCB: case 0xCD: case 0xCE: case 0xCF:
            return JPEG_ERR_UNSUPPORTED;                        /* progressive etc. */
        case 0xC4:
            if ((rc = parse_dht(seg, seglen)) < 0) return rc;
            break;
        case 0xDB:
            if ((rc = parse_dqt(seg, seglen)) < 0) return rc;
            break;
        case 0xDD:
            if (seglen != 2) return JPEG_ERR_SYNTAX;
            D.restart = be16(seg);
            break;
        case 0xDA:
            if ((rc = parse_sos(seg, seglen)) < 0) return rc;
            if ((rc = decode_scan(out, data + pos, data + len)) < 0) return rc;
            *w = D.w; *h = D.h;
            return JPEG_OK;
        default:                                                /* APPn, COM, DNL, ... */
            break;
        }
    }
}

/* ---- host self-test driver -------------------------------------------- */
#ifdef JPEG_HOST_TEST
/* usage: jpeg in.jpg out.ppm [repeat]  -> exit 0 on success, 1 on decode
 * error (prints the code), 2 on usage/IO error. `repeat` decodes the file
 * that many times for timing. */
int main(int argc, char **argv)
{
    static uint32_t out[2048 * 2048];
    FILE *f; long n; uint8_t *buf; int w, h, rc = JPEG_ERR_SYNTAX, i, reps = 1;
    if (argc < 3) { fprintf(stderr, "usage: %s in.jpg out.ppm [repeat]\n", argv[0]); return 2; }
    if (argc > 3) reps = atoi(argv[3]);
    if (reps < 1) reps = 1;
    f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    buf = malloc(n > 0 ? n : 1);
    if (fread(buf, 1, n, f) != (size_t)n) { perror("read"); return 2; }
    fclose(f);
    for (i = 0; i < reps; i++) rc = jpeg_decode(buf, (int)n, out, 2048, 2048, &w, &h);
    if (rc != JPEG_OK) { printf("decode error %d\n", rc); return 1; }
    printf("%dx%d\n", w, h);
    f = fopen(argv[2], "wb"); if (!f) { perror(argv[2]); return 2; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (i = 0; i < w * h; i++) {
        uint8_t px[3] = { out[i] >> 16, out[i] >> 8, out[i] };
        fwrite(px, 1, 3, f);
    }
    fclose(f);
    free(buf);
    return 0;
}
#endif
