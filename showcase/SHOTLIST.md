# Shot list (Pixlz demo video)

Two cuts come out of the same takes:

| Cut | File | Length | For |
|---|---|---|---|
| 9:16 rough cut | `showcase/out/pixlz-9x16-rough.mp4` | about 59 s | X, Reels, Shorts. The first 4.5 s are the intro clip. |
| 16:9 judges' cut | `showcase/out/pixlz-16x9-judges.mp4` | about 134 s | The submission. Every scene, at real speed, with what to look for written beside it. |

Takes and rendered cuts are not committed (`showcase/takes/`, `showcase/out/*.mp4`). The narration
lines (`showcase/out/vo/`) are, so a cut can be rebuilt without running the voice model again.

## Scenes

Showcase mode plays each scene from the app itself: real features, triggered on cue. A scene is a
list of beats. Random choices use one fixed seed, so three takes of a scene match.

| Scene | Title | Beats | Line | Takes |
|---|---|---|---|---|
| H1 | Handoff from the intro clip | zoom out from where the intro leaves Frogg to the desktop | L0 | 3 |
| F1 | Fly snack | a fly loops, his eyes follow it · tongue snap, gulp, a satisfied blink | L1 | 3 |
| F2 | Frogg's wallet | a coin pops over him · his wallet: account, balance, last receipt · the same payment on the testnet explorer | L2 | 3 |
| F3 | A private brain | a brain with a padlock glows above him · click: the attestation card (verified · TEE · NEAR AI) | L3 | 3 |
| E1 | The Pixlz | friends enter from both sides and drop from the top · "The Pixlz" pops in | L4 | 3 |
| F4 | Pays for its own thinking | he's asked a short question; it's answered privately and paid from his wallet | L5 | 1 |
| M1 | Highlight to memory | highlight a passage · the tongue grabs it, saved to memory | L6 | 3 |
| M2 | Ask, from memory | ask what the article said; the answer comes from memory, with its source | L6 | 1 |
| M3 | Back to the passage | the memories panel pops in · click the highlight: the page opens at the passage, glowing | L6 | 3 |
| W1 | Write in place | select the intro, the Pixl hops up · polish: the text in its card · drag it into the draft, where it takes the original's place | L6 | 1 |
| C1 | Tests, with Slugg | `swift test` in the demo repo; Slugg climbs the Terminal and rounds the corner | L7 | 3 |
| C2 | Guard on a risky command | a Claude Code session asks to run `rm -rf build && npm run deploy` · the Pixl leaps onto the Terminal, alert · Deny, it stomps | L7 | 3 |
| C3 | Reply to a finished session | the session finishes, the Pixl asks "done, anything else?" · a reply typed into its bubble, Claude carries on | L7 | 3 |
| D1 | Any device | a render, not a recording: Mosaico display, Mac and iPhone side by side, the Pixlz hopping across. The iPhone is labelled "coming soon". | L8 | render |
| E2 | Pixlz · powered by NEAR | the Pixlz converge into one lineup · the title, hold | L9 | 3 |

F4, M2 and W1 wait on live inference (20 to 60 s), and each take pays for it with a small
testnet payment (about 0.0001 NEAR, from `frogg.pixlz-petz-faucet.testnet`). That is why they
have one take each. Both cuts cut the wait out; the judges' cut says so beside the take, with
how long the answer took. A scene whose take is missing shows as a labelled slate.

To check the framing of W1 without paying, add `--rehearse` when starting the app. The polish
beat then shows a stand-in card marked "REHEARSAL": nothing is sent and nothing is paid. Never
record a take in this mode.

Narration (`showcase/plan.json`), one voice, ten lines:

| | Line |
|---|---|
| L0 | This is Frogg. |
| L1 | Frogg is simple. He likes flies. |
| L2 | He also has a wallet… |
| L3 | …and a brain powered by private AI on NEAR, so nobody else can see what he's thinking. |
| L4 | And he brought friends, just like him. The Pixlz. |
| L5 | They pay for their own thinking, from their own wallet, never from mine. |
| L6 | They remember what you highlight, and help you write right where you are. |
| L7 | They keep an eye on your coding agents. |
| L8 | And they can be on any device, anywhere, anytime. |
| L9 | Pixlz. Powered by NEAR. |

## Recording a take

1. Build and start the app in Showcase mode:

   ```sh
   scripts/build-mac-app.sh
   open "$HOME/Applications/Pixl Memory.app" --args --debug --showcase
   ```

   Showcase mode is a recording aid. It is only on with `--showcase` (or `PIXL_SHOWCASE=1`) and
   never in a normal run. It covers the desktop with a plain dark desk, so nothing private is in
   a take. Scenes that need a window (browser, Terminal, the draft) use the throwaway pages and
   repo in `showcase/demo/`.

2. Record. The app needs Accessibility; the terminal running the script needs Screen Recording.

   ```sh
   showcase/record.sh <scene> <take> <seconds> [x,y,w,h]
   UNTIL_DONE=1 showcase/record.sh F4 1 120      # scenes that wait on something live
   ```

   The script sets the scene up, starts it, and records a fixed 540 × 960 pt region (1080 × 1920
   px, 60 fps) with the cursor. It refuses to run while the screen is locked and keeps the display
   awake for the take. Takes land in `showcase/takes/<scene>/take-<n>.mov`.

3. By hand instead: ⌃⌥K next beat · ⌃⌥⇧K previous · ⌃⌥R restart the scene · Esc reset.
   From a terminal: `PixlMemory showcase <select|run|next|prev|restart|reset> <scene>`.

4. When recording is over, `PixlMemory showcase reset` puts the Pixl's size and the Agents
   settings back.

`showcase/d1.py` draws the D1 render from the Pixls' own sprite frames (`assets/<pet>/sprites.json`).

## Cutting

```sh
showcase/tts/.venv/bin/python showcase/cut.py tall|wide|all [--dry]
```

`showcase/edit.json` is the edit: one segment per line, in order. `--dry` prints the timeline
(where each segment and caption lands) without rendering.

| Field | Meaning |
|---|---|
| `src`, `in`, `out` | the take (under `showcase/takes/`) and the seconds used from it |
| `speed`, `hold` | play faster; freeze the last frame for this long |
| `zoom` | `[centre x, centre y, factor]`: punch in on a card |
| `vo` | `{line, at}`: start a narration line this far into the segment (`slot` high/low, `captions: false` when the picture already says it) |
| `sfx` | `[[seconds, name, gain]]`: the app's own sounds, rebuilt from the formulas in `Sfx.swift` |
| `chip` | 9:16 only: the feature label, top left |
| `panel` | 16:9 only: kicker, title, body and proof lines beside the take |
| `audio` | keep the source's own sound at this gain (the intro clip) |

What the cut adds on top of the takes:

- **Captions**, burned in, one phrase at a time with the key words in green, timed to the voice
  (rules and sources in `CAPTIONS.md`). They take the HIGH or LOW slot so they never cover a pet,
  and stay inside the platforms' safe area.
- **The hook** over the intro (9:16): "A desktop pet with its own NEAR wallet", inside the first
  three seconds.
- **Proof on screen**: the wallet card and the attestation card are punched in; the explorer
  shot is labelled as a real testnet payment; the judges' cut prints the account and network.
- **Sound**: narration levelled line to line, the app's sounds, the mix at −14 LUFS with peaks
  under −1 dB. A music bed is optional: put `showcase/music.wav` (or `.mp3`, `.m4a`) there and
  it is ducked 22 dB under the voice.
- **Speed**: the judges' cut plays every take at real speed; waits are cut, not sped up. The 9:16
  cut speeds up only the intro clip's first 14 s.

Fonts: captions use Inter and the labels Silkscreen when `showcase/fonts/Inter-SemiBold.ttf`,
`Inter-Regular.ttf` and `Silkscreen-Regular.ttf` are present (both are OFL). Without them the cut
falls back to Helvetica Neue and Menlo.

Narration: `showcase/narrate.py` (Chatterbox, an open text-to-speech model, run locally; nothing
is sent anywhere). The voice is synthetic. If the hackathon's rules ask for a human voice, record
the ten lines as `showcase/out/vo/L0.wav … L9.wav` and render again: the captions re-time
themselves to the new recordings.

## Before publishing

- [ ] Optional: two more takes each of F4, M2 and W1 (each take is one small testnet payment).
- [ ] Check the hackathon's video rules: length, AI voice, sped-up footage.
- [ ] Watch both cuts once with sound and once without.
- [ ] The video says "iPhone: coming soon". Nothing in it claims iPhone support.
