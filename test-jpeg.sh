#!/usr/bin/env bash
# test-jpeg.sh - host-side regression for the baseline JPEG decoder
# (user/jpeg.c). Encodes test images with PIL at several sizes, chroma
# subsamplings, qualities and restart intervals, decodes them with the
# decoder compiled for the host (-DJPEG_HOST_TEST), and checks the result
# matches PIL's own decode within tolerance (the remaining difference is
# chroma upsampling: PIL interpolates, we replicate). Then feeds a set of
# malformed/truncated frames and requires a clean error (no crash). The
# decoder is built with ASan/UBSan when the toolchain supports it. Not in
# test-all - it needs PIL/gcc; run it when touching jpeg.c.
set -u
cd "$(dirname "$0")"
command -v gcc >/dev/null || { echo "gcc missing"; exit 2; }
python3 -c "import PIL" 2>/dev/null || { echo "PIL missing - skipping jpeg test"; exit 0; }

TMP=$(mktemp -d /tmp/jpegtest_XXXX)
trap 'rm -rf "$TMP"' EXIT
SAN="-fsanitize=address,undefined -fno-sanitize-recover=all"
if gcc -DJPEG_HOST_TEST -O1 -Wall -Werror $SAN user/jpeg.c -o "$TMP/jpeg" 2>/dev/null; then
    echo "built with ASan/UBSan"
else
    gcc -DJPEG_HOST_TEST -O2 -Wall -Werror user/jpeg.c -o "$TMP/jpeg" || { echo "build failed"; exit 1; }
    echo "built without sanitizers"
fi
export ASAN_OPTIONS=detect_leaks=0:exitcode=99 UBSAN_OPTIONS=halt_on_error=1:exitcode=98

fail=0
gen_cmp() {  # name mode subsampling quality WxH maxavg [extra PIL save kwargs]
    python3 - "$TMP" "$1" "$2" "$3" "$4" "$5" "${7:-}" <<'PY'
import sys, math
from PIL import Image
tmp,name,mode,sub,q,size,extra=sys.argv[1:8]
sub,q=int(sub),int(q); W,H=[int(v) for v in size.split('x')]
kw=eval('dict(%s)'%extra) if extra else {}
img=Image.new(mode,(W,H)); px=img.load()
for y in range(H):
    for x in range(W):
        if mode=='L': px[x,y]=int(255*(x+y)/(W+H))
        else:
            r=int(128+127*math.sin(x/11.))&255; g=int(128+127*math.sin(y/8.))&255
            b=int(128+127*math.sin((x+y)/13.))&255
            if (x-W//2)**2+(y-H//2)**2<(max(min(W,H)//6,1))**2: r,g,b=255,240,64
            px[x,y]=(r,g,b)
img.save("%s/%s.jpg"%(tmp,name),quality=q,subsampling=sub,**kw)
Image.open("%s/%s.jpg"%(tmp,name)).convert('RGB').save("%s/%s_pil.ppm"%(tmp,name))
PY
    "$TMP/jpeg" "$TMP/$1.jpg" "$TMP/$1_dec.ppm" >/dev/null 2>&1 || { echo "FAIL : $1 decode errored"; fail=1; return; }
    avg=$(python3 - "$TMP/$1_dec.ppm" "$TMP/$1_pil.ppm" <<'PY'
import sys
def rd(p):
    d=open(p,'rb').read(); i=2; v=[]
    while len(v)<3:
        while d[i] in b' \t\n\r': i+=1
        s=i
        while d[i] not in b' \t\n\r': i+=1
        v.append(int(d[s:i])); i+=1
    return v[0],v[1],d[i:]
w,h,a=rd(sys.argv[1]); w2,h2,b=rd(sys.argv[2])
if (w,h)!=(w2,h2) or len(a)<w*h*3: print("999"); sys.exit()
n=w*h*3
print("%.3f"%(sum(abs(a[i]-b[i]) for i in range(n))/n))
PY
)
    ok=$(python3 -c "print(1 if float('$avg')<=$6 else 0)")
    if [ "$ok" = 1 ]; then echo "OK   : $1 decodes within tol (avg diff $avg <= $6)"
    else echo "FAIL : $1 avg diff $avg > $6"; fail=1; fi
}

#       name      mode sub q   size     tol  extra
gen_cmp gray      L    0   92  160x120  1.0            # grayscale: near-exact
gen_cmp grayodd   L    0   40  65x33    1.0            # odd size, coarse quantiser
gen_cmp c444      RGB  0   95  160x120  1.5            # 4:4:4
gen_cmp c422      RGB  1   90  160x120  4.0            # 4:2:2
gen_cmp c420      RGB  2   85  160x120  5.0            # 4:2:0 (the video clip's format)
gen_cmp odd420    RGB  2   75  37x29    5.0            # partial MCUs on both axes
gen_cmp odd422    RGB  1   60  131x77   5.0
gen_cmp tiny      RGB  2   90  1x1      1.0            # a single pixel
gen_cmp big444    RGB  0   50  320x240  1.5            # the player's maximum frame
gen_cmp q100      RGB  2   100 64x64    5.0
gen_cmp rst420    RGB  2   80  160x120  5.0 "restart_marker_blocks=3"   # DRI every 3 MCUs
gen_cmp rstrows   RGB  1   88  200x150  4.0 "restart_marker_rows=1"     # DRI every MCU row
gen_cmp rstgray   L    0   70  100x70   1.0 "restart_marker_blocks=5"
gen_cmp opthuff   RGB  2   85  160x120  5.0 "optimize=True"            # non-standard Huffman tables

# --- malformed input: must return an error, never crash ------------------
bad() {  # name hex-bytes
    printf "$2" > "$TMP/$1.bad"
    "$TMP/jpeg" "$TMP/$1.bad" "$TMP/$1.ppm" >"$TMP/$1.out" 2>&1; rc=$?
    if [ $rc = 1 ]; then echo "OK   : malformed '$1' rejected ($(cat "$TMP/$1.out"))"
    else echo "FAIL : malformed '$1' rc=$rc: $(head -c 300 "$TMP/$1.out")"; fail=1; fi
}
bad degenerate-sos  '\xff\xd8\xff\xda\x00\x03\x00'                       # SOI -> SOS ncomp=0 (test-video-fuzz)
bad empty           ''
bad soi-only        '\xff\xd8'
bad soi-eoi         '\xff\xd8\xff\xd9'
bad sof-w0          '\xff\xd8\xff\xc0\x00\x0b\x08\x00\x0a\x00\x00\x01\x01\x11\x00'
bad sof-h0          '\xff\xd8\xff\xc0\x00\x0b\x08\x00\x00\x00\x0a\x01\x01\x11\x00'
bad sof-ncomp0      '\xff\xd8\xff\xc0\x00\x08\x08\x00\x0a\x00\x0a\x00'
bad sof-qtable9     '\xff\xd8\xff\xc0\x00\x0b\x08\x00\x0a\x00\x0a\x01\x01\x11\x09'
bad sof-sampling0   '\xff\xd8\xff\xc0\x00\x0b\x08\x00\x0a\x00\x0a\x01\x01\x00\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00'
bad sof-huge        '\xff\xd8\xff\xc0\x00\x0b\x08\xff\xff\xff\xff\x01\x01\x11\x00'
bad dht-table9      '\xff\xd8\xff\xc4\x00\x13\x19\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
bad dht-oversubscribed '\xff\xd8\xff\xc4\x00\x16\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03'
bad dqt-truncated   '\xff\xd8\xff\xdb\x00\x0a\x00\x01\x01\x01\x01\x01\x01\x01'
bad segment-len0    '\xff\xd8\xff\xe0\x00\x00\xff\xd9'
bad segment-overrun '\xff\xd8\xff\xe0\xff\xff\x00\x00'
bad sos-no-tables   '\xff\xd8\xff\xc0\x00\x0b\x08\x00\x0a\x00\x0a\x01\x01\x11\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x12\x34'
bad sos-huff-id9    '\xff\xd8\xff\xc0\x00\x0b\x08\x00\x0a\x00\x0a\x01\x01\x11\x00\xff\xda\x00\x08\x01\x01\x99\x00\x3f\x00\x12\x34'
# truncated real frames: 25 %, 50 %, 90 % of a valid 4:2:0 file, and a
# bit-flipped scan body
python3 - "$TMP" <<'PY'
import sys; tmp=sys.argv[1]; d=open(tmp+'/c420.jpg','rb').read()
for pct in (25,50,90): open('%s/trunc%d.bad'%(tmp,pct),'wb').write(d[:len(d)*pct//100])
b=bytearray(d); sos=d.index(b'\xff\xda')
for i in range(sos+20,len(b)-2,37): b[i]^=0x5a
open(tmp+'/flipped.bad','wb').write(b)
PY
for n in trunc25 trunc50 trunc90 flipped; do
    "$TMP/jpeg" "$TMP/$n.bad" "$TMP/$n.ppm" >"$TMP/$n.out" 2>&1; rc=$?
    if [ $rc = 0 ] || [ $rc = 1 ]; then echo "OK   : corrupt '$n' handled (rc=$rc, $(head -1 "$TMP/$n.out"))"
    else echo "FAIL : corrupt '$n' rc=$rc: $(head -c 300 "$TMP/$n.out")"; fail=1; fi
done
# progressive JPEG: a clean 'unsupported' (-2), not a crash
python3 -c "
from PIL import Image; Image.new('RGB',(64,64),(10,200,30)).save('$TMP/prog.jpg',progressive=True)"
"$TMP/jpeg" "$TMP/prog.jpg" "$TMP/prog.ppm" >"$TMP/prog.out" 2>&1; rc=$?
if [ $rc = 1 ] && grep -q -- "-2" "$TMP/prog.out"; then echo "OK   : progressive JPEG rejected as unsupported (-2)"
else echo "FAIL : progressive rc=$rc: $(cat "$TMP/prog.out")"; fail=1; fi

if [ "$fail" = 0 ]; then echo "==== jpeg PASSED ===="; exit 0
else echo "==== jpeg FAILED ===="; exit 1; fi
