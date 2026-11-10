#!/usr/bin/env python3
# mkmjpeg.py - build an M-JPEG clip for the TannX OS video player.
#   Layout (the Makefile appends it to the disk image at LBA 1024):
#     sector 0  header : "MJPG", count, w, h, fps, then count entries of
#                        (sector_offset, byte_size) - one per frame
#     sector 1+ data   : each frame's baseline-JPEG bytes, sector-aligned
#   user/video.c reads the header, streams each frame's sectors, and
#   decodes them with the jpeg.c baseline decoder.
#
#   Frames are generated procedurally (a bouncing ball over a colour-
#   cycling gradient, like the raw clip) and encoded to JPEG via PIL.
import struct, sys, math, io
from PIL import Image

W, H, COUNT, FPS, QUALITY = 160, 120, 24, 8, 80
SECTOR = 512

def frame_img(n):
    img = Image.new('RGB', (W, H))
    px = img.load()
    bx = int((W - 28) * (0.5 + 0.5 * math.sin(n / COUNT * 2 * math.pi)))
    by = int(H / 2 + (H / 3) * math.sin(n / COUNT * 4 * math.pi))
    phase = n / COUNT
    for y in range(H):
        for x in range(W):
            r = int(40 + 90 * (x / W) + 70 * phase) & 0xff
            g = int(30 + 100 * (y / H)) & 0xff
            b = int(130 - 90 * (x / W) + 110 * phase) & 0xff
            if (x - bx) ** 2 + (y - by) ** 2 < 15 * 15:
                r, g, b = 0xff, 0xf0, 0x40
            px[x, y] = (r, g, b)
    return img

def main(path):
    frames = []
    for n in range(COUNT):
        buf = io.BytesIO()
        frame_img(n).save(buf, format='JPEG', quality=QUALITY, subsampling=2)  # 4:2:0
        frames.append(buf.getvalue())
    # build the sector-offset table
    table, sect = [], 0
    for jp in frames:
        nsec = (len(jp) + SECTOR - 1) // SECTOR
        table.append((sect, len(jp)))
        sect += nsec
    hdr = struct.pack('<5I', 0x47504A4D, COUNT, W, H, FPS)   # "MJPG"
    for off, size in table:
        hdr += struct.pack('<2I', off, size)
    hdr = hdr + b'\x00' * (SECTOR - len(hdr))
    assert len(hdr) == SECTOR, "too many frames for one header sector"
    with open(path, 'wb') as f:
        f.write(hdr)
        for jp in frames:
            f.write(jp + b'\x00' * ((-len(jp)) % SECTOR))
    total = SECTOR + sect * SECTOR
    print("mjpeg clip: %d frames %dx%d, %d bytes (%d sectors), avg %d B/frame"
          % (COUNT, W, H, total, total // SECTOR, sum(len(f) for f in frames) // COUNT))

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'video.mjpg')
