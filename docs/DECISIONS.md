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
| **M4** | ESP-Mosaico | Frogg goes Mac → Mosaico → Mac over the same Wi-Fi (D17): drop-in entrance, idle with blink, hop-out exit; PetState intact. Spike first (plain TCP), then pairing + TLS before merge. |
| **v1 done** | All | M1–M4 + remaining system reactions (fullscreen hide, Trash signature, typing avoidance, battery, focus guardian) + hotkey mini menu + one small home-screen widget + Send to / Lock (D18). |

Order: M1 → M2 → M3 → M4 → remaining v1 items. Platform order: **macOS → iOS → ESP-Mosaico → Windows.** (amended 2026-11-10, D17)

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
- **ESP-Mosaico** (ESP32-S31, 2.16" 480×480 AMOLED, touch): a travel device like the iPhone (D17). ESP-IDF pinned at `7b9cc1ac79f865983f59bb8ff3ff43eb74ff1dbe`, target `esp32s31`, built and installed only through the vendor's `python mosaico.py` (repo `esp-mosaico/esp-mosaico-vibe`, cloned next to this one). Pixlz code for it lives in `mosaico/`.
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
- **Frames:** `assets/<pixl>/sprites.json` is the source of truth: indexed-colour rows, each frame with its own `w × h`, trimmed to the art and drawn bottom-centred (SPEC §3.1). The fixed per-Pixl canvas from P2 is gone (amended 2026-11-10).
- **Scaling:** whole-number multiples only, nearest-neighbor (no smoothing). User-selectable 2×/3×/4×.
- **Facing:** behavior slots drawn facing right; the engine mirrors them for left.
- **Manifest** `assets/<pixl>/pixl.json`: species, frame size, fps per slot, foot anchor (ground-contact pixel), hitbox, aura preset, movement type (`hop | walk | float | climb`).
- **Validation:** a PixlzCore unit test checks every manifest (all slots present, 3 frames, correct dimensions). A missing frame fails the build.
- **Source:** sprites are rendered headlessly from the Claude Design C7 source (`design/explorations/c3/`), pet only, without props. The app draws props (folder, window, pond) itself. PixelLab fills gaps only (new poses, cleanup). Rendered PNGs are committed as plain git files (amended 2026-11-08, D15; was Git LFS). *(P6)*
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
- **Device kinds** (amended 2026-11-10): every device advertises `_pixlz._tcp` with TXT `id`, `name` and `kind` (`mac`, `iphone`, `mosaico`, later `windows`). `kind` picks the device icon in Send to (D18). The Mosaico advertises `kind=mosaico` and only travels with a Mac on the same Wi-Fi (D17).
- **Pairing blocks travel off the Mac** (2026-11-10): a 6-digit code fed straight into TLS-PSK can be brute-forced offline from a recorded handshake (SPEC §15 Q7). Pairing must use the code to authenticate a fresh key exchange (a PAKE such as SPAKE2) before **M3 iPhone travel ships** and before `mosaico` merges. The planned iroh spike (`IOS-PLAN.md`) is the leading candidate: the code authenticates one exchange of iroh public keys, and after that only paired keys connect. The plain-TCP Mosaico spike is the only exception, and it stays on its branch.
- **Protocol version:** `offer` and the TXT record carry `proto` (now 2). A device declines an offer from a newer protocol with `needsUpdate`, so mismatched builds stop cleanly before any transfer. The checksum is SHA-256 of the raw received `payload.state` bytes on every platform; nobody re-encodes to check it (SPEC §10.1, §10.3).
- **Pairing direction:** the device without a keyboard shows the 6-digit code. Mac ↔ iPhone: the Mac shows it. Mac ↔ Mosaico: the **Mosaico shows it, the user types it on the Mac**. The key derivation doesn't care who shows it (both device ids are sorted into the salt).

## D10. Out of scope for v1
- AI/LLM calls, accounts, cloud sync, payments, analytics
- Windows build, Android
- Multiple simultaneous pets per device
- App Store submission, notarization, TestFlight, Developer ID
- Cat, Ghost, Spider (Frogg only)
- Live Activities / Dynamic Island, lock-screen widgets, extra widgets
- Alarm wake reaction
- Swipe-to-fling travel on the iPhone (on the Mosaico it is how travel works, D17); Nearby Interaction direction-aware travel
- Tiling several Mosaicos into one bigger stage
- Chat and Mic functionality (UI shown greyed out; `IBrain` stub and speech bubble exist, unused)
- Mirroring system Focus modes
- Pixls walking across displays on their own (D11)
- **Free roam:** a Pixl starting trips between devices on its own. Specified now (SPEC §10.6, D18) so the PetState field and rules are settled; ships in v1.1, after pairing + TLS
- On-device AI on the Mosaico (Ask and memory run on the Mac or the cloud; D17)
- A cloud relay (the Mosaico needs an awake Mac on the same Wi-Fi until it exists)
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
- **PNGs leave Git LFS** (amends D6): sprites are a few KB each and screenshots a few hundred KB. A clone or ZIP download without LFS would show judges pointer files, and every download would spend the owner's LFS bandwidth. GIF, WebP, Aseprite and PSD stay in LFS.

## D16. Menus & Bubbles (design C8) replace the radial menu (2026-11-08)

- **Option bubbles** open on double-click, right-click or a 450 ms press; a single click only pokes. The signature moved to an idle quirk and More ▸ "Do your thing" (SPEC §11).
- **One surface material** for every overlay: Liquid Glass (`NSGlassEffectView`) on macOS 26+, paper fallback otherwise or with Reduce Transparency.
- **Legibility without screen capture.** D12 rules out Screen Recording, so text surfaces never sample what's behind them. Instead they use the smallest backdrop dim that keeps text at 4.5:1 over any backdrop (`Legibility.pick`, unit tested).
- **Per-pet UI data** (accent, menu face, signature, Ask placeholder, personality) lives in `pixl.json` → `ui`.
- The iPhone stage (long-press, previously the radial menu) will use the same bubbles when the iPhone app is built.

## D17. ESP-Mosaico is a travel device (2026-11-10)

The Mosaico is a first-class home for a Pixl, like the iPhone (D8): the Pixl can live on it, and it travels to and from the Mac with the same trip protocol (SPEC §10.4). SPEC §12.1 has the details.

- **Screen:** 2.16" 480×480 square AMOLED. To avoid burn-in, the Pixl never holds still in one spot for long (it drifts a few pixels between idle loops), the background is black (unlit pixels), there is no fixed UI chrome, and the screen dims when nobody touches it: 50% after 2 min, 10% after 10 min.
- **Touch only:** no hover, right-click or keyboard. Touch targets at least ~110 px (about 9 mm), so **at most 4 options per screen**. Menus page with "more".
- **Small battery:** when unplugged, the Pixl goes to sleep on the Mosaico and Wi-Fi turns off. It can't send, receive or be called until it's plugged in again. Its state is safe in flash (R8).
- **Network:** travel only with a Mac that is awake and on the same Wi-Fi, until the cloud relay exists. No iPhone ↔ Mosaico trips in v1. Whether the Mosaico later runs iroh itself or keeps plain TCP to a Mac that bridges is Stage B of the iroh spike.
- **No on-device AI.** Ask, Polish and memory run on the Mac (or the cloud later). The Mosaico only shows results the Mac sends it.
- **Pairing is reversed:** the Mosaico shows the 6-digit code; the user types it on the Mac (D9).
- **Mischief:** cursor-based mischief (tongue snatch, ghost drag, icon lick, Dock hop) doesn't port. Each Pixl gets a touch version (for example Frogg's tongue snatches the spot you just tapped) or none. Listed per species in SPEC §9.
- **Pixl size:** a **per-device scale** in device settings, never in PetState. Whole numbers only (no blurry pixels), chosen so the screen is about 4 pet-widths across: `max(1, round(screenWidth / (4 × idle frame width)))`. The rule is for stage devices (Mosaico, iPhone); the Mac keeps its 2× default (D14). `scale.<device>` in `pixl.json` overrides it. Frogg on the Mosaico → **2× (136 px)**. Physics (hop apex and distance, walk/crawl speed) is in sprite pixels and scales with the pet.
- **World map:** all four screen edges are surfaces (floor, walls, ceiling) for the Pixls that can use them. Slugg crawls the whole perimeter, upside down along the top, leaving its slime trail; Frogg hops along the floor and clings to walls because it's sticky (SPEC §12.3).
- **Small-screen menu:** double-tap shows up to 4 bubbles at the screen edges; "more" leads to a second page. Swiping the Pixl off an edge flings it to the device assigned to that side. Tiling several Mosaicos comes later.
- **The spike** (Phase 2 of the 2026-11-10 plan) uses plain TCP with PixlzCore's Framing and a `{"hello":{"deviceId","deviceName"}}` first frame, and maps a single tap on the Pixl to "go home" once the double-tap window expires. Pairing + TLS are required before `mosaico` merges.

## D18. Send to, Lock, Free roam (2026-11-10)

- **Send to ▸** lists paired devices, each with its device icon (`kind`, D9). Reachable ones can be picked. Known devices that are asleep or unreachable are greyed out with "wake it to send". It appears on the Mac (option bubbles and menu bar), the iPhone and the Mosaico.
- **Lock to this device:** a PetState field (`policy.locked`), so the lock stays with the Pixl through restores and conflict resolution. A locked Pixl declines calls with the new reason `locked`, and no offer can start from it (Send to is greyed out: "unlock to send").
- **Free roam:** a PetState field (`policy.freeRoam`). When on, the owner device may start `send` by itself, only to a device that is awake and in use, never during Focus on either device, never while locked, and with a cooldown. Rules in SPEC §10.6.
- **New PetState fields are optional.** Old files still decode; the canonical encoding doesn't change. Adding them raises `proto` to 2 (D9).
- **Free roam ships in v1.1, not v1.** Reasons:
  1. *Trust first.* Until pairing + TLS exist, every trip runs over plain TCP. An autonomous sender would push the Pixl's state onto the network without the user asking.
  2. *Surprise.* A dogfood user whose Pixl vanishes from the Mac with no action of their own will read it as a bug. Lock and Send to need to exist and feel solid first, so the user has an easy way to stop it.
  3. *"In use" needs a signal that doesn't exist yet.* Each device must advertise whether someone is using it right now (SPEC §10.6). That's new TXT data and needs testing on all three platforms.
  4. *Failures are more likely.* A Mosaico that is unplugged or a Mac that is asleep makes autonomous trips fail often. Each failure costs an `annoyed` shrug the user didn't cause.
  - The field and the rules are specified now, so v1 PetState files already carry it and no migration is needed later.
- D10's non-goal "Pixls roaming across displays on their own" is split in two: walking across displays stays out (D11); free roam between devices moves to v1.1.
