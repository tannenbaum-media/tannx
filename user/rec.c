/* rec.c - 'run rec [test|demo]': the TannX recorder.
 *
 * Live microphone/line-in through the HDA engine (user/audio.c): a level
 * meter with peak hold and a scrolling waveform run all the time; R starts
 * and stops a recording (mono, 48 kHz, 16-bit, up to REC_SECS), P plays it
 * back through the output ring, S writes it as REC.WAV to the FAT volume on
 * the virtio-blk disk (vblk_savefile), Q quits.
 *
 *   run rec        the real microphone
 *   run rec test   deterministic test signal instead of the mic + serial
 *                  diagnostics (the headless gate: test-rec.sh)
 *   run rec demo   test signal, recording starts by itself (screenshots)
 *
 * QEMU's -audiodev none delivers silence at the right rate, so 'test' is how
 * the gate sees a non-silent waveform and a non-silent WAV on the host. */
#include "audio.h"
#include "aui.h"

int vblk_savefile(const char *name, const uint8_t *data, int len);

#define REC_SECS 12
#define REC_MAX  (REC_SECS * AU_RATE)                /* mono frames */
#define HIST     1024                                /* waveform columns kept */

static uint8_t *wav;                                 /* 44-byte header + samples */
static int16_t *rec;                                 /* = wav + 44 */
static int rec_len, play_pos, state, mode, text_only;      /* state: 0 idle 1 rec 2 play */
static int chunk_no, level, peak, peak_hold, saved_bytes;
static uint32_t tp_phase;
static int16_t hmin[HIST], hmax[HIST];
static int hpos;
static int WX, WY, WW, WH, CX, CY, CW, LX, LY, LW;  /* layout */
static char buf[64];

static void diag(const char *s) { if (mode == 1) print(s); }

/* consume one stereo chunk: level, waveform history, recording */
static void feed(const int16_t *st, int record) {
    int mx = -32768, mn = 32767, pk = 0;
    for (int i = 0; i < AU_CHUNK; i++) {
        int m = (st[2 * i] + st[2 * i + 1]) >> 1;
        if (m > mx) mx = m;
        if (m < mn) mn = m;
        int a = m < 0 ? -m : m;
        if (a > pk) pk = a;
        if (record && rec_len < REC_MAX) rec[rec_len++] = (int16_t)m;
    }
    hmin[hpos] = (int16_t)mn; hmax[hpos] = (int16_t)mx;
    hpos = (hpos + 1) % HIST;
    level = pk > level ? pk : level - (level >> 3);          /* fast attack, slow decay */
    if (pk >= peak) { peak = pk; peak_hold = 60; }
    else if (peak_hold) peak_hold--;
    else peak -= peak >> 4;
    chunk_no++;
}

static void fmt_time(char *d, int frames) {
    int t = frames / (AU_RATE / 10);
    d = aui_num(d, t / 600); *d++ = ':';
    *d++ = (char)('0' + (t / 100) % 6); *d++ = (char)('0' + (t / 10) % 10);
    *d++ = '.'; *d++ = (char)('0' + t % 10); *d = 0;
}

static void draw_status(void) {
    aui_panel(CX, CY, CW, 6 * AUI_CH + 24 * aui_sc, AUI_PANEL, AUI_BORDER);
    int x = CX + 16 * aui_sc, y = CY + 12 * aui_sc;
    uint32_t c = state == 1 ? AUI_DANGER : state == 2 ? AUI_ACCENT : AUI_MUTED;
    aui_rect(x, y + AUI_CH / 2 + 2 * aui_sc, 10 * aui_sc, 10 * aui_sc, c);
    aui_text(x + 18 * aui_sc, y + AUI_CH / 2 - 4 * aui_sc,
            state == 1 ? "RECORDING" : state == 2 ? "PLAYING" : "READY", 2, c);
    y += 2 * AUI_CH + 8 * aui_sc;
    char *p = aui_str(buf, "take  ");
    fmt_time(p, state == 2 ? play_pos : rec_len);
    p = buf + strlen(buf); p = aui_str(p, " / 0:"); aui_num(p, REC_SECS); aui_str(p + 2, ".0");
    aui_text(x, y, buf, 1, AUI_TEXT);
    y += AUI_CH + 4 * aui_sc;
    p = aui_str(buf, "source  ");
    p = aui_str(p, mode ? "test signal 440 Hz" : au_has_in() ? "HDA input pin " : "none");
    if (!mode && au_has_in()) aui_num(p, au_ipin);
    aui_text(x, y, buf, 1, AUI_MUTED);
    y += AUI_CH + 4 * aui_sc;
    if (saved_bytes > 0) { p = aui_str(buf, "saved  REC.WAV  "); p = aui_num(p, saved_bytes); aui_str(p, " bytes"); }
    else if (saved_bytes < 0) aui_str(buf, "save failed: no FAT volume");
    else aui_str(buf, "mono 48 kHz 16-bit PCM");
    aui_text(x, y, buf, 1, saved_bytes < 0 ? AUI_WARN : AUI_MUTED);
}

static void draw_meter(void) {
    aui_meter(LX, LY + AUI_CH + 8 * aui_sc, LW, 14 * aui_sc, level, peak);
    /* numeric peak in dBFS-ish: 20*log10 is out of reach, use a coarse scale */
    int v = peak, db = 0;
    while (v < 32767 && db < 60) { v = v * 10 / 7; db += 3; }    /* 3 dB steps (~x1.41) */
    char *p = aui_str(buf, "peak -"); p = aui_num(p, db); aui_str(p, " dB ");
    aui_rect(LX + LW - 12 * AUI_CW, LY, 12 * AUI_CW, AUI_CH, AUI_PANEL);
    aui_text(LX + LW - strlen(buf) * AUI_CW, LY, buf, 1, AUI_MUTED);
}

/* the scrolling waveform: newest column at the right edge. Rendered ROW by
 * row (contiguous stores): column strips were 20x slower - every pixel a
 * cache miss 10 KB apart (found with the in-guest fill probe, QEMU TCG). */
static void draw_wave(void) {
    static int16_t y0[HIST], y1[HIST];
    int cols = WW / aui_sc, mid = WY + WH / 2, half = WH / 2 - 4 * aui_sc;
    if (cols > HIST) cols = HIST;
    for (int i = 0; i < cols; i++) {
        int k = (hpos - cols + i + HIST) % HIST;
        y0[i] = (int16_t)(mid - (hmax[k] * half >> 15));
        y1[i] = (int16_t)(mid - (hmin[k] * half >> 15));
        if (y1[i] < y0[i] + aui_sc) y1[i] = (int16_t)(y0[i] + aui_sc);
    }
    uint32_t lit = state == 1 ? AUI_DANGER : AUI_ACCENT;
    for (int y = WY; y < WY + WH; y++) {
        uint32_t *row = aui_fb.base + (unsigned)y * aui_fb.ppsl + WX;
        uint32_t bg = (y >= mid && y < mid + aui_sc) ? AUI_DIM : AUI_PANEL;
        for (int i = 0; i < cols; i++) {
            uint32_t c = (y >= y0[i] && y < y1[i]) ? lit : bg;
            for (int s = 0; s < aui_sc; s++) row[i * aui_sc + s] = c;
        }
    }
}

static void layout(void) {
    int m = 16 * aui_sc, top = AUI_TOP, bot = AUI_CH + 12 * aui_sc + m;
    CX = m; CY = top; CW = aui_fb.w * 2 / 5;
    LX = CX + CW + m; LY = top + 12 * aui_sc; LW = aui_fb.w - LX - m;
    WX = m + 4 * aui_sc; WY = CY + 6 * AUI_CH + 24 * aui_sc + m + 4 * aui_sc;
    WW = aui_fb.w - 2 * m - 8 * aui_sc; WH = aui_fb.h - bot - WY - 4 * aui_sc;
    aui_title("Recorder", "HDA capture  48 kHz / 16-bit");
    aui_footer("R record/stop   P play   S save WAV   Q quit");
    aui_panel(LX - 12 * aui_sc, top, LW + 24 * aui_sc, 6 * AUI_CH + 24 * aui_sc, AUI_PANEL, AUI_BORDER);
    aui_text(LX, LY, "INPUT LEVEL", 1, AUI_ACCENT);
    aui_text(LX, LY + 2 * AUI_CH + 24 * aui_sc, "peak hold  .  fast attack, slow decay", 1, AUI_DIM);
    aui_text(LX, LY + 3 * AUI_CH + 28 * aui_sc, "scrolling waveform below: 10.7 ms per column", 1, AUI_DIM);
    aui_panel(WX - 4 * aui_sc, WY - 4 * aui_sc, WW + 8 * aui_sc, WH + 8 * aui_sc, AUI_PANEL, AUI_BORDER);
    draw_status();
}

static void stop_rec(void) {
    state = 0;
    if (mode == 1) printf("rec: stopped, %d frames, peak %d\r\n", rec_len, peak);
}

static void save_wav(void) {
    au_wav_header(wav, AU_RATE, 1, (uint32_t)rec_len * 2);
    int r = vblk_savefile("REC.WAV", wav, 44 + rec_len * 2);
    saved_bytes = r >= 0 ? 44 + rec_len * 2 : -1;
    if (r >= 0) printf("rec: saved REC.WAV (%d bytes)\r\n", saved_bytes);
    else        print("rec: save failed - no FAT volume (virtio-blk)\r\n");
}

int rec_main(const char *arg) {
    mode = arg[0] == 't' ? 1 : arg[0] == 'd' ? 2 : 0;
    if (au_init(1) < 0) return 0;
    if (!au_has_in() && !mode) print("rec: codec has no input path - 'run rec test' uses a test signal\r\n");
    wav = malloc(44 + REC_MAX * 2);
    if (!wav) { print("rec: out of memory\r\n"); return 0; }
    rec = (int16_t *)(wav + 44);
    printf("rec: capture %s (adc %d in-pin %d), keys R/P/S/Q\r\n",
           au_has_in() ? "running" : "unavailable", au_adc, au_ipin);
    text_only = aui_begin() < 0;
    if (!text_only) layout();
    while (sys_getkey()) ;                               /* drop the command line's keys */
    au_in_start();
    if (mode == 2) state = 1;
    uint32_t t_last = sys_uptime(), out_lpib = 0;
    int redraw = 0, drew_status = -1; uint32_t t_diag = sys_uptime();
    for (;;) {
        int busy = 0, k;
        /* input: every finished chunk feeds meter + waveform (+ the take) */
        while ((k = au_in_next()) >= 0) {
            int16_t *c = au_in_ring + k * AU_CHUNK * 2;
            if (mode) au_test_pattern(c, AU_CHUNK, &tp_phase, chunk_no);
            if (state != 2) feed(c, state == 1);
            if (state == 1 && rec_len >= REC_MAX) stop_rec();
            busy = 1;
        }
        if (!au_has_in() && mode && state != 2) {            /* no ADC at all: synthesize */
            static int16_t fake[AU_CHUNK * 2];
            if (sys_uptime() - t_last >= 1) { t_last = sys_uptime();
                for (int n = 0; n < 5; n++) { au_test_pattern(fake, AU_CHUNK, &tp_phase, chunk_no); feed(fake, state == 1); } busy = 1; }
        }
        /* playback: render the take ahead of LPIB */
        if (state == 2) {
            while ((k = au_out_next()) >= 0) {
                int16_t *d = au_out_ring + k * AU_CHUNK * 2;
                for (int i = 0; i < AU_CHUNK; i++) {
                    int16_t s = play_pos < rec_len ? rec[play_pos] : 0;
                    play_pos++;
                    d[2 * i] = d[2 * i + 1] = s;
                }
                feed(d, 0);
                busy = 1;
                if (play_pos >= rec_len + AU_LEAD * AU_CHUNK) {
                    out_lpib = au_out_lpib();
                    au_out_stop(); state = 0;
                    if (mode == 1) printf("rec: playback done, out-lpib=%u\r\n", out_lpib);
                    break;
                }
            }
        }
        int key = sys_getkey();
        if (key == 'q' || key == 'Q' || key == KEY_ESC) break;
        if (key == 'r' || key == 'R') {
            if (state == 1) stop_rec();
            else if (state == 0) { state = 1; rec_len = 0; saved_bytes = 0; diag("rec: recording\r\n"); }
        }
        if ((key == 'p' || key == 'P') && state == 0 && rec_len) {
            state = 2; play_pos = 0; au_out_start(); diag("rec: playing\r\n");
        }
        if ((key == 's' || key == 'S') && state == 0 && rec_len) save_wav();
        if (!text_only) {
            if (busy && ++redraw >= 8) {                      /* ~11 fps */
                redraw = 0; draw_wave(); draw_meter();
                int st = state * 100000 + (state ? (state == 2 ? play_pos : rec_len) / (AU_RATE / 10) : 0) + saved_bytes;
                if (st != drew_status) { drew_status = st; draw_status(); }
            }
        }
        if (mode == 1 && sys_uptime() - t_diag >= 18) {                 /* ~1/s */
            t_diag = sys_uptime();
            printf("rec: t=%u in-lpib=%u chunks=%d level=%d peak=%d\r\n",
                   t_diag, au_in_lpib(), chunk_no, level, peak);
        }
        /* no sys_yield: a yield parks us for up to two ticks (110 ms), longer
         * than the playback lead. The kernel preempts us anyway. */
    }
    au_in_stop(); au_out_stop();
    { uint32_t t = sys_uptime(); while (sys_uptime() - t < 3) sys_yield(); }   /* let the shell echo the key first */
    printf("rec: quit (recorded %d frames, peak %d, in-lpib %u, chunks %d, overruns %d, saved %d)\r\n",
           rec_len, peak, au_in_lpib(), chunk_no, au_in_overruns, saved_bytes);
    return 0;
}
