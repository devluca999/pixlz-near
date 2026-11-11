# Pixlz — Specification v3

The platform-neutral source of truth for how a Pixl behaves. The macOS, iOS and ESP-Mosaico apps (and later Windows) implement this document; where they differ, §12 says how. `DECISIONS.md` says *what* v1 includes; this file says *how it works*. `RESEARCH.md` has the platform APIs and sources.

Status: draft for owner review, 2026-10-15. Items marked **(spec choice)** were not settled in Phase 0; they are my defaults and can be changed here.

Supersedes "SPEC v2" from the earlier WPF codebase, which isn't available yet (see `DECISIONS.md` open items). When it turns up, anything useful gets folded in here.

---

## 0. Ground rules

These override everything else in this document. A behavior that would break one of them doesn't run.

| # | Rule |
|---|---|
| R1 | Effects never touch, move, or delete real files. The Pixl may *read* that a drag is happening and its file URLs, nothing more. |
| R2 | Never block clicks. Only the Pixl's opaque pixels catch the mouse; everything else, FX included, is click-through. |
| R3 | Never cover the window with keyboard focus (§6.4). |
| R4 | Never move the real cursor, windows or files, and never send clicks or keystrokes (D13). |
| R5 | Never steal focus. The Pixl's windows can't become key or main. |
| R6 | macOS: < 1% CPU idle, render only while something changes, load sprite sheets lazily (D7). Checked by `scripts/bench-energy.swift` (measured Nov 2026: 0.1% idle, 0.2% asleep, 1–5% while moving); shown live in Settings ▸ Energy. |
| R7 | iOS: no background work, no polling loops. |
| R8 | Never lose the Pixl. At every moment at least one device holds a complete PetState (§10.5). |

---

## 1. Terms

| Term | Meaning |
|---|---|
| **Pixl** | One pet. v1 has one, Frogg. |
| **Species** | The data that makes a Pixl look and move the way it does: `pixl.json` plus sprites (§3). New species = new data, no code. |
| **Slot** | One of 9 behavior animations, each a 3-frame strip (§4). |
| **Emotion** | A short-lived expression (6 kinds) shown as a pose and FX (§5). |
| **Needs** | Slow-moving values that drive which behavior runs next (§2). |
| **World map** | The surfaces the Pixl can stand on, hang from or must avoid (§7). |
| **Owner device** | The one device that currently has the Pixl (§10). |
| **Device kind** | `mac`, `iphone`, `mosaico` (later `windows`). Advertised in Bonjour TXT; picks the device icon (§10.3). |
| **pt** | Screen points. **apx** = art pixels at 1×. On screen, 1 apx = `scale` pt. |
| **Tick** | One animation step at 12 fps (≈ 83 ms). The Pixl animates "on twos". |

---

## 2. Needs

Three needs, each a number from 0 to 100, where higher means satisfied. **(spec choice:** the brief didn't list them; these three cover rest, play and attention.)

| Need | Drops when | Rises when |
|---|---|---|
| **energy** | Moving, playing, mischief; faster when the device battery is low | Resting (`rest` slot), device charging |
| **fun** | Time passing with nothing happening | Poke, grab/throw, file ride, signature, mischief, travel |
| **affection** | Being ignored | Any direct interaction: poke, grab, double-click, calling it from the other device |

### 2.1 Rates (per hour, real time)

| Need | Passive drop | Activity | Recovery |
|---|---|---|---|
| energy | −4 | moving −10, mischief −6 | resting +30, charging +5 extra |
| fun | −8 | — | poke +3, throw +6, file ride +10, signature +8, mischief +12, travel +15 |
| affection | −6 | — | poke +4, grab +5, double-click +6, call/receive +10 |

- One-off rises are instant and capped at 100.
- Battery: below 20% and not charging, energy's passive drop doubles.
- On iOS, the iPhone's battery feeds energy the same way (D8).

### 2.2 Computed from timestamps

Needs are never ticked on a timer. PetState stores each need's value and `updatedAt`.
- Reading a need: `value(now) = clamp(stored + rate × hours(now − updatedAt), floor, 100)`.
- Rates change only at events (start/stop resting, battery change). At each change, fold the elapsed time into `stored` and reset `updatedAt`.
- **Offline floor:** time while the app wasn't running, or the device was asleep, can't take a need below **20**. A Pixl left alone for a week comes back sleepy, not miserable. **(spec choice)**
- iOS recomputes on `scenePhase == .active` (D8). The widget computes the same way from the shared file.

### 2.3 Mood

The **mood** is derived, not stored: the lowest need decides it.

| Lowest need | Mood | Effect |
|---|---|---|
| all ≥ 60 | content | normal weights |
| energy < 25 | tired | `rest` weight ×4, no mischief |
| fun < 30 | bored | `move`, `signature`, `mischief` weights ×2 |
| affection < 30 | lonely | idles facing the cursor; `curious` emotion more often |

---

## 3. Species data and sprites

### 3.1 Files

```
assets/<pixl>/
  pixl.json            behavior, physics, UI data (§3.2)
  sprites.json         every frame, as indexed-colour rows (the source of truth for art)
  sprites_<skin>.json  optional: a skin whose shape differs (a recolour is a palette in pixl.json)
```

`sprites.json`:

```json
{
  "chars": "0123…", "palette": ["#1b2a1a", …], "transparent": ".",
  "frames": {
    "idle_0": { "w": 68, "h": 48, "rows": ["....0111…", …] },
    "grab_0": { "w": 39, "h": 74, "rows": […], "pin": [19, 2] }
  }
}
```

- **Frame sizes come from `sprites.json`.** Each frame carries its own `w × h` and is trimmed to the art, so sizes differ between frames (Frogg: idle 68×48, a mid-hop frame 91×74, the grab dangle 39×74). Nothing else declares a frame size.
- Frames are named `<slot>_<0..2>` for the 9 slots (anticipation → action → reaction), `emotion_<kind>` for the 6 emotions, plus extras a species uses (`blink`, `pond_<n>`).
- **Placement:** a frame is drawn **bottom-centred** on the Pixl's spot: its bottom row is the feet, centred horizontally. A frame with an `anchor` (soft-body loops) is drawn with that point on the spot instead; `pin` is where a hanging frame is held.
- **Canvas** (for layout and hit areas) = the widest frame's width × the tallest frame's height, computed from the file. Frogg: 91×75.
- One character per pixel; `transparent` marks empty pixels. No partial transparency, no anti-aliasing.
- Frames face **right**; the engine mirrors them for left.
- Shown at whole-number scales only, nearest-neighbor. The scale is a **per-device setting**, never in PetState (§12.2). Mac default **2×**, 3× and 4× in settings.
- Pet only, no props. Props (pond, fly, fake cursor) come from the FX layer (§8).

### 3.2 `pixl.json`

```json
{
  "id": "frogg",
  "name": "Frogg",
  "species": "Red-eyed tree frog",
  "anchor": { "x": 50, "y": 70 },
  "hitbox": { "x": 22, "y": 30, "w": 62, "h": 40 },
  "movement": "hop",
  "sticky": true,
  "aura": "dew",
  "physics": { "gravity": 900, "hopApex": [18, 30], "hopDistance": [40, 90], "walkSpeed": 0 },
  "slots": {
    "idle":      { "holds": [6, 2, 8], "loop": "all" },
    "move":      { "holds": [3, 0, 3], "loop": "none" },
    "rest":      { "holds": [6, 6, 12], "loop": "last" },
    "poke":      { "holds": [2, 4, 6], "loop": "none" },
    "grab":      { "holds": [2, 6, 3], "loop": "middle" },
    "file_ride": { "holds": [3, 3, 6], "loop": "last" },
    "perch":     { "holds": [4, 4, 8], "loop": "last" },
    "signature": { "holds": [4, 2, 8], "loop": "none" },
    "mischief":  { "holds": [6, 12, 4], "loop": "none" }
  },
  "props": { "signature": ["fly"], "mischief": ["pond"] }
}
```

| Field | Meaning |
|---|---|
| `anchor`, `hitbox` | Legacy, from the retired fixed canvas. Frames are placed bottom-centred (§3.1) and mouse hits use opaque pixels, so neither is used for placement. To be removed from `pixl.json` and the validator, together with its `canvas` key. |
| `hitbox` | Rect used for world collisions and keep-out checks (§6.4). Must end at or above `anchor.y`, so a standing Pixl can perch on the focused window's title bar. Mouse hits use the frame's actual opaque pixels. |
| `movement` | `hop` · `walk` · `float` (ignores gravity) · `climb` (walls and threads). |
| `sticky` | Can hang from undersides and cling to window sides (Frogg's toe pads). |
| `physics.gravity` | apx/s². Multiplied by `scale` on screen. |
| `physics.hopApex`, `hopDistance`, `walkSpeed` | In apx (sprite pixels) and apx/s. They scale with the pet, so a hop covers the same number of pet-widths at any scale. |
| `holds` | Ticks each frame stays up. `0` = held for as long as physics needs (the airborne frame of a hop). |
| `loop` | What repeats while the slot stays active: `none`, `all` (frames 0→2), `middle` (frame 1), `last` (frame 2). |
| `scale` | Optional. `scale.<device kind>` (`mosaico`, `iphone`, `mac`) replaces the default scale on that kind of device (§12.2), whole numbers only. The user's device setting overrides both. |

**Validation** (PixlzCore unit test, fails the build):
- Every slot frame (`<slot>_0..2`) and all 6 emotions are present in `sprites.json`.
- Every frame has `h` rows of `w` characters, and every character is in `chars` or is `transparent`.
- `chars` and `palette` have the same length; no frame is fully empty.
- The bottom row of every grounded frame has opaque pixels (the feet).
- File isn't an unfetched Git LFS pointer.

### 3.3 Where the art comes from

Sprites are rendered from the Claude Design C7 source in `design/explorations/c3/` (D6, P6). The render script (`scripts/render-pixls.mjs`) runs the design's engine headlessly, draws only the pet layer, trims each frame to its art and writes `sprites.json`. PixelLab only fills poses the design lacks.

---

## 4. Behavior

### 4.1 Slots

| Slot | Frames (anticipation → action → reaction) | When it runs | Frogg's version |
|---|---|---|---|
| `idle` | settle → beat → hold | Default; between everything | Deadpan stare, slow blink, throat puff |
| `move` | wind-up → travel → land | Going somewhere | Coil, hop, land nose-first |
| `rest` | wind-down → doze → asleep | Low energy, user away | Yawn, doze, slumped asleep with Zz |
| `poke` | hit → look → recover | Clicked | Head squashes, stares up, smug throat puff |
| `grab` | caught → dangle → drop | Dragged by the user | Hangs by one toe pad, sways, splats |
| `file_ride` | eye it → hop on → ride | User drags a file past | Eyes the file, hops on, rides puffed up |
| `perch` | look up → cling → sit | Reaches a window top or the Dock | Looks up, sticks to the edge, sits on top |
| `signature` | lock on → act → savor | Double-click, or autonomous when fun is high | Tongue snaps a fly, satisfied gulp |
| `mischief` | start → mischief → reveal | User idle, mischief level allows (§9) | Dives into a pixel pond, peeks, pops up |

### 4.2 Modes

The Pixl is always in exactly one mode. Slots are what it *shows*; the mode is what it *is doing physically*.

```
            ┌─────────── user drags ───────────┐
            ▼                                   │
 Grounded ◄──► Airborne ◄──── release ──── Held │
   │  ▲          ▲                              │
   │  │          └── platform vanishes ─────────┤
   │  └── lands ─┘                              │
   ├──► Riding (file ride) ── drop ──► Airborne │
   ├──► Hanging (sticky species, ceiling/side)  │
   ├──► Traveling (§10) ──► gone / back         │
   └──► Hidden (fullscreen, hotkey, Pause)      │
```

| Mode | Physics | Slots allowed |
|---|---|---|
| Grounded | On a platform; follows it if the platform moves | idle, rest, poke, signature, mischief, perch (frame 2), move (frames 0, 2) |
| Airborne | Gravity, no control | move (frame 1), grab (frame 2) |
| Held | Follows the cursor | grab (frames 0–1) |
| Riding | Follows the dragged file icon | file_ride |
| Hanging | Attached to an underside or wall | perch (frame 1), rest |
| Traveling | Not in the world | none (§10.4) |
| Hidden | Not drawn, not hit-testable | none |

### 4.3 Picking what to do next

Two layers: **reactions** interrupt, **autonomy** fills the gaps.

**Reaction priority** (higher wins; a lower one never interrupts a higher one):

| Priority | Trigger |
|---|---|
| 1 | Hidden / traveling requested |
| 2 | Grabbed |
| 3 | Platform vanished → fall |
| 4 | Keep-out violated (§6.4) → leave |
| 5 | Poke / double-click |
| 6 | File drag nearby |
| 7 | System events (§6) |
| 8 | Autonomy |

**Autonomy** runs only when the current slot finishes and the Pixl is Grounded. It picks by weighted random:

| Choice | Base weight | Conditions |
|---|---|---|
| idle (repeat) | 6 | always |
| move to a target | 3 | energy ≥ 25 |
| perch (go to the nearest reachable window top) | 2 | a platform is reachable |
| rest | 1 | ×4 when tired; forced when the user has been away ≥ 10 min |
| signature | 1 | fun ≥ 70, cooldown 10 min |
| mischief | — | only through §9 |
| roam (free roam, **v1.1**) | — | only through §10.6 |

- Weights are multiplied by the mood effects (§2.3) and zeroed by any rule that forbids them (typing, focus session, Low Power Mode).
- **Idle budget:** a run of idles lasts 8–40 s before autonomy may pick something else. Most of the Pixl's life is idle, which keeps CPU low (R6).
- **Move targets:** a random point on the current platform, or a platform reachable by one hop (§7.3). Hops chain until the target is reached.
- A seeded RNG drives all random choices, so tests can replay a run.

### 4.4 Animation timing

- The animation clock is 12 fps. A frame is shown for `holds[i]` ticks.
- **Idle never redraws faster than it has to:** after the last frame of a loop, the next redraw is scheduled for the next frame change, not for every tick. A held frame costs zero CPU.
- During motion (Airborne, Held, Riding, moving platform), position updates run on the display link; frame changes still happen on ticks.

### 4.5 Physics

- Units are apx (sprite pixels), converted to pt or screen pixels by the device's `scale` (§12.2). Gravity, hop apex and distance, and walk/crawl speed are all apx values from `pixl.json`, so motion scales with the pet. Frogg: 900 apx/s².
- **Hop:** pick a landing point; choose apex height from `hopApex`; solve the parabola. Frame 0 plays (3 ticks), frame 1 holds while airborne, frame 2 on landing. Dust FX on landing.
- **Fall:** starts at rest, terminal velocity 1500 apx/s. Lands on the first platform below; if none, lands on the screen ground (§7.1).
- **Throw:** release velocity = cursor velocity over the last 100 ms, capped at 3000 pt/s. Bounces off screen edges and the menu bar with restitution 0.4; ground friction stops it within about 1 s.
- **Float** species ignore gravity and drift to targets; **climb** species can walk up walls. (Not in v1; listed so the code doesn't assume `hop`.)

---

## 5. Emotions

| Emotion | Triggered by | Lasts | FX |
|---|---|---|---|
| happy | Petted after being lonely, travel arrival, charging starts | 4 s | heart |
| annoyed | 3 pokes within 4 s, travel declined/timed out, woken by a poke | 5 s | sweat |
| sleepy | Energy < 25, local time 23:00–06:00, battery < 20% | while true | Zz |
| startled | Platform vanished, grabbed while resting, sudden window under it | 2 s | bang |
| curious | New window appears nearby, file drag starts, peer device found | 3 s | question mark |
| proud | After signature, focus session completed | 4 s | sparkle |

- An emotion doesn't interrupt the running slot. Its FX shows above the head for the whole duration, and if the Pixl is in `idle`, the emotion pose replaces the idle frames until it ends. **(spec choice)**
- Only one emotion at a time; a new one replaces the old.
- `sleepy` is a state, not a burst: while its conditions hold, `rest` is weighted up and the Zz FX shows during rest.
- The current emotion is saved in PetState so the widget can show it.

---

## 6. Reactions to the system (macOS)

The iPhone app has none of these (D8). Each reaction lists its trigger and what the Pixl does.

### 6.1 Windows

| Event | Reaction |
|---|---|
| Window the Pixl stands on **moves** | The Pixl moves with it, tracking the drag live |
| Window the Pixl stands on **closes, minimizes or hides** | `startled`, falls (mode Airborne) |
| Window appears under the Pixl | If it overlaps the hitbox: hop off to the nearest legal spot; `curious` |
| Window resized so the Pixl's spot is gone | Falls |
| App goes **fullscreen** on the Pixl's display | Puff, Hidden; returns with a puff when fullscreen ends (D2) |

### 6.2 User activity

| Event | Reaction |
|---|---|
| No mouse/keyboard input for 2 min | Mischief becomes possible (§9) |
| No input for the Sleepiness threshold (Night owl 10 / Normal 5 / Sleepy 2 min) | Drowsy, then asleep (see **Sleep** below) |
| Your first input after being away | Wakes on its own after a few seconds (but not before 90 s of sleep) with a stretch and yawn |
| **Heavy typing** (≥ 3 key-downs/s sustained 5 s) | Goes quiet: no autonomous move, signature or mischief until 10 s after typing stops. Stays out of the typing window (§6.4) |
| File drag starts | `curious`; file ride if the drag passes within 24 pt (§6.3) |
| File dropped onto the **Trash** in the Dock | **Trash signature:** the Pixl, if within one hop of the Dock, plays `signature` aimed at the Trash (Frogg's tongue "eats" it, visually only). Otherwise `proud` (D2) |

**Sleep** (PixlzCore `SleepCycle`, tested):

- **Stages:** drowsy (~20 s, easy to rouse) → asleep (Frogg under in its pond, Boo upright and floating, the others in their rest pose) → deep after ~10 min.
- **Naps:** besides sleeping when you're away, it takes short naps every ~45–90 min of activity. These are paced by the energy need (§2) and scaled by Sleepiness.
- **Typing:** while you type, it rests quietly and never falls asleep.
- **Minimum sleep:** ~90 s, unless it's deliberately woken.
- **Wake rules:**
  - a cursor passing close: at most a stir;
  - the mouse resting on it for 2 s: one eye opens, then closes again. With "Let me wake them by hovering" on, a longer hover wakes it;
  - a poke: startled, then grumpy, then awake;
  - double-click or right-click: it wakes and the menu opens;
  - grabbed: it stays asleep while dangling;
  - window switches and notifications: at most an ear twitch;
  - ⌃⌥Space or Focus ending: it wakes.
- **No hopping while asleep.** After waking, it catches up to the active window.

Heavy typing comes from the opt-in Input Monitoring count (D12), which never reads key identities. Without it, "typing" = the focused UI element is a text field (AX check on focus change).

### 6.3 File ride

1. A drag session with file URLs starts (`.drag` pasteboard change, R1 read-only).
2. If the cursor passes within 24 pt of the Pixl's hitbox, it plays `file_ride` frames 0–1 and attaches above the cursor, feet on the dragged icon.
3. While riding, it follows the cursor (offset so it never covers the hotspot).
4. On drop, it plays frame 2, detaches and falls (Airborne).
5. If the drag is cancelled (Esc), same as drop.
- Ride at most one drag in a row per 30 s, so it doesn't feel clingy.

### 6.4 Keep-out: the focused window

- **Keep-out rect:** the frame of the window with keyboard focus.
- The Pixl's hitbox may not intersect it, except a 2 pt band at its top edge (so perching on the focused window's title bar is allowed).
- On focus change, the world map rebuilds. If the Pixl is now inside, it leaves: hop to the nearest legal spot within 1 s.
- If no legal spot is reachable (the window covers the whole screen but isn't fullscreen), the Pixl fades to 25% opacity and becomes fully click-through until a spot opens. **(spec choice)**
- Autonomy never picks a move target inside the keep-out rect.

### 6.5 Power and display

| Event | Reaction |
|---|---|
| Battery < 20%, not charging | `sleepy`, energy drops faster |
| Charger connected | `happy` |
| Low Power Mode on | No autonomous move or mischief; idle only; FX limited to landing dust |
| Displays sleep / screen locked | All animation stops; clocks pause |
| Display added/removed/rearranged | World map rebuilds; if the Pixl's display is gone, it drops in on the main display (D11) |

### 6.6 Focus guardian (D12)

- Started from the option bubbles (More ▸ Focus): 25 min on the Mac build.
- During a session the Pixl sits still on the Dock or the bottom of the screen; no mischief, no autonomous moves.
- If the user activates an app on their "distracting" list, the Pixl plays a gentle nudge (`poke` frames 1–2 toward that window, `curious`). At most once per 2 min. It never blocks or closes anything.
- On completion: `proud`, fun +10.

---


### 6.7 Browser bridge (Chrome extension ↔ app)

`extension ⇄ (native messaging) ⇄ pixl-native-host ⇄ (Unix socket) ⇄ app`, and `host → (HTTP + token) → memory service`.

- **Host.** `pixl-native-host` ships inside the app bundle. At launch the app registers it (`dev.pixlz.pixl_memory.json`) in the `NativeMessagingHosts` folder of each installed Chromium browser, allowing only the extension's pinned ID (`chmeigilhkkegiaabjlcidbkgahemceh`, from the public `key` in its manifest).
- **No token in the extension.** The host reads the service token from the service's data folder and forwards only an allowlist: `GET /health`, `GET|POST /highlights`, `DELETE /highlights/<id>`, `POST /ask`, `POST /polish`, `GET /wallet`. Everything else is refused before it leaves the host. Without the app, the extension falls back to a pasted token.
- **App socket.** `~/Library/Application Support/PixlMemory/bridge.sock`, mode 0600, JSON lines. The app accepts a connection only from the `pixl-native-host` next to its own executable (peer PID → executable path). The app may send only `get_selection` and `replace_selection`; the host drops anything else.
- **Polish in web pages.** Accessibility first (form fields; Chromium's web tree is switched on when a Chromium browser becomes active). Where it can't see the selection (rich editors, Google Docs), the app asks the extension (0.4 s timeout). **Replace** in a browser goes through the extension first: `insertText`, so editors see a normal, undoable input event; only if the selection (or a unique match) still holds the original. Google Docs: its own typing iframe (copy event to read, `insertText` to write). Otherwise Accessibility, then copy.
- **Recall.** Ask sends the highlights that share words with the question (ranked on the Mac; if none match, the three newest go as context without being cited). The matching ones come back as sources with their text-fragment backlinks; clicking one reopens the page at the passage, highlighted.

## 7. World map

### 7.1 Surfaces

| Kind | Source | Use |
|---|---|---|
| **Ground** | Bottom edge of each display, except where the Dock is (there the Dock top is the floor) | Always present; the floor of last resort |
| **Dock top** | The Dock's top edge, from `frame` vs `visibleFrame` | Platform |
| **Window tops** | Top edge of every normal (layer 0) on-screen window | Platforms |
| **Window sides** | Left/right edges of windows | Cling surfaces (sticky/climb species) |
| **Menu bar underside** | The menu bar's bottom edge | Hang surface for sticky species (Frogg clings under it with toe pads). **(spec choice:** "perch on the menu bar" = hang below it; standing *on* it would put the Pixl off-screen.) |
| **Keep-out** | Focused window frame (§6.4) | Must not overlap |
| **Desktop icons** | Finder icon rects, if available (UNVERIFIED) | Small platforms; otherwise skipped |

A window top counts as a platform only where it isn't covered by a window above it. Each platform is a set of visible horizontal intervals.

### 7.2 Building it

- Rebuilt only on events: window created/moved/resized/destroyed/minimized, app activated, Space changed, screen parameters changed. Never on a timer.
- Rebuilds are **debounced by 250 ms** and must finish in **< 50 ms** (D7).
- While the user drags the window the Pixl stands on, only that one platform is updated, at the drag rate.
- Without Accessibility permission: ground, Dock and menu bar only ("ground-only mode", D12).

### 7.3 Reachability

A platform is reachable from the current spot by one hop if:
- it is within `hopDistance.max` horizontally and rises at most `hopDistance.max` (a Pixl jumps as high as it jumps far);
- it is on the same display;
- the whole arc keeps the hitbox below the menu bar and out of the keep-out rect (§6.4).

Other windows don't block a hop: the Pixl is drawn above every window, so passing in front of one looks right.

**Between displays** (`HopRoute.plan(…displays:)`): plan the arc in global coordinates and keep the Pixl's head and feet inside the union of both displays' visible frames (they may differ in size, scale and alignment). If no arc does, hop to the shared edge, **pop** through (shrink and fade out, puff, grow back in at the matching edge of the other display), and hop on.

**Switching Spaces:** the Pixl's panels are on every Space and stationary, so during a swipe it stays where it is. On the switch it plays a short "whoa" (the startled frame with a springy wobble) and hops from where it stands to the new perch. Watcher-driven moves are ignored from the first sign of a switch (an app activating with no window on this Space) until the new perch is computed. The drop from under the menu bar is only for when there is no previous position: launch, unhide, leaving fullscreen. A new target retargets the current motion; two motions never run at once.

**Squash and stretch** come from damped springs (`DampedSpring`, PixlzCore): a crouch before take-off, stretch while rising, a slight stretch while falling, and on landing a squash that springs back with one or two overshoots (0.75 → 1.1 → 0.97 → 1.0, about 0.35 s), feet planted, with a dust puff. Positions are computed from elapsed time on the display-synced clock; if the system pauses display frames (Frogg off screen or occluded), a watchdog keeps the motion going.

Sticky species can also reach a window top by climbing its side: hop to the side, cling (perch frame 1), climb, sit (perch frame 2). This needs the side to be visible from the top corner down to within one hop of the Pixl.

---

## 8. FX layer

- A separate, always click-through layer above the Pixl. It draws particles, props and the aura.
- Pixel-art FX at the Pixl's scale, nearest-neighbor, 12 fps.
- At most **24 live particles**; the oldest are dropped. The layer draws nothing (and costs nothing) when no effect is active.

| Effect | Used for |
|---|---|
| dust | Landing, skids |
| puff | Appear/disappear, hide/show, travel |
| speed lines | Throws, fast hops |
| Zz | Sleeping |
| bang, sweat, sparkle, heart, question mark | Emotions (§5) |
| splash, ripple | Pond mischief |
| aura | Per species (`pixl.json` `aura`; Frogg: dew ripples). Shows only during idle, off in Chill mode |

**Props** (drawn, never real):

| Prop | Used by |
|---|---|
| pond | Frogg `mischief` (the Pixl clips into it) |
| fly | Frogg `signature` |
| fake cursor | Mischief "tongue snatches the cursor" (D13) |
| ghost icon | Chaos mischief "drag a ghost copy of an icon" (D13) |

---

## 9. Mischief (D13)

- Purely visual. Off during focus sessions, fullscreen, heavy typing and Low Power Mode.
- Only after ≥ 2 min with no mouse/keyboard input.

| Level | Frequency |
|---|---|
| Chill | Never on its own; only via the mini menu or a poke while idle |
| **Normal** (default) | One per 20–40 min |
| Chaos | One per 5–10 min |

**Frogg's mischief set:**

| Act | Levels | What happens |
|---|---|---|
| Pond | Normal, Chaos | The `mischief` slot: dives into a drawn pond, eyes peek, pops up when the user returns |
| Tongue snatch | Normal, Chaos | A **fake cursor** appears near Frogg; the tongue snatches it; it reappears a moment later. The real cursor isn't moved |
| Title-bar nap | Normal, Chaos | Hops onto a background window's title bar and naps |
| Icon lick | Normal, Chaos | Licks a desktop icon; sparkle |
| Dock hop | Chaos | Hops along the Dock's top edge over the icons (no clicks) |
| Ghost drag | Chaos | Drags a *drawn copy* of a desktop icon a few pt and lets it snap back |

The moment the user moves the mouse or types, mischief ends with its reveal frame and the Pixl returns to idle.

**On touch devices (iPhone stage, Mosaico)** there's no cursor, no Dock and no desktop icons, so those acts don't port. Each species lists a touch version or none. "User idle" means no touch for 2 min.

| Mac act | Frogg on touch |
|---|---|
| Pond | Same (drawn pond on the stage) |
| Tongue snatch | Snatches a drawn fly from the spot last tapped |
| Title-bar nap | none |
| Icon lick, Dock hop, Ghost drag | none |

---

## 10. State, storage and travel

### 10.1 PetState

One JSON document per Pixl. The same schema on every platform.

```json
{
  "schema": 1,
  "petId": "6F0E2C1A-…",
  "species": "frogg",
  "name": "Frogg",
  "createdAt": "2026-10-15T20:00:00Z",
  "owner": { "deviceId": "B1C2-…", "deviceName": "Luca's MacBook Air" },
  "epoch": 7,
  "needs": {
    "energy":    { "value": 82, "updatedAt": "2026-10-15T21:10:00Z", "rate": -4 },
    "fun":       { "value": 55, "updatedAt": "2026-10-15T21:10:00Z", "rate": -8 },
    "affection": { "value": 70, "updatedAt": "2026-10-15T21:10:00Z", "rate": -6 }
  },
  "emotion": { "kind": "happy", "until": "2026-10-15T21:10:04Z" },
  "stats": { "pokes": 41, "rides": 3, "trips": 2, "signatures": 9 },
  "savedAt": "2026-10-15T21:10:00Z"
}
```

- **Not** in PetState: device settings (size/scale, hotkeys, mischief level, distracting apps, edge map). Those stay on each device.
- `epoch` = D9's version number. It increases by 1 on every ownership change and never otherwise.
- **Canonical encoding** (how every writer encodes PetState): keys sorted, UTF-8, no whitespace, dates as `yyyy-MM-ddTHH:mm:ss.SSSZ`. Envelopes use the same encoder.
- **Checksum:** SHA-256 of the **raw bytes of `payload.state` exactly as they appear in the `transfer` frame**, from its opening `{` to its closing `}`. The sender hashes the bytes it wrote; every receiver (Mac, iPhone, Mosaico) hashes the bytes it received. **No platform re-encodes before hashing**, so the check can't fail because two encoders disagree, and a receiver needs no JSON encoder to verify it. The `ack` carries this checksum.
- A device without a full JSON encoder (the Mosaico) sends the Pixl on by editing the received bytes: it changes `epoch`, `owner`, `savedAt` and `stats.trips` in place, and inserts or removes `policy` at its sorted position, so the result is still canonical.

**Optional fields (added 2026-11-10, D18):**

```json
"policy": { "locked": true, "freeRoam": true }
```

| Field | Meaning |
|---|---|
| `policy.locked` | The Pixl stays on its owner device: calls are declined with `locked`, and no offer can start (§10.6). |
| `policy.freeRoam` | The owner device may start trips on its own (§10.6, v1.1). |

- **Compatibility rules for every new PetState field:**
  - It is optional. A file without it decodes, and absent means the default (`false`, off).
  - Writers **omit** a field that holds its default (`policy` disappears when both are off). So a Pixl that never used a new feature encodes to exactly the same bytes as before, and its checksum doesn't change.
  - `schema` stays `1`. It goes up only for a change an old reader can't safely ignore.
  - The canonical encoding rules above don't change.
  - A new field **raises the protocol version** (`proto`, §10.3). A device never accepts a Pixl from a newer protocol than its own: it declines the offer with `needsUpdate` before anything is transferred, so it can never drop a field it doesn't know.

### 10.2 PetStore

```swift
protocol PetStore {
    func load() throws -> StoredPet?          // nil = never had a pet on this device
    func save(_ pet: StoredPet) throws         // atomic: write temp file, then rename
    var changes: AsyncStream<StoredPet> { get } // for the widget / UI
}

enum StoredPet {
    case owned(PetState)                       // this device has the Pixl
    case pendingArrival(PetState)              // received, waiting for commit (§10.4)
    case away(petId: UUID, epoch: Int, ownerName: String, tombstone: PetState?)
}
```

- Apple: one file `pet.json` in the App Group container, so the iOS widget can read it.
- A device shows the Pixl only when its record is `.owned`.
- `.away` drives the "Frogg is on your Mac" card (D8). Its `tombstone` keeps the last full state for 7 days as the safety copy (§10.5).

### 10.3 Transport

**Built (Mac, 2026-11-08):** `PixlTravel` (macos/PixlMemory).
- **Bonjour.** `_pixlz._tcp`, advertised with a TXT record of device id and name. Every device browses, so nearby devices show up like AirDrop targets. The app declares `NSBonjourServices` and asks for Local Network once; until that's allowed, More ▸ Send to device says "allow Local Network".
- **Trips.** PixlzCore's `TravelNode` runs over TCP with length-prefixed envelopes. `TripRunner` persists every `.saved` before any later `.send`, so at least one complete copy of the Pixl always exists.
- **Consent.** The first offer from an unknown device asks the user ("Catch Kiti from Laptop?"). After a yes, that device is trusted.
- **What travels.** Only PetState: name, species, needs, stats. Never memory, highlights or wallet keys.
- **UI:**
  - a "Send to <device>" bubble when one is nearby;
  - leaving: an exit hop with a puff;
  - arriving: the Pixl springs out of the menu-bar icon, in its own skin;
  - the menu-bar icon offers "Call <name> back" while away;
  - Ask answers "what screens are available?" and "jump to <device or display>" on the Mac itself, with no model involved.
- **Tested** by two transports in one process over real Bonjour.
- **Next:** code pairing, then devices on other networks (Windows, a phone on cellular, a Mosaico away from home). Both are planned through an iroh spike (`IOS-PLAN.md`): peers dialled by public key, direct or relayed, with a `P2PTransport` beside the Bonjour one. The 6-digit code + TLS-PSK design below is the fallback if iroh doesn't work out.
- **TXT record** (all devices): `id`, `name`, `kind` (`mac` | `iphone` | `mosaico`), `proto` (protocol version, §10.3 below), and from v1.1 `use` (`active` | `idle`) and `focus` (`1` during a Focus session) for free roam (§10.6). The Mosaico advertises `kind=mosaico` and browses only for `kind=mac`.

```swift
protocol PetTransport {
    var peers: AsyncStream<[Peer]> { get }         // devices currently reachable
    func send(_ envelope: Envelope, to peer: Peer) async throws
    var incoming: AsyncStream<(Envelope, Peer)> { get }
}
```

- v1: `LocalBonjourTransport` over Network.framework (D9, P1). The Mac always listens on `_pixlz._tcp`; the iPhone browses only while its app is in the foreground. Peer-to-peer Wi-Fi enabled.
- Mosaico: ESP-IDF mDNS advertising `_pixlz._tcp` (TXT `kind=mosaico`) and a TCP socket using the same Framing. Only while plugged in (Wi-Fi is off on battery, §12.1).
- Later: `RelayTransport` over WebSocket to a Pixlz server, for Windows.
- **Pairing:** the first connection shows a 6-digit code on one device and the user types it on the other. Mac ↔ iPhone: the Mac shows it, typed on the iPhone. Mac ↔ Mosaico (no keyboard): the **Mosaico** shows it, typed on the Mac. Both derive a TLS pre-shared key (HKDF-SHA256, both device ids sorted into the salt, so the direction doesn't matter) and store it (Keychain; NVS on the Mosaico). Unpaired peers are ignored.
- **Spike only (Mosaico, not mergeable):** plain TCP, no pairing. The first frame each way is `{"hello":{"deviceId":…,"deviceName":…}}`, then envelopes.
- **Framing:** length-prefixed JSON messages.
- **Protocol version (`proto`):** an integer, now **2** (absent = 1, the builds before 2026-11-10). It goes up whenever PetState gains a field or a message changes meaning. Proto 2 adds `policy`, `decline(locked)`, `decline(needsUpdate)` and the raw-bytes checksum.
  - Every `offer` carries the sender's `proto`. A receiver whose own `proto` is lower declines with **`needsUpdate`**; nothing is transferred and the Pixl stays. A newer receiver accepts an older offer.
  - Devices also advertise `proto` in TXT, so Send to can show a peer with a lower version greyed out as "needs update" before offering. That also covers proto-1 builds, which predate `needsUpdate` and can't decline.
  - After a `needsUpdate` decline, the sender shows the notice "<device> needs an update to host <name>." instead of the `annoyed` shrug.

**Envelope:**

```json
{ "v": 1, "msgId": "…", "petId": "…", "from": "<deviceId>", "to": "<deviceId>",
  "type": "offer", "epoch": 7, "payload": { }, "sentAt": "…" }
```

| Type | From → to | Payload |
|---|---|---|
| `call` | non-owner → owner | — ("Call Frogg") |
| `offer` | owner → target | species, name (so the target can check it can host it), `proto` |
| `accept` / `decline` | target → owner, or owner → caller for a `call` | decline reason: `busy`, `hasOtherPet`, `unsupportedSpecies`, `userDeclined`, `locked` (the Pixl is locked to its device, §10.6), `needsUpdate` (the offer's `proto` is newer than the receiver's) |
| `transfer` | owner → target | full PetState with `epoch + 1` and the new owner |
| `ack` | target → owner | checksum of the received `payload.state` bytes (§10.1) |
| `commit` | owner → target | — |
| `commitAck` | target → owner | — |
| `abort` | either | reason |
| `status` / `statusReply` | either | ask/answer "what epoch do you hold for this pet, and is it committed?" |

### 10.4 The trip

**Sender (current owner):**

1. User picks "Send to <device>", drags the Pixl into the portal hole (D9), or flings it off a Mosaico edge (§11.1). Or the other device sent `call`. Or free roam picked a target (§10.6, v1.1). If `policy.locked` is set, nothing starts (and a `call` gets `decline(locked)`).
2. Send `offer`. The Pixl plays `idle` with a "…" bubble; it hasn't left.
3. On `accept`: send `transfer` (state with `epoch + 1`, owner = target).
4. On `ack` with a matching checksum: save `.away(epoch + 1, tombstone: full state)`, send `commit`, **then** play the exit: crouch, look at the camera, big hop off the nearest screen edge (or into the portal), shrink, speed lines, dust (~1 s).
5. On `commitAck`: done. The tombstone stays for 7 days anyway.

**Receiver (target):**

1. On `offer`: if the offer's `proto` is newer than its own, `decline(needsUpdate)`. Otherwise accept automatically if it can host the Pixl (its app is in the foreground on iOS, no other pet, species known); otherwise `decline`.
2. On `transfer`: hash the raw `payload.state` bytes, decode and verify, save `.pendingArrival(state)`, send `ack(checksum)`.
3. On `commit`: save `.owned(state)`, send `commitAck`, play the entrance: iPhone — drop from the top edge, squash, puff, `happy`; Mac — drop onto the window or ground under the cursor (~1 s).

**Failure and timeout (8 s from `offer` to `ack`):**

| Situation | Outcome |
|---|---|
| `decline`, or no `ack` within 8 s | Sender sends `abort`; the Pixl plays an `annoyed` shrug and stays. Receiver discards any pending state |
| Transfer > 1.5 s | A tiny silhouette bobs in the menu bar / iPhone status area (D9) |
| Sender crashes before `commit` | On restart it's still `.owned` (it never saved `.away`). The receiver keeps its pending state hidden and resolves it with `status` (next row) |
| Receiver has `.pendingArrival` but never got `commit` (crash, disconnect) | It keeps the pending state, doesn't show the Pixl, and sends `status` after its 10 s timeout and on the next connection. If the sender says committed at that epoch → promote to `.owned`. If the sender says it still owns it and isn't mid-trip → discard |
| Sender committed, receiver never confirmed | Sender is `.away` with a tombstone. On the next connection it sends `status`. Receiver pending → the sender re-sends `commit`. Receiver has neither owned nor pending state → the sender restores from the tombstone with `epoch + 2` |

### 10.5 Never losing the Pixl

- At every point in the trip, at least one device holds the complete state: the sender holds it as `.owned` until it has the receiver's `ack`, then as a tombstone for 7 days.
- **Conflicts:** if two devices both hold `.owned` for the same pet, the higher `epoch` wins and the other drops to `.away`. Equal epochs can't arise from the protocol; if they do (manual file copy), the lexicographically smaller `deviceId` wins.
- The Pixl is only drawn by a device whose record is `.owned`.

### 10.6 Send to, Lock, Free roam (D18)

**Send to ▸** (Mac option bubbles and menu bar, iPhone, Mosaico):
- Lists every paired device with its icon from `kind` (Mac, iPhone, Mosaico).
- Reachable now → a normal row; picking it starts the trip (§10.4).
- Paired but not reachable (asleep, unplugged Mosaico, iPhone app closed, other Wi-Fi) → greyed out, "wake it to send". Not pickable.
- Reachable but advertising a lower `proto` than this device → greyed out, "needs update".
- No paired devices → one row, "Pair a device…".
- While `policy.locked` is set, the whole menu is greyed out with "unlock to send".

**Lock to this device** (a toggle next to Send to; on the Mosaico on the "more" page):
- Sets `policy.locked` in PetState and saves. Because it lives in PetState, a tombstone restore or a conflict win (§10.5) keeps it.
- While locked: no `offer` can start (user, fling, portal or free roam), and an incoming `call` gets `decline(locked)`. The calling device shows "<name> is locked to <device>." and greys out Call until the next `status` says otherwise.
- Unlocking removes the field (writers omit defaults, §10.1).

**Free roam** (`policy.freeRoam`, **ships in v1.1**, D18):
- A toggle in Pixl settings. Off by default. Turning it on is a user action on the owner device.
- The owner device's autonomy (§4.3) may pick "roam" when **all** of these hold:
  - not locked; no trip in progress; the Pixl is Grounded and idle;
  - no Focus session on this device; the user hasn't touched or clicked the Pixl in the last 5 min;
  - energy ≥ 25 (a tired Pixl stays put);
  - the **cooldown** has passed: at least 45 min since the Pixl last arrived on this device (kept in device settings, not PetState), and at least 2 h after a failed roam attempt (doubling up to 8 h);
  - a Mosaico owner is plugged in.
- **Allowed targets:** paired, reachable now, and advertising `use=active` (someone used it in the last 2 min: input on a Mac, the app in the foreground on an iPhone, a touch on a plugged-in Mosaico) and not `focus=1`. Never a device in Focus, asleep or idle.
- Picks one target at random among the allowed ones, then runs the normal trip (§10.4); the receiver treats it like any offer. The exit goes toward the edge mapped to that device when there is one.
- A failed roam (decline, timeout) is **silent**: no `annoyed` shrug, since the user didn't ask for it. It only starts the failure cooldown.
- The user's Lock always wins over free roam, and any manual Send to resets the cooldown.

---

## 11. Controls

### 11.1 Mouse and touch

| Action | macOS | iPhone stage | Mosaico |
|---|---|---|---|
| **Poke** | Click (press + release < 250 ms, < 6 pt movement). A single click only pokes | Tap | Tap on the Pixl |
| **Option bubbles** (§11.2) | Double-click, right-click, or press and hold 450 ms. The poke from the first click is cut short | Double-tap or long-press | Double-tap anywhere (small-screen menu, §11.2) |
| **Grab / throw** | Drag (after 6 pt movement), release to throw. Starting a drag pops any open bubbles | Drag, release to toss; bounces off screen edges | Same as iPhone, except a **fling off an edge** sends the Pixl to the device on that side (below) |
| **Signature** | An idle quirk (now and then while perched), or More ▸ "Do a trick" | Same | Same |

**Fling to travel (Mosaico):** a release faster than ~1200 px/s whose path crosses an edge mapped to a reachable device starts a trip to it (§10.4). The Pixl clings half off that edge with a "…" bubble until the `ack`, then hops out. No mapped device, unreachable, locked or declined → it bounces back off the edge as a normal toss, with the `annoyed` shrug when the trip itself failed. The **edge map** is a device setting: each of the four edges → a paired device; by default every edge → the Mac the Pixl last came from. (The spike instead maps a single tap on the Pixl to "go home", fired only after the double-tap window (300 ms) expires with no second tap, so a double-tap never sends him away.)

- Poke reaction: `poke` slot, fun +3, affection +4. 3 pokes in 4 s → `annoyed`. A poke while asleep → `startled`, then `annoyed`.
- Mouse hits only on opaque pixels of the current frame (R2).
- 6 pt (not 4) so trackpad jitter during a slow click isn't read as a drag.

### 11.2 Option bubbles (design C8 "Menus & Bubbles")

44 pt round bubbles puff out of the Pixl's head along an arc (32° apart; radius 56 + 16 × scale), one by one: 45 ms stagger, 320 ms spring (0.2 → 1.14 → 0.95 → 1.02 → 1). While open, the Pixl shows its `ui.menuFace` (pixl.json).

| Slot | Shows | Opens |
|---|---|---|
| 1 | **Polish** when text is selected, otherwise **Ask** | Polish: the instruction list. Ask: the Ask card (attested TEE answer, paid from the Pixl's wallet) |
| 2 | **Memory** | Recent highlights with backlinks, searchable |
| 3 | **Wallet** (sub-label: balance) | Balance, cap and recent receipts; "Set up" if the sub-account doesn't exist |
| 4 | **Send to ▸** | Shown once a device is paired. The device list of §10.6 (asleep ones greyed out) and Lock to this Mac |
| last | **More** | The mini list: Ask ⌘K · Memory · Wallet · Send to device · Focus · Do a trick · Pixl settings ⌃⌥P · Hide for now ⌃⌥H |

- **Close:** Esc, a click anywhere else, or a click on the Pixl → reverse stagger (30 ms, 170 ms). Starting a drag → all bubbles pop at once (130 ms, with a 220 ms dither ring).
- **States:** hover lifts 3 pt and grows ×1.1 over 120 ms; press shrinks ×0.9 (glass) or ×0.96 and sinks 2 pt (paper); keyboard focus draws a 2 pt accent ring and shows the label pill.
- **Keyboard:** ←/↑ previous, →/↓/Tab next, Return/Enter/Space choose, Esc close, ⌘K Ask. Focus returns to the app you were in when the menu closes.
- **Accessibility:** the arc is a group "Frogg's menu"; every bubble and list row is a button/menu item with a spoken label ("Wallet, 0.48 NEAR").
- **Placement:** above the head by default; flips left, right or below to stay fully on the visible screen and never cover the caret or the selection being polished (read through Accessibility). The arc follows the Pixl if it moves while open.
- **Surface:** one material for every overlay (bubbles, label pills, the More list, cards, the speech bubble, the polish result, the mini menu): Liquid Glass (`NSGlassEffectView`) on macOS 26+, the paper fallback (paper fill, 2 pt ink ring, hard 3 pt ink shadow) on older systems or with Reduce Transparency.
- **Legibility:** no screen capture (D12), so text surfaces use a backdrop dim that keeps text ≥ 4.5:1 over *any* backdrop (worst case black…white), choosing the light or dark variant from the system appearance. Icon-only bubbles keep the design fill (outlined icons).
- **Per-pet data:** accent, menu face, signature name, Ask placeholder and personality live in `pixl.json` → `ui`, not code.
- **Send to** (slot 4 and More) opens the device list of §10.6, with **Lock to this Mac** below it.

**Small-screen menu (Mosaico, and any screen too small for the arc):**
- Double-tap shows **up to 4 bubbles**, one at the middle of each screen edge, each at least 110 px (about 9 mm). Nothing else is tappable while it's open except the Pixl (closes it).
- Page 1: **Send to** · **Answers** (the latest Ask results the Mac pushed; read-only) · **Memory** (recent highlights, read-only) · **more**.
- Page 2 ("more"): **Lock to this Mosaico** · **Do a trick** · **Settings** (size, brightness, edge map, pairing) · **back**.
- Lists (Send to, Answers) show at most 3 rows plus "back" or "more" per screen.
- Closes after 8 s without a touch (no static UI on the AMOLED, §12.1).

### 11.3 macOS menu bar item

Open menu · Send to ▸ (device list with icons, asleep ones greyed, §10.6) · Lock to this Mac · Mischief ▸ (Chill / Normal / Chaos) · Size ▸ (2× / 3× / 4×) · Pause · Reset position · Permissions… · Quit.

### 11.4 Hotkeys (macOS, D14)

| Default | Action |
|---|---|
| ⌃⌥P | Mini menu (toggle; Esc closes) |
| ⌃⌥Space | Chat stub: the Pixl turns to the user; speech bubble "Chat is coming soon 🐸" |
| ⌃⌥H | Hide / show (puff out and in) |

All rebindable in the mini menu.

### 11.5 Mini menu

Opened from More ▸ Pixl settings or ⌃⌥P, on the shared surface (§11.2).

Name field · Pixl card (Frogg only in v1) · Behavior toggles (file ride, perch, mischief level) · Size · FX (particles & aura on/off) · Hotkey chips · Distracting apps list (for Focus) · "Talk to Frogg" prompt, disabled, "coming soon". Styling follows the design tokens (`design/tokens/colors.css`): ink `#1B2A1A`, paper `#FFFBF2`, accent `#7CD93A`, 3 pt ink borders, hard 8 pt offset shadow.

### 11.6 Text: voice, status and notices

A Pixl's text goes through exactly one of three channels. Code: `PixlVoice.swift` (Kit). Tests: `TextChannelTests`.

1. **Voice.** Speech bubbles hold only the species' own sounds.
   - The sounds are defined per Pixl in `pixl.json` `ui.sounds`, by event: greet, happy, curious, annoyed, startled, sleepy, sad, idle.
   - Examples: Frogg says "ribbit", "rrbt?", "RIBBIT!". Kiti says "meow", "mrrp?", "hss". Mochi says "wan!", "awoo". Silky says "tk tk". Boo says "…" or "boo".
   - Lines are picked so the same one is never said twice in a row (`VoicePicker`).
   - The bubble sits on the shared surface (§11.2), with its tail toward the head, in bold monospace.
   - Boo is shy (`ui.shy`): its sounds float by its head without a bubble.
   - The app's only speech bubble is `speak(_ event)`. A test checks that no other code builds one.
2. **Status.** Third-person narration of what the Pixl is doing right now, for example "Frogg is practicing a croak.", "Kiti is judging you.", "Silky is climbing the walls.".
   - It comes from the current activity: its own `ui.status` lines when idle; otherwise asleep, a Roam outing, a game, thinking, visiting another device, Focus, or resizing.
   - No pronouns: status lines are written so they never need one ("taking a dip in the pond").
   - It shows in the Settings header, in a tooltip after the mouse rests on the Pixl for 4.5 s (a click starts the wait over, so it never covers a double-click to the menu), and in the menu bar (the first row and the icon's tooltip).
   - It never appears in a speech bubble.
3. **Notices.** Every functional message goes on a small notice card in the Menus & Bubbles material (§11.2), with a pixel icon (info, done, warning) and plain English.
   - Examples: selection needed, Accessibility, service stopped, wallet changes, Focus, hand-off, travel, errors.
   - A notice can be led by one voice line (for example "ribbit!" above "Replaced your text.").
   - The full catalogue is `Notice` (Kit). A test checks that every notice is a plain sentence with no emoji.

---

## 12. Platform mapping

| Concept | macOS (v1) | iOS (v1) | ESP-Mosaico (v1) | Windows (later) |
|---|---|---|---|---|
| Pet surface | Borderless non-activating `NSPanel`, `.screenSaver` level, joins all Spaces; CALayer per sprite | SpriteKit scene in the app ("stage") | Full-screen 480×480 stage, Raylib Lite, black background | Layered WPF window, per-pixel hit test |
| Click-through | Toggle `ignoresMouseEvents` by alpha under the cursor | n/a (in-app) | n/a (whole screen is the stage) | `WS_EX_TRANSPARENT` toggling |
| World map | CGWindowList + AX observers, `NSScreen.visibleFrame` | Stage edges only | Four screen edges: floor, walls, ceiling (§12.3) | `EnumWindows` + WinEvent hooks |
| System reactions | §6, all | none | power only: unplugged → sleep (§12.1) | §6 equivalents |
| Typing signal | Opt-in listen-only event tap (count only); AX fallback | n/a | n/a | Raw input count |
| Hotkeys | Carbon `RegisterEventHotKey` | n/a | n/a (touch only) | `RegisterHotKey` |
| PetStore | App Group container file (shared with nothing on Mac) | App Group container file, read by the widget | NVS blob, committed atomically | `%LOCALAPPDATA%\Pixlz\pet.json` |
| Transport | `LocalBonjourTransport` (listens) | `LocalBonjourTransport` (browses, foreground only) | mDNS `_pixlz._tcp` TXT `kind=mosaico` + TCP Framing, plugged in only | `RelayTransport` |
| AI (Ask, Polish, memory) | Local service + NEAR AI (D15) | via the Mac (later) | none on device: shows results from the Mac | later |
| Pairing | Shows the code to an iPhone; types the Mosaico's code | Types the Mac's code | Shows the code | later |
| Rendering clock | Ticks only on frame changes; display link only during motion | SpriteKit at 60 fps, frames stepped at 12 fps | Redraws only on frame changes and during motion | Composition target only during motion |

Sources and caveats for each macOS/iOS row: `RESEARCH.md` §1–§3.

### 12.1 ESP-Mosaico (D17)

The Mosaico is a travel device like the iPhone: the Pixl can live there, and it goes there and back with the normal trip (§10.4).

| Constraint | What the app does |
|---|---|
| **2.16" 480×480 square AMOLED, burn-in** | Black background (unlit pixels). No fixed chrome: bubbles, notices and lists time out (≤ 8 s). The Pixl never stays on one spot: after each idle loop it drifts a few px (±8 px, random), and every few minutes it hops somewhere else on the stage. Dims to 50% after 2 min without a touch, 10% after 10 min; while asleep the screen shows only the dim Pixl and Zz, which also drift. **(spec choice:** drift and screen-off timings.) |
| **Touch only** | No hover, right-click or keyboard. Targets ≥ ~110 px (≈ 9 mm), so **≤ 4 options per screen** (§11.2). Hover-based behaviors (wake by hovering, status tooltip) don't exist here. |
| **Small battery** | Unplugged → the Pixl plays `rest` and falls asleep, **Wi-Fi turns off**, the screen goes to sleep level, then off after 2 min. A touch shows the sleeping Pixl for a few seconds. It can't send, receive or be called; Macs show it greyed out, "wake it to send". Plugged in again → Wi-Fi back, the Pixl wakes with a stretch. State is safe in flash throughout (R8). |
| **Same Wi-Fi as an awake Mac** | Its only travel partner is a Mac on the same network, until the cloud relay exists. No iPhone ↔ Mosaico trips in v1. |
| **No on-device AI** | Ask, Polish and memory run on the Mac (or the cloud later). The Mosaico only shows results the Mac sends it (Answers, Memory pages). The feed format is not specified yet (§15). |
| **Pairing reversed** | The Mosaico shows the 6-digit code; the user types it on the Mac (§10.3). |
| **Mischief** | Cursor-based acts don't port; touch versions per species (§9). |
| **Time** | Needs are computed from timestamps (§2.2), so the Mosaico needs a wall clock: SNTP while on Wi-Fi, kept by the RTC across sleep. Without a valid clock it leaves needs and `updatedAt` untouched. |
| **Wi-Fi credentials** | Read from the shared NVS partition `sysmeta`, namespace `shared` (`wifi_ssid`, `wifi_password`) set up by the Mosaico's own setup; Kconfig as fallback. |

**Building:** ESP-IDF pinned at `7b9cc1ac79f865983f59bb8ff3ff43eb74ff1dbe`, target `esp32s31`, only through the vendor's `python mosaico.py` (validate in `game sim` before flashing). Code in `mosaico/`: the trip protocol as a host-testable C module, the game, and a Mac-side `PixlzSend` tool for the spike.

### 12.2 Pixl size per device

- Size is a **per-device scale** in that device's settings, never in PetState, so the Pixl can be a different size on each device.
- Whole numbers only, nearest-neighbor, everywhere (§3.1).
- **Default on stage devices** (the Mosaico and the iPhone stage, where the screen is the Pixl's whole world): the screen is about **4 pet-widths across**:
  `scale = max(1, round(screenWidth / (4 × w of idle_0)))`, with `screenWidth` in the units the Pixl is drawn in (pt on the iPhone, pixels on the Mosaico).
- **The Mac** keeps its fixed default of **2×** (D14), with 2×/3×/4× in settings. The rule above would make Frogg 5× (about 340 pt) on a 1440-pt screen.
- `scale.<device kind>` in `pixl.json` replaces the computed default (§3.2). The user's setting (default ± 1) overrides both.
- Physics is in apx and scales with the pet (§4.5).

Mosaico (480 px wide) defaults:

| Pixl | idle_0 width | Scale | On screen |
|---|---|---|---|
| Frogg | 68 | **2×** | 136 px |
| Kiti | 45 | 3× | 135 px |
| Mochi | 39 | 3× | 117 px |
| Boo | 32 | 4× | 128 px |
| Slugg | 64 | 2× | 128 px |
| Silky | 77 | 2× | 154 px |

### 12.3 Mosaico world map

All four screen edges are surfaces: the **floor** (bottom), two **walls** (left, right) and the **ceiling** (top). A Pixl uses the ones its `movement` and `sticky` allow:

| Pixl | Movement | How it uses the edges |
|---|---|---|
| Frogg | hop, sticky | Hops along the floor. Sticky, so it can hop to a wall and cling (`perch` frame 1), and hang from the ceiling the way it hangs under the menu bar on the Mac (§7.1). |
| Slugg | crawl (`walk`), sticky | Crawls the **full perimeter**: floor, up a wall, upside down along the ceiling, down the other wall. Rounds each corner through its corner frames, and leaves its slime trail. |
| Silky | hop, sticky (climber) | Climbs the walls and walks the ceiling; drops from the ceiling on a thread. |
| Kiti | hop | Floor only. Jumps toward a wall and lands back on the floor. |
| Mochi | hop | Floor only. |
| Boo | float | Ignores surfaces; drifts anywhere inside the four edges, which only bound it. |

- Moving along an edge never starts a trip. Only a fling released past an edge does (§11.1).
- Burn-in (§12.1): the slime trail fades within a few seconds, and a Pixl clinging to a wall or ceiling still drifts and moves on like one on the floor.
- A Pixl that loses its surface (grabbed off a wall, Frogg's grip times out) falls to the floor (§4.5).

---

## 13. Performance (D7)

| | Budget | How the design meets it |
|---|---|---|
| macOS idle | < 1% CPU over 60 s | No per-tick work during held frames (§4.4); no polling (§7.2) |
| macOS moving | < 5% CPU | Display link only while Airborne/Held/Riding |
| World-map rebuild | < 50 ms, 250 ms debounce | §7.2 |
| Memory | < 80 MB | Lazy per-slot sprite loading; unused slots evicted after 60 s |
| Launch → visible | < 1 s | Load `idle` + `pixl.json` first, everything else lazily |
| Poke → first frame | < 1 tick | Mouse-down handled on the main thread; `poke` strip preloaded with `idle` |
| iOS stage | 60 fps at < 10% CPU | SpriteKit, small textures |
| iOS background | zero work | Recompute on foreground (§2.2) |
| Widget | ≥ 30 min between refreshes | Timeline built from timestamps |
| Mosaico | Redraw only on frame changes and motion; dim at 2 min and 10 min; Wi-Fi off on battery | §12.1 |

---

## 14. Testing

PixlzCore holds everything testable without a screen:
- **Needs math:** decay, recovery, offline floor, rate changes folding correctly.
- **Behavior picker:** with a fixed seed and a scripted world, a sequence of choices matches a snapshot.
- **Physics:** hop parabolas land where planned; fall lands on the first platform below.
- **World map:** given window rects, the visible platform intervals and reachability are correct; keep-out exclusion works.
- **Travel:** a two-node simulation with an in-memory transport covers every row of §10.4's failure table, including crashes at each step (process killed between any two messages). The invariant "at least one complete copy, at most one `.owned`" is checked after every step.
- **Manifests:** §3.2 validation, including any `scale.<kind>` being a whole number ≥ 1 whose canvas fits the device's screen (480×480 on the Mosaico).
- **Scale rule:** `max(1, round(screenWidth / (4 × idle width)))` gives the §12.2 table for every roster Pixl.
- **PetState compatibility:** an old file (no `policy`) decodes and re-encodes to the same bytes; the checksum is computed over raw frame bytes on both sides; an offer with a newer `proto` gets `decline(needsUpdate)` and nothing is transferred; `policy` is omitted when both flags are off; a locked Pixl declines `call` with `locked` and refuses to start an offer.
- **Free roam (v1.1):** the eligibility rules of §10.6 as a pure function, table-tested.
- **Mosaico protocol module** (C, `mosaico/pixl_trip`): host tests for framing, the hello frame, the receiver and sender halves of the trip, the checksum over raw `payload.state` bytes (matching what PixlzCore's sender computes), and that splicing `epoch`, `owner`, `savedAt` and `stats.trips` keeps the bytes equal to PixlzCore's canonical encoding (fixtures generated by PixlzCore).

Platform tests (manual each milestone): Instruments CPU/energy check against §13; permission onboarding on a fresh user account.

---

## 15. Open questions for the owner

1. Are energy / fun / affection the right needs (§2)? Is the offline floor of 20 right?
2. Menu bar perch = hang below the menu bar (§7.1). OK?
3. When the Pixl can't escape the focused window, fade to 25% (§6.4). OK, or hide fully?
4. Emotion pose only during idle, FX always (§5). OK?
5. Mosaico burn-in timings (§12.1): screen off 2 min after unplugging, ±8 px drift. OK? (Dimming settled: 50% at 2 min, 10% at 10 min.)
6. How the Mac pushes Ask answers and highlights to the Mosaico for display (a new envelope type, or a separate feed connection)? Needed before the Answers and Memory pages.
7. Pairing with a 6-digit code feeding TLS-PSK directly lets someone who recorded the handshake try all million codes offline. Use the code to authenticate a fresh key exchange instead (a PAKE such as SPAKE2). **Blocks M3 (iPhone travel) and the Mosaico merge** (D9).
