/* audio.h - the shared ring-3 HDA engine (user/audio.c): one controller
 * bring-up, a cyclic output ring and a cyclic input (microphone/line-in)
 * ring, both 48 kHz 16-bit stereo, polled by LPIB. Used by the recorder
 * ('run rec'), the synthesizer ('run synth'), the voice wish ('run voice')
 * and the system sounds ('run beep' / 'run chime'). */
#ifndef AGENTOS_AUDIO_H
#define AGENTOS_AUDIO_H
#include "libc.h"

#define AU_RATE        48000
#define AU_CHUNK       512                   /* frames per BDL entry (10.7 ms)  */
#define AU_NCHUNK      32                    /* entries per ring (343 ms)       */
#define AU_CHUNK_BYTES (AU_CHUNK * 4)        /* 16-bit stereo                   */
#define AU_RING_BYTES  (AU_NCHUNK * AU_CHUNK_BYTES)
#define AU_LEAD        8                     /* output chunks rendered ahead: must
                                              * outlast one 55 ms scheduler slice */

extern int16_t *au_out_ring;                 /* AU_NCHUNK x AU_CHUNK stereo frames */
extern int16_t *au_in_ring;
extern int      au_out_underruns;            /* DMA caught up with the mixer    */
extern int      au_in_overruns;              /* consumer fell a ring behind     */
extern int      au_cad, au_afg, au_dac, au_opin, au_adc, au_ipin;   /* codec map */

int      au_init(int verbose);               /* 0 ok / -1 no HDA (message when verbose) */
int      au_has_in(void);                    /* 1 when an ADC + input pin were found */
void     au_out_start(void);                 /* ring is silent until the app fills it */
void     au_out_stop(void);
uint32_t au_out_lpib(void);
int      au_out_next(void);                  /* chunk index to render now, or -1 (ring full) */
void     au_in_start(void);
void     au_in_stop(void);
uint32_t au_in_lpib(void);
int      au_in_next(void);                   /* chunk index fully captured, or -1 (nothing new) */
uint32_t au_phase_inc(int hz);              /* hz -> 32-bit phase step at AU_RATE */
int16_t  au_sine(uint32_t phase);            /* Q15 sine of a 32-bit phase (interpolated) */
void     au_tone(int hz, int ms, int vol);   /* blocking sine tone through the out ring */
void     au_wav_header(uint8_t *dst44, int rate, int ch, uint32_t data_bytes);
void     au_test_pattern(int16_t *stereo, int frames, uint32_t *phase, int t);
                                             /* deterministic 'microphone' for headless runs */
#endif
