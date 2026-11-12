"""Narration for the Pixlz demo video with Chatterbox (Resemble AI's open TTS), on this Mac.

    showcase/tts/.venv/bin/python showcase/narrate.py            every line in plan.json
    showcase/tts/.venv/bin/python showcase/narrate.py L1 L2      some lines
    ... --voice path/to/reference.wav                            clone a voice from a 10 s clip

The read follows its reference, pace included. plan.json's "voice" names one ("reference", a
file in showcase/): voice-slow.wav is Chatterbox's own voice reading three of these lines,
slowed to two thirds, which brings the read down from about 250 words a minute to about 175.

Writes showcase/out/vo/<id>.wav and showcase/out/vo/timings.json (each line's length), which
the cut uses to time scenes and captions. Nothing is sent anywhere: the model runs locally.

A line's "say" in plan.json is what is spoken when that is not how it is written ("NEAR" is
written in capitals and said as the word). plan.json's "voice" sets the read: "exaggeration"
and "cfg_weight" are Chatterbox's (a lower cfg_weight is a calmer read), and "tempo" slows or
speeds the finished line without changing its pitch (0.9 is 10 % slower).
"""
import json
import subprocess
import sys
from pathlib import Path

import torch
import torchaudio as ta
from chatterbox.tts import ChatterboxTTS

HERE = Path(__file__).resolve().parent
OUT = HERE / "out" / "vo"


def main(argv: list[str]) -> int:
    voice = None
    if "--voice" in argv:
        i = argv.index("--voice"); voice = argv[i + 1]; argv = argv[:i] + argv[i + 2:]
    plan = json.loads((HERE / "plan.json").read_text())
    lines = [l for l in plan["lines"] if not argv or l["id"] in argv]
    if voice is None and plan.get("voice", {}).get("reference"):
        voice = str(HERE / plan["voice"]["reference"])
    read = {"exaggeration": 0.45, "cfg_weight": 0.5, "tempo": 1.0, **plan.get("voice", {})}     # "reference" is read above
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = ChatterboxTTS.from_pretrained(device=device)
    OUT.mkdir(parents=True, exist_ok=True)
    timings_path = OUT / "timings.json"
    timings = json.loads(timings_path.read_text()) if timings_path.exists() else {}
    for l in lines:
        text = l.get("say", l["vo"]).replace("…", "...")
        torch.manual_seed(l.get("seed", 7))   # the same read every time, whichever lines are asked for
        wav = model.generate(text, audio_prompt_path=voice, exaggeration=read["exaggeration"], cfg_weight=read["cfg_weight"])
        path = OUT / f"{l['id']}.wav"
        ta.save(str(path), wav, model.sr)
        seconds = wav.shape[-1] / model.sr
        if read["tempo"] != 1:
            raw = path.with_suffix(".raw.wav")
            path.rename(raw)
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-af", f"atempo={read['tempo']}", str(path)], check=True)
            raw.unlink()
            seconds /= read["tempo"]
        timings[l["id"]] = round(seconds, 3)
        print(f"{l['id']}  {timings[l['id']]:5.2f} s  {l['vo']}")
    timings_path.write_text(json.dumps(timings, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
