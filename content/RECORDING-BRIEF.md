# Recording brief (directive §12)

What to film next for the Pixlz series and the judges' cut. Written 2026-11-13 after an audit of
`showcase/`, `docs/screenshots/` and `docs/hackathon/evidence/`. Nothing in this brief has been
recorded yet. Steps marked **REHEARSE** come from reading the code and haven't been run. Do a dry
run before rolling.

## 0. What already exists (don't re-shoot)

| Asset | Path | Facts (ffprobe) | Usable for |
|---|---|---|---|
| 9:16 cut | `showcase/out/pixlz-9x16-draft.mp4` | 1080×1920, 30 fps, 89.1 s | Base for social cuts |
| 9:16 cut, Artlist track | `showcase/out/pixlz-9x16-kooma.mp4` | 1080×1920, 59.5 s | Older, faster layout |
| 16:9 judges' cut (v7) | `showcase/out/pixlz-16x9-judges.mp4` | 1920×1080, 127.0 s, 10.1 MB | Current submission video |
| Intro phone clip | `showcase/takes/intro-frogg.mp4` | 1080×1920, 17.0 s | Handheld Mosaico + dialogue ("This is Frogg") |
| Showcase takes | `showcase/takes/{H1,F1,F2,F3,E1,F4,M1,M2,M3,W1,C1,C2,C3,E2}/take-1..3.mov` | 540×960 pt regions at 2× | Pet b-roll, wallet card plus explorer (F2), brain/attestation card (F3), paid answer (F4), memory (M1–M3), polish-in-place (W1), agents (C1–C3) |
| Device render | `showcase/takes/D1/take-1.mov`, `D1/wide-1.mov` (5.0 s) | A **render** that includes an iPhone | Must stay labelled "render · iPhone coming soon" |
| Phone clips | `showcase/shorts/raw/clip1.mp4` (15 s), `clip2.mov` (10.7 s), `clip3.mp4` (17.9 s), `clip4.mp4` (11.3 s) | Handheld Mosaico, mostly blown-out glare; none holds Mac + Mosaico through a full round trip | Delight inserts only |
| Photos | `showcase/shorts/raw/p-{desk,xdesk,camera,sleeping,baseboard}.jpg` | n/a | Collage stills |
| Shorts (rendered) | `showcase/shorts/out/pixlz-{general,general-hookB,dev,crypto,productivity,immortal-snail,not-a-chatbox,twitter-loop}/*-9x16.mp4` and `*-4x5.mp4` | 12.5–42.3 s | Existing social set. **Note:** the `games`, `behaviors`, `skinsSplit`, `mosaicoAllow` and `phoneSoon` scenes are Remotion animations of the sprites, not screen recordings |
| Screenshots | `docs/screenshots/*.png` (30 files) | Rendered from the app's own views by `pixl-snapshots` with constructed data. **`polish-refused.png` and `polish-reply-rejected.png` are not captures of a live failure** | Stills, thumbnails; label them "app view" |
| Live attest log | `docs/hackathon/evidence/live-attest-2026-11-13.txt` | Captured 2026-11-14 02:43 **UTC**; 15 lines (14 mandatory checks plus the deployment log) all ✔, 8 × GH100, TCB UpToDate | Text proof; still needs an on-screen recording (E01) |
| Attack log | `docs/ATTACKS.md` | 23/23, generated 2026-11-14 02:40 UTC | Text proof; prints the fixture account `sylversurferr.testnet` |

Takes recorded **before** the fail-closed fix (Nov 12): F3, F4 and W1. They are still true, since a
verified run looks the same, but they don't show refusal. **No real recording of a refusal exists
yet.** That's the biggest gap.

## 1. Global rules for every shot

- **Screen captures are the technical proof; the physical camera is for delight and context.**
  Never use a phone filming a screen to show a proof.
- Screen capture uses the same ffmpeg line as `showcase/record.sh`: avfoundation, 60 fps, cursor
  on, crop in points ×2, x264 CRF 14. For the 16:9 judges' cut, capture a 960×540 pt region
  (1920×1080 px) and use `"full": true` in `edit.json`. For 9:16, capture 540×960 pt (the
  `record.sh` default region `570,90,540,960`).
- **Terminal:** a dedicated profile with a dark background, an 18–20 pt monospaced font and about
  90×24 characters, the prompt set to `PS1='pixlz $ '` (hides user and hostname), no other tabs,
  scrollback cleared with `clear`.
- **Mac:** Do Not Disturb on (no notifications), Dock hidden, a clean desktop or `--showcase` desk,
  browser in a fresh profile with no other tabs, bookmarks bar hidden, no extensions except Pixl.
- **Never on screen:** `.env` or its contents, `NEAR_AI_API_KEY`, `pixl-memory token` output,
  `~/Library/Application Support/PixlMemory/*_key.json` (Frogg's key), `store.key`, any wallet
  seed or `near` CLI keychain prompt, real email addresses or inboxes, Claude Code transcripts from
  real projects, the macOS user name in paths (`/Users/Luca_M/…`: `cd` into the repo first and
  keep paths relative).
- **Decide once, then apply everywhere:** the owner account names. `pixlz-petz-faucet.testnet` and
  `pixlz-petz.testnet` are already public in the README. `sylversurferr.testnet` is a test fixture
  printed by `attack_demo.py` and `ATTACKS.md`. Blur it, or accept it, since it's public in the repo.
- **Terminal proofs in 9:16 cuts (V2, V3):** record each terminal shot twice: once at 960×540 pt for 16:9, and once in a narrow terminal (about 46×30 characters, 22 pt) captured at 540×960 pt for 9:16. Don't crop a 16:9 terminal down to 9:16.
- **Check counts on recording day:** HEAD has 13 `MANDATORY_CHECKS`. The working tree has an uncommitted change (not from this brief) that adds `gateway.tls`, which would make 14. Caption whatever `attest` prints that day.
- **Defaults for H and O shots unless stated:** screen capture, no lighting needs, no audio, no second device, hide per this section.
- **Simulated footage gets a burned-in label** that stays on screen the whole time it plays:
  `SIMULATED NEAR AI CLOUD · tests the app's decision logic, not the hardware`.
- **Audio:** screen shots are silent (VO and sound effects come later). Physical shots record room
  sound on the camera plus a lav or second phone, for the app's sounds and reactions.

## 2. Shots

Columns are compressed into one block per shot. "Dest" means the cut and the moment it serves.
Judges' cut times refer to the **current** `wide` timeline (`showcase/tts/.venv/bin/python
showcase/cut.py wide --dry`). A new judges' cut is proposed as edit variant `wide-v8` (see
PIPELINE.md). Concept IDs (V1…V22, J1, J2) refer to CONCEPTS.md.

### ESSENTIAL

**E01 · Live attest, unbroken**
- Action: `cd memory && uv run pixl-memory attest`. Hold 3 s on the result. Then `echo $?` → `0`.
- Display: "Attesting z-ai/glm-5.3-flash…", then VERIFIED and 15 ✔ lines (14 mandatory checks plus
  the deployment log), the signers and the image digests.
- Camera: screen capture 960×540 pt. Framing: the terminal fills the frame, cropped below the
  image lines if they wrap.
- Duration: real time (about 5–20 s); record 40 s. Lighting: n/a. Audio: no. Second device: no.
- Hide: prompt and paths (needs no key, so `.env` is never touched).
- Concepts: V2, V3, V6, J1, J2. Dest: `wide-v8` replaces F3 at 17.80–25.08 (keep the F3 brain
  pop as the first 2 s, then E01 full-frame). In the 9:16 variant `tall-v8`, the narrow-terminal
  version follows F3 at 28.44–34.92. In V2, it's the "proof" beat (6–30 s).

**E02 · Real refusal: NVIDIA's attestation service blocked on this Mac** (REHEARSE)
- Setup (off camera):
  `sudo sh -c 'echo "0.0.0.0 nras.attestation.nvidia.com" >> /etc/hosts' && sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`
- On camera, part a, CLI: `cat /etc/hosts | tail -1` (shows the block) → `uv run pixl-memory attest`
  → expect `PARTIAL: Refused: could not prove nvidia gpu attestation. Nothing was sent.` with
  `NVIDIA GPU attestation … NRAS unreachable`, and `echo $?` → `1`.
- On camera, part b, app: in `showcase/demo/draft.txt` (opened in TextEdit), select the first
  paragraph → click Frogg → **Polish this** → the orange card "Enclave failed checks. Not sent." /
  "! NOT SENT". This is the live version of `polish-refused.png`. It needs `NEAR_AI_API_KEY` in
  `.env`, but nothing is sent and nothing is paid.
- Undo (on camera, as the closing beat):
  `sudo sed -i '' '/nras.attestation.nvidia.com/d' /etc/hosts && sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`.
  Re-run E01 to show VERIFIED again.
- Camera: screen 960×540 pt for part a; 540×960 pt around Frogg and the card for part b.
- Duration: part a about 15 s, part b about 12 s, undo about 8 s.
- Hide: the `sudo` password prompt (type it before the take starts), `.env`.
- Label on screen: `REAL network · NVIDIA's service blocked locally with /etc/hosts`. **Not**
  "simulated".
- Concepts: V2, V3 (hero shot), J1, J2. Dest: `wide-v8` new segment right after E01 (from about
  25.1 s, 12 s long). `tall-v8`: part b only, right after E01. V3 2–6 s and 22–35 s.

**E03 · Simulated attack suite on screen**
- Action: `cd memory && uv run pytest tests/test_preflight_matrix.py -q` → `104 passed`; then
  `uv run python attack_demo.py`, scroll to the table → `23/23 behaved as expected`.
- Camera: screen 960×540 pt. Framing: tight on the summary line, plus one pass over the rows.
- Duration: the pytest run in real time (a few seconds); attack_demo 10 s of scrolling.
- Hide: the `sylversurferr.testnet` rows 14–18 (blur, or decide per §1).
- Label: SIMULATED (§1). Concepts: V3, V12, J2. Dest: `wide-v8` after E02 (4–6 s); V3 35–42 s.

**E04 · Before/after of the fix**
- Action, part a (guaranteed): `git show 4c85d08 -- memory/src/pixl_memory/verify.py | sed -n '/def attestation_ok/,+8p'`.
  This shows the old line, which refused only on FAIL, so a SKIP passed, next to the new line,
  where a GPU SKIP blocks. Then
  `grep -n "MANDATORY_CHECKS = (" -A3 memory/src/pixl_memory/verify.py`.
- Action, part b (optional, REHEARSE, needs E02's hosts block): `git worktree add ../pixlz-before bf53f98 && (cd ../pixlz-before/memory && uv run pixl-memory attest; echo $?)`.
  Expect `PARTIAL: Partly verified: could not check nvidia gpu attestation.` and exit `0`: at
  bf53f98, `attestation_ok` was true, so the app would have sent text. Clean up with
  `git worktree remove ../pixlz-before`. **Don't** run a paid polish in the old build.
- Wording rule: before the fix, text went to a TDX-attested enclave **without GPU proof**, shown
  as "Partly verified". It didn't go to an attacker.
- Camera: screen 960×540 pt; diff colours on, font 20 pt. Duration: 8–10 s per part.
- Concepts: V3, V12, J2. Dest: V3's "before" beat; `wide-v8` J2 walkthrough §3.

**E05 · A real polish with every check expanded**
- Action: start the app normally (`open "$HOME/Applications/Pixl Memory.app"`; not `--rehearse`).
  In TextEdit with `showcase/demo/draft.txt`, select the paragraph → Frogg → Polish this. Wait
  (cut later) → panel with the word diff and verdict → expand the checks list → scroll it slowly
  → drag the card into the draft.
- Camera: screen 540×960 pt for 9:16, plus a second pass at 960×540 pt for 16:9. Framing: the panel
  is fully visible; when the checks are expanded, punch in on the list.
- Duration: about 25 s of action (the inference wait is cut, so note it on screen: "answer took N s").
- Hide: TextEdit's file path title if it shows the user name, and Mail or any real inbox.
- Cost: one NEAR AI request plus one testnet transfer.
- Concepts: V1, V2, V6, J1, J2. Dest: `wide-v8` replaces W1 at 68.77–86.98; `tall-v8`
  replaces W1 at 54.34–59.99.

**E06 · The NEAR explorer receipt for that same polish**
- Action: right after E05: Frogg → Wallet → last receipt (amount, model, verdict) → click through
  to testnet nearblocks → the transaction page: signer `frogg.<owner>.testnet`, receiver = the
  allow-listed payee, amount, status Success. Then show the account page with its balance.
- Camera: screen 960×540 pt (browser at 100 % zoom; the URL bar stays visible to show
  `testnet.nearblocks.io`).
- Duration: 12 s. Hide: other tabs and bookmarks; the owner name (§1 decision).
- On-screen text: `Testnet. An accounting payment from Frogg's wallet. Inference is billed in NEAR AI credits.`
- Concepts: V4, V6, J1, J2. Dest: `wide-v8` inserted right after F4 (which ends at 42.48);
  `tall-v8` replaces F2c at 26.83–28.43; V4 8–22 s.

**E07 · Continuous physical trip: Mac → Mosaico → Mac, one take, no cuts**
- Action: Frogg perched on a window → double-click → More → Send to device → the Mosaico → he
  leaps off the Mac screen → appears on the Mosaico → hold 5 s → tap Frogg on the Mosaico
  (double-tap window) → he leaves → springs out of the Mac's menu bar.
- Display: the Mac uses the `--showcase` desk or a clean wallpaper. The Mosaico runs pixlz_dock.
- Camera: phone on a tripod, 4K/30 locked, 1.5–2 m away, lens at desk height, angled about 20°
  off the Mac's axis. The Mac screen and the Mosaico (placed in front of the trackpad, to the
  right) are both in frame for the **whole** take. Lock AE/AF on the Mosaico and set exposure
  −1.5 to −2 EV, so the pixels don't bloom like they do in `clip3`/`clip4`. Mac brightness at
  about 60 %.
- Framing: 16:9 master wide enough to crop a 9:16 version (keep both devices inside the
  centre-right 9:16 band).
- Duration: 60–90 s, real time. A second angle (optional): a handheld close-up of the Mosaico
  for inserts in the social cuts only, never in the proof cut.
- Lighting: a dim room, one soft key from camera-left, no window behind the screens. Audio: yes,
  room sound for the app's whoosh and pop. Second device: the Mosaico, which must be on the same
  Wi-Fi as the Mac (or use `PixlzSend --host <ip>` beforehand to confirm it's reachable).
- Hide: the menu bar clock is fine; the Wi-Fi network name; nothing on the Mac desktop.
- On-screen text: `One take · real speed · Mac → Mosaico → Mac over local Wi-Fi`. In V5, add:
  `Trip link not encrypted yet`.
- Concepts: V5, V1, J1, J2. Dest: `wide-v8` inserted before D1 at 115.70 (the D1 render is
  kept, labelled "render · iPhone coming soon"); `tall-v8` replaces D1 at 73.75–78.61 with a
  9:16 crop of E07; V5 0–24 s.

### HIGH-VALUE

**H01 · Mac → Mac trip on one Mac** (screen)
- `open -n --env PIXL_DEVICE_ID=demo --env "PIXL_DEVICE_NAME=Demo" ~/Applications/Pixl\ Memory.app`
  → Send to device → Demo → "Catch …?" → Yes.
- Screen 960×540 pt, 15 s. Concepts: V5. Dest: V5 beat 4.

**H02 · Ask with web search and sources**
- ⌃⌥Space → "what's new with NEAR AI this week?" → answer, sources, and a "partly verified"
  verdict (signed by the gateway, not the model enclave). Linger on that line.
- Screen 540×960 pt, 15 s (wait cut). Costs a search ($0.005). Concepts: V7, V6. Dest: V7.

**H03 · Ask with pictures**
- "famous Chicago landmarks" → thumbnails → click one to enlarge. Screen 540×960 pt, 10 s.
  Concepts: V8. Dest: V8.

**H04 · Chrome highlight → save → backlink**
- On `showcase/demo/site/glass-frogs.html`, select a passage → ⌥⇧S → close the tab → Ask "what
  did I save about glass frogs?" → click the link → the page reopens, scrolled and highlighted.
- Screen 960×540 pt, 20 s. Fresh Chrome profile. Concepts: V9. Dest: V9; 9:16 M1–M3 region
  (44.63–54.33).

**H05 · Games, real capture**
- Slugg · Inevitable: a full 60 s round, ending on "squelch!" and the crown. Frogg · Snap: a
  round with a dodge streak and a feint.
- Screen 960×540 pt; record in a normal (non-debug) build. Concepts: V10. Dest: V10; replaces
  the Remotion `games` scene in shorts.

**H06 · Agents: guard plus Allow from a paired Mosaico** (screen plus physical; REHEARSE pairing and the Allow route first)
- A Claude Code session in `showcase/demo/` asks to run a command → the Pixl alerts → approve
  on the Mosaico → the Terminal continues.
- Screen capture of the Terminal plus a tripod shot of the Mosaico tap, synced by a clap.
- Hide: real project transcripts (only `showcase/demo/` sessions).
- Concepts: V11. Dest: V11; replaces the Remotion `mosaicoAllow` scene in `pixlz-dev` and
  `pixlz-crypto`.

**H07 · Wallet caps refuse before sending** (REHEARSE: confirm the limit UI path and the exact refusal text)
- Wallet bubble → set the weekly limit just above today's spend (or Pause) → Polish → card: "…
  Your text was not sent." Then show `uv run pixl-memory wallet status`.
- Screen 540×960 pt, 15 s. Hide: the key-file path line if it shows the user name.
- On-screen text: `Limits are enforced by the app, not on chain.` Concepts: V4, V13. Dest: V4 22–30 s;
  V13.

**H08 · Pre-commit hook blocks a secret** (REHEARSE)
- In a throwaway clone (`git clone . /tmp/pixlz-hook && cd /tmp/pixlz-hook && git config core.hooksPath .githooks`):
  `echo 'X=1' > .env && git add -f .env && git commit -m test` → refused.
- Screen 960×540 pt, 10 s. Uses fake values only. Concepts: V14. Dest: V14.

**H09 · Local API guards** (REHEARSE)
- With the service running:
  `curl -s -o /dev/null -w "%{http_code}\n" -H "Host: attacker.example" http://127.0.0.1:7341/health` → `421`;
  `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:7341/attestation` → `401`.
- Screen 960×540 pt, 10 s. Concepts: V15. Dest: V15.

**H10 · Physical desk b-roll with the owner**
- Hands on the keyboard, Frogg perched on the active window, the Mosaico on the desk, a coffee.
  A slow 5 s push-in. Plus a 3 s reaction shot of the owner glancing at Frogg.
- Tripod or a slider, 4K/30, the same lighting as E07. Hide: the screen content (`--showcase`
  desk). Concepts: V1, V4, V5 openers; J1 opener.

### OPTIONAL

| ID | Shot | Capture | Concepts |
|---|---|---|---|
| O01 | Skins: More ▸ Change Pixl through all six pets, then Settings ▸ Alternate skins | Screen 540×960, 15 s | V16 |
| O02 | Settings ▸ Energy: the CPU sparkline while Frogg roams, then `swift scripts/bench-energy.swift` result | Screen 960×540, 12 s | V17 |
| O03 | Mosaico pairing: the same 6-digit code on the Mac and the Mosaico | Tripod and macro, both screens, 10 s | V5, V11 |
| O04 | Mosaico simulator trip (`mosaico/sim.sh` plus `PixlzSend send --host 127.0.0.1`) | Screen 960×540, 15 s | V5 (no-hardware fallback; label "simulator") |
| O05 | Encrypted at rest: `sqlite3` on the store DB shows ciphertext blobs, then the same highlight shown decrypted in the app (REHEARSE: find the DB file name first) | Screen 960×540, 10 s | V6 |
| O06 | Owner setup: `uv run pixl-memory wallet init` (prints the **public** key only) → `wallet status` ends READY | Screen 960×540, 12 s; never show the `near` CLI keychain step | V4 |
| O07 | Behaviours: Calm / Roam / Chaos, Slugg's slime trail, Silky on silk, sleeping in the pond | Screen 960×540, 20 s each | V18 |
| O08 | Macro of Mosaico pixels (Frogg idle), exposure −2 EV | Phone macro, 5 s | Thumbnails, V5 |
| O09 | `swift test` / `make -C mosaico/pixl_trip test` summary lines | Screen, 6 s | J2 |

## 3. Shoot order (one session, about 2 h)

1. Mac prep (§1) → E01 → E03 → E04a.
2. Hosts block → E02a → E04b → E02b → undo → E01 again (the "restored" beat).
3. E05 → E06 immediately (same receipt). → H07 → H02 → H03.
4. H04 → H08 → H09 → H01.
5. Lights for physical shots → O03 → E07 (at least 3 takes) → H06 → H10 → O08.
6. Fill in `showcase/takes/<ID>/take-N.mov`. Proposed IDs: `R1` (E01), `R2` (E02), `R3` (E03),
   `R4` (E04), `P1` (E05), `X1` (E06), `T1` (E07) and so on, so `cut.py` can find them.
