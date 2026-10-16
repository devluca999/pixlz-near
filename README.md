# Pixlz

Animated pixel-art pets that live on your screen. A Pixl idles, walks, perches on window edges, the menu bar and the Dock, reacts when you poke or grab it, and can travel between your Mac and your iPhone. Later, each Pixl becomes the face of an always-on AI agent.

Status: **pre-alpha, personal dogfood build.** v1 ships one Pixl, Frogg.

## Platforms

| Platform | Stack | Status |
|---|---|---|
| macOS 15+ | AppKit, borderless non-activating overlay panel | M1, not started |
| iOS 18+ | SwiftUI + SpriteKit companion, one small widget | M2, not started |
| Windows | WPF, built later from `docs/SPEC.md` | placeholder |

## Layout

```
PixlzCore/   Shared Swift package: pet state, needs, behavior, travel protocol (platform-neutral)
macos/       macOS app (Xcode project, added once Xcode is installed)
ios/         iPhone app + widget (Xcode project, added once Xcode is installed)
windows/     Placeholder for the WPF port
assets/      Runtime sprites: assets/<pixl>/<slot>.png, emotions/, pixl.json (Git LFS)
design/      Claude Design project snapshot: art direction, procedural pixel engine, tokens
docs/        DECISIONS.md (what v1 is), RESEARCH.md (platform research), SPEC.md (source of truth)
Pixlz.xcworkspace  Opens PixlzCore and both apps together
```

## Getting started

Requirements: Xcode 26.x, Git LFS (`brew install git-lfs && git lfs install`).

```sh
git clone https://github.com/devluca999/pixlz.git
cd pixlz
git lfs pull
open Pixlz.xcworkspace
```

Run the shared core's tests without Xcode:

```sh
swift test --package-path PixlzCore
```

## Ground rules

- Effects never touch, move, or delete real files.
- Never block clicks; never cover the window being typed in.
- macOS: under 1% CPU idle; render only while moving; sprite sheets loaded lazily.
- iOS: respect background limits; no polling loops.

Full decisions and budgets: [`docs/DECISIONS.md`](docs/DECISIONS.md).

## License

Proprietary. All rights reserved. See [`LICENSE`](LICENSE).
