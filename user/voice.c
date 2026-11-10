/* voice.c - 'run voice [secs] [test]': plant a wish by speaking it.
 *
 * Records `secs` seconds (default 4) from the microphone through the HDA
 * engine, decimates the 48 kHz stereo capture to 16 kHz mono PCM, wraps it
 * as a WAV and POSTs it to the host proxy's /stt endpoint over the OS's own
 * TCP stack (llm-proxy.py runs Whisper or forwards to STT_URL; --mock
 * answers a fixed transcript). The transcript is shown and staged as the
 * script "wish <transcript>" in AgentFS slot 7, so
 *
 *     run voice; wait; script 7
 *
 * speaks, transcribes and plants the wish through the very same `wish`
 * command path (needs `diskon`, like every slot write). 'test' swaps the
 * microphone for the deterministic test signal (the headless gate). */
#include "audio.h"
#include "aui.h"

int http_post_bin(const char *path, const uint8_t *data, int len, char *cap, int capmax);

#define VR 16000
static uint8_t *wav;
static char reply[480];
static int secs = 4, test, quiet, text_only, level, peak, n16;
static char log1[120], log2[300];                    /* deferred console lines (demo) */
static uint32_t tp_phase;
static int CX, CY, CW, CH, TX, TY, TW, TH;
static char buf[96];

static void card(const char *head, const char *line, uint32_t col) {
    aui_panel(CX, CY, CW, CH, AUI_PANEL, AUI_BORDER);
    aui_text(CX + 16 * aui_sc, CY + 12 * aui_sc, head, 2, col);
    aui_text(CX + 16 * aui_sc, CY + 12 * aui_sc + 2 * AUI_CH + 8 * aui_sc, line, 1, AUI_MUTED);
}

/* the three steps of a voice wish, lit as they complete (0..3) */
static void steps(int done) {
    static const char *const st[3] = { "1  record 16 kHz WAV", "2  POST /stt -> transcript", "3  script 7  ->  wish" };
    int w = 27 * AUI_CW, g = 10 * aui_sc, y = TY + TH - AUI_CH - 24 * aui_sc;
    for (int i = 0; i < 3; i++) aui_chip(TX + 16 * aui_sc + i * (w + g), y, w, st[i], i < done);
}

/* word-wrapped transcript, as large as fits (3x, else 2x) */
static void transcript(const char *t, uint32_t col, int done) {
    aui_panel(TX, TY, TW, TH, AUI_PANEL, AUI_ACCENT2);
    aui_text(TX + 16 * aui_sc, TY + 12 * aui_sc, "TRANSCRIPT", 1, AUI_ACCENT);
    int sc = strlen(t) * 3 * AUI_CW < (TW - 32 * aui_sc) * 2 ? 3 : 2;
    int maxc = (TW - 32 * aui_sc) / (sc * AUI_CW), y = TY + 12 * aui_sc + AUI_CH + 20 * aui_sc;
    if (*t) aui_text(TX + 16 * aui_sc, y, "\"", sc, AUI_DIM);
    while (*t) {
        int n = strlen(t), cut = n;
        if (n > maxc) { cut = maxc; while (cut > 0 && t[cut] != ' ') cut--; if (!cut) cut = maxc; }
        for (int i = 0; i < cut && i < 95; i++) buf[i] = t[i];
        buf[cut < 95 ? cut : 95] = 0;
        aui_text(TX + 16 * aui_sc + sc * AUI_CW, y, buf, sc, col);
        y += sc * AUI_CH + 6 * aui_sc;
        t += cut; while (*t == ' ') t++;
        if (y > TY + TH - 5 * AUI_CH) break;
    }
    steps(done);
}

static void layout(void) {
    int m = 16 * aui_sc, top = AUI_TOP, bot = AUI_CH + 12 * aui_sc + m;
    aui_title("Voice", test ? "HDA mic  16 kHz  test signal" : "HDA mic  16 kHz  -> /stt");
    aui_footer("speak your wish   any key quits   then: script 7 plants it");
    CX = m; CY = top; CW = aui_fb.w - 2 * m; CH = 4 * AUI_CH + 64 * aui_sc;
    TX = m; TY = CY + CH + m; TW = CW; TH = aui_fb.h - bot - TY;
    transcript("", AUI_TEXT, 0);
}

int voice_main(const char *arg) {
    for (const char *p = arg; *p; p++) {
        if (*p >= '1' && *p <= '9' && (p == arg || p[-1] == ' ')) secs = *p - '0';
        if (*p == 't' && p[1] == 'e') test = 1;
        if (*p == 'd' && p[1] == 'e') test = quiet = 1;      /* demo: test signal, no mid-run prints */
    }
    if (au_init(1) < 0) return 0;
    if (!au_has_in() && !test) { print("voice: this codec has no input path (try 'run voice test')\r\n"); return 0; }
    n16 = secs * VR;
    wav = malloc(44 + n16 * 2);
    if (!wav) { print("voice: out of memory\r\n"); return 0; }
    int16_t *pcm = (int16_t *)(wav + 44);
    printf("voice: listening for %d s%s ...\r\n", secs, test ? " (test signal)" : "");
    text_only = aui_begin() < 0;
    if (!text_only) { layout(); card("Listening ...", "say the wish you want the agents to grow", AUI_DANGER); }
    while (sys_getkey()) ;

    /* capture: 48 kHz stereo chunks -> 16 kHz mono (every 3 frames, L+R) */
    au_in_start();
    int got = 0, chunks = 0, drawn = 0; uint32_t t0 = sys_uptime();
    while (got < n16) {
        int k = au_in_next();
        if (k < 0) { if (sys_uptime() - t0 > (uint32_t)secs * 18 + 90) break; continue; }   /* DMA stalled */
        int16_t *c = au_in_ring + k * AU_CHUNK * 2;
        if (test) au_test_pattern(c, AU_CHUNK, &tp_phase, chunks);
        int pk = 0;
        for (int i = 0; i + 2 < AU_CHUNK && got < n16; i += 3) {
            int m = (c[2*i] + c[2*i+1] + c[2*i+2] + c[2*i+3] + c[2*i+4] + c[2*i+5]) / 6;
            pcm[got++] = (int16_t)m;
            int a = m < 0 ? -m : m; if (a > pk) pk = a;
        }
        level = pk > level ? pk : level - (level >> 3);
        if (pk > peak) peak = pk;
        chunks++;
        sys_progress(got / (n16 / 100 + 1));
        if (!text_only && ++drawn >= 6) {
            drawn = 0;
            aui_meter(CX + 16 * aui_sc, CY + CH - 40 * aui_sc, CW - 32 * aui_sc, 14 * aui_sc, level, peak);
            int w = (CW - 32 * aui_sc) * got / n16;                      /* progress */
            aui_rect(CX + 16 * aui_sc, CY + CH - 16 * aui_sc, CW - 32 * aui_sc, 4 * aui_sc, AUI_PANEL2);
            aui_rect(CX + 16 * aui_sc, CY + CH - 16 * aui_sc, w, 4 * aui_sc, AUI_ACCENT);
        }
    }
    au_in_stop();
    au_wav_header(wav, VR, 1, (uint32_t)got * 2);
    { char *q = aui_str(log1, "voice: captured "); q = aui_num(q, got); q = aui_str(q, " samples (");
      q = aui_num(q, chunks); q = aui_str(q, " chunks, in-lpib "); q = aui_num(q, (int)au_in_lpib());
      q = aui_str(q, ", peak "); q = aui_num(q, peak); q = aui_str(q, "), sending ");
      q = aui_num(q, 44 + got * 2); aui_str(q, " bytes to /stt\r\n"); }
    if (!quiet) print(log1);
    if (!text_only) { card("Transcribing ...", "the host proxy runs the speech model", AUI_WARN); steps(1); }

    int r = http_post_bin("/stt", wav, 44 + got * 2, reply, sizeof reply);
    char *t = reply;
    while (*t == ' ' || *t == '\r' || *t == '\n') t++;
    for (char *e = t + strlen(t); e > t && (e[-1] == '\r' || e[-1] == '\n' || e[-1] == ' '); e--) e[-1] = 0;
    if (r <= 0 || !*t) {
        aui_str(log2, "voice: no answer - is llm-proxy.py running on the dev box?\r\n");
        if (!text_only) card("No answer", "start llm-proxy.py on the host (--mock for a canned transcript)", AUI_DANGER);
    } else if (t[0] == 'S' && t[1] == 'T' && t[2] == 'T') {                /* "STT error: ..." */
        { char *q = aui_str(log2, "voice: "); q = aui_str(q, t); aui_str(q, "\r\n"); }
        if (!text_only) { card("Transcription failed", t, AUI_DANGER); }
    } else {
        { char *q = aui_str(log2, "voice: transcript: "); q = aui_str(q, t); aui_str(q, "\r\n"); }
        if (!text_only) { card("Heard you.", "the wish is staged as 'wish <transcript>' in slot 7", AUI_ACCENT); transcript(t, AUI_TEXT, 2); }
        static uint8_t sec[512];                     /* AgentFS slot: 'A' 'F' | len | text */
        memset(sec, 0, 512);
        sec[0] = 'A'; sec[1] = 'F';
        int n = 0;
        for (const char *s = "wish "; *s; s++) sec[3 + n++] = (uint8_t)*s;
        for (int i = 0; t[i] && n < 205; i++) sec[3 + n++] = (uint8_t)(t[i] < ' ' ? ' ' : t[i]);
        sec[2] = (uint8_t)n;
        if (sys_write_slot(7, sec) == 0) {
            aui_str(log2 + strlen(log2), "voice: staged in slot 7 - plant it:  script 7   (or: run voice; wait; script 7)\r\n");
            if (!text_only) steps(3);
        }
        else {
            char *q = aui_str(log2 + strlen(log2), "voice: slot write refused ('diskon' first) - plant it by hand:  wish ");
            q = aui_str(q, t); aui_str(q, "\r\n");
        }
    }
    /* console lines while the UI is up would make the kernel scroll the
     * framebuffer under us - the demo defers them to the end */
    if (!quiet) print(log2);
    /* leave the result on screen for a moment (any key ends it earlier) */
    t0 = sys_uptime();
    while (sys_uptime() - t0 < (quiet ? 20 : 8) * 18 && !sys_getkey()) sys_yield();
    if (quiet) { print(log1); print(log2); }
    return 0;
}
