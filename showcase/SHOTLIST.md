# Shot list (Pixlz demo video)

Two cuts come out of the same takes, the 9:16 one with either of two tracks:

| Cut | File | Length | For |
|---|---|---|---|
| 9:16 cut | `showcase/out/pixlz-9x16-draft.mp4` | 85 s | X, Reels, Shorts. Part 1 is the phone clip, whole and at real speed (17 s); Part 2 is the demo, cut on the beat of the track, with the narration at a speaking pace and no take sped up. |
| 9:16 cut, other track | `showcase/out/pixlz-9x16-kooma.mp4` | 60 s | An earlier, faster version of the cut on Kooma's "Arch" (licensed through Artlist; 140 beats a minute against 148). Not rendered again since the narration was slowed and the scenes were given more room: `tall-kooma` follows the new layout, but nobody has checked how it falls on that track. |
| 16:9 judges' cut | `showcase/out/pixlz-16x9-judges.mp4` | about 127 s | The submission. The demo only: every scene, at real speed, with what to look for written beside it. |

Takes, rendered cuts and the music (`showcase/takes/`, `showcase/out/*.mp4`, `showcase/music.*`)
are not committed. The narration lines (`showcase/out/vo/`) are, so a cut can be rebuilt without
running the voice model again.

## How the 9:16 cut works

It opens like an ordinary reel and turns into the demo on the track's beat drop.

- **Part 1** is `takes/intro-frogg.mp4` from its first frame to its last: 1.0×, its own sound, no
  cuts, no grade. On top of it: one caption in the style of the Instagram app ("POV: 2026 startup
  founders be like"), subtitles of what is said in the room (both voices, 2 to 4 words at a time,
  same style, lower middle), and the track very low underneath. No brand, no logo, no narration.
- **The handoff.** Over the clip's last 0.9 s the picture pushes in on Frogg on the Mosaico
  display, following him (`intro-track.json` has his position in each frame), until he has the
  size, tilt and place of the app's Frogg in H1's first frame. The display's glare is taken down
  during the push only. A 5-frame dissolve ends on the drop.
- **Part 2** is the demo on a grid of beats counted from the drop: every cut is on a beat, and
  each payoff (tongue snap, coin, card, title, Deny) is placed on one with `hit`. Waits are cut,
  never sped up: every take plays at real speed (H1 alone runs 10 % fast, so that the landing
  falls on its beat). The narration starts about three seconds after the drop, once Frogg has
  landed, and every line ends before the scene it belongs to does.

## Scenes

Showcase mode plays each scene from the app itself: real features, triggered on cue. A scene is a
list of beats. Random choices use one fixed seed, so three takes of a scene match.

| Scene | Title | Beats | Line | Takes |
|---|---|---|---|---|
| H1 | Handoff from the intro clip | the intro ends pushed in on Frogg on the Mosaico display; the app's Frogg takes his place at the same spot and size, then the picture zooms out to the desktop | L0 (16:9 only: in the clip it is said on camera) | 3 |
| F1 | Fly snack | a fly loops, his eyes follow it · tongue snap, gulp, a satisfied blink | L1 | 3 |
| F2 | Frogg's wallet | a coin pops over him · his wallet: account, balance, last receipt · the same payment on the testnet explorer | L2 | 3 |
| F3 | A private brain | a brain with a padlock glows above him · click: the attestation card (verified · TEE · NEAR AI) | L3 | 3 |
| E1 | The Pixlz | friends enter from both sides and drop from the top · "The Pixlz" pops in | L4 | 3 |
| F4 | Pays for its own thinking | he's asked a short question; it's answered privately and paid from his wallet | L5 | 3 |
| M1 | Highlight to memory | highlight a passage · the tongue grabs it, saved to memory | L6 | 3 |
| M2 | Ask, from memory | ask what the article said; the answer comes from memory, with its source | L6 | 3 |
| M3 | Back to the passage | the memories panel pops in · click the highlight: the page opens at the passage, glowing | L6 | 3 |
| W1 | Write in place | select the intro, the Pixl hops up · polish: the text in its card · drag it into the draft, where it takes the original's place | L6b | 2 |
| C1 | Tests, with Slugg | `swift test` in the demo repo; Slugg climbs the Terminal and rounds the corner | L7 | 3 |
| C2 | Guard on a risky command | a Claude Code session asks to run `rm -rf build && npm run deploy` · the Pixl leaps onto the Terminal, alert · Deny, it stomps | L7 | 3 |
| C3 | Reply to a finished session | the session finishes, the Pixl asks "done, anything else?" · a reply typed into its bubble, Claude carries on | L7 | 3 |
| D1 | Any device | a render, not a recording: Mosaico display, Mac and iPhone side by side, the Pixlz hopping across. The iPhone is labelled "coming soon". | L8 | render |
| E2 | Pixlz · powered by NEAR | the Pixlz converge into one lineup · the title, hold | L9 | 3 |

F4, M2 and W1 wait on live inference (20 to 90 s), and each take pays for it with a small
testnet payment (0.00004 to 0.0002 NEAR, from `frogg.pixlz-petz-faucet.testnet`). Both cuts cut
the wait out; the judges' cut says so beside the take, with how long the answer took. A scene
whose take is missing shows as a labelled slate.

The answers differ from take to take, so the cuts pick by what the answer says:

| Scene | 9:16 | 16:9 | Why |
|---|---|---|---|
| F4 | take 2 | take 3 | take 2 is short enough to read in 3 s; take 3 is the funnier answer and the judges' cut has the time for it |
| M2 | take 3 | take 3 | the shortest wait (22 s); the answers are alike |
| W1 | take 1 | take 1 | the cleanest polish. Its "Verified in TEE" bubble touches the frame's edge (fixed since). Take 2 has the bubble whole, but its polish barely changes the text. |

W1 has a third recording that is not a take: the answer took longer than the 90 s the scene
waited then, so the card never showed (the payment was still made). The scenes wait 150 s now;
record them with a limit of 170.

To check the framing of F4, M2 or W1 without paying, add `--rehearse` when starting the app. The
card then shows a stand-in marked "REHEARSAL": nothing is sent and nothing is paid. Never record
a take in this mode.

Narration (`showcase/plan.json`), one voice, ten lines:

| | Line |
|---|---|
| L0 | This is Frogg. |
| L1 | Frogg is simple. He likes flies. |
| L2 | He also has a wallet… |
| L3 | …and a brain powered by private AI on NEAR, so nobody else can see what he's thinking. |
| L4 | And he brought friends, just like him. The Pixlz. |
| L5 | They pay for their own thinking, from their own wallet, never from mine. |
| L6 | They remember what you highlight, and always take you back to the source. |
| L6b | They help you write right where you are. |
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
   UNTIL_DONE=1 showcase/record.sh F4 1 170      # scenes that wait on something live
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
showcase/tts/.venv/bin/python showcase/cut.py tall|tall-kooma|wide|all [--dry]
```

`showcase/edit.json` is the edit: one segment per line, in order. `--dry` prints the timeline
(where each segment and caption lands, and where the track's drop falls) without rendering.

A cut can be written as another one with changes: `"like"` names that cut, `"patch"` changes
its segments (by their `"id"`), and any other key takes the place of the same key. `tall-kooma`
is `tall` with another track (`all` renders `tall` and `wide` only).

A moment in a segment is written as seconds from its start, as `"@x"` (where second x of the take
falls) or as `"bX"` (X beats after the segment's first beat).

| Field | Meaning |
|---|---|
| `src`, `in`, `out` | the take (under `showcase/takes/`) and the seconds used from it |
| `speed`, `hold` | play faster; freeze the last frame for this long |
| `beats` | the segment lasts this many beats of the track (needs `music`); with `in` and `out` the speed follows |
| `hit` | `[second of the take, beat]`: that moment of the take falls on that beat of the segment; `in` and `out` follow |
| `drop` | seconds into this segment where the track's drop falls. Beats are counted from there. |
| `zoom` | `[centre x, centre y, factor]`: punch in |
| `push` | an eased push-in over the segment's last seconds. `[centre x, centre y, factor, seconds]` for a still subject; `{track, to, scale, turn, seconds, deglare}` to follow a moving one to a given place, size and tilt |
| `dissolve` | seconds of cross-fade from the segment before |
| `vo` | `{line, at}`: start a narration line. `slot` high, low or a y, one per phrase if a list; `part: [from, to]` plays only that stretch of the line; `plate` puts a dark patch behind the caption; `captions: false` when the picture already says it |
| `sfx` | `[[moment, name, gain]]`: the app's own sounds, rebuilt from the formulas in `Sfx.swift` (plus `riser`, the swell into the drop) |
| `texts` | `[{lines, style, y, from, to}]`: words on the picture. `ig`: white on black boxes, as typed in the Instagram app; `shadow`: like the captions; `small`: a note |
| `chip` | 9:16 only: the feature label, top left |
| `panel` | 16:9 only: kicker, title, body and proof lines beside the take |
| `audio` | keep the source's own sound: a gain, or `{gain, out, clean, lift}`. `out` fades it out over the last seconds; `clean` is a chain of ffmpeg filters run on it first (rumble and room noise off); `lift: [[from, to, dB], …]` brings up a quiet speaker between those seconds of the take |

For the whole cut: `music` (`src`, the `drop`'s second in the track, `beat` and `bar` lengths,
`bars` in the section that loops (`"loop": false` plays the track on to its own end instead), and levels in dB against the voice: `bed` before the drop,
`full` after it, `under` while a line is spoken), `snap` (move every cut to the nearest beat),
`sfx_gain`.

What the cut adds on top of the takes:

- **Captions**, burned in, 3 to 5 words at a time with the key words in green, timed to the
  voice (`plan.json` has the second each phrase starts; rules in `CAPTIONS.md`). 9:16: bold white
  with a dark edge and shadow, above the bottom 20 %. 16:9: pills at the bottom.
- **Framing**: a scene with a window in it (the memory panel, the draft, the Terminal) is shown
  at the full width of the recording, so nothing the narration talks about is cut off. Only
  scenes where Frogg or a single card is the whole subject are punched in.
- **Proof on screen**: the wallet card and the attestation card are punched in; the explorer
  shot is labelled as a real testnet payment; F3 carries "TEE · NEAR AI private inference"; the
  judges' cut prints the account and network.
- **Sound**: narration levelled line to line, the app's sounds, the track, the mix at −14 LUFS
  with peaks under −1 dB (measured on the encoded file and corrected). The track is `showcase/music.mp3` (not committed; without it the cut
  renders with no music). 9:16: 21 dB under the clip's voices before the drop, a 1.2 s swell
  into it, then full, dropping 18 dB while a line is spoken. The track's full section is 32
  bars and the demo is longer, so it goes round once; the seam is put on a scene change (the
  cut into C3). The clip's voices: rumble and room noise are filtered off, the whole clip is
  raised, and the quieter of the two speakers is lifted another 7 to 10 dB while speaking, so
  both sit at about the narration's level. Nothing in the clip is cut or moved. The Kooma cut uses
  `showcase/music.kooma.mp3`: before its drop the track is quiet and then silent, so under the
  clip it stays below the room's own noise and the drop comes out of near silence, on the same
  frame. 16:9: the track starts on its drop
  and stays under the voice throughout.
- **Speed**: Part 1 is never sped up, cut or zoomed (the push at its end aside). Both
  demos play every take at real speed and cut the waits (in the 9:16 one, H1 runs 10 % fast).
- **The end card** (E2): the title holds for about 9.4 s, the last 6.7 s of it over "Comment if you want one 👇"
  (the take runs out and its last frame holds; the cut ends at 1:29). No
  repository link: it goes in the post.

The intro is `showcase/takes/intro-frogg.mp4`: the phone clip turned upright, 1080 × 1920, 30 fps,
with its first sound track only (`ffmpeg -i clip.mov -map 0:v:0 -map 0:a:0 -c:v libx264 -crf 15
-c:a aac`). `push` reads the picture's stored size, so a rotated clip has to be made upright first.

Fonts: captions use Inter and the labels Silkscreen, from `showcase/fonts/` (`Inter-SemiBold.ttf`,
`Inter-Regular.ttf`, `Silkscreen-Regular.ttf`; both families are OFL, and their licence texts are
beside them). Without those files the cut falls back to Helvetica Neue and Menlo.

Narration: `showcase/narrate.py` (Chatterbox, an open text-to-speech model, run locally; nothing
is sent anywhere). The voice is synthetic. `voice` in `plan.json` sets the read: the reference
recording it copies (`voice-mid.wav`: `voice-slow.wav`, a slowed one that brings the read down
from about 250 words a minute, lowered a semitone and a half for a calmer voice, still above
the three-semitone one that was too deep), how lively it is, and `tempo`, a last change of pace
without a change of pitch (1.25, and a line's own `tempo` where its read came out quick or slow:
the lines come out at about 155 to 200 words a minute). L6 is split
over the Memory shots (its first half on M1, "and always take you back to the source" over M2's
answer into M3) so the narration doesn't go quiet there. A line can carry `say`
(what is spoken when it differs from the caption: "Near" for NEAR, so that it is said as a word,
and "Pixels" for Pixlz) and `seed` (another reading of the same line: L9's is the one whose
"Near" falls, like the end of a sentence). If the hackathon's rules ask for a human voice, record
the eleven lines as `showcase/out/vo/L0.wav … L9.wav` (with `L6b.wav`) and render again: the captions re-time
themselves to the new recordings.

## Before publishing

- [x] W1 stays as it is: no further take. In the take used, the pet's "Verified in TEE" bubble touches the frame's edge; that is cosmetic.
- [x] The hackathon's rules allow an AI voice and a commercial track (confirmed on Nov 12, 2026).
- [ ] The track of `pixlz-9x16-draft.mp4` and of the judges' cut is a commercial release. The hackathon allows it, but a platform may still mute or block the post. `pixlz-9x16-kooma.mp4` uses a track licensed through Artlist, but it is the earlier, faster cut.
- [ ] Watch both cuts once with sound and once without.
- [ ] The video says "iPhone: coming soon". Nothing in it claims iPhone support.
