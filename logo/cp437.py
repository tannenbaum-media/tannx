"""CP437 block/shade/box glyphs added to the framebuffer font (8x16, MSB =
left pixel). Shared by mklogo.py (previews) and the kernel font table."""

def _rows(top, bot, split=8):
    return [top] * split + [bot] * (16 - split)

EXTRA = {
    0xB0: [0x22, 0x88] * 8,          # light shade  (25 %)
    0xB1: [0x55, 0xAA] * 8,          # medium shade (50 %)
    0xB2: [0xDD, 0x77] * 8,          # dark shade   (75 %)
    0xDB: [0xFF] * 16,               # full block
    0xDC: _rows(0x00, 0xFF),         # lower half block
    0xDF: _rows(0xFF, 0x00),         # upper half block
    0xDD: [0xF0] * 16,               # left half block
    0xDE: [0x0F] * 16,               # right half block
    0xC4: [0] * 7 + [0xFF] + [0] * 8,                   # box: horizontal
    0xFA: [0] * 7 + [0x18, 0x18] + [0] * 7,             # middle dot
    0xFE: [0] * 4 + [0x7E] * 7 + [0] * 5,               # small square
}
