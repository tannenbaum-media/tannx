/* tour.c - 'run tour': the guided tour for first-time users.
 *
 * Seven step cards in the brand style (dark teal-green, accent #2DD4BF): what
 * TannX is, agents and tasks, fault isolation, planting a wish, the LLM
 * and Claude Code loop, and where to go next. The agent steps are LIVE: the
 * tour types real shell commands through SYS_SHELL ('spawn prime', 'task
 * prime 100', 'task scan b8000'), waits for the prompt to come back, reads
 * what the shell and the agents printed through SYS_CONSOLE and shows it in
 * a terminal panel inside the card. Nothing is faked.
 *
 * Keys: Enter / n / space = next, b / p = back, q / ESC = quit. The tour owns
 * the keyboard (SYS_FGRAB) so the keys never reach the shell line.
 * Serial markers for the headless test: "tour: ready", "tour: step N",
 * "tour: done". */
#include "dui.h"

typedef struct {
    const char *kicker;     /* small label above the title            */
    const char *title;      /* big title                              */
    const char *body;       /* paragraphs separated by '\n'           */
    const char *cmd[3];     /* live commands run when the step opens  */
    int         settle;     /* ticks to wait for async agent output   */
} step_t;

static const step_t steps[] = {
    { "WELCOME", "Plant a wish. The agents grow it.",
      "TannX OS is a bootable 32-bit x86 operating system whose kernel is pure "
      "GNU assembler and whose programs run in ring 3, written in freestanding C. "
      "You are looking at one of those programs right now.\n"
      "Its one idea: the AGENT is the first-class citizen and the LLM is part of the "
      "toolchain. Whatever is missing is not lamented but wished for, from inside the "
      "running OS - and the next coding session grows it.\n"
      "This tour runs real commands on the shell underneath and shows you the output. "
      "Press Enter to continue.",
      { 0, 0, 0 }, 0 },
    { "STEP 1 - AGENTS", "Agents live in ring 3",
      "An agent is a worker thread with a type: math, scan, count, prime, gcd, or ask "
      "(the LLM agent). The kernel schedules it preemptively, it talks to the kernel "
      "only through one syscall gate (INT 0x30) and it can never touch kernel memory.\n"
      "The tour just typed 'spawn prime' into the shell for you. Below is what the OS "
      "printed: the agent got a slot and a name and is waiting for work.",
      { "spawn prime", 0, 0 }, 10 },
    { "STEP 2 - TASKS", "Give them work",
      "'task prime 100' hands the prime agent a job: find the 100th prime. The shell "
      "returns immediately; the agent claims the task, reports progress, and pushes the "
      "result back through the gate. 'tasks' lists the table, 'waittask 0' joins on it.\n"
      "The result line below was printed by the kernel when the agent finished - the "
      "100th prime is 541.",
      { "task prime 100", "tasks", 0 }, 30 },
    { "STEP 3 - ISOLATION", "Faults stay in their box",
      "'task scan b8000' makes a scan agent read VGA RAM, which ring 3 may not touch. "
      "The CPU raises a page fault, the kernel kills THAT agent and prints why - and "
      "the shell, this tour and every other agent keep running.\n"
      "Try it yourself later: 'dump 0' faults in the shell itself and is caught too.",
      { "spawn scan", "task scan b8000", 0 }, 25 },
    { "STEP 4 - WISHES", "Plant a wish",
      "Something missing? Wish for it, from inside the OS:\n"
      "    diskon\n"
      "    wish build me a tetris game\n"
      "The wish is stored on the OS's own disk (LBA 265-272). On the host, 'make wishes' "
      "harvests it and the next LLM coding session builds the feature, runs the 35-suite "
      "test gate and commits - so the next boot has it. Most of this OS came to be that way.\n"
      "(The tour does not plant one for you: your wish slots are yours.)",
      { 0, 0, 0 }, 0 },
    { "STEP 5 - THE LOOP", "The LLM is part of the toolchain",
      "Start the host proxy ('./llm-proxy.py', or '--mock' for canned answers) and the "
      "OS can talk to a model over its own ring-3 TCP/IP stack:\n"
      "    llm what is a page fault        ask a model from the shell\n"
      "    llmscript 6 count to 100        the model WRITES an OS script into slot 6\n"
      "    script 6                        ... and the OS runs it\n"
      "    autopilot                       ask, run, ask again - the OS flies itself\n"
      "With '--backend claude' the proxy hands your wishes to Claude Code on the host: "
      "it edits the source, rebuilds, tests - and the OS reboots into its new self.",
      { 0, 0, 0 }, 0 },
    { "STEP 6 - WHERE NEXT", "Explore the forest",
      "    help           every shell command\n"
      "    gui            the desktop compositor (runs beside the shell)\n"
      "    run www <url>  a text web browser through the host proxy\n"
      "    run files      the FAT file manager (virtio-blk, USB, NVMe)\n"
      "    run shot       screenshot -> SHOTnnnn.BMP on the FAT volume\n"
      "    run cast       stream YouTube / media to a Chromecast via the proxy\n"
      "    run rain       the agent rain screensaver\n"
      "    snake, invaders, play cdefg, sysinfo, lspci, smpon ...\n"
      "Thank you for visiting. Press Enter or q to return to the shell.",
      { 0, 0, 0 }, 0 },
};
#define NSTEPS ((int)(sizeof steps / sizeof steps[0]))

/* card geometry in cells */
static int cx0, cy0, cw, chh;             /* card origin + size (cells) */
static int termrow;                       /* first row of the terminal panel */
static char termbuf[DUI_CON_LINES][81];
static int  termn;

/* word-wrap one paragraph into the card; returns the next free row */
static int wrap_para(const char *p, int row, int width, uint32_t col) {
    int i = 0;
    while (p[i] && p[i] != '\n') {
        char line[200]; int n = 0, lastsp = -1;
        while (p[i] && p[i] != '\n' && n < width) {
            line[n] = p[i];
            if (p[i] == ' ') lastsp = n;
            n++; i++;
        }
        if (p[i] && p[i] != '\n' && lastsp > 0) { i -= (n - lastsp - 1); n = lastsp; }
        line[n] = 0;
        if (row < cy0 + chh - 1) dui_text(cx0 + 3, row, line, col);
        row++;
    }
    return row;
}

static int termh;                          /* rows: title + lines + pad */
static void draw_term(int running) {
    int x = (cx0 + 2) * DUI.cw, y = termrow * DUI.ch;
    int w = (cw - 4) * DUI.cw, h = termh * DUI.ch;
    dui_panel(x, y, w, h, 0x06110Fu, DUI_LINE);
    dui_fill(x, y, w, DUI.ch, 0x0B1A17u);
    dui_text(cx0 + 3, termrow, "LIVE CONSOLE  -  the shell underneath, in real time", DUI_DIM);
    if (running) { dui_text(cx0 + 3, termrow + 1, "running on the shell ...", DUI_WARN); return; }
    for (int i = 0; i < termn && i < DUI_CON_LINES; i++) {
        const char *l = termbuf[i];
        uint32_t c = dui_startswith(l, "tannx> ") ? DUI_ACCENT
                   : dui_startswith(l, ">>") ? DUI_OK
                   : dui_startswith(l, "***") ? DUI_BAD : DUI_TEXT;
        dui_textn(cx0 + 3, termrow + 1 + i, l, cw - 6, c);
    }
}

/* a fir skyline along the bottom of a text-only card */
static void draw_forest(int px, int py, int w, int h) {
    static const unsigned char sz[] = { 3, 5, 4, 7, 5, 8, 6, 4, 7, 5, 3, 6, 4, 8, 5, 3 };
    int n = (int)sizeof sz, x = px;
    int step = w / (n + 1);
    for (int i = 0; i < n && x + 12 * sz[i] < px + w; i++, x += step) {
        int s = (int)sz[i] * DUI.sc / 2; if (s < 1) s = 1;
        dui_logo(x, py + h - 20 * s, s);
    }
}

static void draw_step(int n, int running) {
    const step_t *s = &steps[n];
    dui_clear(DUI_BG);
    dui_header("Guided tour", "q quits");
    dui_footer("Enter / n / space: next    b: back    q: quit");
    cx0 = 2; cy0 = 4; cw = DUI.cols - 4; chh = DUI.rows - 6;
    int px = cx0 * DUI.cw, py = cy0 * DUI.ch;
    dui_panel(px, py, cw * DUI.cw, chh * DUI.ch, DUI_PANEL, DUI_LINE);
    dui_fill(px, py, 4, chh * DUI.ch, DUI_ACCENT);                 /* accent spine */

    char lab[48]; dui_strcpy(lab, s->kicker, sizeof lab);
    dui_text(cx0 + 3, cy0 + 1, lab, DUI_ACCENT);
    if (n > 0) {
        char pg[24]; char *e = dui_utoa(pg, (uint32_t)n);
        dui_strcpy(e, " OF ", 6); dui_utoa(e + 4, (uint32_t)(NSTEPS - 1));
        dui_text(cx0 + cw - 4 - dui_strlen(pg), cy0 + 1, pg, DUI_DIM);
    }
    dui_text_big(cx0 + 3, cy0 + 2, s->title, DUI_TEXT);
    dui_hline(px + 3 * DUI.cw, py + 5 * DUI.ch - DUI.sc * 2, (dui_strlen(s->title) * 2) * DUI.cw, DUI_LINE);

    int width = cw - 8; if (width > 96) width = 96;
    int row = cy0 + 6;
    const char *p = s->body;
    while (*p) {
        row = wrap_para(p, row, width, dui_startswith(p, "    ") ? DUI_ACCENT2 : DUI_TEXT);
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
        row++;
    }
    termrow = row + 1;                      /* the console fills the rest of the card */
    termh = cy0 + chh - 4 - termrow;
    if (termh > DUI_CON_LINES + 3) termh = DUI_CON_LINES + 3;
    if (s->cmd[0]) draw_term(running);
    else draw_forest(px + 3 * DUI.cw, (row + 1) * DUI.ch, (cw - 6) * DUI.cw,
                     (cy0 + chh - 4 - row - 1) * DUI.ch);

    /* progress dots + the Next/Back buttons on the card's bottom edge */
    int by = (cy0 + chh - 2) * DUI.ch;
    for (int i = 0; i < NSTEPS; i++)
        dui_fill(px + 3 * DUI.cw + i * 2 * DUI.cw, by + DUI.ch / 2 - DUI.sc, DUI.cw, 2 * DUI.sc,
                i == n ? DUI_ACCENT : i < n ? DUI_DIM : DUI_LINE);
    int bx = px + (cw - 2) * DUI.cw;
    if (n < NSTEPS - 1) {
        bx -= 10 * DUI.cw;
        dui_panel(bx, by, 9 * DUI.cw, DUI.ch + 4 * DUI.sc, DUI_ACCENT, DUI_ACCENT2);
        dui_textpx(bx + DUI.cw, by + 2 * DUI.sc, " Next >", DUI.sc, DUI_BG);
    } else {
        bx -= 10 * DUI.cw;
        dui_panel(bx, by, 9 * DUI.cw, DUI.ch + 4 * DUI.sc, DUI_ACCENT, DUI_ACCENT2);
        dui_textpx(bx + DUI.cw, by + 2 * DUI.sc, " Done  ", DUI.sc, DUI_BG);
    }
    if (n > 0) {
        bx -= 10 * DUI.cw;
        dui_panel(bx, by, 9 * DUI.cw, DUI.ch + 4 * DUI.sc, DUI_PANEL2, DUI_LINE);
        dui_textpx(bx + DUI.cw, by + 2 * DUI.sc, "< Back ", DUI.sc, DUI_TEXT);
    }
}

/* wait until no task is waiting/running any more (the agents finished or
 * were shot down), so the console holds their result lines. tasks_tbl entry:
 * +0 used, +2 status (0 waiting / 1 running / 2 done / 3 ERROR). */
static void wait_tasks(int maxticks) {
    static unsigned char tbl[192];
    uint32_t t0 = sys_uptime();
    for (;;) {
        int busy = 0;
        if (sys_agents(tbl) == 0)
            for (int i = 0; i < 8; i++) { const unsigned char *t = tbl + 64 + i * 16; if (t[0] && t[2] < 2) busy = 1; }
        if (!busy || sys_uptime() - t0 > (uint32_t)maxticks) break;
        dui_sleep(2);
    }
}

/* run the step's live commands, collecting the console lines of all of them */
static void run_step(int n) {
    const step_t *s = &steps[n];
    termn = 0;
    if (!s->cmd[0]) return;
    draw_step(n, 1);
    for (int c = 0; c < 3 && s->cmd[c]; c++) {
        char out[DUI_CON_LINES][81];
        int got = dui_run_shell(s->cmd[c], out, 90, 0);
        if (!s->cmd[c + 1] && s->settle) {           /* last command: let the agents finish */
            wait_tasks(s->settle * 4);
            dui_sleep(s->settle / 2);                 /* the kernel prints their result lines */
            got = dui_console_rows(DUI.last_r0, out);
        }
        /* the panel shows "tannx> <cmd>" + what came back; the shell's own
         * echo row and the tour's serial markers are dropped */
        if (termn < DUI_CON_LINES) {
            dui_strcpy(termbuf[termn], "tannx> ", 81);
            dui_strcpy(termbuf[termn] + 8, s->cmd[c], 72);
            termn++;
        }
        for (int i = 0; i < got && termn < DUI_CON_LINES; i++) {
            const char *l = out[i];
            if (dui_startswith(l, "tannx> ")) l += 8;
            if (!*l || dui_startswith(l, "tour: ") || dui_startswith(l, s->cmd[c])) continue;
            dui_strcpy(termbuf[termn++], l, 81);
        }
    }
    sys_fgrab(1);          /* a killed agent (step 3) releases fg_prog - take it back */
    printf("tour: step %d ran %s\r\n", n, s->cmd[0]);
}

int tour_main(void) {
    if (dui_init() < 0) {
        print("tour: needs a framebuffer (VBE/GOP) - boot with -vga std\r\n");
        return 0;
    }
    sys_fgrab(1);
    dui_flush_keys();       /* the ring still holds the 'run tour' keystrokes */
    print("tour: ready\r\n");
    char dummy[DUI_CON_LINES][81];
    dui_run_shell("clear", dummy, 36, 4);        /* a clean console to read from */
    int n = 0;
    run_step(0);
    draw_step(0, 0);
    for (;;) {
        int k = dui_getkey();
        if (k == 'q' || k == DUI_KEY_ESC) break;
        if (k == 'n' || k == ' ' || k == DUI_KEY_ENTER || k == '\n') {
            if (n == NSTEPS - 1) break;
            n++;
            printf("tour: step %d\r\n", n);
            run_step(n);
            draw_step(n, 0);
        } else if ((k == 'b' || k == 'p') && n > 0) {
            n--;
            printf("tour: step %d\r\n", n);
            run_step(n);
            draw_step(n, 0);
        }
    }
    dui_clear(DUI_BG);
    print("tour: done - type 'help' to see every command\r\n");
    sys_fgrab(0);
    return 0;
}
