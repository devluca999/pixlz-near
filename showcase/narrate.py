"""Narration for the Pixlz demo video with Chatterbox (Resemble AI's open TTS), on this Mac.

    showcase/tts/.venv/bin/python showcase/narrate.py            every line in plan.json
    showcase/tts/.venv/bin/python showcase/narrate.py L1 L2      some lines
    ... --voice path/to/reference.wav                            clone a voice from a 10 s clip

Writes showcase/out/vo/<id>.wav and showcase/out/vo/timings.json (each line's length), which
the cut uses to time scenes and captions. Nothing is sent anywhere: the model runs locally.
"""
import json
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
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    torch.manual_seed(7)                      # the same read every time
    model = ChatterboxTTS.from_pretrained(device=device)
    OUT.mkdir(parents=True, exist_ok=True)
    timings_path = OUT / "timings.json"
    timings = json.loads(timings_path.read_text()) if timings_path.exists() else {}
    for l in lines:
        text = l["vo"].replace("…", "...")
        wav = model.generate(text, audio_prompt_path=voice, exaggeration=0.45, cfg_weight=0.5)
        path = OUT / f"{l['id']}.wav"
        ta.save(str(path), wav, model.sr)
        timings[l["id"]] = round(wav.shape[-1] / model.sr, 3)
        print(f"{l['id']}  {timings[l['id']]:5.2f} s  {l['vo']}")
    timings_path.write_text(json.dumps(timings, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
