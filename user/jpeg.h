/* jpeg.h - Baseline JPEG decoder for TannX OS. Written from ITU-T T.81.
 * Copyright (c) 2026 Tannenbaum Media, GPL-3.0-or-later.
 *
 * Decodes a baseline (SOF0/SOF1, 8-bit, Huffman) sequential JPEG with one
 * grayscale component or three YCbCr components (JFIF), any sampling
 * factors 1..4 (4:4:4, 4:2:2, 4:2:0, ...), with or without restart
 * intervals, into a caller-supplied 0x00RRGGBB buffer. Progressive,
 * arithmetic-coded, lossless, 12-bit and CMYK files are rejected. */
#ifndef AGENTOS_JPEG_H
#define AGENTOS_JPEG_H

#ifdef JPEG_HOST_TEST
#  include <stdint.h>
#else
#  include "libc.h"
#endif

enum {
    JPEG_OK            =  0,
    JPEG_ERR_SYNTAX    = -1,   /* malformed / truncated / inconsistent data */
    JPEG_ERR_UNSUPPORTED = -2, /* valid JPEG, but not baseline 8-bit gray/YCbCr */
    JPEG_ERR_TOO_LARGE = -3,   /* image exceeds the caller's max_w x max_h */
};

/* Decode `len` bytes of JPEG at `data` into `out`, one 0x00RRGGBB word per
 * pixel, row-major, tightly packed (stride == width). The image must fit
 * max_w x max_h; `out` must hold at least max_w*max_h words, which is all
 * the decoder will ever write to. On success *w and *h receive the image size
 * and JPEG_OK is returned; on failure a negative JPEG_ERR_* and *w = *h = 0.
 * Never reads outside data[0..len) and never crashes on corrupt input.
 * Not reentrant (uses static scratch state). */
int jpeg_decode(const uint8_t *data, int len, uint32_t *out,
                int max_w, int max_h, int *w, int *h);

#endif /* AGENTOS_JPEG_H */
