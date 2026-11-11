# Pixls on more devices: phone and Windows (draft, 2026-11-11)

Builds on `IOS-PLAN.md` and `WINDOWS.md`. Those were written before the Mosaico work; this page records what that work changed, and the plan from here. Nothing here is built yet.

## What the Mosaico work settled

The Mosaico was the first device that isn't a Mac. Getting it right fixed several things every new device needs:

| Learned on the Mosaico | What it means for a phone or Windows |
|---|---|
| **The trip rules are bigger than offer → accept → commit.** Give-way to a newer copy, ask-back (`>=`, 60 s guard), `alreadyHere`, restyle, reclaim at epoch + 2. Every duplicated Frogg we saw broke one of these. | A new device must implement exactly the same rules. Either reuse a tested implementation, or write one against the same fixtures. |
| **There are two tested implementations already.** Swift (`PixlzCore` `TravelNode`) and C (`mosaico/pixl_trip`: `pt_trip`, `pt_pair`, `pt_crypto`, `pt_frame`, `pt_json`). The C one uses only the C standard library. | iPhone uses the Swift one as is. Windows (and Android, if the phone is Android) can compile the C one, so all devices behave identically, instead of writing a third copy. |
| **Pairing is D20:** X25519 commit/reveal, a 6-digit code you compare on both screens, HKDF, signed decisions. | This replaces the older "type the 6-digit code" PSK plan in IOS-PLAN.md. The same pairing works on any screen. |
| **Links die silently.** The duplicated Pixls in the BLE work came from a link that looked alive. Ping every 15 s; drop after 45 to 60 s of silence; reconnect to the known device first. | Every transport needs a heartbeat, not just Bluetooth. A phone app going to the background is a silent link death. |
| **One owner, and the Pixl stays visible while it's away.** The Mac refuses to show a Pixl that's away; the reclaim path exists for a device that never comes back (a dead battery). | The same rules apply when a phone dies or a laptop sleeps mid-trip. |
| **Agent mode is a feed** (`MosaicoFeed`: agents list, chat, quick replies, signed Allow/Deny, dictation). | A phone is a natural agents screen: approve a Claude Code request or reply from your pocket. The Mosaico protocol already works for it. |

## Transports, per device

| Device | Same network | Anywhere |
|---|---|---|
| Mac ↔ Windows | Bonjour (`_pixlz._tcp`; Windows has DNS-SD built in) + TCP, same frames | later: iroh (IOS-PLAN.md) |
| Mac ↔ iPhone | Bonjour + TCP while the app is open (iOS stops it in the background) | iroh, or a relay we host. Needed for "carry it away" |
| Mac ↔ Android | NSD (Android's DNS-SD) + TCP | same as iPhone |
| Phone ↔ Mosaico | Bluetooth works on both (the Mosaico is already a BLE peripheral) | n/a |

## Suggested order

1. **Windows on the same Wi-Fi.** A tray app with the overlay Pixl and trips only, no Polish/Ask yet. The C `pixl_trip` is compiled into a DLL and called from C# (or the app is written in C++). Done when Frogg hops Mac → Windows → Mac with no duplicate, including when you pull the network cable mid-trip.
2. **Phone on the same Wi-Fi, app open.** The Pixl full-screen, Send/Call, catch prompt. On iPhone, PixlzCore is reused directly. Done when the same test passes.
3. **The phone as an agents screen.** The Mosaico's agents feed and pairing, shown on the phone.
4. **Anywhere.** The iroh spike from IOS-PLAN.md, then a `P2PTransport`. Only after 1 to 3 hold up, since this is where the hard failures live (phones in the background, cellular).

## Decisions (2026-11-11)

1. **Phone:** iPhone (an iPhone 11).
2. **One cross-platform app** for Windows and the iPhone. The Mac app stays native Swift.
3. **Memory and wallet travel too**, not just the Pixl.
4. **It must work from the phone on cellular**, not only on the same Wi-Fi.

### Proposed stack: Tauri 2 with a Rust core (to be confirmed)

React Native isn't required. The candidates for one app on Windows and iPhone are React Native (with Microsoft's `react-native-windows`), Flutter, and Tauri 2. Tauri 2 is proposed because:

- **The hard parts are native code anyway.** Reaching the phone on cellular means iroh (IOS-PLAN.md), which is written in Rust. Tauri's core is Rust, so iroh is used directly, with no bridge. React Native or Flutter would each need a native module for it on both platforms.
- **The trip and pairing code is reused.** The C `pixl_trip` compiles into the Rust core, so Windows and the iPhone follow exactly the Mosaico's tested rules.
- **The desktop pet needs an overlay:** a transparent, always-on-top window that lets clicks through except on the Pixl. Tauri has transparent windows and click-through on Windows. With React Native on Windows this is the weakest spot.
- **One core for memory and the wallet.** The Mac's memory service is Python and can't run on an iPhone. The phone needs its own store (SQLite, encrypted) and wallet code (the NEAR key in the Keychain, the spending limits). Both are written once in the Rust core.
- The UI (the Pixl's sprites, bubbles, cards) is web tech drawn on a canvas, the same on both.

Risks to check in a spike first: Tauri's iPhone support is younger than its desktop support; click-through only off the Pixl's pixels on Windows; iroh's build size and its background behaviour on iOS.

### What "memory and wallet travel" needs

- **Memory (the backpack):** you pick which folders travel. They go with the trip, encrypted under the pairing key, and are stored encrypted on the other device. Edits on both sides merge per highlight, newest wins (IOS-PLAN.md).
- **The Pixl's brain on the phone:** Ask and Polish call NEAR AI from the phone, so the attestation checks (`memory/verify.py`, `tdx.py`) are ported to the Rust core. The phone checks the enclave before sending your text, as the Mac does.
- **Wallet:** the phone gets its own key on the Pixl's NEAR sub-account, added with your approval, with the same daily and weekly limits enforced on the phone. A lost phone's key can be removed.

### Updated order

1. **Spike (a few days):** a Tauri 2 app on Windows and the iPhone simulator that shows Frogg in an overlay, links `pixl_trip`, and does one trip with the Mac over Bonjour. Then the same trip over iroh, phone on cellular. Measure size and battery.
2. Windows and iPhone trips on the same Wi-Fi, with the duplicate tests (pull the network mid-trip).
3. Trips over cellular (iroh, with a relay we run).
4. Memory travels (the backpack).
5. Ask/Polish on the phone (ported attestation checks).
6. Wallet on the phone.
7. The phone as an agents screen (the Mosaico's feed).
