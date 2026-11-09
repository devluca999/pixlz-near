# Demo script

Run the app with `scripts/build-mac-app.sh --debug` (debug log: `~/Library/Logs/PixlMemory/debug.log`).

## Ask does things (no model, nothing sent)

Press ⌃⌥Space, then try:

| Type | What happens |
|---|---|
| `open Spotify` | Opens the app, or the web player in a new tab |
| `go to en.wikipedia.org/wiki/Glass_frog and save the part about their transparent skin` | Opens the page, finds the paragraph, saves it with a link that opens the page at that paragraph |
| `save the part about reproduction` | Same, on the page in front |
| `what did I save about glass frogs` | Your saves about it, with their links |
| `tell me a joke` · `what's new with NEAR AI this week?` | A private NEAR AI answer with web search, and its sources |
| `famous Chicago landmarks` | An answer with pictures (small squares; click one to enlarge) |

## Games (C16)

Open the option bubbles (click the Pixl), then **Play**. Each Pixl has its own game; the others are
listed dimmed ("switch Pixl"). With Behavior set to Chaos, a Pixl now and then invites you
(2 s, ignore it and nothing happens; click the Pixl to accept).

Typing, or clicking in another app, ends a game at once ("…another time"), with no score.
Best scores per Pixl show in the menu bar menu.

### Slugg · Inevitable (60 s; 90 s on Chaos)

1. Choose Slugg (More ▸ Change Pixl), then Play ▸ Inevitable.
2. He crawls toward your cursor (turning before he moves). Keep moving.
3. Click him: into his shell for ~3 s ("bonk!"), then he comes out a little faster.
4. Park the cursor in the menu bar or a corner: he waits at the edge below it.
5. Let him reach the cursor: "squelch!", a crown, and a nap. Last the round: "fine. FINE."

### Frogg · Snap (60 s)

1. Choose Frogg, then Play ▸ Snap. A fly rides your cursor.
2. Before every strike: throat puff, eyes narrow, body coils. Move the cursor when you see it.
3. The tongue hits where the fly was when the tell ended. Dodges count up.
4. After 20 s some tells are feints: the strike comes 400 ms later.
5. Caught: "*gulp*". Last the round: a sulk, and the fly buzzes off.

With `PIXL_DEBUG=1` (the `--debug` build), the games draw their hitboxes and a timer line
(phase, time, tell length, gap, feint chance) at the top left.

### Tuning (PixlzCore `Games.swift`)

| Too easy? | Too hard? |
|---|---|
| Slugg: raise `crawlStart`/`crawlEnd` (14 → 22 px/s), `closeBoost` (0.20), `bonkSpeedUp` (0.08); lower `shellStart`/`shellEnd` (3.0 → 2.2 s) | Slugg: lower `turnStart`/`turnEnd` (45 → 70 °/s), raise `turnBeforeMove` (35°), `cooldown` (1.5 s) |
| Frogg: shorten `tell` (0.70 → 0.28 s per 10 s), `gapStart`/`gapEnd` (2.2 → 1.1 s); raise `feint` (up to 30 %), `hitRadius` (10 px) | Frogg: lengthen `tell`, `recovery` (0.60 → 0.35 s); lower `hitRadius`; raise `feintsFrom` (20 s) |
