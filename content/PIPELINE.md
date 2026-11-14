# Content pipeline (directive §13)

A repeatable path from a recording to a published post, reusing the tooling in `showcase/`.
Every command below comes from the scripts as they are today (2026-11-13). Paths are relative to
the repo root unless they're absolute.

## 1. Tooling map (what exists)

| Stage | Long cuts (9:16 demo, 16:9 judges) | Shorts (12–45 s, 9:16 + 4:5) |
|---|---|---|
| Record | `showcase/record.sh <scene> <take> <seconds> [x,y,w,h]` (needs the app with `--showcase`) | Reuses the takes in `showcase/takes/` + phone clips in `showcase/shorts/raw/` |
| Narrate | `showcase/tts/.venv/bin/python showcase/narrate.py [L1 L2 …] [--voice ref.wav]` → `showcase/out/vo/<id>.wav` + `timings.json` | `showcase/shorts/tools/vo-all.sh` (loops `tools/vo.py <cut>` 1 line per process; Chatterbox leaks GPU memory) → `showcase/shorts/vo/<cut>/` |
| Check speech | — | `python showcase/shorts/tools/asr.py [cut]` (Whisper; checks NEAR / Pixlz / Frogg pronunciation) |
| Plan / time | `showcase/plan.json` (lines, captions, `times`) + `showcase/edit.json` (segments) | `showcase/shorts/tools/plan.py` (no args; plans every cut) → `app/src/timeline.json` + `.srt` per cut (from `app/src/cuts.json`, `music/beats.json`) |
| Grade (IRL) | — | `showcase/shorts/tools/grade.py` (white balance, exposure, privacy blur boxes) → `app/public/irl/` |
| Assemble | `showcase/tts/.venv/bin/python showcase/cut.py tall\|wide\|all [--dry]` → `showcase/out/<out>.mp4` | `showcase/shorts/tools/render.sh <cut-key> [45 916]` (Remotion `npx remotion render <key>-<fmt>`, then mux) |
| Mix | Inside `cut.py`: −14 LUFS, −1 dBTP, measured on the encoded file | `tools/mix.py <cut>`: −14 LUFS / −1 dBTP (voice stem at −16 LUFS), two-pass loudnorm; `tools/remux.sh <cut>` swaps the new audio into rendered videos |
| Copy | — | `tools/posts.py` → `out/<title>/posts.md`, `script.md`, `credits.txt` |
| Stills | `pixl-snapshots` (`swift run --package-path macos/PixlMemory pixl-snapshots <reply.json> docs/screenshots`) | `cd showcase/shorts/app && node stills.mjs <comp> <outdir> <frames\|all> [scale]` |

How `edit.json` works (from `cut.py`): each top-level key is a cut (`tall`, `tall-kooma`, `wide`).
A cut written as `{"like": "<base>", "patch": {"<segment id>": {...}}, ...}` inherits its base,
patches segments by `id`, and replaces the other keys. A segment is `{"src": "<scene>/take-N.mov",
"in", "out" | "beats", "zoom", "vo": {"line", "at"}, "sfx", "panel" (16:9 side panel: kicker,
title, body, proof), "full": true (a 16:9 source fills the 16:9 frame)}`. A missing take renders
as a labelled slate, so you can review a cut before the footage exists.

## 2. Workflow for a new video (example: V3)

1. **Script:** pick the concept in `content/CONCEPTS.md` and run its VO through the claim rules (§5).
2. **Record** the shots from `content/RECORDING-BRIEF.md`. Showcase scenes go through `record.sh`.
   For terminal or browser shots, run the same capture by hand:
   ```sh
   /opt/homebrew/bin/ffmpeg -f avfoundation -capture_cursor 1 -framerate 60 -pixel_format uyvy422 \
     -i "1:none" -t 40 -vf "crop=1920:1080:<2x>:<2y>,format=yuv420p" -c:v libx264 -preset ultrafast -crf 14 \
     showcase/takes/R2/take-1.mov
   ```
   (`1` is the screen device as in `record.sh`; list devices with `ffmpeg -f avfoundation -list_devices true -i ""`.)
3. **Narration:** add lines to `plan.json` (`cut.py` and `narrate.py` both read this one file), then `narrate.py <ids>`. If you
   use a human voice, save `showcase/out/vo/<id>.wav`; captions re-time themselves.
4. **Edit:** add a variant to `edit.json`, e.g. `"wide-v8": {"like": "wide", "out": "pixlz-16x9-judges-v8.mp4", "patch": {...}}`.
   Segments that are new (not patches) need a full `segments` list in the variant. Run `--dry`
   first and compare the timeline with the brief's destinations.
5. **Render:** `showcase/tts/.venv/bin/python showcase/cut.py wide-v8`.
   `cut.py`'s `__main__` passes any name through `variant()`, so variant keys render directly.
   For shorts: the Remotion app reads transcoded takes from `showcase/shorts/app/public/takes/<scene>.mp4`
   (the step that makes them isn't scripted in `tools/`: unverified, so copy the existing files' format).
   Then add the cut to `showcase/shorts/app/src/cuts.json` → `vo.py <cut>` → `plan.py` (all cuts) →
   `mix.py <cut>` → `render.sh <cut>` → `posts.py`.
6. **QA** with the checklist (§5). Export (§3–4). Publish by hand; nothing in the repo posts.

Takes, renders and music aren't committed (`SHOTLIST.md`). Narration lines and specs are.
Commit `edit.json` / `plan.json` / `cuts.json` changes with the render they produced, and
mention the video in the commit message.

## 3. Export specs

Everything is H.264 High, yuv420p, 30 fps (the takes are 60 fps; cuts are 30), AAC 48 kHz
(the shorts use 320 kb/s), `-movflags +faststart`. That's what the current files use.

| Target | Size | Length (ours) | Notes |
|---|---|---|---|
| TikTok | 1080×1920 | 15–60 s | Burned-in captions; keep the first frame as the poster (RESEARCH-NOTES §1) |
| Instagram Reels | 1080×1920 (+1080×1350 4:5 for feed) | 15–60 s | `render.sh` makes both |
| YouTube Shorts | 1080×1920 | ≤ 60 s | Same master as Reels |
| X | 1080×1920 or 1920×1080 | 15–140 s | Autoplays muted → burned-in captions; or upload the `.srt` on desktop (RESEARCH-NOTES §3) |
| Reddit | 1080×1350 (4:5) | ≤ 45 s | Important content within the central 4:5 band of a 9:16 master |
| Judges / README | 1920×1080 | 75–90 s (J1), 3:30–4:30 (J2) | Burned-in pill captions (CAPTIONS.md §16:9). GitHub attachments cap at 10 MB on free plans: the current judges' cut is 10,116,796 bytes. Check it uploads, or link to a hosted copy |

Platform-imposed maximum lengths, sizes and bitrates aren't verified here. Check each platform's
current upload page before publishing. Lengths above are editorial targets.

**Caption safe zone, 9:16 (1080×1920):** the intersection of `showcase/CAPTIONS.md` and
`showcase/shorts/RESEARCH-NOTES.md`: **x 90–890, y 300–1250**. That clears the top ~14 %, the
bottom ~35 % and the right action rail, and it falls inside Reddit's central 4:5 band (y 285–1635).
Caption at most 720 px wide, centred at about x 500. Two slots: LOW (centre y ≈ 1180), HIGH (y ≈ 400).
Inter SemiBold 64–72 px, 3–5 words, keyword in green `#7CD93A`.
**16:9:** Inter SemiBold 44 px pill, baseline 90 px above the bottom, at most 1300 px wide and 42 characters per line.
**Labels** (SIMULATED, testnet, render, planned): Silkscreen 32–36 px (9:16) / 28 px (16:9),
top-left of the safe box, on screen for the whole shot they qualify.

**Loudness:** −14 LUFS integrated, true peak ≤ −1 dBTP (as `cut.py` and `mix.py` do now). Voice
stem −16 LUFS; music bed −24 to −28 LUFS under voice. Check a finished file with:
`ffmpeg -hide_banner -i out.mp4 -af loudnorm=print_format=json -f null - 2>&1 | tail -12`.

## 4. Export commands (from existing masters, no re-render)

4:5 crop of a 9:16 master (centre band):
`ffmpeg -i in-9x16.mp4 -vf "crop=1080:1350:0:285" -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -c:a copy -movflags +faststart out-4x5.mp4`
(Only for long cuts; shorts already render 4:5 natively.)

Smaller judges' file for GitHub (if > 10 MB):
`ffmpeg -i pixlz-16x9-judges.mp4 -c:v libx264 -crf 26 -preset slow -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart judges-small.mp4`
(Watch it after re-encoding, because burned-in pixel text gets soft.)

## 5. Pre-publish checklist

**Claims match the code** (check each sentence of VO, captions and post text):
- [ ] "14 mandatory checks": `MANDATORY_CHECKS` in `memory/src/pixl_memory/verify.py` (14 since `de02672`, which added `gateway.tls`). The `attest` CLI prints 15 lines (the 14 plus the deployment log). The app's panel counts more (it adds the signature checks). **Caption only a number that's visible in the frame.**
- [ ] Refusal is "fail, skip or missing → not sent (HTTP 409)". Reply failure is "discarded, text did reach the enclave (HTTP 502)".
- [ ] No "pays for its own AI / thinking". The transfer is an accounting payment; inference is billed in NEAR AI credits. (Fix `plan.json` L5 and the shorts lines `pixlz-general` "wallet", `pixlz-crypto` "pays", `pixlz-not-a-chatbox` "pays" before re-using them.)
- [ ] No "nobody else can see" (`plan.json` L3). Use "processed inside a verified enclave".
- [ ] Limits are said to be **app-enforced**. A stolen key is said to drain **Frogg's** balance only.
- [ ] TEE ≠ encryption at rest; never in the same sentence as if they were one thing.
- [ ] "Remote model in a TEE", never "offline" / "on-device".
- [ ] Trips: "local Wi-Fi, not encrypted yet" appears whenever a trip is a feature beat.
- [ ] iPhone appears only as "planned / coming soon" (D1 render is labelled).
- [ ] Counts are current: run the suites and update. The README says 125 memory tests and "21 attacks"; the commit `8247283` reports 222 passed; ATTACKS.md shows 22. Use the number from today's run.
- [ ] Dates on evidence are UTC as stamped (`2026-11-14 02:43Z` for the attest log).
- [ ] No claim about NFTs, Solana, mainnet or Windows as shipped.

**No private info** (scrub each frame at 0.25× speed):
- [ ] No `.env`, API key, `pixl-memory token`, `*_key.json`, `store.key`, seed phrase or `near` keychain prompt.
- [ ] No real emails, inboxes, notifications, other browser tabs or bookmarks, Wi-Fi name or user-name paths.
- [ ] Owner account names: the agreed policy is applied (`sylversurferr.testnet` in attack_demo/ATTACKS; `pixlz-petz-faucet.testnet` on explorer shots).
- [ ] Claude Code transcripts are only from `showcase/demo/`.
- [ ] Faces and street views in phone clips: `grade.py` blur boxes are applied (clip2/clip3 show streets and buildings).

**Labels for non-live footage:**
- [ ] `pytest` / `attack_demo` footage → "SIMULATED NEAR AI CLOUD · tests the app's decision logic, not the hardware".
- [ ] `polish-refused.png`, `polish-reply-rejected.png`, other `pixl-snapshots` stills → "app view".
- [ ] Remotion scenes (`games`, `behaviors`, `skinsSplit`, `mosaicoAllow`, `phoneSoon`) → "animation", or replace them with real captures (H05, H06).
- [ ] D1 → "render · iPhone coming soon". Mosaico simulator → "simulator".
- [ ] E02 → "real network · NVIDIA's service blocked locally" (it's **not** simulated).
- [ ] Waits cut from inference shots → "answer took N s" where the judges might care.

**Technical:**
- [ ] Watched once with sound and once muted; every beat reads muted.
- [ ] Loudness measured (§3). Captions inside the safe zone in a 9:16 phone preview.
- [ ] Music licence noted in `credits.txt` (Pixabay tracks: `showcase/shorts/music/PIXABAY-LICENSE.txt`; `music.mp3` is a commercial release and may be muted by platforms).
- [ ] Synthetic voice disclosed in the post if a platform requires it (Chatterbox, local).

## 6. The loop: engineering change → regression test → recorded demo → explainer → social video → thread

Every security-relevant change ships with a story. The NRAS fix is the template's first run.

| Step | Output | Done when |
|---|---|---|
| 1. Engineering change | A commit that names the property ("a skipped GPU check blocks send") | Merged; the hash noted |
| 2. Regression test | A test that fails on the old code and passes on the new (e.g. `tests/test_preflight_matrix.py`; the commit message records a mutation check: "pre-fix logic leaks in 12") | The test command and its pass count are noted |
| 3. Recorded demo | A real-network shot when possible (E02), a simulated suite shot (E03), a before/after (E04) | Takes in `showcase/takes/<ID>/`, labelled |
| 4. Explainer | A paragraph in `docs/ATTACKS.md` / README + an evidence file in `docs/hackathon/evidence/` | Reviewed against the claim rules |
| 5. Social video | A V-episode (here V3) through §2 | Checklist §5 passes |
| 6. Thread | X thread (template below), linked from the video post | Posted by hand |

**Template (copy for each change):**

```markdown
### <short name of the change>  ·  <date, UTC>
- Property: <one sentence: what must always / never happen>
- Before: <what happened, honestly scoped>  (commit <old-hash>)
- After: <what happens now>                 (commit <new-hash>)
- Regression test: `<command>` → <N passed>;  fails on old code: <yes/how shown>
- Real or simulated: <which shots are live, which use the fake cloud>
- Limits: <what this does NOT prove>
- Shots: <brief IDs>  ·  Video: <concept ID>  ·  Cut: <edit.json key>
- Thread:
  1/ <hook: the attack in one line>
  2/ Before: <…> (screenshot)
  3/ The rule now: <…> (code snippet, 3 lines)
  4/ Proof: <test command + count>, labelled simulated
  5/ Live: <real-network clip>
  6/ What it doesn't prove: <…>
  7/ Try it: `<command>` · repo link
```

**Filled for the NRAS fix:** Property: "text is never sent unless all 14 mandatory properties
pass". Before: a GPU check skipped because NRAS was unreachable let text go to a TDX-attested
enclave, shown as "Partly verified" (`bf53f98`). After: refused, nothing sent (`4c85d08`,
`8247283`). Test: `cd memory && uv run pytest tests/test_preflight_matrix.py -q` → 104 passed;
`uv run python attack_demo.py` → 23/23. Simulated: both suites. Live: E02. Limits: proves the
client's decision; it doesn't prove the hardware is secure. Shots: E02, E03, E04. Video: V3.
Cut: `v3-leak` (new shorts cut) and `wide-v8`.
