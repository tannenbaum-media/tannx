/* synth.c - 'run synth [demo|test]': a playable polyphonic synthesizer.
 *
 * Two octaves on the computer keyboard (the usual DAW layout: z..m is the
 * lower octave, q..p the upper, s/d/g/h/j and 2/3/5/6/7 the black keys),
 * four waveforms (sine / square / saw / triangle), three ADSR envelopes
 * (keys / pad / pluck), 8 voices mixed in integer math straight into the
 * HDA output ring AU_LEAD chunks (~32 ms) ahead of the DMA engine. On
 * screen: the keyboard with pressed keys lit, the waveform and envelope
 * chips, an oscilloscope of the mix and the envelope curve.
 *
 * Ring 3 only sees key presses (SYS_GETKEY delivers ASCII, no key-up), so a
 * note is one envelope: attack, decay, a sustain hold, release. Controls:
 * TAB or ` cycles the waveform, [ ] the envelope, - = shift the octave,
 * ESC quits. 'demo' auto-plays a sequence (screenshots), 'test' does the
 * same with serial diagnostics (the gate asserts LPIB progress + peaks). */
#include "audio.h"
#include "aui.h"

#define NV 8
enum { OFF, ATT, DEC, SUS, REL };
static struct voice { int note, wave, env, stage, left, step, level; uint32_t ph, inc; } vc[NV];
static int wave, preset, octave = 3, mode, text_only, chunk_no, score_t, peak;
static int16_t scope[AU_CHUNK];
static char buf[80];

/* 12-TET octave 4 in 1/16 Hz (C4 = 261.63 Hz ... B4 = 493.88 Hz) */
static const uint16_t hz16[12] = { 4186, 4435, 4699, 4978, 5274, 5588, 5920, 6272, 6645, 7040, 7459, 7902 };
static const char *const names[12] = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" };
static const char *const wave_names[4]   = { "SINE", "SQUARE", "SAW", "TRI" };
static const char *const preset_names[3] = { "KEYS", "PAD", "PLUCK" };
/* envelope presets: attack, decay, sustain (Q15), hold, release (ms) */
static const int env_ms[3][5] = { { 6, 220, 18000, 260, 320 }, { 140, 400, 24000, 650, 900 }, { 2, 200, 0, 0, 260 } };
/* key -> semitone from C(octave): lower row then upper row (index+12) */
static const char lower[] = "zsxdcvgbhnjm,l.;/", upper[] = "q2w3er5t6y7ui9o0p";
static const unsigned char is_black[12] = { 0,1,0,1,0,0,1,0,1,0,1,0 };

static int key_note(int k) {
    for (int i = 0; lower[i]; i++) if (lower[i] == k) return i;
    for (int i = 0; upper[i]; i++) if (upper[i] == k) return 12 + i;
    return -1;
}

static int ms_samples(int ms) { return ms * (AU_RATE / 1000) + 1; }

static void note_on(int semi) {                        /* semi: 0.. from C(octave) */
    int v = 0;
    for (int i = 0; i < NV; i++) if (vc[i].stage == OFF) { v = i; break; }
    if (vc[v].stage != OFF)                            /* steal the quietest */
        for (int i = 1; i < NV; i++) if (vc[i].env < vc[v].env) v = i;
    struct voice *o = &vc[v];
    int midi = (octave + 1) * 12 + semi;               /* C3 = 48 at octave 3 */
    int oct = midi / 12 - 1, n = midi % 12;            /* octave 4 table, shifted */
    uint32_t inc = au_phase_inc(hz16[n]) / 16;
    o->inc = oct >= 4 ? inc << (oct - 4) : inc >> (4 - oct);
    o->ph = 0; o->note = midi; o->wave = wave;
    o->stage = ATT; o->left = ms_samples(env_ms[preset][0]);
    o->env = 0; o->step = 32767 / o->left;
    if (mode == 2) printf("synth: note %s%d on, %s %s\r\n", names[n], oct, wave_names[wave], preset_names[preset]);
}

/* advance one voice's envelope by one sample; 0 when it just went silent */
static int env_tick(struct voice *o) {
    o->env += o->step;
    if (--o->left > 0) return 1;
    const int *e = env_ms[preset];
    switch (o->stage) {
    case ATT: o->stage = DEC; o->env = 32767; o->left = ms_samples(e[1]); o->step = -(32767 - e[2]) / o->left; break;
    case DEC: o->stage = SUS; o->env = e[2]; o->left = ms_samples(e[3]) * (mode ? 3 : 1); o->step = 0; break;
                                                   /* demo/test: hold 3x, the score rings on */
    case SUS: o->stage = REL; o->left = ms_samples(e[4]); o->step = -o->env / o->left; break;
    default:  o->stage = OFF; o->env = 0; return 0;
    }
    return 1;
}

static int osc(const struct voice *o) {
    uint32_t t = o->ph >> 16;
    switch (o->wave) {
    case 1:  return o->ph < 0x80000000u ? 24000 : -24000;              /* square, a bit softer */
    case 2:  return (int)t - 32768;                                     /* saw */
    case 3:  return t < 32768 ? (int)t * 2 - 32768 : 98303 - (int)t * 2; /* triangle */
    default: return au_sine(o->ph);
    }
}

/* render one chunk of the mix into the out ring + the scope copy */
static void render(int16_t *d) {
    static int32_t mix[AU_CHUNK];
    memset(mix, 0, sizeof mix);
    for (int v = 0; v < NV; v++) {
        struct voice *o = &vc[v];
        if (o->stage == OFF) continue;
        for (int i = 0; i < AU_CHUNK; i++) {
            mix[i] += (osc(o) * o->env) >> 17;                          /* 1/4 scale per voice */
            o->ph += o->inc;
            if (!env_tick(o)) break;
        }
    }
    int pk = 0;
    for (int i = 0; i < AU_CHUNK; i++) {
        int s = mix[i], a = s < 0 ? -s : s;
        if (a > 20000) a = 20000 + (a - 20000) / 3;                   /* soft knee for chords */
        if (a > 32767) a = 32767;
        s = s < 0 ? -a : a;
        if (a > pk) pk = a;
        d[2 * i] = d[2 * i + 1] = (int16_t)s;
        scope[i] = (int16_t)s;
    }
    peak = pk > peak ? pk : peak - (peak >> 5);
    chunk_no++; score_t++;
}

/* ---- screen ------------------------------------------------------------ */
static int KX, KY, KW, KH, SX, SY, SW, SH, EX, EY, EW, EH, CHIPY;
#define NKEYS 29                                   /* C3 .. E5: 17 white keys */
static unsigned char lit[NKEYS];

static void draw_chips(void) {
    int x = 16 * aui_sc, w = 10 * AUI_CW, g = 6 * aui_sc;
    for (int i = 0; i < 4; i++, x += w + g) aui_chip(x, CHIPY, w, wave_names[i], i == wave);
    x += 2 * g;
    for (int i = 0; i < 3; i++, x += w + g) aui_chip(x, CHIPY, w, preset_names[i], i == preset);
    x += 2 * g;
    char *p = aui_str(buf, "OCTAVE "); p = aui_num(p, octave); *p++ = '-'; aui_num(p, octave + 1);
    aui_chip(x, CHIPY, 13 * AUI_CW, buf, 0);
}

/* white key i (0..13) x position; black key sits between whites */
static int white_x(int i) { return KX + i * KW; }
static void draw_key(int semi) {
    int oct = semi / 12, n = semi % 12, wi = 0;
    static const unsigned char white_idx[12] = { 0,0,1,1,2,3,3,4,4,5,5,6 };
    wi = oct * 7 + white_idx[n];
    int on = lit[semi];
    const char *lab = semi < 12 ? lower + semi : upper + semi - 12;   /* C4.. shows q..p */
    char l[2] = { lab[0] >= 'a' ? (char)(lab[0] - 32) : lab[0], 0 };
    if (!is_black[n]) {
        int x = white_x(wi) + aui_sc, w = KW - 2 * aui_sc;
        aui_panel(x, KY, w, KH, on ? AUI_ACCENT : 0xDCE9E4, on ? AUI_ACCENT2 : 0x9BB5AC);
        aui_textc(x + w / 2, KY + KH - AUI_CH - 8 * aui_sc, l, 1, on ? AUI_BG : 0x4F6F66);
        if (n == 0) { char nm[3] = { 'C', (char)('0' + octave + oct), 0 }; aui_textc(x + w / 2, KY + KH - 2 * AUI_CH - 12 * aui_sc, nm, 1, on ? AUI_BG : AUI_DIM); }
        /* a white key redraw must restore the black keys overlapping it */
        if (n > 0 && is_black[n - 1]) draw_key(semi - 1);
        if (n < 11 && is_black[n + 1] && semi + 1 < NKEYS) draw_key(semi + 1);
    } else {
        int bw = KW * 6 / 10, x = white_x(wi + 1) - bw / 2, bh = KH * 62 / 100;
        aui_panel(x, KY, bw, bh, on ? AUI_ACCENT2 : 0x15221E, on ? AUI_ACCENT : 0x0A1210);
        aui_textc(x + bw / 2, KY + bh - AUI_CH - 6 * aui_sc, l, 1, on ? AUI_BG : AUI_DIM);
    }
}
static void draw_keyboard(void) {
    for (int s = 0; s < NKEYS; s++) if (!is_black[s % 12]) draw_key(s);
    for (int s = 0; s < NKEYS; s++) if (is_black[s % 12]) draw_key(s);
}

/* the envelope curve of the current preset (static per preset) */
static void draw_env(void) {
    const int *e = env_ms[preset];
    aui_panel(EX, EY, EW, EH, AUI_PANEL, AUI_BORDER);
    aui_text(EX + 12 * aui_sc, EY + 8 * aui_sc, "ENVELOPE", 1, AUI_ACCENT);
    int tot = e[0] + e[1] + e[3] + e[4], x0 = EX + 12 * aui_sc, w = EW - 24 * aui_sc;
    int yb = EY + EH - 12 * aui_sc, h = EH - AUI_CH - 36 * aui_sc;
    int xa = x0 + w * e[0] / tot, xd = xa + w * e[1] / tot, xs = xd + w * e[3] / tot;
    int ys = yb - h * e[2] / 32767;
    aui_line(x0, yb, xa, yb - h, AUI_ACCENT);
    aui_line(xa, yb - h, xd, ys, AUI_ACCENT);
    aui_line(xd, ys, xs, ys, AUI_ACCENT);
    aui_line(xs, ys, x0 + w, yb, AUI_ACCENT);
    char *p = aui_str(buf, "A "); p = aui_num(p, e[0]); p = aui_str(p, "  D "); p = aui_num(p, e[1]);
    p = aui_str(p, "  S "); p = aui_num(p, e[2] * 100 / 32767); p = aui_str(p, "%  R "); p = aui_num(p, e[4]); aui_str(p, " ms");
    aui_text(EX + 12 * aui_sc, EY + 8 * aui_sc + AUI_CH + 4 * aui_sc, buf, 1, AUI_MUTED);
}

/* oscilloscope of the last chunk, triggered on a rising zero crossing;
 * cleared and redrawn row-wise for speed */
static void draw_scope(void) {
    static int16_t ys[1024];
    int w = SW - 16 * aui_sc, h = SH - AUI_CH - 28 * aui_sc, x0 = SX + 8 * aui_sc, y0 = SY + AUI_CH + 16 * aui_sc;
    int cols = w / aui_sc, trig = 0;
    if (cols > 1024) cols = 1024;
    for (int i = 1; i < AU_CHUNK - cols / 2; i++) if (scope[i - 1] < 0 && scope[i] >= 0) { trig = i; break; }
    for (int i = 0; i < cols; i++) {
        int s = scope[trig + i * 2 * (AU_CHUNK - trig) / (2 * cols)];        /* ~2 samples per column */
        ys[i] = (int16_t)(y0 + h / 2 - (s * (h / 2 - 2 * aui_sc) >> 15));
    }
    for (int y = y0; y < y0 + h; y++) {
        uint32_t *row = aui_fb.base + (unsigned)y * aui_fb.ppsl + x0;
        uint32_t bg = (y >= y0 + h / 2 && y < y0 + h / 2 + aui_sc) ? AUI_DIM : AUI_PANEL;
        for (int i = 0; i < cols; i++) {
            int a = ys[i], b = i + 1 < cols ? ys[i + 1] : a;
            if (a > b) { int t = a; a = b; b = t; }
            uint32_t c = (y >= a - aui_sc && y <= b + aui_sc) ? AUI_ACCENT : bg;
            for (int s = 0; s < aui_sc; s++) row[i * aui_sc + s] = c;
        }
    }
    char *p = aui_str(buf, "peak "); p = aui_num(p, peak * 100 / 32767); aui_str(p, "%  ");
    aui_rect(SX + SW - 11 * AUI_CW, SY + 8 * aui_sc, 10 * AUI_CW, AUI_CH, AUI_PANEL);
    aui_text(SX + SW - 11 * AUI_CW, SY + 8 * aui_sc, buf, 1, AUI_MUTED);
}

static void layout(void) {
    int m = 16 * aui_sc, top = AUI_TOP, bot = AUI_CH + 12 * aui_sc + m;
    aui_title("Synth", "HDA out  48 kHz  8 voices  ~85 ms");
    aui_footer("z..m q..p play   TAB wave   [ ] envelope   - = octave   Q quit");
    CHIPY = top;
    SX = m; SY = top + AUI_CH + 8 * aui_sc + m; SW = aui_fb.w * 62 / 100 - m;
    KH = aui_fb.h * 34 / 100; KY = aui_fb.h - bot - KH; KW = (aui_fb.w - 2 * m) / 17;
    KX = (aui_fb.w - 17 * KW) / 2;
    SH = KY - SY - m;
    EX = SX + SW + m; EY = SY; EW = aui_fb.w - EX - m; EH = SH;
    draw_chips();
    aui_panel(SX, SY, SW, SH, AUI_PANEL, AUI_BORDER);
    aui_text(SX + 12 * aui_sc, SY + 8 * aui_sc, "OSCILLOSCOPE", 1, AUI_ACCENT);
    draw_env();
    draw_keyboard();
}

/* the demo score: (chunk, key) - an arpeggio, a chord, then a waveform change */
static const struct { uint16_t at; char key; } demo[] = {
    { 10, 'q' }, { 24, 'e' }, { 38, 't' }, { 52, 'i' }, { 66, 'o' }, { 80, 'p' },
    { 110, 'z' }, { 110, 'q' }, { 110, 'e' }, { 110, 't' }, { 112, 'o' },
    { 190, '\t' }, { 192, 'c' }, { 206, 'b' }, { 220, 'm' }, { 234, 'u' }, { 234, 'e' },
    { 300, '\t' }, { 302, 'z' }, { 302, 'c' }, { 302, 'b' }, { 302, 'i' },
    { 380, '\t' }, { 382, 'q' }, { 396, 'r' }, { 410, 'y' }, { 424, 'p' }, { 424, 'w' },
    { 0, 0 }
};

int synth_main(const char *arg) {
    mode = arg[0] == 'd' ? 1 : arg[0] == 't' ? 2 : 0;
    if (au_init(1) < 0) return 0;
    if (!au_dac) { print("synth: no output path\r\n"); return 0; }
    print("synth: ready (8 voices, 48 kHz)\r\n");          /* console lines BEFORE the UI owns the screen */
    text_only = aui_begin() < 0;
    if (!text_only) layout();
    while (sys_getkey()) ;                                  /* drop the command line's keys */
    au_out_start();
    int di = 0, frame = 0; uint32_t t_diag = sys_uptime();
    for (;;) {
        int k, busy = 0, key;
        while ((k = au_out_next()) >= 0) { render(au_out_ring + k * AU_CHUNK * 2); busy = 1; }
        if (mode && demo[di].key && score_t >= demo[di].at) {
            key = demo[di++].key;
            if (!demo[di].key) { di = 0; score_t = 0; }        /* loop the score */
            int k2 = sys_getkey();                              /* ESC still quits */
            if (k2 == KEY_ESC || k2 == 'Q') key = k2;   /* a quit key that lands on a demo step must not be lost */
        } else key = sys_getkey();
        if (key == KEY_ESC || key == 'Q') break;              /* ESC (PS/2) or shift-Q: the
                                                               * serial ISR eats a lone ESC
                                                               * (escape-sequence parser) */
        if (key == '\t' || key == '`') { wave = (wave + 1) & 3; if (!text_only) draw_chips(); }
        if (key == '[' || key == ']') { preset = (preset + (key == ']' ? 1 : 2)) % 3; if (!text_only) { draw_chips(); draw_env(); } }
        if (key == '-' && octave > 1) { octave--; if (!text_only) { draw_chips(); draw_keyboard(); } }
        if (key == '=' && octave < 6) { octave++; if (!text_only) { draw_chips(); draw_keyboard(); } }
        int semi = key ? key_note(key) : -1;
        if (semi >= 0) note_on(semi);
        /* keyboard lights follow the voices */
        if (!text_only) {
            for (int s = 0; s < NKEYS; s++) {
                int on = 0;
                for (int v = 0; v < NV; v++) if (vc[v].stage != OFF && vc[v].stage != REL && vc[v].note == (octave + 1) * 12 + s) on = 1;
                if (on != lit[s]) { lit[s] = (unsigned char)on; draw_key(s); }
            }
            if (busy && ++frame >= 6) { frame = 0; draw_scope(); }
        }
        if (mode == 2 && sys_uptime() - t_diag >= 18) {
            t_diag = sys_uptime();
            printf("synth: t=%u out-lpib=%u chunks=%d peak=%d underruns=%d\r\n",
                   t_diag, au_out_lpib(), chunk_no, peak, au_out_underruns);
        }
    }
    au_out_stop();
    { uint32_t t = sys_uptime(); while (sys_uptime() - t < 3) sys_yield(); }   /* let the shell echo the key first */
    printf("synth: quit (chunks %d, out-lpib %u, underruns %d)\r\n", chunk_no, au_out_lpib(), au_out_underruns);
    return 0;
}
