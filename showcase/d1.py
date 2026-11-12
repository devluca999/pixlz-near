#!/usr/bin/env python3
"""D1, "any device": a render (not a recording) of a Mosaico, a Mac and an iPhone side by side,
with the Pixlz hopping from one to the next. Drawn from the real sprites in assets/.
The iPhone is labelled "coming soon" for the whole shot: there is no iPhone app yet.

    showcase/tts/.venv/bin/python showcase/d1.py        # needs Pillow and ffmpeg

Writes showcase/takes/D1/take-1.mov (1080x1920) and showcase/takes/D1/wide-1.mov (1920x1080).
"""
import json, math, os, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG = "/opt/homebrew/bin/ffmpeg" if os.path.exists("/opt/homebrew/bin/ffmpeg") else "ffmpeg"
FPS, SECONDS, SS = 30, 5.0, 2          # SS: supersampling for the drawn devices


def font(size, pixel=False):
    here = os.path.join(ROOT, "showcase", "fonts")
    picks = ([(os.path.join(here, "Silkscreen-Regular.ttf"), 0), ("/System/Library/Fonts/Menlo.ttc", 1)] if pixel else
             [(os.path.join(here, "Inter-SemiBold.ttf"), 0), ("/System/Library/Fonts/HelveticaNeue.ttc", 1)])
    for path, index in picks:
        if os.path.exists(path):
            return ImageFont.truetype(path, size, index=index)
    return ImageFont.load_default()


def sprite(pet, frame):
    d = json.load(open(os.path.join(ROOT, "assets", pet, "sprites.json")))
    pal = [tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) + (255,) for c in d["palette"]]
    rows = d["frames"][frame]["rows"]
    im = Image.new("RGBA", (len(rows[0]), len(rows)), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != d["transparent"]:
                px[x, y] = pal[d["chars"].index(ch)]
    return im


_cache = {}


def pet_image(pet, frame, scale, mirrored=False, led=False):
    """The sprite at a whole-number scale; `led` leaves a dark gap between pixels (the Mosaico)."""
    key = (pet, frame, scale, mirrored, led)
    if key in _cache:
        return _cache[key]
    im = sprite(pet, frame)
    if mirrored:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
    if led and scale >= 3:
        px = im.load()
        for y in range(im.height):
            for x in range(im.width):
                if x % scale == scale - 1 or y % scale == scale - 1:
                    px[x, y] = (0, 0, 0, 0)
    _cache[key] = im
    return im


def content_box(pet, frame="idle_0"):
    """The drawn part of a frame: (left, top, right, bottom) in art pixels, and the frame's width."""
    im = sprite(pet, frame)
    return im.getbbox(), im.width


def layout(w, h):
    """Device rectangles and the spot each pet stands on, for a w x h frame."""
    k = 1.0 if h > w else 1.45
    ox, oy = (w - 1080 * k) / 2, (h - 1920 * k) / 2 + (0 if h > w else 40)
    def r(x0, y0, x1, y1): return tuple(round(v) for v in (ox + x0 * k, oy + y0 * k, ox + x1 * k, oy + y1 * k))
    return {
        "k": k,
        "mosaico": r(70, 760, 320, 1010), "mosaico_led": r(92, 782, 298, 988),
        "mac": r(350, 730, 770, 990), "mac_base": r(318, 990, 802, 1008),
        "phone": r(832, 690, 992, 1010),
        "labels_y": round(oy + 1052 * k),
        "feet": {"mosaico": (round(ox + 195 * k), round(oy + 968 * k)),
                 "mac": (round(ox + 640 * k), round(oy + 978 * k)),
                 "phone": (round(ox + 912 * k), round(oy + 968 * k))},
        "scale": {"mosaico": round(3 * k), "mac": round(3 * k), "phone": round(2 * k)},
    }


def background(w, h, L):
    """The desk and the three devices (static), drawn at SS x and scaled down."""
    W, H = w * SS, h * SS
    im = Image.new("RGB", (W, H))
    top, bot = (19, 21, 27), (9, 10, 13)
    d = ImageDraw.Draw(im)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bot)))
    k = L["k"] * SS
    def S(box): return tuple(v * SS for v in box)
    # Mosaico: a small square LED display
    d.rounded_rectangle(S(L["mosaico"]), radius=26 * k, fill=(34, 36, 44), outline=(70, 74, 88), width=round(3 * k))
    d.rounded_rectangle(S(L["mosaico_led"]), radius=8 * k, fill=(4, 4, 6))
    x0, y0, x1, y1 = S(L["mosaico_led"])
    step = L["scale"]["mosaico"] * SS
    for y in range(y0 + step // 2, y1, step):          # the unlit LEDs
        for x in range(x0 + step // 2, x1, step):
            d.point((x, y), fill=(22, 23, 28))
    # Mac: screen, bezel, base
    x0, y0, x1, y1 = S(L["mac"])
    d.rounded_rectangle((x0, y0, x1, y1), radius=14 * k, fill=(16, 17, 21), outline=(84, 88, 102), width=round(3 * k))
    inset = round(10 * k)
    sx0, sy0, sx1, sy1 = x0 + inset, y0 + inset, x1 - inset, y1 - inset
    for y in range(sy0, sy1):
        t = (y - sy0) / (sy1 - sy0)
        d.line([(sx0, y), (sx1, y)], fill=(round(28 + 20 * t), round(34 + 14 * t), round(66 - 10 * t)))
    d.rectangle((sx0, sy0, sx1, sy0 + round(9 * k)), fill=(20, 22, 30))                  # menu bar
    d.rounded_rectangle((sx0 + 20 * k, sy0 + 26 * k, sx0 + 168 * k, sy0 + 112 * k), radius=6 * k,
                        fill=(236, 238, 242))                                              # a window, clear of the pet
    d.rectangle((sx0 + 20 * k, sy0 + 32 * k, sx0 + 168 * k, sy0 + 42 * k), fill=(210, 213, 220))
    for i in range(3):
        d.rounded_rectangle((sx0 + 34 * k, sy0 + (56 + i * 17) * k, sx0 + (150 - i % 2 * 40) * k, sy0 + (63 + i * 17) * k),
                            radius=3 * k, fill=(176, 180, 190))
    bx0, by0, bx1, by1 = S(L["mac_base"])
    d.polygon([(bx0, by0), (bx1, by0), (bx1 - 14 * k, by1), (bx0 + 14 * k, by1)], fill=(96, 100, 114))
    d.rounded_rectangle(((bx0 + bx1) / 2 - 40 * k, by0, (bx0 + bx1) / 2 + 40 * k, by0 + 5 * k), radius=3 * k, fill=(60, 63, 74))
    # iPhone (coming soon): a quieter outline
    x0, y0, x1, y1 = S(L["phone"])
    d.rounded_rectangle((x0, y0, x1, y1), radius=30 * k, fill=(20, 21, 26), outline=(70, 74, 88), width=round(3 * k))
    d.rounded_rectangle((x0 + 8 * k, y0 + 8 * k, x1 - 8 * k, y1 - 8 * k), radius=23 * k, fill=(13, 14, 18))
    d.rounded_rectangle(((x0 + x1) / 2 - 24 * k, y0 + 18 * k, (x0 + x1) / 2 + 24 * k, y0 + 32 * k), radius=7 * k, fill=(4, 4, 6))
    im = im.resize((w, h), Image.LANCZOS)
    # labels (drawn at 1x so pixel fonts stay crisp)
    d = ImageDraw.Draw(im)
    f = font(round(26 * L["k"]), pixel=True)
    for name, text, colour in (("mosaico", "Mosaico", (150, 156, 172)), ("mac", "Mac", (150, 156, 172))):
        box = L[name]
        d.text(((box[0] + box[2]) / 2, L["labels_y"]), text, font=f, fill=colour, anchor="mm")
    box = L["phone"]
    cx = (box[0] + box[2]) / 2
    d.text((cx, L["labels_y"]), "iPhone", font=f, fill=(150, 156, 172), anchor="mm")
    f2 = font(round(22 * L["k"]), pixel=True)
    text = "coming soon"
    tw = d.textlength(text, font=f2)
    cy = L["labels_y"] + round(44 * L["k"])
    cx = min(cx, w - tw / 2 - 30 * L["k"])
    d.rounded_rectangle((cx - tw / 2 - 14 * L["k"], cy - 20 * L["k"], cx + tw / 2 + 14 * L["k"], cy + 20 * L["k"]),
                        radius=10 * L["k"], fill=(124, 217, 58))
    d.text((cx, cy), text, font=f2, fill=(12, 14, 10), anchor="mm")
    return im


def ease(t): return t * t * (3 - 2 * t)


class Hop:
    def __init__(self, start, end, a, b): self.start, self.end, self.a, self.b = start, end, a, b


def pose(t, stops, hops, L):
    """Where a pet is at time t: (device or None while in the air, foot point, scale, frame)."""
    place = stops[0]
    for hp in hops:
        if t >= hp.end:
            place = hp.b
        elif t >= hp.start:
            u = (t - hp.start) / (hp.end - hp.start)
            (ax, ay), (bx, by) = L["feet"][hp.a], L["feet"][hp.b]
            x = ax + (bx - ax) * ease(u)
            lift = 96 * L["k"] * math.sin(math.pi * u)
            y = ay + (by - ay) * u - lift
            s = L["scale"][hp.a] + (L["scale"][hp.b] - L["scale"][hp.a]) * u
            return None, (x, y), s, "move_1" if u < 0.7 else "move_2"
    blink = (t * 2.4) % 5 > 4.75
    return place, L["feet"][place], L["scale"][place], "idle_0" if not blink else "idle_1"


def render(w, h, out):
    L = layout(w, h)
    bg = background(w, h, L)
    desk = Image.new("RGB", (w, h), (9, 10, 13))
    # who goes where: Frogg crosses all three; the cat follows to the Mac; the ghost stays on the Mosaico
    cast = [
        ("frogg", 0.0, [Hop(0.9, 1.5, "mosaico", "mac"), Hop(2.3, 2.9, "mac", "phone")]),
        ("cat", 1.7, [Hop(2.5, 3.1, "mosaico", "mac")]),
        ("ghost", 3.3, []),
    ]
    os.makedirs(os.path.dirname(out), exist_ok=True)
    enc = subprocess.Popen([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                            "-s", f"{w}x{h}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium",
                            "-crf", "14", "-pix_fmt", "yuv420p", out], stdin=subprocess.PIPE)
    for n in range(round(SECONDS * FPS)):
        t = n / FPS
        frame = Image.blend(desk, bg, min(1, t / 0.4)).convert("RGBA")
        for pet, appears, hops in cast:
            if t < appears:
                continue
            place, (fx, fy), scale, name = pose(t, ["mosaico"], hops, L)
            grow = min(1, (t - appears) / 0.18) if appears > 0 else 1
            whole = max(1, round(scale))
            im = pet_image(pet, name, whole, mirrored=(place == "phone"), led=(place == "mosaico"))
            size = scale * grow / whole
            if abs(size - 1) > 0.01:
                im = im.resize((max(1, round(im.width * size)), max(1, round(im.height * size))), Image.NEAREST)
            (l, _, r, b), art_w = content_box(pet, name)
            if place == "phone":
                l, r = art_w - r, art_w - l            # mirrored
            sx = im.width / art_w
            x = round(fx - (l + r) / 2 * sx)
            y = round(fy - b * sx)
            frame.alpha_composite(im, (max(0, x), max(0, y)))
        enc.stdin.write(frame.convert("RGB").tobytes())
    enc.stdin.close()
    enc.wait()
    print(out)


if __name__ == "__main__":
    takes = os.path.join(ROOT, "showcase", "takes", "D1")
    render(1080, 1920, os.path.join(takes, "take-1.mov"))
    render(1920, 1080, os.path.join(takes, "wide-1.mov"))
