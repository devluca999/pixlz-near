#!/usr/bin/env python3
"""Assembles the demo cuts from the takes, the narration and showcase/edit.json.

    showcase/tts/.venv/bin/python showcase/cut.py tall        # 9:16 rough cut (1080x1920)
    showcase/tts/.venv/bin/python showcase/cut.py wide        # 16:9 judges' cut (1920x1080)
    showcase/tts/.venv/bin/python showcase/cut.py all --dry   # print both timelines, render nothing

Needs Pillow, numpy and ffmpeg. Each segment of the edit list is a piece of a take
(showcase/takes/<scene>/take-N.mov), cut, optionally sped up or zoomed. On top go the burned-in
captions (showcase/CAPTIONS.md), the feature chips, and a mix of the narration lines
(showcase/out/vo), the app's own sound effects (the formulas of Sfx.swift) and the cut's music.
With music, the cut has a beat grid: it starts at the segment marked "drop", where the track's
beat drop is placed, and segments are then measured in beats. A scene with no take yet shows as a
labelled slate, so the cut can be reviewed before every take exists.
Output: showcase/out/<name>.mp4 at -14 LUFS, -1 dBTP.
"""
import json, re, math, os, subprocess, sys
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
TAKES, OUT = os.path.join(HERE, "takes"), os.path.join(HERE, "out")
BREW = "/opt/homebrew/bin/"
FFMPEG = BREW + "ffmpeg" if os.path.exists(BREW + "ffmpeg") else "ffmpeg"
FFPROBE = BREW + "ffprobe" if os.path.exists(BREW + "ffprobe") else "ffprobe"
FPS, SR = 30, 48000
WHITE, ACCENT, MUTED = (255, 255, 255), (124, 217, 58), (176, 182, 198)
DESK_TOP, DESK_BOT = (19, 21, 27), (9, 10, 13)          # the app's clean desk (DeskView)
STAGE_WIDE = (1232, 0, 608, 1080)                       # where a 9:16 take sits in the 16:9 frame


# ---------------------------------------------------------------- drawing

def font(size, kind="text"):
    """Inter and Silkscreen from showcase/fonts if they are there, else system fonts."""
    local, system = os.path.join(HERE, "fonts"), "/System/Library/Fonts/"
    picks = {"text": [(local + "/Inter-SemiBold.ttf", 0), (system + "HelveticaNeue.ttc", 1)],
             "body": [(local + "/Inter-Regular.ttf", 0), (system + "HelveticaNeue.ttc", 0)],
             "pixel": [(local + "/Silkscreen-Regular.ttf", 0), (system + "Menlo.ttc", 1)],
             "mono": [(system + "Menlo.ttc", 0)]}[kind]
    for path, index in picks:
        if os.path.exists(path):
            return ImageFont.truetype(path, size, index=index)
    return ImageFont.load_default()


def desk(w, h):
    t = np.linspace(0, 1, h)[:, None, None]
    col = np.array(DESK_TOP) + (np.array(DESK_BOT) - np.array(DESK_TOP)) * t
    return Image.fromarray(np.repeat(col, w, axis=1).round().astype(np.uint8), "RGB")


def spans(line, keywords):
    """The line as [(text, is a keyword)]."""
    low, mark = line.lower(), [False] * len(line)
    for k in keywords:
        i = low.find(k.lower())
        while i >= 0:
            mark[i:i + len(k)] = [True] * len(k)
            i = low.find(k.lower(), i + 1)
    out = []
    for ch, m in zip(line, mark):
        if out and out[-1][1] == m:
            out[-1][0] += ch
        else:
            out.append([ch, m])
    return out


def draw_line(d, x, y, line, keywords, f, colour=WHITE, centred=True):
    if centred:
        x -= f.getlength(line) / 2
    for text, key in spans(line, keywords):
        d.text((x, y), text, font=f, fill=ACCENT if key else colour)
        x += f.getlength(text)


def pill(lines, keywords=(), size=64, maxw=800, pad=(30, 18), radius=22, kind="text",
         fill=(12, 12, 14, 184), colour=WHITE, outline=None):
    """Text on a rounded dark pill (drawn at 2x, scaled down). Shrinks the type to fit maxw."""
    S = 2
    while True:
        f = font(size * S, kind)
        wid = max(f.getlength(l) for l in lines)
        if wid / S <= maxw - 2 * pad[0] or size <= 26:
            break
        size -= 2
    lh = round(size * 1.15 * S)
    asc, desc = f.getmetrics()
    w, h = round(wid + 2 * pad[0] * S), lh * len(lines) + 2 * pad[1] * S
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, w - 1, h - 1), radius * S, fill=fill, outline=outline, width=2 * S if outline else 1)
    for i, l in enumerate(lines):
        draw_line(d, w / 2, pad[1] * S + i * lh + (lh - asc - desc) / 2, l, keywords, f, colour)
    return im.resize((w // S, h // S), Image.LANCZOS)


EMOJI = "/System/Library/Fonts/Apple Color Emoji.ttc"
_glyphs = {}


def glyph(ch, px):
    """An emoji px tall (Apple Color Emoji only has fixed sizes: drawn at 160, scaled)."""
    if (ch, px) not in _glyphs:
        im = Image.new("RGBA", (220, 220), (0, 0, 0, 0))
        ImageDraw.Draw(im).text((10, 10), ch, font=ImageFont.truetype(EMOJI, 160), embedded_color=True)
        im = im.crop(im.getbbox())
        _glyphs[ch, px] = im.resize((max(1, round(im.width * px / im.height)), px), Image.LANCZOS)
    return _glyphs[ch, px]


def runs(line, keywords, f, em):
    """The line as [(text, is a keyword, is an emoji, width)]."""
    out = []
    for text, key in spans(line, keywords):
        for part in re.split("([\U0001F000-\U0001FAFF])", text):
            if part:
                emoji = len(part) == 1 and ord(part) >= 0x1F000
                out.append((part, key, emoji, glyph(part, em).width if emoji else f.getlength(part)))
    return out


def shadowed(lines, keywords=(), size=70, maxw=840, kind="text", colour=WHITE, plate=False):
    """Bold text with a thin dark edge and a soft shadow, no box (drawn at 2x, scaled down).
    plate: a soft dark patch behind it, for the shots where it lies on a white page or on small print."""
    S = 2
    while True:
        f, em = font(size * S, kind), round(size * S * 0.95)
        rows = [runs(l, keywords, f, em) for l in lines]
        wid = max(sum(r[3] for r in row) for row in rows)
        if wid / S <= maxw or size <= 28:
            break
        size -= 2
    lh, m = round(size * 1.2 * S), round(size * 0.4 * S)
    asc, desc = f.getmetrics()
    w, h = round(wid) + 2 * m, lh * len(lines) + 2 * m
    edge, fill = Image.new("L", (w, h), 0), Image.new("RGBA", (w, h), (0, 0, 0, 0))
    de, df = ImageDraw.Draw(edge), ImageDraw.Draw(fill)
    for i, row in enumerate(rows):
        x, y = (w - sum(r[3] for r in row)) / 2, m + i * lh + (lh - asc - desc) / 2
        for text, key, emoji, width in row:
            if emoji:
                g = glyph(text, em)
                at = (round(x), round(y + (asc + desc - em) / 2))
                fill.paste(g, at, g)
                edge.paste(g.getchannel("A"), at, g.getchannel("A"))
            else:
                de.text((x, y), text, font=f, fill=255, stroke_width=max(2, round(size * S * 0.045)))
                df.text((x, y), text, font=f, fill=ACCENT if key else colour)
            x += width
    soft = ImageChops.offset(edge.filter(ImageFilter.GaussianBlur(size * S * 0.09)), 0, round(size * S * 0.05))
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    im.putalpha(ImageChops.lighter(edge.point(lambda v: int(v * 0.9)), soft.point(lambda v: min(255, int(v * 1.1)))))
    if plate:
        back = Image.new("L", (w, h), 0)
        ImageDraw.Draw(back).rounded_rectangle((m * 0.35, m * 0.55, w - m * 0.35, h - m * 0.55), radius=m * 0.8, fill=228)
        dark = Image.new("RGBA", (w, h), (8, 8, 10, 0))
        dark.putalpha(back.filter(ImageFilter.GaussianBlur(m * 0.18)))
        dark.alpha_composite(im)
        im = dark
    im.alpha_composite(fill)
    return im.resize((w // S, h // S), Image.LANCZOS)


def ig_caption(lines, size=52):
    """A caption as the Instagram app sets it: white on black, one rounded box per line."""
    S = 2
    f = font(size * S, "text")
    asc, desc = f.getmetrics()
    px, lh, r = round(size * 0.42 * S), round(size * 1.42 * S), round(size * 0.32 * S)
    wid = [f.getlength(l) for l in lines]
    w, h = round(max(wid)) + 2 * px, lh * len(lines)
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for i, l in enumerate(lines):
        x = (w - wid[i]) / 2 - px
        d.rounded_rectangle((x, i * lh - (r if i else 0), x + wid[i] + 2 * px, (i + 1) * lh - 1), r, fill=(0, 0, 0, 255))
    for i, l in enumerate(lines):
        d.text(((w - wid[i]) / 2, i * lh + (lh - asc - desc) / 2), l, font=f, fill=WHITE)
    return im.resize((w // S, h // S), Image.LANCZOS)


class Overlay:
    """Something on top of the picture from t0 to t1. In: fade (and a small pop); out: fade."""
    def __init__(self, im, t0, t1, x, y, centred=True, pop=True, fin=0.14, fout=0.10):
        self.im, self.t0, self.t1, self.x, self.y = im, t0, t1, x, y
        self.centred, self.pop, self.fin, self.fout = centred, pop, fin, fout

    def stamp(self, base, t):
        if not self.t0 <= t < self.t1:
            return
        ease = 1 - (1 - min(1, (t - self.t0) / max(self.fin, 1e-6))) ** 3
        alpha = min(ease, min(1, (self.t1 - t) / max(self.fout, 1e-6)))
        im = self.im
        if self.pop and ease < 1:
            k = 0.94 + 0.06 * ease
            im = im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.BILINEAR)
        if alpha < 1:
            im = im.copy()
            im.putalpha(im.getchannel("A").point(lambda v: int(v * alpha)))
        x, y = (self.x - im.width / 2, self.y - im.height / 2) if self.centred else \
               (self.x, self.y + (self.im.height - im.height) / 2)
        base.paste(im, (round(x), round(y)), im)


def slate(w, h, scene, note):
    """A scene with no take yet."""
    im = desk(w, h)
    d = ImageDraw.Draw(im)
    d.text((w / 2, h / 2 - 70), scene, font=font(round(w * 0.16), "pixel"), fill=ACCENT, anchor="mm")
    d.text((w / 2, h / 2 + 30), "take to record", font=font(round(w * 0.045), "pixel"), fill=MUTED, anchor="mm")
    d.text((w / 2, h / 2 + 90), note, font=font(round(w * 0.042), "body"), fill=MUTED, anchor="mm")
    return im


def panel(canvas, p, brand):
    """The judges' cut's left side: what the scene is, in words, and the proof to look for."""
    im = canvas.copy()
    d = ImageDraw.Draw(im)
    x = 110
    d.text((x, 70), brand, font=font(22, "pixel"), fill=(110, 116, 132))
    if not p:
        return im
    title_f = font(p.get("title_size", 68), "text")
    body, proof = p.get("body", []), p.get("proof", [])
    height = 60 + len(p["title"]) * 80 + 26 + len(body) * 52 + (30 + len(proof) * 44 if proof else 0)
    y = round((1080 - height) / 2) - 40
    d.text((x, y), p.get("kicker", "").upper(), font=font(26, "pixel"), fill=ACCENT)
    y += 60
    for line in p["title"]:
        d.text((x, y), line, font=title_f, fill=WHITE)
        y += 80
    y += 26
    for line in body:
        d.text((x, y), line, font=font(36, "body"), fill=(196, 201, 214))
        y += 52
    if proof:
        y += 30
        for line in proof:
            d.rectangle((x, y + 6, x + 5, y + 32), fill=ACCENT)
            d.text((x + 22, y), line, font=font(27, "mono"), fill=(170, 226, 128))
            y += 44
    return im


# ---------------------------------------------------------------- sound

def read_audio(path, start=None, seconds=None, channels=1):
    cmd = [FFMPEG, "-v", "error"]
    if start is not None:
        cmd += ["-ss", str(start), "-t", str(seconds)]
    cmd += ["-i", path, "-vn", "-ac", str(channels), "-ar", str(SR), "-f", "f32le", "-"]
    sig = np.frombuffer(subprocess.run(cmd, capture_output=True).stdout, dtype=np.float32).copy()
    return sig if channels == 1 else sig.reshape(-1, channels)


def synth(name):
    """The app's sound effects, from the same formulas as Sfx.swift."""
    rng = np.random.RandomState(1114)
    def make(seconds, f):
        t = np.arange(int(seconds * SR)) / SR
        fade = np.minimum(1, t / 0.004) * np.minimum(1, (seconds - t) / 0.01)
        return (np.clip(f(t), -1, 1) * fade).astype(np.float32)
    def riser(t):                                          # soft air that opens up and swells: into the beat drop
        raw, y, out = rng.uniform(-1, 1, len(t)), 0.0, np.zeros(len(t))
        u = t / t[-1]
        a = 0.01 + 0.5 * u ** 2.5                              # a low-pass that opens as it goes
        for i in range(len(t)):
            y += a[i] * (raw[i] - y)
            out[i] = y
        return out * u ** 2 * 0.9
    tone = lambda hz, t: np.sin(2 * np.pi * hz * t)
    noise = lambda t: rng.uniform(-1, 1, len(t))
    two = lambda t, cut, a, b: np.where(t < cut, a, b)
    return {
        "pop": lambda: make(0.09, lambda t: tone(520 + 2600 * t, t) * np.exp(-t * 38) * 0.8),
        "ding": lambda: make(0.9, lambda t: (tone(1318.5, t) + 0.45 * tone(2637, t) + 0.2 * tone(3951, t)) * np.exp(-t * 4.2) * 0.45),
        "snap": lambda: make(0.11, lambda t: noise(t) * np.exp(-t * 90) * 0.5 + tone(1800 - 9000 * t, t) * np.exp(-t * 30) * 0.5),
        "gulp": lambda: make(0.22, lambda t: tone(320 - 900 * t, t) * np.sin(np.pi * np.minimum(1, t / 0.22)) * 0.8),
        "chime": lambda: make(0.42, lambda t: two(t, 0.12, tone(880, t), tone(1318.5, t)) * np.exp(-two(t, 0.12, t, t - 0.12) * 9) * 0.5),
        "coin": lambda: make(0.32, lambda t: two(t, 0.07, tone(1975.5, t), tone(2637, t)) * np.exp(-two(t, 0.07, t * 6, (t - 0.07) * 10)) * 0.45),
        "thud": lambda: make(0.16, lambda t: tone(95 - 160 * t, t) * np.exp(-t * 22) * 0.9),
        "ribbit": lambda: make(0.34, lambda t: np.where((t < 0.13) | ((t > 0.18) & (t < 0.31)),
                                                        np.sign(tone(330, t)) * 0.45 * (0.6 + 0.4 * tone(32, t)), 0)),
        "alert": lambda: make(0.3, lambda t: np.where((t < 0.1) | ((t > 0.16) & (t < 0.26)), tone(1046.5, t) * 0.4, 0)),
        "riser": lambda: make(0.9, riser),
        "whoosh": lambda: make(0.25, lambda t: noise(t) * np.sin(np.pi * t / 0.25) * 0.22),
        "sparkle": lambda: make(0.35, lambda t: (tone(2093, t) * 0.5 + tone(3136, t) * 0.3) * (0.5 + 0.5 * tone(24, t)) * np.exp(-t * 7) * 0.45),
    }[name]()


def speech(sig):
    """Where the voice starts and ends in a narration line, and the pauses inside it (seconds)."""
    win = SR // 100
    env = np.sqrt((sig[:len(sig) // win * win].reshape(-1, win) ** 2).mean(axis=1))
    loud = env > env.max() * 0.06
    idx = np.flatnonzero(loud)
    on, off = idx[0], idx[-1] + 1
    pauses, start = [], None
    for i in range(on, off):
        if not loud[i] and start is None:
            start = i
        elif loud[i] and start is not None:
            if i - start >= 7:
                pauses.append((start / 100, i / 100))
            start = None
    return on / 100, off / 100, pauses


def phrase_starts(sig, phrases):
    """When each caption phrase starts: by its share of the line's letters, moved to the nearest
    pause in the voice when there is one close by."""
    on, off, pauses = speech(sig)
    sizes = [len(" ".join(p)) for p in phrases]
    starts, done = [on], 0
    for size in sizes[:-1]:
        done += size
        guess = on + (off - on) * done / sum(sizes)
        near = [p for p in pauses if abs((p[0] + p[1]) / 2 - guess) < 0.45 and p[1] > starts[-1] + 0.3]
        starts.append(min(near, key=lambda p: abs((p[0] + p[1]) / 2 - guess))[1] if near else guess)
    return starts, off


# ---------------------------------------------------------------- the cut

_size = {}


def source_size(path):
    if path not in _size:
        out = subprocess.run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                              "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip()
        _size[path] = tuple(int(v) for v in out.split(",")[:2])
    return _size[path]


def pushed(im, push, u, w, h):
    """im at w x h, cut in toward a point; u runs 0 to 1 over the push."""
    cx, cy, k = push[:3]
    z = k ** (u * u)                                    # eased in: the move speeds up into the cut
    fx, fy = ((c * k - 0.5) / (k - 1) for c in (cx, cy))   # the point that stays put on screen
    bw, bh = im.width / z, im.height / z
    x, y = (fx - (fx - 0.5) / z) * im.width - bw / 2, (fy - (fy - 0.5) / z) * im.height - bh / 2
    return im.resize((w, h), Image.LANCZOS, box=(x, y, x + bw, y + bh))


def warp(im, P, A, z, a, size, resample=Image.BICUBIC):
    """im scaled by z and turned by a degrees about its point P, which lands on A."""
    c, n = np.cos(np.radians(a)) / z, np.sin(np.radians(a)) / z
    return im.transform(size, Image.AFFINE, (c, -n, P[0] - c * A[0] + n * A[1], n, c, P[1] - n * A[0] - c * A[1]), resample)


_tracks = {}


def tracked(im, push, frame, u, w, h):
    """A push-in on a subject that moves: its centre comes from a track (by source frame), and the
    push ends with it at push["to"], scaled by "scale" and turned by "turn" degrees, so that it
    lies where the next shot has it. "deglare" takes that much off the black level as it goes."""
    if u <= 0:
        return im if im.size == (w, h) else im.resize((w, h), Image.LANCZOS)
    if push["track"] not in _tracks:
        points = json.load(open(os.path.join(HERE, push["track"])))["points"]
        _tracks[push["track"]] = {int(k): v for k, v in points.items()}
    points = _tracks[push["track"]]
    P, Q = points[min(max(frame, min(points)), max(points))], push["to"]
    e, k = u * u, push["scale"]                             # eased in: the move speeds up into the cut
    z = k ** e
    g = (z - 1) / (k - 1)
    out = warp(im, P, (P[0] + (Q[0] - P[0]) * g, P[1] + (Q[1] - P[1]) * g), z, push.get("turn", 0) * e, (w, h))
    d = push.get("deglare", 0) * e
    if d:
        out = out.point([min(255, max(0, round((v - d) * 255 / (255 - d)))) for v in range(256)] * 3)
    return out


def frames(seg, w, h):
    """The segment's pictures at w x h, one per output frame."""
    if "slate" in seg:
        im = slate(w, h, seg["slate"], seg.get("note", ""))
        while True:
            yield im
    path = os.path.join(TAKES, seg["src"])
    vf = [f"setpts=PTS/{seg.get('speed', 1)}", f"fps={FPS}"]
    if "zoom" in seg:                                   # [centre x, centre y, factor], as fractions
        cx, cy, k = seg["zoom"]
        sw, sh = source_size(path)
        cw, ch = round(sw / k / 2) * 2, round(sh / k / 2) * 2
        x, y = min(max(round(cx * sw - cw / 2), 0), sw - cw), min(max(round(cy * sh - ch / 2), 0), sh - ch)
        vf.append(f"crop={cw}:{ch}:{x}:{y}")
    push = seg.get("push")                              # a push-in over the segment's last seconds
    follow = isinstance(push, dict)                     # {track, to, scale, turn, seconds}: on a moving subject
    dw, dh = source_size(path) if push else (w, h)      # a push is cut from the full-size picture
    vf.append(f"scale={dw}:{dh}:flags=lanczos")
    dec = subprocess.Popen([FFMPEG, "-v", "error", "-ss", str(seg["in"]), "-t", str(seg["out"] - seg["in"]), "-i", path,
                            "-an", "-vf", ",".join(vf), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    size, last, i = dw * dh * 3, None, 0
    m = max(round((push["seconds"] if follow else push[3]) * FPS), 2) if push else 0
    try:
        while True:
            buf = dec.stdout.read(size)
            if len(buf) == size:
                last = Image.frombytes("RGB", (dw, dh), buf)
            elif last is None:
                sys.exit(f"no picture from {seg['src']} at {seg['in']} s")
            if push:
                u = min(max((i - (seg["n"] - m)) / (m - 1), 0), 1)
                yield tracked(last, push, round(seg["in"] * FPS) + i, u, w, h) if follow else pushed(last, push, u, w, h)
            else:
                yield last                              # past the end: the last frame holds
            i += 1
    finally:
        dec.kill()
        dec.wait()


def when(v, s):
    """A moment in a segment, in seconds from its start. A number is just that; "@x" is where
    second x of the take falls; "bX" is X beats after the segment's first beat."""
    if isinstance(v, str) and v[0] == "@":
        return (float(v[1:]) - s["in"]) / s.get("speed", 1)
    if isinstance(v, str) and v[0] == "b":
        return s["first"] + float(v[1:]) * s["beat"]
    return v


def timeline(cut):
    """Gives every segment its place (t0 and n frames); returns the cut's length in seconds.

    With music there is a beat grid. It starts at the segment that has "drop" (seconds into that
    segment where the track's beat drop falls). From there a segment with "beats" lasts that many
    beats, and what it does not say is worked out: with "hit": [second of the take, beat], that
    moment of the take falls on that beat of the segment ("in" given: the speed is made to fit;
    otherwise "in" is); with "in" and "out", the speed; with "in" only, "out". A cut with
    "snap" moves the end of every other segment to the nearest beat."""
    beat, origin, b = (cut.get("music") or {}).get("beat"), None, 0
    t, n = 0.0, 0
    for s in cut["segments"]:
        name = s.get("src", s.get("slate"))
        s["t0"] = t
        if "drop" in s:
            if not beat:
                sys.exit(f"{name}: \"drop\" needs the cut's \"music\"")
            origin, b = t + s["drop"], 0
            cut["drop_at"] = origin
        if "beats" in s:
            if origin is None:
                sys.exit(f"{name}: \"beats\" needs a segment with \"drop\" before it")
            first, dur = origin + b * beat - t, origin + (b + s["beats"]) * beat - t
            b += s["beats"]
            if "hit" in s:
                at = first + s["hit"][1] * beat
                if "in" in s and "speed" not in s:
                    if at <= 0:
                        sys.exit(f"{name}: a \"hit\" on the segment's first frame cannot set the speed")
                    s["speed"] = (s["hit"][0] - s["in"]) / at
                else:
                    s.setdefault("speed", 1)
                    s["in"] = s["hit"][0] - at * s["speed"]
                s["out"] = s["in"] + dur * s["speed"]
            elif "out" in s:
                s["speed"] = (s["out"] - s["in"]) / dur
            else:
                s.setdefault("speed", 1)
                s["out"] = s["in"] + dur * s["speed"]
            if s["in"] < 0 or s["speed"] <= 0:
                sys.exit(f"{name}: in {s['in']:.2f} s at ×{s['speed']:.2f} does not fit the take")
        else:
            dur = s["seconds"] if "seconds" in s else (s["out"] - s["in"]) / s.get("speed", 1) + s.get("hold", 0)
            if origin is not None:
                if cut.get("snap"):                         # the cut after this segment falls on a beat
                    b = max(round((t + dur - origin) / beat), b + 1)
                    more = origin + b * beat - (t + dur)
                    if "hold" in s and s["hold"] + more >= 0:
                        s["hold"] += more
                    elif "seconds" not in s:
                        s["out"] += more * s.get("speed", 1)
                    dur += more
                first = origin + float(np.ceil((t - origin) / beat - 1e-6)) * beat - t
        if origin is not None:
            s["first"], s["beat"] = first, beat
        t += dur
        s["n"] = round(t * FPS) - n
        n += s["n"]
        if "slate" not in s and not os.path.exists(os.path.join(TAKES, s["src"])):
            s["note"], s["slate"] = s.get("note", "") or s["src"], s["src"].split("/")[0]
    return n / FPS


def schedule(cut, plan):
    """Lays the segments end to end; returns (segments, seconds, overlays, sounds)."""
    W, H = cut["size"]
    wide = W > H
    segs, total = cut["segments"], timeline(cut)
    lines = {l["id"]: l for l in plan["lines"]}
    overlays, sounds = [], []
    for s in segs:
        end = s["n"] / FPS
        for at, name, *gain in s.get("sfx", []):
            sounds.append((s["t0"] + when(at, s), "sfx", name, (gain[0] if gain else 0.5) * cut.get("sfx_gain", 1)))
        if s.get("audio") and "slate" not in s:
            sounds.append((s["t0"], "src", s, s["audio"]))
        for tx in s.get("texts", []):                       # words on the picture: from/to as in when(); negative: from the end
            style = tx.get("style", "shadow")
            im = ig_caption(tx["lines"], tx.get("size", 52)) if style == "ig" else \
                shadowed(tx["lines"], tx.get("keywords", ()), tx.get("size", 30 if style == "small" else 70), tx.get("maxw", 900))
            edge = lambda v, d: d if v is None else end + v if isinstance(v, (int, float)) and v < 0 else when(v, s)
            overlays.append(Overlay(im, s["t0"] + edge(tx.get("from"), 0), s["t0"] + edge(tx.get("to"), end), tx.get("x", W / 2), tx["y"],
                                    pop=style == "shadow", fin=0 if style == "ig" else 0.14, fout=0 if style == "ig" else 0.10))
        if "vo" not in s:
            continue
        vo = s["vo"]
        line = lines[vo["line"]]
        at = s["t0"] + when(vo["at"], s)
        sig = read_audio(os.path.join(OUT, "vo", line["id"] + ".wav"))
        on, off, _ = speech(sig)
        gain = 0.11 / max(np.sqrt((sig[int(on * SR):int(off * SR)] ** 2).mean()), 1e-4)   # every line at the same level
        starts = line.get("times") or phrase_starts(sig, line["captions"])[0]
        a, b = vo.get("part", [0, None])                    # "part": only this stretch of the line (seconds)
        b = len(sig) / SR if b is None else b
        if "part" in vo:
            sig = sig[int(a * SR):int(b * SR)].copy()
            k = np.arange(len(sig))
            sig *= np.minimum(1, np.minimum(k, len(sig) - 1 - k) / (0.01 * SR))
        sounds.append((at, "vo", sig, gain))
        shown = [(p, st - a) for p, st in zip(line["captions"], starts) if a - 0.02 <= st < b]
        if not vo.get("captions", True):                    # false: the picture already says it
            shown = []
        off, slots = min(off, b) - a, vo.get("slot", line.get("slot", "low"))
        for i, (phrase, st) in enumerate(shown):
            t0 = at + st - 1 / FPS
            t1 = at + shown[i + 1][1] - 2 / FPS if i + 1 < len(shown) else max(at + off + 0.2, t0 + 0.9)
            if wide:
                full = s.get("full")
                im = pill(phrase, line.get("keywords", []), 44, 1300 if full else 1000, (24, 14), 16)
                overlays.append(Overlay(im, t0, t1, 960 if full else 110 + im.width / 2, 1010 - im.height / 2))
            else:
                slot = slots[i] if isinstance(slots, list) else slots
                plate = vo.get("plate", False)              # true, or one per phrase shown
                plate = plate[i] if isinstance(plate, list) else plate
                overlays.append(Overlay(shadowed(phrase, line.get("keywords", []), 72, 880, plate=plate), t0, t1, 500,
                                        {"low": 1150, "high": 450}.get(slot, slot)))
            print(f"    {t0:6.2f}–{t1:6.2f}  {line['id']}  {' / '.join(phrase)}")
    if not wide:                                        # feature chips, one per run of segments
        i = 0
        while i < len(segs):
            chip, j = segs[i].get("chip"), i
            while j + 1 < len(segs) and segs[j + 1].get("chip") == chip:
                j += 1
            if chip:
                real = os.path.exists(os.path.join(HERE, "fonts", "Silkscreen-Regular.ttf"))
                im = pill([chip if real else chip.upper()], (), 34, 780, (20, 13), 12, "pixel",
                          fill=(12, 12, 14, 205), colour=ACCENT, outline=(124, 217, 58, 120))
                overlays.append(Overlay(im, segs[i]["t0"] + 0.1, segs[j]["t0"] + segs[j]["n"] / FPS - 0.05, 90, 290,
                                        centred=False, pop=False, fin=0.15))
            i = j + 1
    for ti in cut.get("titles", []):
        t0 = ti["from"] if ti["from"] >= 0 else total + ti["from"]
        im = pill(ti["lines"], ti.get("keywords", []), ti.get("size", 64), ti.get("maxw", 860), kind=ti.get("font", "text"),
                  colour=tuple(ti["colour"]) if "colour" in ti else WHITE)
        overlays.append(Overlay(im, t0, ti["to"] if ti["to"] > 0 else total + ti["to"], ti.get("x", W / 2), ti["y"]))
    return segs, total, overlays, sounds


VOICE = 0.11                                            # the level every narration line is brought to


def soundtrack(m, n, drop_at, voice, total):
    """The cut's music as n stereo samples, the track's beat drop at drop_at.

    Before the drop it is a bed, "bed" dB under the voice's level, that swells over the last
    "swell" seconds. From the drop it is at "full" (dB against the voice's level) and goes down to
    "under" while a narration line is spoken. Past the track's full section ("bars" bars from the
    drop) it goes round to the drop again."""
    path = os.path.join(HERE, m["src"])
    if not os.path.exists(path):
        print(f"  no showcase/{m['src']}: this cut goes without music")
        return 0
    rms = lambda x: max(float(np.sqrt((x ** 2).mean())), 1e-4)
    trk = read_audio(path, channels=2)
    d0, lap = round(m["drop"] * SR), round(m.get("bars", 32) * m["bar"] * SR)
    trk /= rms(trk[d0:d0 + lap])                            # the full section at level 1
    pos = np.arange(n) + d0 - round(drop_at * SR)           # where in the track each sample is
    into = np.where(pos >= d0, (pos - d0) % lap, 0)
    idx = np.where(pos >= d0 + lap, d0 + into, pos)
    sig = trk[np.clip(idx, 0, len(trk) - 1)] * ((idx >= 0) & (idx < len(trk)))[:, None]
    seam, xf = (pos >= d0 + lap) & (into < 0.012 * SR), 0.012 * SR
    if seam.any():                                          # each time round, a short crossfade out of what came next
        a = (into[seam] / xf)[:, None]
        sig[seam] = sig[seam] * a + trk[np.clip(idx[seam] + lap, 0, len(trk) - 1)] * (1 - a)
    db = lambda g: 20 * np.log10(g)
    full, under = db(VOICE) + m.get("full", 3), db(VOICE) + m.get("under", -15)
    hop = SR // 100                                         # the voice, in 10 ms steps
    talk = (np.abs(voice[:n // hop * hop]).reshape(-1, hop).max(axis=1) > 0.01).astype(float)
    near = np.convolve(np.concatenate([talk, np.zeros(20)]), np.ones(51), "full")[20:20 + len(talk)] > 0   # from 0.2 s before to 0.3 s after
    level = np.convolve(np.pad(np.where(near, under, full), 15, mode="edge"), np.ones(31) / 31, "valid")
    t = np.arange(n) / SR
    gain = np.interp(t, (np.arange(len(level)) + 0.5) * hop / SR, level)
    if drop_at > 0.1:
        swell = m.get("swell", 1.2)
        bed = db(VOICE) + m.get("bed", -21) - db(rms(trk[:max(d0 - round(1.5 * SR), SR)]))
        at_drop = float(np.interp(drop_at - 0.02, t, gain))
        gain = np.where(t < drop_at - 0.02, np.interp(t, [drop_at - swell, drop_at - 0.05, drop_at - 0.02], [bed, full - 6, at_drop]), gain)
    return (sig * (10 ** (gain / 20) * np.clip((total - t) / 1.4, 0, 1))[:, None]).astype(np.float32)


def mix(total, sounds, music=None, drop_at=0.0):
    """The cut's sound in stereo: voice, effects and a take's own sound in the middle, music around."""
    n = int((total + 0.5) * SR)
    out, voice = np.zeros((n, 2), np.float32), np.zeros(n, np.float32)
    def add(buf, sig, at, gain):
        i = max(0, int(at * SR))
        sig = sig[:max(0, len(buf) - i)] * gain
        buf[i:i + len(sig)] += sig[:, None] if buf.ndim == 2 else sig
    for at, kind, what, gain in sounds:
        if kind == "vo":
            add(voice, what, at, gain)
        elif kind == "sfx":
            add(out, synth(what), at, gain)
        else:                                                   # the take's own sound: a number, or {gain, out: seconds of fade-out}
            g = gain if isinstance(gain, dict) else {"gain": gain}
            sig = read_audio(os.path.join(TAKES, what["src"]), what["in"], what["out"] - what["in"])
            k = np.arange(len(sig))
            add(out, sig * np.minimum(1, np.minimum(k / (0.08 * SR), (len(sig) - k) / (g.get("out", 0.08) * SR))), at, g["gain"])
    if music:
        out += soundtrack(music, n, drop_at, voice, total)
    return (out + voice[:, None]) * 0.5                         # headroom: the level is set when it is encoded


def render(name, cut, plan, dry=False):
    W, H = cut["size"]
    wide = W > H
    print(f"{name}: {cut['out']}")
    segs, total, overlays, sounds = schedule(cut, plan)
    for s in segs:
        what = f"slate {s['slate']}" if "slate" in s else f"{s['src']} {s['in']:.2f}–{s['out']:.2f}" + \
            (f" ×{s['speed']:.2f}" if s.get("speed", 1) != 1 else "")
        print(f"  {s['t0']:6.2f}  {s['n'] / FPS:5.2f} s  {what}" + (f"  [{s['vo']['line']} +{when(s['vo']['at'], s):.2f}]" if "vo" in s else ""))
    print(f"  total {total:.2f} s")
    music, drop_at = cut.get("music"), cut.get("drop_at", 0.0)
    if music:
        print(f"  music: the drop ({music['drop']} s into the track) at {drop_at:.3f} s, frame {round(drop_at * FPS)}; "
              f"the track starts at {drop_at - music['drop']:.3f} s")
    if dry:
        return
    tmp = os.path.join(OUT, "tmp")
    os.makedirs(tmp, exist_ok=True)
    silent, wav, final = os.path.join(tmp, name + "-video.mp4"), os.path.join(tmp, name + ".f32"), os.path.join(OUT, cut["out"])
    enc = subprocess.Popen([FFMPEG, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
                            "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", str(cut.get("crf", 17)),
                            "-pix_fmt", "yuv420p", silent], stdin=subprocess.PIPE)
    canvas = desk(W, H)
    sx, sy, sw, sh = STAGE_WIDE if wide else (0, 0, W, H)
    k, last, panels = 0, None, {}
    for s in segs:
        full = wide and s.get("full")
        w, h = (W, H) if full or not wide else (sw, sh)
        src = frames(s, w, h)
        fade = round(s.get("dissolve", 0) * FPS)
        if wide and not full:
            key = json.dumps(s.get("panel"), sort_keys=True)
            if key not in panels:
                panels[key] = panel(canvas, s.get("panel"), cut.get("brand", ""))
        for i in range(s["n"]):
            im = next(src)
            if i < fade and last is not None and last.size == im.size:
                im = Image.blend(last, im, (i + 1) / (fade + 1))
            if i == s["n"] - 1:
                last = im
            if wide and not full:
                frame = panels[key].copy()
                frame.paste(im, (sx, sy))
            else:
                frame = im.copy()
            for o in overlays:
                o.stamp(frame, k / FPS)
            enc.stdin.write(frame.tobytes())
            k += 1
        src.close()
    enc.stdin.close()
    enc.wait()
    mix(total, sounds, music, drop_at).astype(np.float32).tofile(wav)
    raw = ["-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", wav]
    seen = subprocess.run([FFMPEG, "-hide_banner", "-nostats"] + raw + ["-af", "ebur128=peak=true", "-f", "null", "-"],
                          capture_output=True, text=True).stderr
    loud = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", seen)[-1])
    gain = -14 - loud
    for _ in range(3):                                     # the limiter and the encoder take a little off: measure, correct
        target = f"volume={gain:.2f}dB,alimiter=limit=0.89:level=disabled"   # -14 LUFS, peaks under -1 dB
        subprocess.run([FFMPEG, "-v", "error", "-y", "-i", silent] + raw + ["-af", target, "-ar", str(SR), "-ac", "2", "-c:v", "copy",
                        "-c:a", "aac", "-b:a", "192k", "-t", f"{total:.3f}", "-movflags", "+faststart", final], check=True)
        seen = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", final, "-vn", "-af", "ebur128", "-f", "null", "-"],
                              capture_output=True, text=True).stderr
        got = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", seen)[-1])
        if abs(got + 14) < 0.15:
            break
        gain += -14 - got
    print(f"  {got:.1f} LUFS")
    os.remove(wav)
    os.remove(silent)
    print(f"  wrote {final}")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    which = args[0] if args else "tall"
    edit = json.load(open(os.path.join(HERE, "edit.json")))
    plan = json.load(open(os.path.join(HERE, "plan.json")))
    for name in (["tall", "wide"] if which == "all" else [which]):
        render(name, edit[name], plan, dry="--dry" in sys.argv)
