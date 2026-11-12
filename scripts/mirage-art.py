#!/usr/bin/env python3
"""Mirage add-on art: one cohesive set of shop covers and row icons, drawn here and bundled into the dylib.

  scripts/mirage-art.py [preview-dir]

Writes mirage/Sources/Addons/MRGAddonArtData.m (the images as byte arrays, so the phone shows exactly what was
previewed) and, with a preview dir, every PNG plus a contact sheet (sheet.png) there.

The system: a deep ink ground with a faint 24 px dot grid and a little grain, everything else flat geometry on
one grid (a 12-unit square stage centred right of middle), Mirage purple for the main shapes, lavender and white
for detail, and exactly one secondary tone per add-on. No text, no glows, no photos.
"""
import io, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_C = os.path.join(ROOT, "mirage", "Sources", "Addons", "MRGAddonArtData.m")

SS = 4                       # supersampling
COVER = (1080, 608)          # 16:9, ≥ 3x of the widest shop card on a 390 pt phone
ICON = 132                   # 44 pt @3x

INK_TOP = (24, 18, 40)
INK_BOTTOM = (11, 9, 19)
PURPLE = (139, 92, 246)
PURPLE_DEEP = (96, 58, 214)
LAVENDER = (196, 181, 253)
WHITE = (255, 255, 255)
VINYL_BLACK = (14, 12, 20)

SECOND = {
    "vinyl":          (245, 177, 76),    # amber
    "dynamic-colors": (255, 122, 107),   # coral
    "playlist-tools": (45, 212, 191),    # teal
    "genres":         (96, 165, 250),    # sky
    "popup-lyrics":   (244, 114, 182),   # pink
    "trash":          (248, 113, 113),   # red
    "shuffle-plus":   (163, 230, 53),    # lime
    "generic":        (196, 181, 253),
}
IDS = ["vinyl", "dynamic-colors", "playlist-tools", "genres", "popup-lyrics", "trash", "shuffle-plus", "generic"]


def a(c, alpha):
    return tuple(c[:3]) + (int(round(alpha * 255)),)


def vgrad(w, h, top, bottom):
    t = np.linspace(0, 1, h)[:, None, None]
    arr = np.array(top)[None, None, :] * (1 - t) + np.array(bottom)[None, None, :] * t
    arr = np.repeat(arr, w, axis=1)
    return Image.fromarray(arr.astype(np.uint8), "RGB").convert("RGBA")


def grain(img, amount, seed):
    rng = np.random.default_rng(seed)
    n = rng.normal(0, 255 * amount, (img.height, img.width, 1))
    arr = np.asarray(img).astype(np.float32)
    arr[..., :3] = np.clip(arr[..., :3] + n, 0, 255)
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


class Pen:
    """Draws on a supersampled RGBA layer in output pixel units."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))

    def layer(self):
        return Pen(self.w, self.h)

    def paste(self, other, opacity=1.0):
        im = other.img
        if opacity < 1:
            alpha = im.getchannel("A").point(lambda v: int(v * opacity))
            im = im.copy(); im.putalpha(alpha)
        self.img = Image.alpha_composite(self.img, im)

    def d(self):
        return ImageDraw.Draw(self.img)

    @staticmethod
    def s(v):
        return v * SS

    def box(self, x, y, w, h):
        return [self.s(x), self.s(y), self.s(x + w), self.s(y + h)]

    def rrect(self, x, y, w, h, r, fill=None, outline=None, width=0):
        self.d().rounded_rectangle(self.box(x, y, w, h), radius=self.s(r), fill=fill, outline=outline, width=int(self.s(width)))

    def circle(self, cx, cy, r, fill=None, outline=None, width=0):
        self.d().ellipse(self.box(cx - r, cy - r, 2 * r, 2 * r), fill=fill, outline=outline, width=int(self.s(width)))

    def poly(self, pts, fill):
        self.d().polygon([(self.s(x), self.s(y)) for x, y in pts], fill=fill)

    def line(self, pts, fill, width, round_caps=True):
        sp = [(self.s(x), self.s(y)) for x, y in pts]
        self.d().line(sp, fill=fill, width=int(self.s(width)), joint="curve")
        if round_caps:
            r = width / 2
            for x, y in (pts[0], pts[-1]):
                self.circle(x, y, r, fill=fill)

    def arc(self, cx, cy, r, start, end, fill, width):
        self.d().arc(self.box(cx - r, cy - r, 2 * r, 2 * r), start, end, fill=fill, width=int(self.s(width)))

    def result(self):
        return self.img.resize((self.w, self.h), Image.LANCZOS)


# ---------------------------------------------------------------- glyphs (drawn in a unit box: x, y, size)

def g_vinyl(p, x, y, s, sec, big=True):
    cx, cy, r = x + s * 0.5, y + s * 0.5, s * 0.5
    p.circle(cx, cy, r, fill=a(VINYL_BLACK, 1) if big else a(WHITE, 1))
    groove = a(WHITE, 0.09) if big else a(PURPLE_DEEP, 0.35)
    for k in (0.86, 0.74, 0.62):
        p.circle(cx, cy, r * k, outline=groove, width=max(1.0, s * 0.012))
    p.circle(cx, cy, r * 0.36, fill=a(LAVENDER if big else PURPLE_DEEP, 1))
    p.circle(cx, cy, r * 0.08, fill=a(sec, 1))


def g_shuffle(p, x, y, s, c1, c2, width):
    # two crossing paths that end in arrowheads, drawn as smooth polylines
    def path(y0, y1):
        pts = []
        for i in range(41):
            t = i / 40
            e = t * t * (3 - 2 * t)
            px = x + s * (0.05 + 0.72 * t)
            py = y + s * (y0 + (y1 - y0) * e)
            pts.append((px, py))
        return pts
    lo, hi = 0.74, 0.26
    for (y0, y1, col) in ((lo, hi, c1), (hi, lo, c2)):
        pts = path(y0, y1)
        p.line(pts, fill=a(col, 1), width=width)
        ex, ey = pts[-1]
        hs = width * 1.9
        p.poly([(ex + hs * 1.15, ey), (ex - hs * 0.2, ey - hs), (ex - hs * 0.2, ey + hs)], fill=a(col, 1))


# ---------------------------------------------------------------- covers

def stage(W, H):
    """The shared grid: a square stage of side 0.62 H, centred at 0.58 W."""
    side = H * 0.62
    return W * 0.58 - side / 2, H / 2 - side / 2, side


def ground(W, H, sec, seed):
    img = vgrad(W, H, INK_TOP, INK_BOTTOM)
    p = Pen(W, H)
    # the one big quiet shape every cover shares: a disc of the add-on's tone, low, off to the right
    p.circle(W * 0.80, H * 0.98, H * 0.78, fill=a(sec, 0.07))
    p.circle(W * 0.80, H * 0.98, H * 0.52, fill=a(sec, 0.05))
    dots = p.layer()
    step = 24
    for gy in range(step // 2, H, step):
        for gx in range(step // 2, W, step):
            dots.circle(gx, gy, 1.1, fill=a(WHITE, 0.07))
    p.paste(dots)
    img = Image.alpha_composite(img, p.result())
    return img


def finish(img, seed):
    img = grain(img, 0.012, seed)
    W, H = img.size
    p = Pen(W, H)
    p.rrect(0.5, 0.5, W - 1, H - 1, 0, outline=a(WHITE, 0.06), width=1.5)
    return Image.alpha_composite(img, p.result())


def shadow(img, pen, blur, opacity, dy):
    """A soft drop shadow under the shapes on `pen` (used sparingly: one per cover)."""
    sh = pen.result()
    alpha = sh.getchannel("A").point(lambda v: int(v * opacity))
    base = Image.new("RGBA", sh.size, (0, 0, 0, 255)); base.putalpha(alpha)
    base = base.filter(ImageFilter.GaussianBlur(blur))
    moved = Image.new("RGBA", sh.size, (0, 0, 0, 0)); moved.paste(base, (0, dy))
    return Image.alpha_composite(img, moved)


def compose(img, pen, shadow_blur=18, shadow_op=0.45, dy=10):
    img = shadow(img, pen, shadow_blur, shadow_op, dy)
    return Image.alpha_composite(img, pen.result())


def cover_vinyl(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    g_vinyl(p, x + s * 0.40, y + s * 0.06, s * 0.88, sec)
    p.rrect(x - s * 0.16, y + s * 0.04, s * 0.92, s * 0.92, s * 0.04, fill=a(PURPLE, 1))
    # sleeve detail: a lavender band and a small amber square, flat
    p.rrect(x - s * 0.08, y + s * 0.74, s * 0.46, s * 0.05, s * 0.025, fill=a(LAVENDER, 0.9))
    p.rrect(x - s * 0.08, y + s * 0.83, s * 0.26, s * 0.05, s * 0.025, fill=a(WHITE, 0.45))
    p.rrect(x - s * 0.08, y + s * 0.12, s * 0.14, s * 0.14, s * 0.03, fill=a(sec, 1))
    # the spin: a thin arc on the record's free side
    p.arc(x + s * 0.84, y + s * 0.50, s * 0.56, -36, 36, fill=a(sec, 0.9), width=s * 0.022)
    return p


def cover_dynamic(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    cs = s * 0.74
    cx0, cy0 = x - s * 0.18, y + (s - cs) / 2
    q = cs / 2
    p.rrect(cx0, cy0, cs, cs, s * 0.05, fill=a(PURPLE_DEEP, 1))
    # the cover in four flat blocks
    blk = p.layer()
    blk.rrect(cx0, cy0, cs, cs, s * 0.05, fill=a(PURPLE_DEEP, 1))
    blk.poly([(cx0 + q, cy0), (cx0 + cs, cy0), (cx0 + cs, cy0 + q)], fill=a(sec, 1))
    blk.circle(cx0 + q * 0.75, cy0 + q * 1.25, q * 0.55, fill=a(LAVENDER, 1))
    blk.poly([(cx0 + q, cy0 + cs), (cx0 + cs, cy0 + q * 1.1), (cx0 + cs, cy0 + cs)], fill=a(PURPLE, 1))
    p.paste(blk)
    # → three swatches taken from it
    sx = cx0 + cs + s * 0.16
    r = s * 0.11
    for i, col in enumerate((sec, PURPLE, LAVENDER)):
        cyy = y + s * 0.22 + i * s * 0.28
        p.circle(sx + r, cyy, r, fill=a(col, 1))
        p.rrect(sx + r * 2 + s * 0.06, cyy - s * 0.022, s * 0.30 - i * s * 0.06, s * 0.044, s * 0.022, fill=a(WHITE, 0.28))
    return p


def cover_playlist(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    cw, ch = s * 1.25, s * 1.0
    cx0, cy0 = x + s / 2 - cw / 2, y
    p.rrect(cx0, cy0, cw, ch, s * 0.06, fill=a((32, 25, 54), 1))
    rows = 4
    rh = ch / rows
    for i in range(rows):
        ry = cy0 + i * rh
        hl = i == 1
        if hl:
            p.rrect(cx0 + s * 0.04, ry + s * 0.03, cw - s * 0.08, rh - s * 0.06, s * 0.035, fill=a(PURPLE, 1))
        art = s * 0.13
        p.rrect(cx0 + s * 0.08, ry + (rh - art) / 2, art, art, s * 0.025, fill=a(sec if hl else LAVENDER, 1 if hl else 0.55))
        p.rrect(cx0 + s * 0.28, ry + rh * 0.36, s * (0.50 - 0.06 * (i % 2)), s * 0.04, s * 0.02, fill=a(WHITE, 0.95 if hl else 0.55))
        p.rrect(cx0 + s * 0.28, ry + rh * 0.58, s * 0.28, s * 0.032, s * 0.016, fill=a(WHITE, 0.6 if hl else 0.25))
    # the tool: a round badge with a plus, on the card's corner
    bx, by, br = cx0 + cw - s * 0.06, cy0 + ch - s * 0.06, s * 0.15
    p.circle(bx, by, br, fill=a(sec, 1))
    p.rrect(bx - br * 0.5, by - br * 0.09, br, br * 0.18, br * 0.09, fill=a(INK_BOTTOM, 1))
    p.rrect(bx - br * 0.09, by - br * 0.5, br * 0.18, br, br * 0.09, fill=a(INK_BOTTOM, 1))
    return p


def cover_genres(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    pills = [(0.00, 0.10, 0.86, PURPLE, WHITE), (0.22, 0.40, 0.70, sec, INK_BOTTOM), (0.06, 0.70, 0.98, (32, 25, 54), LAVENDER)]
    for ox, oy, w, fill, mark in pills:
        px, py, ph = x - s * 0.10 + ox * s, y + oy * s, s * 0.20
        p.rrect(px, py, w * s, ph, ph / 2, fill=a(fill, 1))
        # a tag hole and two "word" bars
        p.circle(px + ph * 0.5, py + ph / 2, ph * 0.13, fill=a(mark, 0.85))
        p.rrect(px + ph * 0.95, py + ph * 0.40, w * s * 0.42, ph * 0.20, ph * 0.10, fill=a(mark, 0.85))
        p.rrect(px + ph * 0.95 + w * s * 0.46, py + ph * 0.40, w * s * 0.18, ph * 0.20, ph * 0.10, fill=a(mark, 0.45))
    return p


def cover_lyrics(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    cw = s * 1.30
    cx0 = x + s / 2 - cw / 2
    # the feed below, pushed down: flat tiles
    for i in range(3):
        p.rrect(cx0 + i * (cw / 3 + s * 0.0) + s * 0.01, y + s * 0.70, cw / 3 - s * 0.04, s * 0.30, s * 0.04, fill=a((32, 25, 54), 1))
    # the lyrics card: glass-like flat panel (lighter ink + thin rim), lines with the current one highlighted
    p.rrect(cx0, y, cw, s * 0.60, s * 0.06, fill=a((44, 34, 76), 1), outline=a(WHITE, 0.10), width=1.5)
    lines = [(0.12, 0.60, 0.30), (0.27, 0.86, 1.0), (0.42, 0.52, 0.30)]
    for ly, lw, op in lines:
        cur = op == 1.0
        p.rrect(cx0 + s * 0.08, y + s * ly, cw * lw * 0.86, s * (0.07 if cur else 0.05), s * 0.03, fill=a(WHITE if cur else LAVENDER, 1 if cur else 0.35))
    # the beat dot and progress under the current line
    p.circle(cx0 + cw - s * 0.10, y + s * 0.305, s * 0.035, fill=a(sec, 1))
    return p


def cover_trash(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    cw = s * 1.25
    cx0 = x + s / 2 - cw / 2
    rh = s * 0.24
    for i in range(4):
        ry = y + s * 0.02 + i * (rh + s * 0.02)
        bad = i == 1
        p.rrect(cx0, ry, cw, rh, s * 0.04, fill=a((32, 25, 54), 1) if not bad else a((48, 26, 40), 1))
        art = rh * 0.62
        p.rrect(cx0 + s * 0.05, ry + (rh - art) / 2, art, art, s * 0.02, fill=a(LAVENDER if not bad else sec, 0.5 if not bad else 0.9))
        p.rrect(cx0 + s * 0.25, ry + rh * 0.40, s * 0.50, s * 0.045, s * 0.022, fill=a(WHITE, 0.25 if bad else 0.55))
        if bad:
            # struck through: the row's title crossed out in the tone
            p.rrect(cx0 + s * 0.22, ry + rh * 0.46, s * 0.56, s * 0.03, s * 0.015, fill=a(sec, 1))
    # the badge: a circle with a bar (no entry), on the struck row
    bx, by, br = cx0 + cw - s * 0.14, y + s * 0.02 + (rh + s * 0.02) + rh / 2, s * 0.13
    p.circle(bx, by, br, fill=a(sec, 1))
    p.rrect(bx - br * 0.55, by - br * 0.11, br * 1.1, br * 0.22, br * 0.11, fill=a(INK_BOTTOM, 1))
    return p


def cover_shuffle(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    g_shuffle(p, x - s * 0.12, y + s * 0.02, s * 1.05, PURPLE, sec, s * 0.075)
    # the plus, on a lavender disc
    bx, by, br = x + s * 1.02, y + s * 0.20, s * 0.13
    p.circle(bx, by, br, fill=a(LAVENDER, 1))
    p.rrect(bx - br * 0.5, by - br * 0.1, br, br * 0.2, br * 0.1, fill=a(INK_BOTTOM, 1))
    p.rrect(bx - br * 0.1, by - br * 0.5, br * 0.2, br, br * 0.1, fill=a(INK_BOTTOM, 1))
    # the spaced queue below: dots in alternating tones, never two of a kind together
    for i in range(7):
        col = [PURPLE, sec, LAVENDER][i % 3]
        p.circle(x + s * (0.02 + i * 0.15), y + s * 0.98, s * 0.035, fill=a(col, 1))
    return p


def cover_generic(W, H, sec):
    x, y, s = stage(W, H)
    p = Pen(W, H)
    u = s * 0.40
    for i, (ox, oy, col) in enumerate(((0, 0, PURPLE), (1, 0, LAVENDER), (0, 1, (32, 25, 54)), (1, 1, PURPLE_DEEP))):
        p.rrect(x + s * 0.08 + ox * (u + s * 0.04), y + s * 0.08 + oy * (u + s * 0.04), u, u, s * 0.06, fill=a(col, 1))
    return p


COVERS = {"vinyl": cover_vinyl, "dynamic-colors": cover_dynamic, "playlist-tools": cover_playlist, "genres": cover_genres,
          "popup-lyrics": cover_lyrics, "trash": cover_trash, "shuffle-plus": cover_shuffle, "generic": cover_generic}


def render_cover(addon):
    W, H = COVER
    sec = SECOND[addon]
    img = ground(W, H, sec, IDS.index(addon))
    pen = COVERS[addon](W, H, sec)
    img = compose(img, pen, shadow_blur=22, shadow_op=0.5, dy=12)
    return finish(img, 100 + IDS.index(addon)).convert("RGB")


# ---------------------------------------------------------------- icons

def render_icon(addon):
    n = ICON
    sec = SECOND[addon]
    tile = vgrad(n, n, (154, 110, 255), (104, 64, 222))
    mask = Pen(n, n)
    mask.rrect(0, 0, n, n, n * 0.235, fill=(255, 255, 255, 255))
    m = mask.result().getchannel("A")
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(tile, (0, 0), m)
    p = Pen(n, n)
    u = n / 12.0   # the icon grid: 12 units, glyphs live in units 3..9
    W_ = a(WHITE, 1)
    if addon == "vinyl":
        g_vinyl(p, 2.6 * u, 2.6 * u, 6.8 * u, sec, big=False)
    elif addon == "dynamic-colors":
        r = 1.45 * u
        p.circle(4.6 * u, 4.7 * u, r, fill=W_)
        p.circle(7.4 * u, 4.7 * u, r, fill=a(LAVENDER, 1))
        p.circle(6.0 * u, 7.3 * u, r, fill=a(sec, 1))
    elif addon == "playlist-tools":
        for i in range(3):
            yy = (3.4 + i * 2.0) * u
            p.rrect(3.0 * u, yy, 1.2 * u, 1.2 * u, 0.3 * u, fill=W_)
            p.rrect(4.9 * u, yy + 0.35 * u, (3.6 - 0.8 * (i == 2)) * u, 0.5 * u, 0.25 * u, fill=W_)
        p.circle(8.4 * u, 8.4 * u, 1.35 * u, fill=a(sec, 1))
        p.rrect(7.75 * u, 8.2 * u, 1.3 * u, 0.4 * u, 0.2 * u, fill=a(PURPLE_DEEP, 1))
        p.rrect(8.2 * u, 7.75 * u, 0.4 * u, 1.3 * u, 0.2 * u, fill=a(PURPLE_DEEP, 1))
    elif addon == "genres":
        p.rrect(2.6 * u, 3.4 * u, 5.6 * u, 2.1 * u, 1.05 * u, fill=W_)
        p.rrect(3.8 * u, 6.5 * u, 5.6 * u, 2.1 * u, 1.05 * u, fill=a(sec, 1))
        p.circle(3.65 * u, 4.45 * u, 0.36 * u, fill=a(PURPLE_DEEP, 1))
        p.circle(4.85 * u, 7.55 * u, 0.36 * u, fill=a(PURPLE_DEEP, 1))
    elif addon == "popup-lyrics":
        p.rrect(2.5 * u, 2.9 * u, 7.0 * u, 5.2 * u, 1.1 * u, fill=a(WHITE, 0.22), outline=a(WHITE, 0.9), width=0.32 * u)
        p.rrect(3.6 * u, 4.2 * u, 3.6 * u, 0.55 * u, 0.27 * u, fill=a(WHITE, 0.55))
        p.rrect(3.6 * u, 5.35 * u, 4.8 * u, 0.75 * u, 0.37 * u, fill=W_)
        p.rrect(3.6 * u, 6.7 * u, 2.6 * u, 0.55 * u, 0.27 * u, fill=a(WHITE, 0.55))
        p.rrect(2.5 * u, 8.7 * u, 7.0 * u, 0.6 * u, 0.3 * u, fill=a(sec, 1))
    elif addon == "trash":
        p.circle(6 * u, 6 * u, 3.5 * u, fill=None, outline=W_, width=0.75 * u)
        p.poly([(3.85 * u, 7.6 * u), (7.6 * u, 3.85 * u), (8.15 * u, 4.4 * u), (4.4 * u, 8.15 * u)], fill=a(sec, 1))
    elif addon == "shuffle-plus":
        g_shuffle(p, 2.4 * u, 2.7 * u, 6.4 * u, WHITE, sec, 0.78 * u)
    else:
        for ox, oy in ((0, 0), (1, 0), (0, 1), (1, 1)):
            p.rrect((3.0 + ox * 3.2) * u, (3.0 + oy * 3.2) * u, 2.8 * u, 2.8 * u, 0.7 * u, fill=W_ if (ox + oy) % 2 == 0 else a(LAVENDER, 1))
    out = Image.alpha_composite(out, p.result())
    # a hairline inner rim keeps the tile crisp on dark rows
    rim = Pen(n, n)
    rim.rrect(0.5, 0.5, n - 1, n - 1, n * 0.235 - 0.5, outline=a(WHITE, 0.20), width=1.2)
    return Image.alpha_composite(out, rim.result())


# ---------------------------------------------------------------- output

def png_bytes(img):
    b = io.BytesIO()
    img.save(b, "PNG", optimize=True)
    return b.getvalue()


def jpeg_bytes(img):
    b = io.BytesIO()
    img.save(b, "JPEG", quality=90, optimize=True, progressive=False, subsampling=0)
    return b.getvalue()


def c_name(addon, kind):
    return "MRGArt_%s_%s" % (kind, addon.replace("-", "_"))


def main():
    preview = sys.argv[1] if len(sys.argv) > 1 else None
    if preview:
        os.makedirs(preview, exist_ok=True)
    blobs = []
    covers, icons = {}, {}
    for addon in IDS:
        cv, ic = render_cover(addon), render_icon(addon)
        covers[addon], icons[addon] = cv, ic
        blobs.append((addon, "cover", jpeg_bytes(cv)))
        blobs.append((addon, "icon", png_bytes(ic)))
        if preview:
            cv.save(os.path.join(preview, "cover-%s.png" % addon))
            ic.save(os.path.join(preview, "icon-%s.png" % addon))
    if preview:
        cw, chh = 540, 304
        sheet = Image.new("RGB", (cw * 2 + 60, (chh + 30) * 4 + 30 + 150), (5, 5, 8))
        for i, addon in enumerate(IDS):
            im = covers[addon].resize((cw, chh), Image.LANCZOS)
            sheet.paste(im, (20 + (i % 2) * (cw + 20), 20 + (i // 2) * (chh + 30)))
        for i, addon in enumerate(IDS):
            ic = icons[addon].resize((88, 88), Image.LANCZOS)
            sheet.paste(ic, (20 + i * 110, (chh + 30) * 4 + 40), ic)
        sheet.save(os.path.join(preview, "sheet.png"))
    with open(OUT_C, "w") as f:
        f.write("// Generated by scripts/mirage-art.py: the add-on covers (JPEG) and icons (PNG). Do not edit by hand.\n")
        f.write("#include <stddef.h>\n\n")
        for addon, kind, data in blobs:
            name = c_name(addon, kind)
            f.write("static const unsigned char %s[] = {\n" % name)
            for i in range(0, len(data), 20):
                f.write("  " + ",".join(str(b) for b in data[i:i + 20]) + ",\n")
            f.write("};\n")
        f.write("\ntypedef struct { const char *addon; const char *kind; const unsigned char *bytes; size_t length; } MRGArtBlob;\n")
        f.write("const MRGArtBlob MRGArtBlobs[] = {\n")
        for addon, kind, data in blobs:
            f.write('  {"%s", "%s", %s, sizeof(%s)},\n' % (addon, kind, c_name(addon, kind), c_name(addon, kind)))
        f.write("};\nconst size_t MRGArtBlobCount = %d;\n" % len(blobs))
    total = sum(len(d) for _, _, d in blobs)
    print("wrote %s (%d images, %.0f KB)" % (OUT_C, len(blobs), total / 1024))


if __name__ == "__main__":
    main()
