#!/usr/bin/env python3
"""Assembles the demo cuts from the takes, the narration and showcase/edit.json.

    showcase/tts/.venv/bin/python showcase/cut.py tall        # 9:16 rough cut (1080x1920)
    showcase/tts/.venv/bin/python showcase/cut.py wide        # 16:9 judges' cut (1920x1080)
    showcase/tts/.venv/bin/python showcase/cut.py all --dry   # print both timelines, render nothing

Needs Pillow, numpy and ffmpeg. Each segment of the edit list is a piece of a take
(showcase/takes/<scene>/take-N.mov), cut, optionally sped up or zoomed. On top go the burned-in
captions (showcase/CAPTIONS.md), the feature chips, and a mix of the narration lines
(showcase/out/vo), the app's own sound effects (the formulas of Sfx.swift) and, if there is a
showcase/music.wav|mp3|m4a, a music bed ducked under the voice. A scene with no take yet shows as
a labelled slate, so the cut can be reviewed before every take exists.
Output: showcase/out/<name>.mp4 at -14 LUFS, -1 dBTP.
"""
import json, re, math, os, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

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


class Overlay:
    """Something on top of the picture from t0 to t1. In: fade (and a small pop); out: fade."""
    def __init__(self, im, t0, t1, x, y, centred=True, pop=True, fin=0.14, fout=0.10):
        self.im, self.t0, self.t1, self.x, self.y = im, t0, t1, x, y
        self.centred, self.pop, self.fin, self.fout = centred, pop, fin, fout

    def stamp(self, base, t):
        if not self.t0 <= t < self.t1:
            return
        ease = 1 - (1 - min(1, (t - self.t0) / self.fin)) ** 3
        alpha = min(ease, min(1, (self.t1 - t) / self.fout))
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

def read_audio(path, start=None, seconds=None):
    cmd = [FFMPEG, "-v", "error"]
    if start is not None:
        cmd += ["-ss", str(start), "-t", str(seconds)]
    cmd += ["-i", path, "-vn", "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"]
    return np.frombuffer(subprocess.run(cmd, capture_output=True).stdout, dtype=np.float32).copy()


def synth(name):
    """The app's sound effects, from the same formulas as Sfx.swift."""
    rng = np.random.RandomState(1114)
    def make(seconds, f):
        t = np.arange(int(seconds * SR)) / SR
        fade = np.minimum(1, t / 0.004) * np.minimum(1, (seconds - t) / 0.01)
        return (np.clip(f(t), -1, 1) * fade).astype(np.float32)
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
    vf.append(f"scale={w}:{h}:flags=lanczos")
    dec = subprocess.Popen([FFMPEG, "-v", "error", "-ss", str(seg["in"]), "-t", str(seg["out"] - seg["in"]), "-i", path,
                            "-an", "-vf", ",".join(vf), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    size, last = w * h * 3, None
    try:
        while True:
            buf = dec.stdout.read(size)
            if len(buf) == size:
                last = Image.frombytes("RGB", (w, h), buf)
            elif last is None:
                sys.exit(f"no picture from {seg['src']} at {seg['in']} s")
            yield last                                  # past the end: the last frame holds
    finally:
        dec.kill()
        dec.wait()


def schedule(cut, plan):
    """Lays the segments end to end; returns (segments, seconds, overlays, sounds)."""
    W, H = cut["size"]
    wide = W > H
    segs, t, n = cut["segments"], 0.0, 0
    for s in segs:
        if "slate" not in s and not os.path.exists(os.path.join(TAKES, s["src"])):
            s["note"] = s.get("note", "") or s["src"]
            s["slate"], s["seconds"] = s["src"].split("/")[0], (s["out"] - s["in"]) / s.get("speed", 1) + s.get("hold", 0)
        dur = s["seconds"] if "slate" in s else (s["out"] - s["in"]) / s.get("speed", 1) + s.get("hold", 0)
        s["t0"], t = t, t + dur
        s["n"] = round(t * FPS) - n
        n += s["n"]
    total = n / FPS
    lines = {l["id"]: l for l in plan["lines"]}
    overlays, sounds = [], []
    for s in segs:
        for at, name, *gain in s.get("sfx", []):
            sounds.append((s["t0"] + at, "sfx", name, gain[0] if gain else 0.5))
        if s.get("audio") and "slate" not in s:
            sounds.append((s["t0"], "src", s, s["audio"]))
        if "vo" not in s:
            continue
        line = lines[s["vo"]["line"]]
        at = s["t0"] + s["vo"]["at"]
        sig = read_audio(os.path.join(OUT, "vo", line["id"] + ".wav"))
        sounds.append((at, "vo", sig, 1.0))
        phrases = line["captions"] if s["vo"].get("captions", True) else []   # false: the picture already says it
        starts, off = phrase_starts(sig, line["captions"])
        for i, phrase in enumerate(phrases):
            t0 = at + starts[i] - 1 / FPS
            t1 = at + starts[i + 1] - 2 / FPS if i + 1 < len(starts) else max(at + off + 0.2, t0 + 0.9)
            if wide:
                full = s.get("full")
                im = pill(phrase, line.get("keywords", []), 44, 1300 if full else 1000, (24, 14), 16)
                overlays.append(Overlay(im, t0, t1, 960 if full else 110 + im.width / 2, 1010 - im.height / 2))
            else:
                slot = s["vo"].get("slot", line.get("slot", "low"))
                overlays.append(Overlay(pill(phrase, line.get("keywords", []), 64, 800), t0, t1, 495, 1150 if slot == "low" else 450))
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
                overlays.append(Overlay(im, segs[i]["t0"] + 0.15, segs[j]["t0"] + segs[j]["n"] / FPS - 0.05, 90, 290,
                                        centred=False, pop=False, fin=0.2))
            i = j + 1
    for ti in cut.get("titles", []):
        t0 = ti["from"] if ti["from"] >= 0 else total + ti["from"]
        im = pill(ti["lines"], ti.get("keywords", []), ti.get("size", 64), ti.get("maxw", 860), kind=ti.get("font", "text"),
                  colour=tuple(ti["colour"]) if "colour" in ti else WHITE)
        overlays.append(Overlay(im, t0, ti["to"] if ti["to"] > 0 else total + ti["to"], ti.get("x", W / 2), ti["y"]))
    return segs, total, overlays, sounds


def mix(total, sounds):
    out = np.zeros(int((total + 0.5) * SR), np.float32)
    voice = np.zeros_like(out)
    def add(buf, sig, at, gain):
        i = max(0, int(at * SR))
        sig = sig[:max(0, len(buf) - i)]
        buf[i:i + len(sig)] += sig * gain
    for at, kind, what, gain in sounds:
        if kind == "vo":
            on, off, _ = speech(what)
            level = np.sqrt((what[int(on * SR):int(off * SR)] ** 2).mean())
            add(voice, what, at, 0.11 / max(level, 1e-4))       # every line at the same level
        elif kind == "sfx":
            add(out, synth(what), at, gain)
        else:                                                   # the take's own sound, faded at both ends
            sig = read_audio(os.path.join(TAKES, what["src"]), what["in"], what["out"] - what["in"])
            ramp = np.minimum(1, np.minimum(np.arange(len(sig)), len(sig) - np.arange(len(sig))) / (0.08 * SR))
            add(out, sig * ramp, at, gain)
    bed = next((os.path.join(HERE, "music" + e) for e in (".wav", ".mp3", ".m4a") if os.path.exists(os.path.join(HERE, "music" + e))), None)
    if bed:                                                     # 12 dB under the voice's level, 22 dB while it speaks
        m = read_audio(bed)
        m = np.resize(m, len(out)) / max(np.sqrt((m ** 2).mean()), 1e-4) * 0.11
        win = int(0.15 * SR)
        talking = np.convolve((np.abs(voice) > 0.01).astype(np.float32), np.ones(win) / win, "same") > 0.02
        duck = np.convolve(np.where(talking, 10 ** (-22 / 20), 10 ** (-12 / 20)), np.ones(win) / win, "same")
        edge = np.minimum(1, np.minimum(np.arange(len(m)), len(m) - np.arange(len(m))) / (0.6 * SR))
        out += (m * duck * edge).astype(np.float32)
    return np.clip(out + voice, -1, 1)


def render(name, cut, plan, dry=False):
    W, H = cut["size"]
    wide = W > H
    print(f"{name}: {cut['out']}")
    segs, total, overlays, sounds = schedule(cut, plan)
    for s in segs:
        what = f"slate {s['slate']}" if "slate" in s else f"{s['src']} {s['in']}–{s['out']}" + (f" ×{s['speed']}" if "speed" in s else "")
        print(f"  {s['t0']:6.2f}  {s['n'] / FPS:5.2f} s  {what}" + (f"  [{s['vo']['line']} +{s['vo']['at']}]" if "vo" in s else ""))
    print(f"  total {total:.1f} s")
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
    mix(total, sounds).astype(np.float32).tofile(wav)
    raw = ["-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", wav]
    seen = subprocess.run([FFMPEG, "-hide_banner", "-nostats"] + raw + ["-af", "ebur128=peak=true", "-f", "null", "-"],
                          capture_output=True, text=True).stderr
    loud = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", seen)[-1])
    gain = -14 - loud
    for _ in range(2):                                     # the encoded track lands a little under: measure it, correct once
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
