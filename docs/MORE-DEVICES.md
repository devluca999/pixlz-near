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

## Decisions needed

1. **Which phone:** iPhone or Android? iPhone reuses the Swift code and has a plan already. Android means Kotlin, plus the C library through the NDK.
2. **Windows UI stack:** WPF/.NET with the C library through P/Invoke (WINDOWS.md's plan), or something cross-platform that could also cover Android (e.g. Flutter, Tauri)? Cross-platform saves work but loses the native overlay feel, which matters most for a desktop pet.
3. **What travels at first:** only the Pixl (name, mood, style), or also memory (the "backpack") and the wallet key? Starting with the Pixl alone keeps the first version small.
4. **Away from home:** does the Pixl need to reach your Mac from a phone on cellular in the first version, or is same-Wi-Fi enough to start?
