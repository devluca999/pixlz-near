# Pixlz — v1 Decisions

Outcome of the Phase 0 grilling (2026-10-15), amended by the Phase 1 research (P1–P6 in `RESEARCH.md` §5, approved 2026-10-15). This file is the record of what v1 is and isn't.
Changes to any decision here should be made by editing this file in the same commit as the change.

---

## D1. Audience
- **v1 is a personal dogfood build for the owner only.**
- macOS: local builds signed with the owner's free Personal Team "Apple Development" certificate, not ad-hoc. A stable signature keeps the Accessibility, Input Monitoring and Local Network grants across rebuilds (TN3127). *(P5)*
- iOS: sideloaded to the owner's iPhone with a free Apple account (7-day provisioning, re-run from Xcode).
- No notarization, Developer ID, TestFlight, or installer in v1. Architecture must not preclude adding them later.

## D2. v1 scope and milestones

| Milestone | Platform | Done when |
|---|---|---|
| **M1** | macOS | Frogg on the desktop: idles, walks, perches on window edges and menu bar/Dock, falls when a window closes. Poke, grab, file ride. Menu bar icon. First-run permissions onboarding. Meets idle CPU budget (D7). |
| **M2** | iOS | Frogg on an in-app stage, idling and reacting to taps (D8). |
| **M3** | Travel | Frogg goes Mac → iPhone → Mac over the local network (D9) with exit/entrance animations; PetState intact. |
| **v1 done** | All | M1–M3 + remaining system reactions (fullscreen hide, Trash signature, typing avoidance, battery, focus guardian) + hotkey mini menu + one small home-screen widget. |

Order: M1 → M2 → M3 → remaining v1 items.

## D3. Launch roster
Order: **Frogg → Cat → Ghost → Spider.** Only Frogg ships in v1.

| # | Pixl | Movement | What it tests in the spec |
|---|---|---|---|
| 1 | Frogg | hop | baseline |
| 2 | Cat | walk | `move` is not hop-specific |
| 3 | Ghost (art in progress) | float, ignores gravity | physics is per-species |
| 4 | Spider | climb / hang | perch/climb on walls and threads |

## D4. Platforms and toolchain
- **macOS 15.0+**, **iOS 18.0+**.
- Owner's devices: Mac on macOS 15 Sequoia (may upgrade to macOS 26 Tahoe; the floor stays at 15). iPhone 11 on iOS 18.7.8 (no Dynamic Island; has U1).
- Build with the latest Xcode that runs on the host Mac (Xcode 26.x on macOS 15.6+), Swift 6 language mode.
- Windows (WPF) later, from the platform-neutral SPEC.md.

## D5. Repository
- Name **`pixlz`**, **private**, on the owner's **personal GitHub account**.
- License: **proprietary, all rights reserved.** `LICENSE` reads "Copyright © 2026 <owner name from GitHub profile>. All rights reserved." Third-party licenses are tracked separately.
- Local path: `~/pixlz`.

## D6. Art pipeline handoff
- **Behavior slots:** one PNG strip per slot with 3 frames side by side (anticipation → action → reaction), transparent background, native resolution.
  - `assets/<pixl>/<slot>.png`, e.g. `assets/frogg/poke.png`
  - Slots: `idle, move, rest, poke, grab, file_ride, perch, signature, mischief`
- **Emotions:** front view, `assets/<pixl>/emotions/<emotion>.png`. Emotions: `happy, annoyed, sleepy, startled, curious, proud`.
- **Canvas:** fixed per-frame canvas **per Pixl**, declared in `pixl.json`. All frames of one Pixl share it. Frogg: **104×76 px**, from the Claude Design source. *(P2)*
- **Scaling:** whole-number multiples only, nearest-neighbor (no smoothing). User-selectable 2×/3×/4×.
- **Facing:** behavior slots drawn facing right; the engine mirrors them for left.
- **Manifest** `assets/<pixl>/pixl.json`: species, frame size, fps per slot, foot anchor (ground-contact pixel), hitbox, aura preset, movement type (`hop | walk | float | climb`).
- **Validation:** a PixlzCore unit test checks every manifest (all slots present, 3 frames, correct dimensions). A missing frame fails the build.
- **Source:** sprites are rendered headlessly from the Claude Design C7 source (`design/explorations/c3/`), pet only, without props. The app draws props (folder, window, pond) itself. PixelLab fills gaps only (new poses, cleanup). Rendered PNGs are committed via Git LFS. *(P6)*
- A new Pixl = new data only; no code changes.

## D7. Performance budgets

**macOS** (measured on the owner's Mac with Instruments / Activity Monitor):

| State | Budget |
|---|---|
| Idle (sitting/breathing) | **< 1% CPU** averaged over 60 s; no display link; timer only on 12 fps frame changes |
| Moving / FX | **< 5% CPU**; display link runs only during motion |
| World-map rebuild | **< 50 ms**; event-driven, 250 ms debounce; never polled |
| Memory | **< 80 MB** resident; lazy per-slot sprite loading, eviction of unused slots |
| Energy Impact | **"Low"** when idle; timers with tolerance, App Nap–friendly |
| Launch → Pixl visible | **< 1 s** |
| Poke → first frame | **< 1 frame (~83 ms)** |

**iOS:**
- Stage holds 60 fps at **< 10% CPU**.
- **Zero** background work beyond system-scheduled widget timelines; networking only while the app is in the foreground.
- Widget timeline refresh **≥ 30 min** apart.

Each milestone includes an Instruments check against these numbers.

## D8. iPhone app in v1
1. **Full home:** the Pixl can live on the iPhone indefinitely. Needs are **recalculated from timestamps** on foreground; no background ticking.
2. **Stage interactions:** tap = poke, double-tap = signature, long-press = radial menu (Chat/Mic greyed "coming soon"), drag = grab with toss and bounce off screen edges. iPhone battery feeds energy.
3. **Pixl on the Mac:** the stage is empty except a "Frogg is on your Mac" card with a **Call Frogg** button (asks the Mac to send Frogg over).
4. **Sending back:** explicit **Send to Mac** in the radial menu. Swipe-to-fling is v1.1.
5. **Widget:** one **small home-screen widget**: current emotion pose, name, which device it's on; tap opens the app.
6. **Not on iOS:** system-event reactions, world map, notifications, background work.

## D9. Travel
- **Transport:** Network.framework + Bonjour (`NWListener` / `NWBrowser` / `NWConnection`, peer-to-peer enabled, service `_pixlz._tcp`), behind a `PetTransport` protocol. Multipeer Connectivity is deprecated (TN3213) and has an iOS 26 regression. *(P1)*
- **Constraint:** iOS only keeps the connection while the app is in the foreground. Opening the iPhone app is part of the ritual.
- **Trigger Mac → iPhone:** when the iPhone app is open, the Mac discovers it (~2 s) and shows **"Send to <device name>"** in the radial menu and menu bar menu. **Bonus:** drag Frogg onto a **portal hole** that fades in at the bottom-right corner while a peer is nearby.
- **Trigger iPhone → Mac:** Send to Mac, or Call Frogg from the iPhone. The Mac app is always running, so the Mac can always receive.
- **Animations:**
  - Exit (~1 s): crouch + look at camera → big hop off the nearest screen edge (or into the portal), shrink, speed-line smear, dust puff.
  - In transit: faint "…" bubble where Frogg left. If transfer > 1.5 s, a tiny silhouette bobs in the menu bar / iPhone status area.
  - Entrance (~1 s): iPhone — drop from the top edge, squash + puff, `happy` emotion. Mac — drop onto the window or ground under the cursor.
- **Never lose Frogg:**
  - Protocol: offer → accept → transfer PetState → receiver saves and confirms → sender plays exit and deletes its copy → receiver plays entrance.
  - The sender keeps the real copy until the receiver confirms. The exit plays only after confirmation, so it can't happen and then fail.
  - **Timeout 8 s** or decline → `annoyed` shrug, the Pixl stays.
  - Every move increments a **version number**. On conflict (both devices think they own it), the higher version wins; the other device drops its copy.
- **Transport-agnostic interface;** local network in v1, cloud later for Windows.

## D10. Out of scope for v1
- AI/LLM calls, accounts, cloud sync, payments, analytics
- Windows build, Android
- Multiple simultaneous pets per device
- App Store submission, notarization, TestFlight, Developer ID
- Cat, Ghost, Spider (Frogg only)
- Live Activities / Dynamic Island, lock-screen widgets, extra widgets
- Alarm wake reaction
- Swipe-to-fling travel; Nearby Interaction direction-aware travel
- Chat and Mic functionality (UI shown greyed out; `IBrain` stub and speech bubble exist, unused)
- Mirroring system Focus modes
- Pixls roaming across displays on their own
- Localization (English only), auto-update, crash reporting
- Sound effects

## D11. Multiple displays
- Supported. The Pixl lives on **one display at a time**: the display with the menu bar by default, or whichever display the user drags it to.
- It doesn't walk across display edges on its own (v1.1).

## D12. Permissions and focus
- **Accessibility: required.** Used for window frames, Finder desktop icon positions, and AX observers. If denied: "ground only" mode (menu bar, Dock, screen bottom).
- **Input Monitoring: optional, off until the user opts in.** Used only to count key-downs per second for "heavy typing." **Never reads which keys were pressed.** Nothing logged or stored. Fallback when declined: an AX check of the frontmost window with a focused text field keeps the Pixl off the typing window.
- **Screen Recording: never requested.** No screen capture.
- **Onboarding:** one required prompt (Accessibility), one optional prompt (Input Monitoring) with plain-language explanation.
- **Focus session = Pixlz's own focus timer** (radial menu → Focus: 25/50 min or custom).
  - Guardian behavior: sits still on the menu bar/Dock; gentle nudge animation if the user switches to an app on a user-defined "distracting" list.
  - Never blocks apps.

## D13. Mischief
**Purely visual; never blocks input.** Off during focus sessions, during fullscreen, and while typing.

| Level | Frequency | Frogg examples |
|---|---|---|
| Chill | Never on its own; only when poked | — |
| **Normal (default)** | ~1 per 20–40 min, only after ≥ 2 min with no mouse/keyboard activity | Tongue-snatches a **cosmetic fake cursor** (real cursor never moved), naps on a title bar, licks a desktop icon (sparkle) |
| Chaos | ~1 per 5–10 min, still only when idle | Above + visual hop along Dock icons (no clicks), drags a **ghost copy** of a desktop icon a few px and snaps it back |

**Hard rules at all levels:**
- Never move the real cursor, windows, or files.
- Never send clicks or keystrokes.
- Never cover the window with keyboard focus.

## D14. Hotkeys and defaults

| Action | Default | Notes |
|---|---|---|
| Mini menu (skin, name, behavior toggles, mischief level, size, hotkeys) | **⌃⌥P** | Toggle; Esc closes. Matches Windows Ctrl+Alt+P |
| Chat | **⌃⌥Space** | Frogg turns to the user; speech bubble "Chat is coming soon 🐸" (exercises the bubble component + `IBrain` stub) |
| Hide / show Pixl | **⌃⌥H** | Screen-share panic button |

- All rebindable in the mini menu.
- Registered via Carbon `RegisterEventHotKey`, which needs no permission. ⌃⌥ avoids the ⌥⌘ system conflicts (⌥⌘H Hide Others, ⌥⌘Space Finder search, ⌥⌘P Finder path bar). *(P4)*
- **Default size: 2×** (Frogg ≈ 80 pt tall, inside the design's 64–128 px target). 3× / 4× selectable. *(P3)*

---

## Open items
- [x] **Canvas size** (D6): resolved by P2.
- [x] Copyright holder name (D5): "Luca M" from the GitHub profile; owner can override.
- [ ] **Legacy Windows code:** the design readme refers to an earlier WPF `pixlz` codebase (SPEC v2, `MiniMenu.cs`, `FroggPainter.cs`). It isn't on GitHub; it's probably on the Windows laptop. When it's back, push it to a separate repo or branch and fold anything useful into `SPEC.md`.
- [ ] **Design PNGs:** `design/assets`, `design/screenshots`, `design/uploads` are not pulled yet. They wait for Git LFS.

---

## D15. NEAR Hackathon fork: Pixl Memory (2026-11-08)
- Branch `near-hackathon` from tag `pre-hackathon` (`8f546ec`). Plan: `docs/PLAN-pixl-memory.md`.
- **Overrides D10 on this branch only:** AI/LLM calls (NEAR AI Cloud TEE models only, attested before any text is sent), a local service (`memory/`), and a NEAR wallet for Frogg (testnet first).
- Inference only on models served from NEAR AI's own TEEs (`owned_by: nearai`); "incognito" models refused.
- Frogg's wallet: a sub-account created and funded by the user; the app holds only a function-call key for `pay_inference` on Frogg's own policy contract. The app never holds the user's keys.
- Ground rules R1–R8 still apply. Text reaches the user's apps only by the user dragging it (R4: no synthetic keystrokes or pastes).
- License unchanged (proprietary). The repo goes public for judging by 2026-11-14 23:59 UTC.
