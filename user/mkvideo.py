#!/usr/bin/env python3
# mkvideo.py - build a raw-RGB test clip for the TannX OS video player.
#   Output: a header sector ("AVID", count, w, h, fps) followed by
#   `count` frames, each w*h BGRx pixels (uint32 0x00RRGGBB), padded to
#   a 512-byte sector boundary. The Makefile appends this to the disk
#   image at LBA 1024; user/video.c streams and blits it.
#
#   No external deps (no PIL) - the frames are generated procedurally:
#   a colour-cycling gradient background with a ball bouncing across it,
#   so playback is obvious by eye and the dominant colour shifts per
#   frame (lets a headless test sample a pixel and see motion).
import struct, sys, math

W, H, COUNT, FPS = 128, 96, 16, 6
SECTOR = 512

def frame_bytes(n):
    px = bytearray(W * H * 4)
    # ball position (bounces horizontally, gentle vertical sine)
    bx = int((W - 24) * (0.5 + 0.5 * math.sin(n / COUNT * 2 * math.pi)))
    by = int(H / 2 + (H / 3) * math.sin(n / COUNT * 4 * math.pi))
    phase = n / COUNT
    for y in range(H):
        for x in range(W):
            # background gradient, hue cycles with the frame index
            r = int(40 + 80 * (x / W) + 60 * phase) & 0xff
            g = int(30 + 90 * (y / H)) & 0xff
            b = int(120 - 80 * (x / W) + 100 * phase) & 0xff
            # the ball: bright yellow disc
            dx, dy = x - bx, y - by
            if dx * dx + dy * dy < 12 * 12:
                r, g, b = 0xff, 0xf0, 0x40
            off = (y * W + x) * 4
            px[off + 0] = b          # BGRx: byte0=B, byte1=G, byte2=R
            px[off + 1] = g
            px[off + 2] = r
            px[off + 3] = 0
    # pad to a whole number of sectors
    pad = (-len(px)) % SECTOR
    return bytes(px) + b'\x00' * pad

def main(path):
    hdr = struct.pack('<5I', 0x44495641, COUNT, W, H, FPS)  # "AVID"
    hdr = hdr + b'\x00' * (SECTOR - len(hdr))
    with open(path, 'wb') as f:
        f.write(hdr)
        for n in range(COUNT):
            f.write(frame_bytes(n))

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'video.raw')
