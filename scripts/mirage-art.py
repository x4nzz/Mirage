#!/usr/bin/env python3
"""Mirage add-on art: the shop covers and row icons, rendered here and compiled into the dylib.

  scripts/mirage-art.py [preview-dir]

Writes mirage/Sources/Addons/MRGAddonArtData.m (the images as byte arrays, so the phone shows exactly what was
previewed) and, with a preview dir, every image plus contact sheets there (sheet.png: the newest add-ons,
sheet-all.png: all of them).

The style is the original Vinyl card's: a soft, out-of-focus mesh-gradient ground (deep indigo and purple melting
into a warm tone) with one realistic, glossy, well-lit hero object in the middle, soft contact shadows, specular
highlights and fine grain. Each add-on has its own palette and its own object.
"""
import io, math, os, sys
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_M = os.path.join(ROOT, "mirage", "Sources", "Addons", "MRGAddonArtData.m")
W, H = 1080, 608          # 16:9 cover, 3x of a 360 pt card
ICON = 132                # 44 pt @3x
SS = 3                    # supersampling for shape masks
IDS = ["vinyl", "dynamic-colors", "playlist-tools", "genres", "popup-lyrics", "trash", "shuffle-plus", "generic",
       "radio", "focus", "on-repeat", "more-like-this", "cover-ring", "lyrics-backdrop", "queue-tools", "up-next"]
NEW_066 = IDS[8:]


# ------------------------------------------------------------------ basics (float RGB in 0..1, masks HxW)

def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], np.float32)


def box_blur_1d(a, r, axis):
    if r < 1:
        return a
    n = a.shape[axis]
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    p = np.pad(a, pad, mode="edge")
    c = np.cumsum(p, axis=axis, dtype=np.float64)
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return ((hi - lo) / (2 * r + 1)).astype(np.float32)


def blur(a, sigma):
    """Gaussian blur (three box passes); big radii run on a downscaled copy."""
    if sigma <= 0.3:
        return a
    scale = 1
    while sigma / scale > 24 and min(a.shape[0], a.shape[1]) / (scale * 2) > 16:
        scale *= 2
    src = a
    if scale > 1:
        h, w = a.shape[:2]
        src = resize(a, (max(1, w // scale), max(1, h // scale)))
    s = sigma / scale
    r = max(1, int(round(math.sqrt(12 * s * s / 3 + 1) / 2)))
    out = src
    for _ in range(3):
        out = box_blur_1d(out, r, 0)
        out = box_blur_1d(out, r, 1)
    if scale > 1:
        out = resize(out, (a.shape[1], a.shape[0]))
    return out


def resize(a, size):
    w, h = size
    if a.ndim == 2:
        im = Image.fromarray(a.astype(np.float32), "F").resize((w, h), Image.BICUBIC)
        return np.asarray(im, np.float32)
    return np.stack([resize(a[..., i], size) for i in range(a.shape[2])], axis=-1)


def mask(w, h, draw):
    """A soft-edged shape mask drawn by `draw(d, k)` with coordinates multiplied by k (supersampled)."""
    im = Image.new("L", (w * SS, h * SS), 0)
    draw(ImageDraw.Draw(im), SS)
    im = im.resize((w, h), Image.LANCZOS)
    return np.asarray(im, np.float32) / 255.0


def over(dst, color, m):
    m = np.clip(m, 0, 1)[..., None]
    return dst * (1 - m) + color * m


def grid(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    return x, y


def mesh(w, h, base, blobs, soften=0.0):
    """A mesh gradient: colored gaussian blobs (x, y in 0..1, radius in 0..1 of the width, color, strength) blended
    over a base, then softened."""
    x, y = grid(w, h)
    acc = np.zeros((h, w, 3), np.float32) + base
    for bx, by, br, col, k in blobs:
        d2 = ((x - bx * w) ** 2 + (y - by * h) ** 2) / (br * w) ** 2
        wgt = np.exp(-d2 * 1.6)[..., None] * k
        acc = acc * (1 - wgt) + hexc(col) * wgt
    if soften:
        acc = blur(acc, soften)
    return acc


def zones(w, h, base, blobs, soften=0.0, base_weight=0.02):
    """A mesh gradient with distinct color zones: each point takes the weighted average of the blobs near it
    (normalized, sharp falloff), so colors stay saturated instead of washing into each other; then softened."""
    x, y = grid(w, h)
    num = np.zeros((h, w, 3), np.float32) + hexc(base) * base_weight if isinstance(base, str) else base * base_weight
    den = np.full((h, w), base_weight, np.float32)
    for bx, by, br, col, k in blobs:
        d2 = ((x - bx * w) ** 2 + (y - by * h) ** 2) / (br * w) ** 2
        wgt = np.exp(-d2 * 2.5) * k
        num += hexc(col) * wgt[..., None]
        den += wgt
    acc = num / den[..., None]
    if soften:
        acc = blur(acc, soften)
    return acc


def grain(img, amount, seed):
    rng = np.random.default_rng(seed)
    n = rng.normal(0, amount, img.shape[:2]).astype(np.float32)[..., None]
    return np.clip(img + n, 0, 1)


def shadow(img, m, sigma, opacity, dx=0, dy=0, color=(0, 0, 0)):
    s = np.roll(np.roll(m, int(dy), axis=0), int(dx), axis=1)
    s = blur(s, sigma) * opacity
    return over(img, np.array(color, np.float32), s)


def vertical(h, w, top, bottom):
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    return np.repeat(top * (1 - t) + bottom * t, w, axis=1)


def to_image(a):
    return Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")


def rrect(x, y, w, h, r):
    return lambda d, k: d.rounded_rectangle([x * k, y * k, (x + w) * k, (y + h) * k], radius=r * k, fill=255)


def ellipse(cx, cy, rx, ry=None):
    ry = rx if ry is None else ry
    return lambda d, k: d.ellipse([(cx - rx) * k, (cy - ry) * k, (cx + rx) * k, (cy + ry) * k], fill=255)


def polygon(pts):
    return lambda d, k: d.polygon([(px * k, py * k) for px, py in pts], fill=255)


def stroke(pts, width):
    def f(d, k):
        sp = [(px * k, py * k) for px, py in pts]
        d.line(sp, fill=255, width=int(width * k), joint="curve")
        r = width * k / 2
        for px, py in (sp[0], sp[-1]):
            d.ellipse([px - r, py - r, px + r, py + r], fill=255)
    return f


def rotate_pts(pts, cx, cy, deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return [(cx + (px - cx) * c - (py - cy) * s, cy + (px - cx) * s + (py - cy) * c) for px, py in pts]


def rrect_pts(x, y, w, h, r, n=10):
    pts = []
    for cx, cy, a0 in ((x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


# ------------------------------------------------------------------ shared pieces

def ground(pal, seed):
    """The card's backdrop: the reference's dark, painterly mesh (near-black left, a color crown on top, a warm
    glow low right)."""
    a, b, c, d = pal["ground"]
    img = mesh(W, H, hexc("#07060c"), [
        (0.48, -0.10, 0.55, a, 0.95),
        (0.95, 1.05, 0.70, b, 0.95),
        (0.15, 1.10, 0.45, c, 0.35),
        (0.85, 0.05, 0.35, d, 0.45),
    ], soften=40)
    x, y = grid(W, H)
    # the left falls off to black, as in the reference
    fall = np.clip(1 - x / (W * 0.55), 0, 1) ** 1.6 * 0.55
    img = img * (1 - fall[..., None])
    return img


def gloss_sheen(m, strength, angle=-35, width=0.55):
    """A soft diagonal specular sheen inside a mask."""
    x, y = grid(W, H)
    a = math.radians(angle)
    proj = (x * math.cos(a) + y * math.sin(a))
    ys, xs = np.nonzero(m > 0.5)
    if len(xs) == 0:
        return np.zeros_like(m)
    p0, p1 = np.percentile(proj[m > 0.5], [0, 100])
    t = (proj - p0) / max(p1 - p0, 1)
    band = np.exp(-((t - 0.18) / (width * 0.35)) ** 2) * strength
    return band * m


def inner_edge(m, sigma, strength):
    """A bright rim just inside the shape (light catching the edge)."""
    e = np.clip(m - blur(m, sigma), 0, 1) * 2.2
    return np.clip(e, 0, 1) * strength


def finish(img, seed, vignette=0.35):
    x, y = grid(W, H)
    d = np.sqrt(((x - W * 0.52) / W) ** 2 + ((y - H * 0.48) / H) ** 2)
    v = np.clip((d - 0.30) / 0.45, 0, 1) ** 1.5 * vignette
    img = img * (1 - v[..., None])
    return grain(img, 0.012, seed)


def soft_album(w, h, palette, seed):
    """A sleeve's printed art: a big soft blurred gradient like the reference's."""
    a, b, c, d = palette
    art = zones(w, h, b, [
        (0.15, 0.15, 0.55, a, 0.9),
        (0.85, 0.10, 0.40, d, 0.7),
        (0.55, 0.95, 0.55, c, 1.0),
        (0.95, 0.80, 0.45, b, 0.6),
        (0.50, 0.55, 0.35, c, 0.55),
    ], soften=w * 0.06)
    rng = np.random.default_rng(seed)
    sparkle = (rng.random((h, w)) > 0.9993).astype(np.float32) * 0.35
    return np.clip(art + sparkle[..., None], 0, 1)


def place(img, layer, m, x0, y0):
    """Composite a sub-image `layer` (h, w, 3) with mask `m` (full-size) at its offset."""
    hh, ww = layer.shape[:2]
    full = np.zeros_like(img)
    ys, xs = slice(max(0, y0), min(H, y0 + hh)), slice(max(0, x0), min(W, x0 + ww))
    full[ys, xs] = layer[ys.start - y0:ys.stop - y0, xs.start - x0:xs.stop - x0]
    return over(img, full, m)


def sleeve(img, x, y, s, palette, seed, angle=0.0, shadow_op=0.75, radius=None, art_fn=None):
    """A square album sleeve with soft blurred art, rounded corners, contact shadow, rim light and sheen."""
    r = radius if radius is not None else s * 0.055
    pts = rotate_pts(rrect_pts(x, y, s, s, r), x + s / 2, y + s / 2, angle)
    m = mask(W, H, polygon(pts))
    img = shadow(img, m, 26, shadow_op, dy=18)
    img = shadow(img, m, 6, 0.35, dy=4)
    n = int(round(s))
    art = art_fn(n, n, seed) if art_fn else soft_album(n, n, palette, seed)
    pad = int(n * 0.25)
    art = np.pad(art, ((pad, pad), (pad, pad), (0, 0)), mode="edge")
    big = Image.fromarray((art * 255).astype(np.uint8)).rotate(-angle, resample=Image.BICUBIC)
    art = np.asarray(big, np.float32) / 255
    ox, oy = int(x + s / 2 - art.shape[1] / 2), int(y + s / 2 - art.shape[0] / 2)
    img = place(img, art, m, ox, oy)
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.05, angle=-60))
    img = over(img, np.ones(3, np.float32), inner_edge(m, 2.0, 0.22))
    return img, m


def record(img, cx, cy, R, label_palette, seed, label=0.36):
    """A glossy black vinyl: grooves, a conic specular sweep, a gradient label and a spindle hole."""
    x, y = grid(W, H)
    m = mask(W, H, ellipse(cx, cy, R))
    img = shadow(img, m, 24, 0.7, dy=14)
    dx, dy = x - cx, y - cy
    rr = np.sqrt(dx * dx + dy * dy) / R
    ang = np.arctan2(dy, dx)
    base = np.full((H, W, 3), 0.035, np.float32)
    # grooves: fine rings plus a few wider gaps between "tracks"
    fine = 0.5 + 0.5 * np.sin(rr * R * 0.9)
    tracks = np.zeros_like(rr)
    for t in (0.52, 0.64, 0.76, 0.88):
        tracks += np.exp(-((rr - t) / 0.006) ** 2)
    lum = 0.035 + fine * 0.012 + tracks * 0.10
    # light sweeping across the grooves (two opposite lobes, like a lit record)
    sweep = (np.cos(2 * (ang + 0.75)) * 0.5 + 0.5) ** 6 * 0.20 * np.clip((rr - 0.38) / 0.1, 0, 1)
    lum = lum + sweep
    disc = base * 0 + lum[..., None]
    img = over(img, disc, m)
    # outer rim
    rim = np.exp(-((rr - 0.995) / 0.006) ** 2) * 0.35
    img = over(img, np.ones(3, np.float32), rim * m)
    # label
    lr = R * label
    lm = mask(W, H, ellipse(cx, cy, lr))
    a, b, c, d = label_palette
    lab = mesh(W, H, hexc(b), [(cx / W - 0.01, (cy - lr * 0.7) / H, lr / W * 1.3, a, 1.0),
                               (cx / W, (cy + lr * 0.8) / H, lr / W * 1.2, c, 1.0)], soften=lr * 0.25)
    img = over(img, lab, lm)
    img = over(img, np.zeros(3, np.float32), mask(W, H, ellipse(cx, cy, R * 0.025)) * 0.9)
    return img, m


def tube(img, pts, width, color, light, shadow_op=0.6, seed=0):
    """A glossy rounded tube along a path: shaded across its width, a specular line, a soft shadow."""
    m = mask(W, H, stroke(pts, width))
    img = shadow(img, m, width * 0.45, shadow_op, dy=width * 0.35)
    core = mask(W, H, stroke(pts, width * 0.45))
    body = blur(core, width * 0.22)
    body = body / max(body.max(), 1e-3)
    shade = hexc(color) * (0.55 + 0.45 * body[..., None])
    img = over(img, shade, m)
    hl_pts = [(px - width * 0.12, py - width * 0.16) for px, py in pts]
    hl = blur(mask(W, H, stroke(hl_pts, width * 0.16)), width * 0.06) * m
    img = over(img, hexc(light), hl * 0.85)
    return img, m


def arrowhead(img, tip, direction, size, color, light):
    ang = math.atan2(direction[1], direction[0])
    c, s = math.cos(ang), math.sin(ang)
    def P(u, v):
        return (tip[0] + u * c - v * s, tip[1] + u * s + v * c)
    pts = [P(size * 0.55, 0), P(-size * 0.55, -size * 0.62), P(-size * 0.30, 0), P(-size * 0.55, size * 0.62)]
    m = blur(mask(W, H, polygon(pts)), 1.2)
    img = shadow(img, m, size * 0.25, 0.6, dy=size * 0.18)
    x, y = grid(W, H)
    t = ((x - tip[0]) * -s + (y - tip[1]) * c) / size
    shade = hexc(color) * (0.75 + 0.25 * np.clip(-t * 1.2 + 0.4, 0, 1))[..., None]
    img = over(img, shade, m)
    img = over(img, hexc(light), inner_edge(m, 3, 0.5))
    return img


def frosted(img, m, tint, amount=0.16, frost=14):
    """Frosted glass: what's behind, blurred, lifted with a tint, a bright rim and a top sheen."""
    behind = blur(img, frost)
    glass = behind * (1 - amount) + hexc(tint) * amount
    glass = glass + 0.06
    out = over(img, np.clip(glass, 0, 1), m)
    out = over(out, np.ones(3, np.float32), inner_edge(m, 2.5, 0.55))
    return out


# ------------------------------------------------------------------ the covers

PAL = {
    "vinyl":          {"ground": ("#3a1d66", "#6e2a44", "#1a1240", "#4a2058"), "art": ("#9a8fb0", "#7a3fa6", "#ff6f61", "#3d5bd8")},
    "dynamic-colors": {"ground": ("#1f3c7a", "#7a2f3a", "#0f2a4a", "#3a2270"), "art": ("#ffb35c", "#e0457b", "#ff6f61", "#7b5cff")},
    "playlist-tools": {"ground": ("#163f63", "#3d2b78", "#0b2a3a", "#1f5a6a"), "art": ("#5ee7c7", "#2b6fd8", "#9b6cff", "#2dd4bf")},
    "genres":         {"ground": ("#2a2f86", "#1f5a8a", "#140f3a", "#4b2a8a"), "art": ("#8fd3ff", "#5b6cff", "#c084fc", "#60a5fa")},
    "popup-lyrics":   {"ground": ("#5a1f78", "#8a2a5a", "#221040", "#7a2a8a"), "art": ("#ff8fd0", "#9b4dff", "#ff6fa8", "#ffd1f0")},
    "trash":          {"ground": ("#4a1830", "#7a2a2a", "#1a0f22", "#5a1f48"), "art": ("#ff9a8a", "#c2415c", "#ff6f61", "#ffc1b5")},
    "shuffle-plus":   {"ground": ("#3a2478", "#2f5a3a", "#120f2a", "#4a2a8a"), "art": ("#c6f66b", "#6d3fe0", "#8bd43a", "#a78bfa")},
    "generic":        {"ground": ("#33206e", "#5a2a6a", "#140f30", "#3d2a7a"), "art": ("#c4b5fd", "#8b5cf6", "#f0abfc", "#a78bfa")},
    "radio":          {"ground": ("#4a1f7a", "#7a3a2a", "#160f30", "#5a2a6a"), "art": ("#ffb86b", "#8b3fe0", "#ff7a59", "#c4a1ff")},
    "focus":          {"ground": ("#24124a", "#3a1a5a", "#05040a", "#2a1450"), "art": ("#b89cff", "#2a1060", "#7c4dff", "#e0d4ff")},
    "on-repeat":      {"ground": ("#3a1f78", "#7a2a5a", "#120f2a", "#5a2a8a"), "art": ("#ff9ad5", "#7b3fe0", "#ffb35c", "#c4b5fd")},
    "more-like-this": {"ground": ("#1f3f7a", "#5a2a7a", "#0f1a3a", "#3a2a8a"), "art": ("#8fe3ff", "#5b4dd6", "#f0abfc", "#7dd3fc")},
    "cover-ring":     {"ground": ("#3d1f78", "#245a5a", "#120f2a", "#4a2a7a"), "art": ("#a3f0c0", "#6d3fe0", "#5eead4", "#c4b5fd")},
    "lyrics-backdrop":{"ground": ("#5a1f5a", "#2a1f6a", "#140a20", "#6a2a7a"), "art": ("#ffd1f0", "#8b3fe0", "#ff8fb8", "#f5d0fe")},
    "queue-tools":    {"ground": ("#1f2f6e", "#4a2a78", "#0c1230", "#2a3a8a"), "art": ("#93c5fd", "#4f46e5", "#a78bfa", "#bfdbfe")},
    "up-next":        {"ground": ("#3a2070", "#6a2a4a", "#140f2a", "#4a2a6a"), "art": ("#fbcfe8", "#7c3aed", "#fda4af", "#ddd6fe")},
}


def vinyl_art(w, h, seed):
    """The reference sleeve: mauve-grey top, a blue corner, a violet band, a salmon glow low in the middle and hot
    pink at the bottom corners, all out of focus."""
    art = zones(w, h, "#c42a86", [
        (0.45, -0.05, 0.50, "#8e7f97", 1.0),
        (0.10, 0.05, 0.30, "#8a7a95", 0.8),
        (1.00, -0.02, 0.20, "#3456d4", 1.0),
        (0.22, 0.36, 0.30, "#6e3aa8", 1.0),
        (0.82, 0.38, 0.20, "#b87a8c", 0.8),
        (0.50, 0.58, 0.24, "#d8687e", 0.9),
        (0.00, 1.02, 0.36, "#f01e7a", 1.0),
        (1.00, 1.02, 0.36, "#f01e7a", 1.0),
        (0.50, 0.84, 0.34, "#ff7468", 1.3),
    ], soften=w * 0.05)
    rng = np.random.default_rng(seed)
    sparkle = (rng.random((h, w)) > 0.9994).astype(np.float32) * 0.3
    return np.clip(art + sparkle[..., None], 0, 1)


def cover_vinyl():
    p = PAL["vinyl"]
    img = ground(p, 1)
    s = H * 0.61
    sx, sy = W * 0.255, H * 0.5 - s / 2 - 4
    img, _ = record(img, sx + s * 0.98, sy + s / 2, H * 0.285, ("#3a5bd0", "#9a3fb0", "#f0207a", "#ff6f61"), 3, label=0.30)
    img, _ = sleeve(img, sx, sy, s, None, 4, art_fn=vinyl_art)
    return img


def cover_dynamic():
    p = PAL["dynamic-colors"]
    img = ground(p, 2)
    # the album on the left
    s = H * 0.40
    ax, ay = W * 0.20, H * 0.5 - s / 2
    img, _ = sleeve(img, ax, ay, s, p["art"], 5, angle=-6)
    # a beam from the album into a glass prism, fanning out into the album's colors
    px, py, ps = W * 0.60, H * 0.53, H * 0.36
    tri = [(px, py - ps * 0.62), (px - ps * 0.62, py + ps * 0.45), (px + ps * 0.62, py + ps * 0.45)]
    beam_in = blur(mask(W, H, polygon([(ax + s * 0.9, H * 0.46), (px - ps * 0.30, py - ps * 0.02), (px - ps * 0.28, py + ps * 0.06), (ax + s * 0.9, H * 0.50)])), 3)
    img = over(img, np.array([1, 0.95, 0.9], np.float32), beam_in * 0.55)
    bands = ["#ffb35c", "#ff6f61", "#e0457b", "#9b4dff", "#5b8cff"]
    ex = W * 0.96
    fan = np.zeros((H, W, 3), np.float32)
    fan_m = np.zeros((H, W), np.float32)
    for i, col in enumerate(bands):
        y0 = py + ps * 0.02 + i * 3
        y1a, y1b = H * (0.36 + i * 0.07), H * (0.36 + (i + 1) * 0.07)
        band = mask(W, H, polygon([(px + ps * 0.20, y0), (ex, y1a), (ex, y1b), (px + ps * 0.22, y0 + 5)]))
        fan = fan + hexc(col) * band[..., None]
        fan_m = np.maximum(fan_m, band)
    fan = blur(fan, 9)
    fan_m = blur(fan_m, 9)
    x, y = grid(W, H)
    falloff = np.clip(1 - (x - px) / (ex - px), 0, 1) ** 0.6
    img = img + fan * (falloff * 0.8)[..., None]
    img = np.clip(img, 0, 1)
    m = mask(W, H, polygon(tri))
    img = shadow(img, m, 26, 0.6, dy=18)
    # thick glass: the background through it, lifted and tinted, a rainbow caught inside, bright facets
    img = frosted(img, m, "#dfe4ff", amount=0.18, frost=10)
    inside = zones(W, H, "#9aa6ff", [(px / W - 0.03, (py + ps * 0.25) / H, 0.06, "#ff8fa0", 1.0),
                                     (px / W + 0.05, (py + ps * 0.2) / H, 0.06, "#8fb6ff", 1.0),
                                     (px / W, (py - ps * 0.25) / H, 0.05, "#ffffff", 0.8)], soften=12)
    img = over(img, inside, m * 0.30)
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.28, angle=-70, width=0.3))
    edge = np.clip(m - blur(m, 2.0), 0, 1) * 2.5
    img = over(img, np.ones(3, np.float32), np.clip(edge, 0, 1) * 0.7)
    # a faint inner facet line from the apex
    facet = blur(mask(W, H, stroke([(px, py - ps * 0.58), (px + ps * 0.05, py + ps * 0.42)], 2)), 1.0)
    img = over(img, np.ones(3, np.float32), facet * 0.25 * m)
    return img


def cover_playlist():
    p = PAL["playlist-tools"]
    img = ground(p, 3)
    s = H * 0.50
    cx, cy = W * 0.52, H * 0.50
    pals = [("#2b6fd8", "#1f3c7a", "#5ee7c7", "#2dd4bf"), ("#9b6cff", "#3d2b78", "#ff8fd0", "#5b6cff"), p["art"]]
    for i, (dxk, ang, pal) in enumerate(((-0.30, -12, pals[0]), (0.0, -3, pals[1]), (0.28, 7, pals[2]))):
        x = cx + dxk * s - s / 2
        y = cy - s / 2 + abs(dxk) * s * 0.10
        img, _ = sleeve(img, x, y, s, pal, 10 + i, angle=ang, shadow_op=0.65)
    return img


def tag(img, cx, cy, w, h, angle, colors, seed):
    """A glossy luggage-style tag: a rounded body with a cut corner side, an eyelet and a gradient finish."""
    r = h * 0.22
    body = [(cx - w / 2 + h * 0.35, cy - h / 2), (cx + w / 2 - r, cy - h / 2), (cx + w / 2, cy - h / 2 + r),
            (cx + w / 2, cy + h / 2 - r), (cx + w / 2 - r, cy + h / 2), (cx - w / 2 + h * 0.35, cy + h / 2), (cx - w / 2, cy)]
    pts = rotate_pts(body, cx, cy, angle)
    m = blur(mask(W, H, polygon(pts)), 1.0)
    hx, hy = rotate_pts([(cx - w / 2 + h * 0.42, cy)], cx, cy, angle)[0]
    hole = mask(W, H, ellipse(hx, hy, h * 0.10))
    m = np.clip(m - hole, 0, 1)
    img = shadow(img, m, 18, 0.6, dy=12)
    x, y = grid(W, H)
    a = math.radians(angle + 90)
    t = ((x - cx) * math.cos(a) + (y - cy) * math.sin(a)) / h + 0.5
    t = np.clip(t, 0, 1)[..., None]
    fill = hexc(colors[0]) * (1 - t) + hexc(colors[1]) * t
    img = over(img, fill, m)
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.30, angle=angle - 80, width=0.25))
    img = over(img, np.ones(3, np.float32), inner_edge(m, 2.0, 0.45))
    # eyelet ring
    ring = np.clip(mask(W, H, ellipse(hx, hy, h * 0.15)) - mask(W, H, ellipse(hx, hy, h * 0.10)), 0, 1)
    img = over(img, hexc("#e9e6f5"), ring * 0.9)
    return img


def cover_genres():
    p = PAL["genres"]
    img = ground(p, 4)
    cx, cy = W * 0.52, H * 0.50
    # a string through the eyelets
    img = tag(img, cx + 10, cy + H * 0.17, W * 0.40, H * 0.20, 6, ("#c084fc", "#7c3aed"), 1)
    img = tag(img, cx - 6, cy, W * 0.42, H * 0.20, -4, ("#8fd3ff", "#3b6fe0"), 2)
    img = tag(img, cx + 18, cy - H * 0.18, W * 0.38, H * 0.20, -11, ("#a5b4fc", "#5b4dd6"), 3)
    return img


def cover_lyrics():
    p = PAL["popup-lyrics"]
    # brighter blobs so the frost has something to show
    img = ground(p, 5)
    # a painterly field behind the card, so the frost has color to soften
    field = zones(W, H, "#2a0f3a", [(0.30, 0.30, 0.20, "#d63c8c", 1.0), (0.70, 0.70, 0.22, "#7b3fe0", 1.0),
                                    (0.62, 0.25, 0.14, "#ff8a5c", 0.9), (0.40, 0.78, 0.16, "#5a2aa0", 0.8)], soften=50, base_weight=0.3)
    x, y = grid(W, H)
    fade = np.clip(1 - np.sqrt(((x - W * 0.5) / (W * 0.48)) ** 2 + ((y - H * 0.5) / (H * 0.62)) ** 2), 0, 1) ** 0.8
    img = over(img, field, fade * 0.9)
    cw, ch = W * 0.58, H * 0.50
    x, y = W * 0.5 - cw / 2, H * 0.5 - ch / 2
    m = mask(W, H, rrect(x, y, cw, ch, 34))
    img = shadow(img, m, 30, 0.45, dy=18)
    img = frosted(img, m, "#ffffff", amount=0.14, frost=26)
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.08, angle=-80, width=0.4))
    # lines: dim, the current one glowing, dim
    lines = [(0.24, 0.52, 0.38, 14), (0.47, 0.80, 1.0, 22), (0.70, 0.62, 0.38, 14)]
    for ly, lw, op, th in lines:
        lm = mask(W, H, rrect(x + cw * 0.09, y + ch * ly - th / 2, cw * lw, th, th / 2))
        if op == 1.0:
            img = over(img, hexc("#ffd1f0"), blur(lm, 14) * 0.65)
        img = over(img, np.ones(3, np.float32), lm * op)
    return img


def cover_trash():
    p = PAL["trash"]
    img = ground(p, 6)
    cx, base = W * 0.52, H * 0.86
    bw_top, bw_bot, bh = H * 0.50, H * 0.38, H * 0.56
    top = base - bh
    body = [(cx - bw_top / 2, top), (cx + bw_top / 2, top), (cx + bw_bot / 2, base), (cx - bw_bot / 2, base)]
    m = blur(mask(W, H, polygon(body)), 1.0)
    img = shadow(img, m, 28, 0.65, dy=18)
    # the back wall, darker glass
    img = frosted(img, m, "#3a1420", amount=0.30, frost=14)
    # a sleeve dropped in, half inside
    img, sm = sleeve(img, cx - H * 0.13, top - H * 0.20, H * 0.30, ("#ffc1b5", "#c2415c", "#ff6f61", "#7a2a8a"), 7, angle=16, shadow_op=0.45)
    # the front glass over it (only the part inside the bin is seen through glass)
    behind = img.copy()
    img = frosted(img, m, "#ffc9c0", amount=0.16, frost=16)
    for k in (-0.26, 0.0, 0.26):
        rx0, rx1 = cx + k * bw_top, cx + k * bw_bot
        rib = blur(mask(W, H, stroke([(rx0, top + bh * 0.12), (rx1, base - bh * 0.08)], 8)), 2.5)
        img = over(img, np.ones(3, np.float32), rib * 0.22)
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.16, angle=-75, width=0.3))
    # the rim: a glossy rounded band across the open top
    rim = mask(W, H, rrect(cx - bw_top / 2 - 10, top - 12, bw_top + 20, 24, 12))
    img = shadow(img, rim, 8, 0.4, dy=5)
    img = frosted(img, rim, "#ffe5e0", amount=0.35, frost=6)
    img = over(img, np.ones(3, np.float32), gloss_sheen(rim, 0.35, angle=-85, width=0.2))
    return img


def smooth_path(p0, p1, n=60):
    pts = []
    for i in range(n + 1):
        t = i / n
        e = t * t * (3 - 2 * t)
        pts.append((p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * e))
    return pts


def cover_shuffle():
    p = PAL["shuffle-plus"]
    img = ground(p, 7)
    x0, x1 = W * 0.27, W * 0.70
    ylo, yhi = H * 0.70, H * 0.30
    wdt = H * 0.085
    a = smooth_path((x0, yhi), (x1, ylo))   # back arrow first (purple), then the front one (lime)
    b = smooth_path((x0, ylo), (x1, yhi))
    img, _ = tube(img, a, wdt, "#8b5cf6", "#e6dcff")
    img = arrowhead(img, (x1 + wdt * 1.05, ylo), (1, 0), wdt * 2.3, "#8b5cf6", "#e6dcff")
    img, _ = tube(img, b, wdt, "#a3e635", "#f4ffd6")
    img = arrowhead(img, (x1 + wdt * 1.05, yhi), (1, 0), wdt * 2.3, "#a3e635", "#f4ffd6")
    # the plus: a small glossy sphere
    sx, sy, sr = W * 0.80, H * 0.18, H * 0.07
    sm = mask(W, H, ellipse(sx, sy, sr))
    img = shadow(img, sm, 12, 0.5, dy=8)
    xg, yg = grid(W, H)
    d = np.sqrt((xg - (sx - sr * 0.35)) ** 2 + (yg - (sy - sr * 0.35)) ** 2) / (sr * 1.6)
    sph = hexc("#f2edff") * (1 - np.clip(d, 0, 1)[..., None] * 0.35)
    img = over(img, sph, sm)
    for (w_, h_) in ((sr * 1.0, sr * 0.24), (sr * 0.24, sr * 1.0)):
        img = over(img, hexc("#5b3fd0"), mask(W, H, rrect(sx - w_ / 2, sy - h_ / 2, w_, h_, min(w_, h_) / 2)))
    return img


def cover_generic():
    p = PAL["generic"]
    img = ground(p, 8)
    s = H * 0.46
    x, y = W * 0.5 - s / 2, H * 0.5 - s / 2
    m = mask(W, H, rrect(x, y, s, s, s * 0.24))
    img = shadow(img, m, 26, 0.7, dy=18)
    tile = mesh(W, H, hexc("#7c4dff"), [(0.45, 0.30, 0.18, "#c4b5fd", 0.9), (0.58, 0.75, 0.16, "#f0abfc", 0.7)], soften=10)
    img = over(img, tile, m)
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.25, angle=-70, width=0.3))
    img = over(img, np.ones(3, np.float32), inner_edge(m, 2.5, 0.4))
    # an embossed puzzle piece
    u = s / 10
    piece = np.clip(mask(W, H, rrect(x + 2.6 * u, y + 3.2 * u, 4.8 * u, 4.2 * u, u * 0.7)) +
                    mask(W, H, ellipse(x + 5 * u, y + 3.0 * u, 1.0 * u)) + mask(W, H, ellipse(x + 7.5 * u, y + 5.3 * u, 1.0 * u)), 0, 1)
    img = shadow(img, piece, 6, 0.4, dy=4)
    img = over(img, hexc("#f7f2ff"), piece * 0.95)
    return img


COVERS = {"vinyl": cover_vinyl, "dynamic-colors": cover_dynamic, "playlist-tools": cover_playlist, "genres": cover_genres,
          "popup-lyrics": cover_lyrics, "trash": cover_trash, "shuffle-plus": cover_shuffle, "generic": cover_generic}


# ------------------------------------------------------------------ 0.6.6 covers

def arc_pts(cx, cy, r, a0, a1, n=80):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


def sphere(img, sx, sy, sr, color, light="#ffffff", glow=None):
    """A glossy ball: soft shadow, a radial body, a specular dot."""
    sm = mask(W, H, ellipse(sx, sy, sr))
    if glow:
        img = over(img, hexc(glow), blur(sm, sr * 0.6) * 0.55)
    img = shadow(img, sm, sr * 0.35, 0.55, dy=sr * 0.25)
    xg, yg = grid(W, H)
    d = np.sqrt((xg - (sx - sr * 0.35)) ** 2 + (yg - (sy - sr * 0.38)) ** 2) / (sr * 1.7)
    body = hexc(color) * (1.08 - np.clip(d, 0, 1)[..., None] * 0.55)
    img = over(img, np.clip(body, 0, 1), sm)
    spec = blur(mask(W, H, ellipse(sx - sr * 0.38, sy - sr * 0.42, sr * 0.22, sr * 0.14)), sr * 0.06)
    img = over(img, hexc(light), spec * 0.85 * sm)
    img = over(img, np.ones(3, np.float32), inner_edge(sm, 2.0, 0.25))
    return img


def glass_card(img, x, y, w, h, r, tint="#ffffff", amount=0.14, frost=22, shadow_op=0.45):
    m = mask(W, H, rrect(x, y, w, h, r))
    img = shadow(img, m, 26, shadow_op, dy=16)
    img = frosted(img, m, tint, amount=amount, frost=frost)
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.08, angle=-80, width=0.4))
    return img, m


def cover_radio():
    p = PAL["radio"]
    img = ground(p, 21)
    cx, cy = W * 0.5, H * 0.52
    # broadcast waves on both sides, nearest brightest
    for i, r in enumerate((H * 0.20, H * 0.31, H * 0.42)):
        col = ["#ffd1a3", "#ffb86b", "#c4a1ff"][i]
        for a0, a1 in ((-40, 40), (140, 220)):
            img, _ = tube(img, arc_pts(cx, cy, r, a0, a1, 50), H * 0.040, col, "#fff6ea", shadow_op=0.35)
    # an endless loop under the orb, faint
    img = sphere(img, cx, cy, H * 0.11, "#ff8a5c", glow="#ffb86b")
    return img


def cover_focus():
    p = PAL["focus"]
    img = ground(p, 22)
    # a black OLED slab holding just the cover and the three controls
    pw, ph = H * 0.50, H * 0.86
    x, y = W * 0.5 - pw / 2, H * 0.5 - ph / 2
    m = mask(W, H, rrect(x, y, pw, ph, pw * 0.14))
    img = shadow(img, m, 30, 0.8, dy=20)
    img = over(img, np.full(3, 0.008, np.float32), m)
    img = over(img, np.ones(3, np.float32), inner_edge(m, 2.0, 0.30))
    img = over(img, np.ones(3, np.float32), gloss_sheen(m, 0.06, angle=-65, width=0.35))
    s = pw * 0.74
    img, _ = sleeve(img, W * 0.5 - s / 2, y + ph * 0.14, s, p["art"], 23, shadow_op=0.5)
    ry = y + ph * 0.14 + s + ph * 0.16
    for k, rad in ((-1, 0.040), (0, 0.062), (1, 0.040)):
        img = sphere(img, W * 0.5 + k * pw * 0.26, ry, ph * rad, "#f4f0ff" if k == 0 else "#b8a8e8")
    return img


def cover_on_repeat():
    p = PAL["on-repeat"]
    img = ground(p, 24)
    cx, cy, r = W * 0.5, H * 0.5, H * 0.33
    s = H * 0.36
    img, _ = sleeve(img, cx - s / 2, cy - s / 2, s, p["art"], 25, shadow_op=0.6)
    # a glossy repeat loop around it, its arrowhead catching up with its tail
    img, _ = tube(img, arc_pts(cx, cy, r, -60, 235, 120), H * 0.055, "#ff9ad5", "#fff0fa", shadow_op=0.45)
    tip = (cx + r * math.cos(math.radians(-60)), cy + r * math.sin(math.radians(-60)))
    img = arrowhead(img, tip, (math.cos(math.radians(30)), math.sin(math.radians(30))), H * 0.13, "#ff9ad5", "#fff0fa")
    return img


def sparkle(img, cx, cy, r, color):
    pts = []
    for i in range(8):
        a = math.radians(i * 45 - 90)
        rr = r if i % 2 == 0 else r * 0.28
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    m = blur(mask(W, H, polygon(pts)), 1.2)
    img = over(img, hexc(color), blur(m, r * 0.35) * 0.6)
    img = shadow(img, m, r * 0.15, 0.4, dy=r * 0.10)
    img = over(img, hexc(color), m)
    img = over(img, np.ones(3, np.float32), inner_edge(m, 2, 0.5))
    return img


def cover_more_like_this():
    p = PAL["more-like-this"]
    img = ground(p, 26)
    s = H * 0.42
    cx, cy = W * 0.46, H * 0.52
    img, _ = sleeve(img, cx + s * 0.55 - s * 0.36, cy - s * 0.80, s * 0.72, ("#5b4dd6", "#2b3fa8", "#f0abfc", "#7dd3fc"), 27, angle=9, shadow_op=0.5)
    img, _ = sleeve(img, cx + s * 0.70 - s * 0.36, cy - s * 0.10, s * 0.72, ("#7dd3fc", "#3d2b78", "#c084fc", "#8fe3ff"), 28, angle=-7, shadow_op=0.5)
    img, _ = sleeve(img, cx - s * 0.75, cy - s / 2, s, p["art"], 29, angle=-3)
    img = sparkle(img, W * 0.78, H * 0.20, H * 0.08, "#e0f7ff")
    return img


def cover_ring():
    p = PAL["cover-ring"]
    img = ground(p, 30)
    cx, cy = W * 0.5, H * 0.5
    s = H * 0.50
    img, _ = sleeve(img, cx - s / 2, cy - s / 2, s, p["art"], 31, radius=s * 0.08)
    # the track behind the ring, then the glossy progress (about two thirds round)
    r = s * 0.66
    track = mask(W, H, stroke(arc_pts(cx, cy, r, 0, 360, 160), H * 0.022))
    img = over(img, np.ones(3, np.float32), track * 0.12)
    img, _ = tube(img, arc_pts(cx, cy, r, -90, 150, 120), H * 0.030, "#a3f0c0", "#f2fff7", shadow_op=0.35)
    hx, hy = cx + r * math.cos(math.radians(150)), cy + r * math.sin(math.radians(150))
    img = sphere(img, hx, hy, H * 0.030, "#f2fff7", glow="#5eead4")
    return img


def cover_lyrics_backdrop():
    p = PAL["lyrics-backdrop"]
    img = ground(p, 32)
    # a big, dimmed cover filling the middle, the lines large on top of it
    s = H * 0.80
    x, y = W * 0.5 - s / 2, H * 0.5 - s / 2
    img, m = sleeve(img, x, y, s, p["art"], 33, shadow_op=0.6)
    img = over(img, np.zeros(3, np.float32), m * 0.55)
    lines = [(0.28, 0.58, 0.35, 18), (0.48, 0.80, 1.0, 34), (0.66, 0.70, 0.55, 26), (0.82, 0.46, 0.25, 18)]
    for ly, lw, op, th in lines:
        lm = mask(W, H, rrect(x + s * 0.10, y + s * ly - th / 2, s * lw, th, th / 2))
        if op == 1.0:
            img = over(img, hexc("#ffd1f0"), blur(lm, 16) * 0.7)
        img = over(img, np.ones(3, np.float32), lm * op)
    return img


def cover_queue_tools():
    p = PAL["queue-tools"]
    img = ground(p, 34)
    rw, rh = W * 0.42, H * 0.12
    x0 = W * 0.5 - rw / 2
    for i, yy in enumerate((0.26, 0.44, 0.62, 0.80)):
        lift = i == 1
        x = x0 + (W * 0.05 if lift else 0)
        y = H * yy - rh / 2 - (H * 0.02 if lift else 0)
        img, m = glass_card(img, x, y, rw, rh, rh * 0.35, tint="#dbeafe" if lift else "#ffffff", amount=0.22 if lift else 0.12,
                            frost=12, shadow_op=0.7 if lift else 0.35)
        s = rh * 0.70
        img, _ = sleeve(img, x + rh * 0.18, y + (rh - s) / 2, s, p["art"], 35 + i, shadow_op=0.3, radius=s * 0.12)
        bar = mask(W, H, rrect(x + rh * 1.15, y + rh * 0.40, rw * (0.50 if i % 2 else 0.38), rh * 0.18, rh * 0.09))
        img = over(img, np.ones(3, np.float32), bar * (0.9 if lift else 0.5))
        for k in range(3):
            g = mask(W, H, rrect(x + rw - rh * 0.55, y + rh * (0.32 + 0.14 * k), rh * 0.30, rh * 0.06, rh * 0.03))
            img = over(img, np.ones(3, np.float32), g * 0.55)
    img = arrowhead(img, (x0 - W * 0.05, H * 0.30), (0, -1), H * 0.10, "#93c5fd", "#eff6ff")
    img = arrowhead(img, (x0 - W * 0.05, H * 0.70), (0, 1), H * 0.10, "#a78bfa", "#f5f3ff")
    return img


def cover_up_next():
    p = PAL["up-next"]
    img = ground(p, 38)
    cw, ch = W * 0.64, H * 0.46
    x, y = W * 0.5 - cw / 2, H * 0.5 - ch / 2
    img, m = glass_card(img, x, y, cw, ch, 30, frost=24)
    lab = mask(W, H, rrect(x + cw * 0.07, y + ch * 0.13, cw * 0.24, ch * 0.08, ch * 0.04))
    img = over(img, np.ones(3, np.float32), lab * 0.8)
    s = ch * 0.50
    pals = [p["art"], ("#ddd6fe", "#5b21b6", "#fda4af", "#c4b5fd"), ("#fda4af", "#9d174d", "#fbcfe8", "#7c3aed")]
    for i in range(3):
        img, _ = sleeve(img, x + cw * 0.07 + i * (s + cw * 0.06), y + ch * 0.34, s, pals[i], 39 + i, shadow_op=0.45, radius=s * 0.10)
    img = arrowhead(img, (x + cw * 0.93, y + ch * 0.60), (1, 0), H * 0.08, "#fbcfe8", "#ffffff")
    return img


COVERS.update({"radio": cover_radio, "focus": cover_focus, "on-repeat": cover_on_repeat, "more-like-this": cover_more_like_this,
               "cover-ring": cover_ring, "lyrics-backdrop": cover_lyrics_backdrop, "queue-tools": cover_queue_tools, "up-next": cover_up_next})


def glyph_066(addon, n):
    u = n / 12
    if addon == "radio":
        m = mask(n, n, ellipse(6 * u, 6 * u, 1.2 * u))
        for r in (2.4, 3.8):
            for a0, a1 in ((-45, 45), (135, 225)):
                m = np.maximum(m, mask(n, n, stroke(arc_pts(6 * u, 6 * u, r * u, a0, a1, 30), 0.7 * u)))
        return m
    if addon == "focus":
        slab = mask(n, n, rrect(3.6 * u, 1.8 * u, 4.8 * u, 8.4 * u, 0.9 * u)) * 0.38
        cov = mask(n, n, rrect(4.3 * u, 2.7 * u, 3.4 * u, 3.4 * u, 0.4 * u))
        dots = np.maximum.reduce([mask(n, n, ellipse((6 + k * 1.2) * u, 7.9 * u, (0.55 if k == 0 else 0.4) * u)) for k in (-1, 0, 1)])
        return np.maximum.reduce([slab, cov, dots])
    if addon == "on-repeat":
        ring = mask(n, n, stroke(arc_pts(6 * u, 6 * u, 3.4 * u, -60, 240, 60), 0.9 * u))
        tip = (6 * u + 3.4 * u * math.cos(math.radians(-60)), 6 * u + 3.4 * u * math.sin(math.radians(-60)))
        head = mask(n, n, polygon([(tip[0] + 1.3 * u, tip[1] + 0.7 * u), (tip[0] - 0.9 * u, tip[1] - 0.9 * u), (tip[0] - 0.1 * u, tip[1] + 1.4 * u)]))
        return np.maximum.reduce([ring, head, mask(n, n, rrect(4.9 * u, 4.9 * u, 2.2 * u, 2.2 * u, 0.4 * u))])
    if addon == "more-like-this":
        a = mask(n, n, rrect(2.4 * u, 4.2 * u, 4.8 * u, 4.8 * u, 0.6 * u))
        b = mask(n, n, rrect(5.8 * u, 2.8 * u, 3.6 * u, 3.6 * u, 0.5 * u)) * 0.55
        pts = []
        for i in range(8):
            ang = math.radians(i * 45 - 90)
            rr = 1.3 * u if i % 2 == 0 else 0.4 * u
            pts.append((8.9 * u + rr * math.cos(ang), 8.4 * u + rr * math.sin(ang)))
        return np.maximum.reduce([a, b, mask(n, n, polygon(pts))])
    if addon == "cover-ring":
        cov = mask(n, n, rrect(4.0 * u, 4.0 * u, 4.0 * u, 4.0 * u, 0.6 * u))
        ring = mask(n, n, stroke(arc_pts(6 * u, 6 * u, 3.9 * u, -90, 170, 60), 0.7 * u))
        track = mask(n, n, stroke(arc_pts(6 * u, 6 * u, 3.9 * u, 0, 360, 80), 0.4 * u)) * 0.35
        return np.maximum.reduce([cov, ring, track])
    if addon == "lyrics-backdrop":
        cov = mask(n, n, rrect(2.2 * u, 2.2 * u, 7.6 * u, 7.6 * u, 1.0 * u)) * 0.35
        lines = np.maximum.reduce([mask(n, n, rrect(3.2 * u, 4.0 * u, 4.4 * u, 0.7 * u, 0.35 * u)),
                                   mask(n, n, rrect(3.2 * u, 5.5 * u, 5.6 * u, 1.1 * u, 0.55 * u)),
                                   mask(n, n, rrect(3.2 * u, 7.4 * u, 3.6 * u, 0.7 * u, 0.35 * u))])
        return np.maximum(cov, lines)
    if addon == "queue-tools":
        rows = np.maximum.reduce([mask(n, n, rrect((3.4 + (0.6 if k == 1 else 0)) * u, (2.6 + k * 2.4) * u, 6.0 * u, 1.5 * u, 0.5 * u)) * (1.0 if k == 1 else 0.6) for k in range(3)])
        arr = mask(n, n, polygon([(2.2 * u, 3.2 * u), (1.3 * u, 4.6 * u), (3.1 * u, 4.6 * u)]))
        arr2 = mask(n, n, polygon([(2.2 * u, 8.8 * u), (1.3 * u, 7.4 * u), (3.1 * u, 7.4 * u)]))
        return np.maximum.reduce([rows, arr, arr2])
    if addon == "up-next":
        card = mask(n, n, rrect(1.8 * u, 3.0 * u, 8.4 * u, 6.0 * u, 1.1 * u)) * 0.35
        tiles = np.maximum.reduce([mask(n, n, rrect((2.6 + k * 2.3) * u, 4.8 * u, 1.9 * u, 1.9 * u, 0.3 * u)) for k in range(3)])
        return np.maximum(card, tiles)
    return None


def render_cover(addon):
    img = COVERS[addon]()
    return to_image(finish(img, 100 + IDS.index(addon)))


# ------------------------------------------------------------------ icons: a soft gradient tile with a glossy glyph

def render_icon(addon):
    """Drawn at cover resolution in a square region and scaled down, so the glyph uses the same lighting."""
    global W, H
    saveW, saveH = W, H
    n = 396
    W, H = n, n
    try:
        a, b, c, d = PAL[addon]["art"]
        tile = mesh(n, n, hexc(b), [(0.2, 0.1, 0.7, a, 0.8), (0.9, 0.95, 0.6, c, 0.7), (0.9, 0.1, 0.4, d, 0.4)], soften=24)
        tile = tile * 0.82
        m = mask(n, n, rrect(0, 0, n, n, n * 0.235))
        img = np.zeros((n, n, 3), np.float32)
        img = over(img, tile, m)
        g = glyph_mask(addon, n)
        img = shadow(img, g, 8, 0.45, dy=6)
        lit = vertical(n, n, np.array([1, 1, 1], np.float32), np.array([0.86, 0.84, 0.95], np.float32))
        img = over(img, lit, g)
        img = over(img, np.ones(3, np.float32), gloss_sheen(g, 0.0))
        # the tile's own gloss: a soft top highlight and a hairline rim
        x, y = grid(n, n)
        top = np.exp(-((y / n - 0.0) / 0.35) ** 2) * 0.16 * m
        img = over(img, np.ones(3, np.float32), top)
        img = over(img, np.ones(3, np.float32), inner_edge(m, 2.0, 0.35))
        rgba = np.dstack([np.clip(img, 0, 1), m])
        im = Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA")
        return im.resize((ICON, ICON), Image.LANCZOS)
    finally:
        W, H = saveW, saveH


def glyph_mask(addon, n):
    u = n / 12
    if addon in NEW_066:
        return glyph_066(addon, n)
    if addon == "vinyl":
        return np.clip(mask(n, n, ellipse(6 * u, 6 * u, 3.6 * u)) - mask(n, n, ellipse(6 * u, 6 * u, 1.1 * u)) * 0.55
                       - mask(n, n, ellipse(6 * u, 6 * u, 0.3 * u)), 0, 1)
    if addon == "dynamic-colors":
        return mask(n, n, polygon([(6 * u, 2.6 * u), (2.6 * u, 8.9 * u), (9.4 * u, 8.9 * u)]))
    if addon == "playlist-tools":
        m = np.zeros((n, n), np.float32)
        for i, yy in enumerate((2.8, 4.6, 6.4)):
            m = np.maximum(m, mask(n, n, rrect((2.6 + i * 0.9) * u, yy * u, 5.2 * u, 3.0 * u, 0.6 * u)) * (0.55 + 0.22 * i))
        return m
    if addon == "genres":
        return np.clip(mask(n, n, polygon([(3.9 * u, 3.4 * u), (9.2 * u, 3.4 * u), (9.2 * u, 8.6 * u), (3.9 * u, 8.6 * u), (2.4 * u, 6 * u)]))
                       - mask(n, n, ellipse(4.1 * u, 6 * u, 0.55 * u)), 0, 1)
    if addon == "popup-lyrics":
        card = mask(n, n, rrect(2.4 * u, 3.0 * u, 7.2 * u, 6.0 * u, 1.3 * u)) * 0.38
        lines = np.maximum.reduce([mask(n, n, rrect(3.4 * u, 4.3 * u, 3.6 * u, 0.6 * u, 0.3 * u)),
                                   mask(n, n, rrect(3.4 * u, 5.7 * u, 5.2 * u, 0.9 * u, 0.45 * u)),
                                   mask(n, n, rrect(3.4 * u, 7.3 * u, 3.0 * u, 0.6 * u, 0.3 * u))])
        return np.maximum(card, lines)
    if addon == "trash":
        body = mask(n, n, polygon([(3.4 * u, 4.4 * u), (8.6 * u, 4.4 * u), (8.0 * u, 9.6 * u), (4.0 * u, 9.6 * u)]))
        lid = mask(n, n, rrect(2.8 * u, 3.0 * u, 6.4 * u, 0.9 * u, 0.45 * u))
        knob = mask(n, n, rrect(5.0 * u, 2.2 * u, 2.0 * u, 1.0 * u, 0.4 * u))
        ribs = np.maximum.reduce([mask(n, n, rrect((4.9 + k * 1.1) * u, 5.4 * u, 0.4 * u, 3.2 * u, 0.2 * u)) for k in range(3)])
        return np.clip(np.maximum.reduce([body, lid, knob]) - ribs * 0.5, 0, 1)
    if addon == "shuffle-plus":
        a = mask(n, n, stroke(smooth_path((2.6 * u, 3.8 * u), (7.4 * u, 8.2 * u), 30), 1.0 * u))
        b = mask(n, n, stroke(smooth_path((2.6 * u, 8.2 * u), (7.4 * u, 3.8 * u), 30), 1.0 * u))
        h1 = mask(n, n, polygon([(9.6 * u, 3.8 * u), (7.2 * u, 2.3 * u), (7.2 * u, 5.3 * u)]))
        h2 = mask(n, n, polygon([(9.6 * u, 8.2 * u), (7.2 * u, 6.7 * u), (7.2 * u, 9.7 * u)]))
        return np.maximum.reduce([a, b, h1, h2])
    return np.clip(mask(n, n, rrect(3.0 * u, 4.0 * u, 6.0 * u, 5.2 * u, 0.9 * u)) + mask(n, n, ellipse(6 * u, 3.8 * u, 1.2 * u))
                   + mask(n, n, ellipse(9.1 * u, 6.6 * u, 1.2 * u)), 0, 1)


# ------------------------------------------------------------------ output

def jpeg_bytes(img):
    b = io.BytesIO()
    img.save(b, "JPEG", quality=90, optimize=True, subsampling=0)
    return b.getvalue()


def png_bytes(img):
    b = io.BytesIO()
    img.save(b, "PNG", optimize=True)
    return b.getvalue()


def c_name(addon, kind):
    return "MRGArt_%s_%s" % (kind, addon.replace("-", "_"))


def make_sheet(path, ids, covers, icons):
    cw, chh, cols = 540, 304, 4 if len(ids) > 8 else 2
    rows = (len(ids) + cols - 1) // cols
    sheet = Image.new("RGB", (cw * cols + 20 * (cols + 1), (chh + 30) * rows + 30 + 150), (5, 5, 8))
    for i, addon in enumerate(ids):
        sheet.paste(covers[addon].resize((cw, chh), Image.LANCZOS), (20 + (i % cols) * (cw + 20), 20 + (i // cols) * (chh + 30)))
    for i, addon in enumerate(ids):
        ic = icons[addon].resize((88, 88), Image.LANCZOS)
        sheet.paste(ic, (20 + i * 110, (chh + 30) * rows + 40), ic)
    sheet.save(path)


def main():
    preview = sys.argv[1] if len(sys.argv) > 1 else None
    only = sys.argv[2].split(",") if len(sys.argv) > 2 else None
    if preview:
        os.makedirs(preview, exist_ok=True)
    blobs, covers, icons = [], {}, {}
    for addon in IDS:
        if only and addon not in only:
            continue
        cv, ic = render_cover(addon), render_icon(addon)
        covers[addon], icons[addon] = cv, ic
        blobs.append((addon, "cover", jpeg_bytes(cv)))
        blobs.append((addon, "icon", png_bytes(ic)))
        if preview:
            cv.save(os.path.join(preview, "cover-%s.png" % addon))
            ic.save(os.path.join(preview, "icon-%s.png" % addon))
        print("rendered", addon, flush=True)
    if only:
        return
    if preview:
        # sheet.png: this release's new art; sheet-all.png: every cover and icon
        make_sheet(os.path.join(preview, "sheet.png"), NEW_066, covers, icons)
        make_sheet(os.path.join(preview, "sheet-all.png"), IDS, covers, icons)
    with open(OUT_M, "w") as f:
        f.write("// Generated by scripts/mirage-art.py: the add-on covers (JPEG) and icons (PNG). Do not edit by hand.\n")
        f.write("#include <stddef.h>\n\n")
        for addon, kind, data in blobs:
            name = c_name(addon, kind)
            f.write("static const unsigned char %s[] = {\n" % name)
            for i in range(0, len(data), 24):
                f.write("  " + ",".join(str(x) for x in data[i:i + 24]) + ",\n")
            f.write("};\n")
        f.write("\ntypedef struct { const char *addon; const char *kind; const unsigned char *bytes; size_t length; } MRGArtBlob;\n")
        f.write("const MRGArtBlob MRGArtBlobs[] = {\n")
        for addon, kind, data in blobs:
            f.write('  {"%s", "%s", %s, sizeof(%s)},\n' % (addon, kind, c_name(addon, kind), c_name(addon, kind)))
        f.write("};\nconst size_t MRGArtBlobCount = %d;\n" % len(blobs))
    print("wrote %s (%d images, %.0f KB)" % (OUT_M, len(blobs), sum(len(d) for _, _, d in blobs) / 1024))


if __name__ == "__main__":
    main()
