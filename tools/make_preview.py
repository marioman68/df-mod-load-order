"""Generates the Workshop preview image for Mod Load Order.

Drawn at 256x256 "pixel art" size using DF's curses font, then scaled 4x
with nearest-neighbour so it stays crisp.
"""
import random
import sys
from PIL import Image, ImageDraw

FONT = sys.argv[1]   # curses_800x600.png (16x16 grid of 10x12 glyphs)
OUT = sys.argv[2]

W = H = 256
GW, GH = 10, 12

# palette
BG = (22, 19, 15)
STONE = [(26, 22, 18), (30, 26, 21), (24, 21, 17), (33, 28, 22)]
GOLD = (232, 176, 52)
GOLD_DARK = (138, 100, 24)
GOLD_LIGHT = (255, 214, 110)
SHADOW = (10, 8, 5)
PANEL = (34, 30, 26)
PANEL_EDGE = (92, 76, 50)
ROW = (44, 40, 35)
ROW_HI = (64, 48, 26)
WHITE = (226, 226, 220)
GREY = (150, 146, 138)
GREEN = (98, 214, 92)
YELLOW = (255, 224, 70)
ORANGE = (255, 150, 48)
CYAN = (96, 210, 220)

# ---- font -------------------------------------------------------------------
sheet = Image.open(FONT).convert('RGB')
glyph_masks = {}


def glyph(code):
    if code not in glyph_masks:
        x, y = (code % 16) * GW, (code // 16) * GH
        g = sheet.crop((x, y, x + GW, y + GH))
        # background is magenta (green = 0), glyph pixels are white/grey
        mask = g.getchannel('G').point(lambda v: 255 if v > 100 else 0)
        glyph_masks[code] = mask
    return glyph_masks[code]


def text(img, s, x, y, color, scale=1, shadow=None, spacing=0):
    for i, ch in enumerate(s):
        code = ch if isinstance(ch, int) else ord(ch)
        m = glyph(code)
        if scale != 1:
            m = m.resize((GW * scale, GH * scale), Image.NEAREST)
        px = x + i * (GW * scale + spacing)
        if shadow:
            img.paste(shadow, (px + scale, y + scale), m)
        img.paste(color, (px, y), m)


def text_width(s, scale=1, spacing=0):
    return len(s) * (GW * scale + spacing) - spacing


def centered(img, s, y, color, scale=1, shadow=None, spacing=0):
    text(img, s, (W - text_width(s, scale, spacing)) // 2, y, color, scale, shadow, spacing)


# ---- canvas -----------------------------------------------------------------
img = Image.new('RGB', (W, H), BG)
d = ImageDraw.Draw(img)

# stone floor texture
rnd = random.Random(7)
for ty in range(0, H, 8):
    for tx in range(0, W, 8):
        d.rectangle([tx, ty, tx + 7, ty + 7], fill=rnd.choice(STONE))
        if rnd.random() < 0.18:
            d.point((tx + rnd.randint(1, 6), ty + rnd.randint(1, 6)), fill=(40, 34, 27))

# DF-style double gold frame
d.rectangle([3, 3, W - 4, H - 4], outline=GOLD_DARK, width=1)
d.rectangle([4, 4, W - 5, H - 5], outline=GOLD, width=2)
d.rectangle([9, 9, W - 10, H - 10], outline=GOLD_DARK, width=1)

# ---- title ------------------------------------------------------------------
centered(img, 'MOD LOAD', 20, GOLD_LIGHT, scale=2, shadow=SHADOW, spacing=1)
centered(img, 'ORDER', 46, GOLD, scale=2, shadow=SHADOW, spacing=1)
# small divider under the title: --- * ---
d.line([60, 76, 116, 76], fill=GOLD_DARK)
d.line([140, 76, 196, 76], fill=GOLD_DARK)
text(img, [15], 123, 70, GOLD)  # sun/star glyph

# ---- mod list panel ---------------------------------------------------------
px0, py0, px1, py1 = 34, 86, 222, 196
d.rectangle([px0, py0, px1, py1], fill=PANEL, outline=PANEL_EDGE)

rows = [
    ('Vanilla Text', 'ok'),
    ('Vanilla Items', 'ok'),
    ('Better Bodies', 'moved'),
    ('Armor Pack', 'ok'),
    ('Creatures', 'ok'),
]
row_h = 20
for i, (name, state) in enumerate(rows):
    y = py0 + 6 + i * row_h
    hi = state == 'moved'
    d.rectangle([px0 + 22, y, px1 - 6, y + 15], fill=ROW_HI if hi else ROW,
                outline=ORANGE if hi else None)
    text(img, str(i + 1), px0 + 9, y + 2, GREY)
    text(img, name, px0 + 28, y + 2, ORANGE if hi else WHITE)
    if hi:
        text(img, [24], px1 - 20, y + 2, YELLOW)   # up arrow
    else:
        text(img, [251], px1 - 20, y + 2, GREEN)   # check mark

# the "moved up" arrow on the left: from where it was (row 5 slot) up to row 3
ax = px0 - 12
y_from = py0 + 6 + 4 * row_h + 8
y_to = py0 + 6 + 2 * row_h + 8
d.line([ax, y_from, ax, y_to], fill=YELLOW, width=2)
d.line([ax, y_from, ax + 8, y_from], fill=YELLOW, width=2)
d.line([ax, y_to, ax + 7, y_to], fill=YELLOW, width=2)
d.polygon([(ax + 10, y_to), (ax + 5, y_to - 4), (ax + 5, y_to + 4)], fill=YELLOW)

# ---- tagline + badge ----------------------------------------------------------
centered(img, 'fix your mod list', 206, CYAN)

badge = 'requires DFHack'
bw = text_width(badge) + 12
bx = (W - bw) // 2
d.rectangle([bx, 224, bx + bw, 240], fill=(30, 52, 30), outline=GREEN)
text(img, badge, bx + 6, 227, GREEN)

img = img.resize((W * 4, H * 4), Image.NEAREST)
img.save(OUT, optimize=True)
print('saved', OUT, img.size)
