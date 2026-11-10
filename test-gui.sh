#!/usr/bin/env bash
# ============================================================
#  Dark Glass compositor test. The `gui` command launches a ring-3
#  program (user/gui.c) that OWNS the framebuffer: the kernel sets
#  compositor_active and stops drawing, the compositor renders a deep
#  navy "Dark Glass" gradient wallpaper. We screendump the framebuffer
#  and verify the compositor's exact gradient is on screen (top color,
#  and that it lifts toward the bottom), and that the shell still lives
#  underneath (the compositor does not grab the keyboard).
# ============================================================
set -u
cd "$(dirname "$0")"
command -v qemu-system-i386 >/dev/null 2>&1 || { echo "qemu missing"; exit 2; }
command -v nc >/dev/null 2>&1 || { echo "nc missing"; exit 2; }
make agentos32.img >/dev/null 2>&1 || { echo "build failed"; exit 1; }

PPM="$(mktemp --suffix=.ppm)"; PPM2=""; PPM3=""; PA=""; PB=""
LOG="$(mktemp)"; FIFO="$(mktemp -u)"; mkfifo "$FIFO"
IMG="$(mktemp --suffix=.img)"; cp agentos32.img "$IMG"
MPORT=55573
QPID=""
cleanup() {
  exec 3>&- 2>/dev/null
  [ -n "$QPID" ] && kill "$QPID" 2>/dev/null
  [ -n "$QPID" ] && wait "$QPID" 2>/dev/null
  rm -f "$FIFO" "$IMG" "$PPM" "$PPM2" "$PPM3" "$PA" "$PB" "$LOG"
}
trap cleanup EXIT
agent_panel_ready() { python3 - "$1" <<'PY'
import sys
try:
    f=open(sys.argv[1],"rb")
    if f.readline().strip()!=b"P6":
        sys.exit(1)
    w,h=map(int,f.readline().split()); f.readline()
    d=f.read()
    def px(x,y):
        o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    panel=0
    for y in range(h//16, h//3, 1):
        for x in range(int(w*0.91), w-2, 1):
            r,g,b=px(x,y)
            if r>90 or g>110 or b>150:
                panel+=1
    sys.exit(0 if panel > 60 else 1)
except Exception:
    sys.exit(1)
PY
}
qemu-system-i386 -drive format=raw,file="$IMG" -vga std \
  -monitor telnet:127.0.0.1:$MPORT,server,nowait -net none -nographic <"$FIFO" >"$LOG" 2>/dev/null &
QPID=$!
exec 3>"$FIFO"
sleep 4
PPM2="$(mktemp --suffix=.ppm)"; PPM3="$(mktemp --suffix=.ppm)"
PA="$(mktemp --suffix=.ppm)"; PB="$(mktemp --suffix=.ppm)"
printf 'sysinfo\r' >&3;         sleep 2          # colourful console output to render
printf 'spawn prime\r' >&3;     sleep 1          # an agent for the Dark Glass AGENTS panel
printf 'task prime 100\r' >&3;  sleep 2          # give it work -> a result to show
printf 'gui\r' >&3;             sleep 2
# the top-bar accent line "breathes" - two frames apart differ in brightness
printf "screendump %s\n" "$PA" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
printf "screendump %s\n" "$PB" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1; sleep 1
# long scrolling output: the kernel must NOT shift framebuffer pixels under the
# compositor (fb_scroll/fb_clear gated) or it leaves black patches behind
printf 'help\r' >&3;            sleep 1
printf ' ' >&3; sleep 1; printf ' ' >&3; sleep 1   # page through the 'more' pager
printf 'tasks\r' >&3;           sleep 2
printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1
sleep 1
for _try in 1 2 3; do
  agent_panel_ready "$PPM" && break
  sleep 1
  printf "screendump %s\n" "$PPM" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1
done
# coexistence: a foreground game takes the screen, the compositor steps aside,
# and reclaims it (rebuilding after the game's crt0 wiped the shared .bss).
printf 'snake\r' >&3;           sleep 5    # let snake fully take the FB (loaded gate)
printf "screendump %s\n" "$PPM2" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1
sleep 1
printf 'q' >&3; sleep 1; printf 'q' >&3;  sleep 3   # 'q' quits snake (reaches key_ring)
printf "screendump %s\n" "$PPM3" | timeout 5 nc 127.0.0.1 $MPORT >/dev/null 2>&1
sleep 1
printf 'echo shell-after-gui\r' >&3;  sleep 2    # the shell must still answer
printf 'halt\r' >&3;            sleep 1
exec 3>&- 2>/dev/null; kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""

# fraction (%) of sampled pixels that differ between two screendumps - used to
# prove the game took the screen from the compositor (and vice versa)
framediff() { python3 - "$1" "$2" <<'PY'
import sys
try:
    def load(p):
        f=open(p,'rb'); f.readline(); w,h=map(int,f.readline().split()); f.readline(); return w,h,f.read()
    w,h,a=load(sys.argv[1]); _,_,b=load(sys.argv[2])
    tot=diff=0
    for y in range(0,h,7):
        for x in range(0,w,7):
            o=(y*w+x)*3; tot+=1
            if abs(a[o]-b[o])+abs(a[o+1]-b[o+1])+abs(a[o+2]-b[o+2]) > 40: diff+=1
    print(100*diff//max(tot,1))
except Exception: print(0)
PY
}
# count the neon-cyan spinner pixels in the right margin of a screendump
spincount() { python3 - "$1" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb'); f.readline(); w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    def px(x,y): o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    n=0
    for y in range(h//2-220,h//2+220,2):
        for x in range(int(w*0.78),w,2):
            r,g,b=px(x,y)
            if b>120 and g>100 and r<140 and b>r+30: n+=1
    print(n)
except Exception: print(0)
PY
}
S_GLASS="$(spincount "$PPM")"; S_BACK="$(spincount "$PPM3")"
D_GAME="$(framediff "$PPM" "$PPM2")"     # how much the game changed the screen
# accent-line brightness (the band just above the top bar) of two frames apart
accbright() { python3 - "$1" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb'); f.readline(); w,h=map(int,f.readline().split()); f.readline(); d=f.read()
    best=0
    for y in range(80,100):
        o=((y*w)+w//2)*3
        if d[o+2]>best: best=d[o+2]
    print(best)
except Exception: print(0)
PY
}
A_A="$(accbright "$PA")"; A_B="$(accbright "$PB")"
DIFF=$(( A_A>A_B ? A_A-A_B : A_B-A_A ))

echo "==== Dark Glass compositor checks ===="
fail=0
chk() { if [ "$1" = 1 ]; then echo "OK   : $2"; else echo "FAIL : $2"; fail=1; fi; }

grep -aq 'shell-after-gui' "$LOG" && a=1 || a=0
chk "$a" "shell still answers while the compositor runs (no keyboard grab)"

# Parse the screendump and verify the compositor's gradient wallpaper.
RES="$(python3 - "$PPM" <<'PY'
import sys
try:
    f=open(sys.argv[1],'rb')
    if f.readline().strip()!=b'P6': print("noppm"); sys.exit(0)
    w,h=map(int,f.readline().split()); f.readline()
    d=f.read()
    def px(x,y):
        o=(y*w+x)*3; return d[o],d[o+1],d[o+2]
    # sample bare wallpaper in the left margin (the panels are centred), below
    # the top bar: must be dark navy and lift toward the bottom
    tr,tg,tb=px(10, h//5)
    br,bg,bb=px(10, h-10)
    top_ok = tr<28 and tg<34 and tb<48 and tb>tr   # dark + bluish navy
    grad_ok = bb > tb and bg > tg
    # console text: count glyph pixels in the centre region clearly brighter than
    # the glass background (catches grey/green/cyan console output)
    ink=0
    for y in range(h//4, 3*h//4, 3):
        for x in range(w//4, 3*w//4, 3):
            r,g,b=px(x,y)
            if r>90 or g>110 or b>150: ink+=1
    text_ok = ink > 300
    # software-3D accent: neon-cyan wireframe in the right wallpaper margin
    spin=0
    for y in range(h//2-220, h//2+220, 2):
        for x in range(int(w*0.78), w, 2):
            r,g,b=px(x,y)
            if b>120 and g>100 and r<140 and b>r+30: spin+=1
    spin_ok = spin > 80
    # scroll cleanliness: after 'help' scrolled, the glass panel must have NO
    # black patches (the fb_scroll-under-compositor bug). Count true-black px in
    # the panel centre - clean Dark Glass is navy/text there, never near-black.
    black=0; samp=0
    for y in range(h//3, 2*h//3, 3):
        for x in range(w//4, 3*w//5, 3):
            r,g,b=px(x,y); samp+=1
            if r<8 and g<8 and b<8: black+=1
    clean_ok = black < samp//20      # <5% black
    # AGENTS panel: a thin glass panel in the far-right margin (past the centred
    # console, x>0.91w), above the spinner (y<h/3). After `spawn prime; task
    # prime 100` it shows the "AGENTS" header + a prime row with its result -
    # count bright text pixels in that clean band (empty wallpaper otherwise).
    panel=0
    for y in range(h//16, h//3, 1):
        for x in range(int(w*0.91), w-2, 1):
            r,g,b=px(x,y)
            if r>90 or g>110 or b>150: panel+=1
    panel_ok = panel > 60
    # P1 drop shadow: the full-width top bar casts a soft dark band on the
    # wallpaper just below it (~TOPBAR..TOPBAR+SH_R). At the gate's 2560x1600
    # TOPBAR=96 and the console panel starts at y=200, so the shadow trough sits
    # at y~0.065h and clean wallpaper baseline at y~0.11h. The trough must be
    # clearly darker (without the shadow both are the same gentle gradient).
    s_near = min(sum(px(w//2, y)) for y in range(int(h*0.062), int(h*0.072)))
    s_base = sum(px(w//2, int(h*0.11)))
    shadow_ok = s_near < s_base - 8
    # P3 status chip: an "AGENTS N" glass chip sits in the top bar (y<TOPBAR),
    # left of the clock (clock is past ~0.94w). Count bright text px in that
    # band - empty top-bar glass otherwise. (the test spawns an agent before gui)
    chip = 0
    for y in range(int(h*0.012), int(h*0.058)):
        for x in range(int(w*0.80), int(w*0.93)):
            r,g,b = px(x,y)
            if r>90 or g>110 or b>150: chip += 1
    chip_ok = chip > 30
    print(f"top={tr},{tg},{tb} bottom={br},{bg},{bb} ink={ink} spin={spin} panel={panel} chip={chip} black={black}/{samp} shadow={s_near}<{s_base} top_ok={int(top_ok)} grad_ok={int(grad_ok)} text_ok={int(text_ok)} spin_ok={int(spin_ok)} clean_ok={int(clean_ok)} panel_ok={int(panel_ok)} shadow_ok={int(shadow_ok)} chip_ok={int(chip_ok)}")
except Exception as e:
    print("err", e)
PY
)"
echo "  $RES"
echo "$RES" | grep -q 'top_ok=1' && b=1 || b=0
chk "$b" "wallpaper is the Dark Glass navy (dark, bluish)"
echo "$RES" | grep -q 'grad_ok=1' && c=1 || c=0
chk "$c" "wallpaper is a vertical gradient (lifts toward the bottom)"
echo "$RES" | grep -q 'text_ok=1' && e=1 || e=0
chk "$e" "console text renders inside the glass panel (SYS_CONSOLE shadow)"
echo "$RES" | grep -q 'spin_ok=1' && g=1 || g=0
chk "$g" "software-3D wireframe accent renders (right margin)"
echo "$RES" | grep -q 'clean_ok=1' && cl=1 || cl=0
chk "$cl" "scrolling output renders cleanly (no fb_scroll black patches)"
echo "$RES" | grep -q 'panel_ok=1' && ap=1 || ap=0
chk "$ap" "AGENTS panel shows the spawned agent (SYS_AGENTS roster)"
echo "$RES" | grep -q 'shadow_ok=1' && sh=1 || sh=0
chk "$sh" "panels cast a soft drop shadow (P1 depth)"
echo "$RES" | grep -q 'chip_ok=1' && cp=1 || cp=0
chk "$cp" "top-bar shows the live AGENTS status chip (P3)"
echo "  accent brightness: frameA=$A_A frameB=$A_B diff=$DIFF"
{ [ "$DIFF" -gt 12 ] 2>/dev/null && p=1 || p=0; }
chk "$p" "the top-bar accent line breathes (animation)"

# coexistence: spinner present in Dark Glass, gone while snake owns the screen,
# back after snake quits (compositor stepped aside, then reclaimed the FB)
echo "  spinner px: glass=$S_GLASS back=$S_BACK ; game changed ${D_GAME}% of the screen"
{ [ "$D_GAME" -gt 30 ] 2>/dev/null && h=1 || h=0; }
chk "$h" "compositor steps aside; the game takes over the screen (>30% changed)"
{ [ "$S_BACK" -gt 80 ] 2>/dev/null && j=1 || j=0; }
chk "$j" "compositor reclaims the screen after the game exits"

[ "$fail" = 0 ] && { echo "==== GUI OK ===="; exit 0; }
echo "==== GUI FAILED ===="; exit 1
