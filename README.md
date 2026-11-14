# Pixl Memory

![Frogg, Kiti, Mochi, Boo, Silky and Slugg, each with its menu open](docs/screenshots/pixlz-lineup.png)

**Your AI assistant should be able to prove where your private text goes. Pixlz makes it prove it, every time, before it sends anything.**

Pixl Memory puts Frogg, a pixel-art frog, on your Mac. Select text in any app, click Frogg and choose **Polish this**. Before a single byte of your text leaves the Mac, the local service makes NEAR AI Cloud prove that the model runs in a genuine, production Intel TDX + NVIDIA confidential-GPU enclave, fresh for this request, reachable only over the TLS key bound in that enclave's quote. 14 properties must each be proven: if one fails **or can't be checked**, nothing is sent. The reply must then carry the enclave's signature over the exact bytes sent and received, or it's thrown away.

Frogg also has **his own NEAR testnet account**, a sub-account of yours holding only what you gave him. Each private answer is logged with a small payment from his balance, never yours: the app holds only his key. (The payment is an on-chain receipt sized to the request's cost; NEAR AI bills the inference itself in its own credits.)

Built for the **NEAR Hackathon** (November 2026). Tracks: **Privacy & Private AI** (primary), Agent Economy, AI Security & Defense.

| | | |
|---|---|---|
| ![Frogg perched on a Mail window, bubble: Verified in TEE, 17/17](docs/screenshots/frogg-perched.png) | ![The polish panel: word diff, verdict, and the card you drag into your text](docs/screenshots/polish-panel.png) | ![Refused: the enclave failed verification, so the text was never sent](docs/screenshots/polish-refused.png) |
| **1. Select text, click Frogg.** He sits on the window you're working in. | **2. A private edit, verified.** A real NEAR AI Cloud reply: word diff, 17 of 17 checks passed, a card to drag into your text. | **3. Or refused.** If the enclave fails verification, or a check can't run, your text is never sent. (Rendered from the app's view with sample check data.) |

> Published for NEAR Hackathon judging. No license is granted. See [`LICENSE`](LICENSE).

## At a glance

| | |
|---|---|
| What it is | A desktop pet for macOS that edits and answers privately, saves highlights with links back to the page, and travels to other devices |
| NEAR pieces | NEAR AI Cloud private inference, its attestation checked on the Mac before sending; a NEAR testnet sub-account per pet that logs every request with an on-chain payment |
| Runs on | macOS (Apple silicon), Chrome, and an ESP-Mosaico display |
| Network | NEAR **testnet only**; the config refuses mainnet |
| Your keys | Your NEAR account key is never on the Mac. Only the pet's own key and your NEAR AI API key (in `.env`, git-ignored) are |
| Tests | 691 automated tests plus 6,575 checks in the Mosaico C code, all passing ([full list](#whats-built-and-how-its-tested)) |
| Start here | [Try it in 5 minutes](#try-it-in-5-minutes) |

## What to verify, and where

| Claim | Enforced in | Check it yourself |
|---|---|---|
| No text leaves before 14 attestation properties are proven; a skip counts as a failure | `memory/src/pixl_memory/verify.py` (`MANDATORY_CHECKS`), `nearai.py` (`chat`) | `cd memory && uv run pixl-memory attest` (live, free, no key) · `uv run pytest tests/test_preflight_matrix.py` (104 cases assert the completion endpoint is never called) |
| The completion goes only to the TLS key bound in the gateway's Intel-signed quote | `nearai.py` (`TlsPin`) | `uv run pytest -m live -k tls` (accepts the attested key, rejects any other) |
| NVIDIA's GPU verdict is signature-checked, not just trusted | `verify.py` (`verify_es384_jwt`) | `uv run pytest tests/test_nras_signature.py` |
| A reply that fails its signature is discarded: not shown, saved or paid for | `nearai.py` (`ResponseRejected`), `server.py` | `uv run python attack_demo.py` (23/23) |
| The pet's wallet can't touch the owner's funds | NEAR protocol: the owner's key is never on the Mac | [Frogg's wallet](#froggs-wallet) and the testnet receipts linked there |
| Caps and the one-payee rule | **App code** (`wallet.py`), not an on-chain contract | `uv run pytest tests/test_wallet.py` |

What attestation does **not** prove, and what you still trust (Intel, NVIDIA, NEAR's gateway hop): [`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md). A 90-second and a 5-minute path for judges: [`docs/hackathon/JUDGE-WALKTHROUGH.md`](docs/hackathon/JUDGE-WALKTHROUGH.md).

## The problem

Writing assistants see everything you write: unsent emails, medical notes, contracts. "We don't train on your data" is a promise you can't check. Pixl Memory lets you check it. The model runs in an enclave whose code and hardware are attested, and your Mac verifies that before it sends anything, not after.

## Try it in 5 minutes

**1. Check NEAR AI Cloud's enclave yourself. No account or key needed.**

```sh
git clone https://github.com/devluca999/pixlz-near && cd pixlz-near
cd memory && uv run pixl-memory attest
```

This runs 15 checks against the live NEAR AI Cloud: the gateway's TLS key bound in its quote, the Intel TDX quote and its TCB, your fresh nonce inside the signed quote, the signing key bound to the quote, the RTMR3 replay, the measured docker-compose, NVIDIA GPU attestation (with every NVIDIA token's signature checked) and the deployment log. 14 of them are mandatory: if any fails, **or can't be checked**, the app sends nothing. What this proves and what it doesn't: [`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md). It needs [uv](https://docs.astral.sh/uv/) (`brew install uv`), which installs Python 3.12 and every dependency.

**2. See the attacks it blocks.**

```sh
uv run python attack_demo.py
```

23 attacks against the real code (NEAR AI Cloud and the chain are simulated): forged, stale and debug enclaves; models outside a TEE; NVIDIA's attestation service made unreachable; tampered or unattested replies (thrown away, never shown); a compromised app holding Frogg's key; a malicious web page; a key leaked in a commit. All are blocked. One (a stolen key file) is limited to Frogg's own balance. The log is in [`docs/ATTACKS.md`](docs/ATTACKS.md).

**3. Install the Mac app.**

```sh
cd .. && scripts/install.sh    # sets up the local service, builds Pixl Memory.app and opens it
```

Click the frog in the menu bar. Frogg springs out of the icon onto the window you're working in. Right-click the menu bar frog for Open at login, settings and Hide. The app starts its own memory service, so you won't need the terminal again. There's no `.dmg` download yet: that needs the service bundled and an Apple Developer ID, which come after judging.

**4. Polish something.** Put your `NEAR_AI_API_KEY` (from cloud.near.ai) in `.env`, which the installer created from `.env.example`. Allow Accessibility when macOS asks. Select text in any app, click Frogg, and choose **Polish this**. The panel shows a word diff, the verdict and all 17 checks behind it. Drag the green-edged card into your text and it replaces your selection.

## Screenshots

Six Pixls (pictured at the top): Frogg (a red-eyed tree frog), Kiti (a cat), Mochi (a Shiba Inu), Boo (a sheet ghost), Silky (a black widow, mostly harmless) and Slugg (a slug). Each has its own accent colour, menu detail, trick, sounds and way of moving. Switch in Settings or under More ▸ Change Pixl. Memory, wallet and position carry over.

![Every Pixl with its Default and two alternate skins](docs/screenshots/skins-grid.png)
Each Pixl has two alternate skins (Kiti has three), picked under Settings ▸ Alternate skins.

| | |
|---|---|
| ![All 17 checks](docs/screenshots/polish-panel-checks.png) | ![Ask: an answer with pictures](docs/screenshots/ask-pictures.png) |
| All 17 checks behind the verdict at the top, from the same live request. (In the top-left picture the Mail window is drawn; Frogg, the bubble and the panels are the app's real views.) | Answers that name places or things show small pictures of them. Click one to enlarge it. |
| ![Chrome: a saved highlight reopened](docs/screenshots/backlink-long-passage.png) | ![Chrome: the right "the frog" out of 35](docs/screenshots/backlink-the-frog.png) |
| A saved passage, reopened from its link, scrolled to and highlighted. | The link finds the right "the frog" out of 35 on the page. |
| ![Double-click or right-click: the option bubbles](docs/screenshots/bubbles-white-doc.png) | ![⌃⌥P: the mini menu](docs/screenshots/mini-menu.png) |
| Double-click or right-click the Pixl: Polish (with a selection) or Ask, Memory, Wallet, More. | ⌃⌥P opens Settings: pet, skins, size S to XL, Calm / Roam / Chaos, Focus, Shortcuts, Privacy & Memory, Energy, Wallet. |
| ![Frogg's wallet setup page](docs/screenshots/wallet-setup.jpg) | ![Settings ▸ Energy](docs/screenshots/settings-energy.png) |
| `/wallet/setup`: the owner approves Frogg's account in their own wallet. | Settings ▸ Energy: live CPU, a 10-minute sparkline, memory and power. |

| | | |
|---|---|---|
| ![Ask: open Spotify](docs/screenshots/ask-open-spotify.png) | ![Ask: a joke, with web search](docs/screenshots/ask-web-joke.png) | ![Ask: save this, with a backlink](docs/screenshots/ask-save-backlink.png) |
| **"open Spotify"**: done on the Mac. No model, nothing sent. | **"tell me a joke"**: a private answer that searched the web, with its sources. | **"save this"**: saved to Memory with a link back to the passage. |

More: [the cards in light](docs/screenshots/cards-light.png) and [dark](docs/screenshots/cards-dark.png), [the More list](docs/screenshots/more-list.png), and every animation frame for [Frogg](docs/screenshots/frogg-frames.png), [Kiti](docs/screenshots/cat-frames.png), [Mochi](docs/screenshots/shiba-frames.png), [Boo](docs/screenshots/ghost-frames.png), [Silky](docs/screenshots/widow-frames.png) and [Slugg](docs/screenshots/slugg-frames.png). App screenshots are rendered from the app's own views (`swift run --package-path macos/PixlMemory pixl-snapshots <reply.json> docs/screenshots`). Browser screenshots are from Chrome.

## How it works

```
 macOS app (the Pixl)        Chrome extension
   select → polish → diff     highlight → save → #:~:text= backlink
        \                     /
         127.0.0.1:7341  pixl-memory  (encrypted SQLite, token auth)
                │  1. attest: nonce → Intel TDX + NVIDIA NRAS + signer binding
                │  2. only then: the completion (exact bytes kept)
                │  3. signature over sha256(request):sha256(response) → the attested key?
                ▼
        NEAR AI Cloud  ── gateway TEE ── model TEE (z-ai/glm-5.3-flash)
                │
        Frogg's wallet  frogg.pixlz-petz-faucet.testnet  ── transfer(cost) ─▶ pixlz-petz.testnet (allowlisted)
```

1. **Attest first.** The local service sends a fresh nonce, then checks the Intel TDX quote, NVIDIA's GPU attestation and that the signing key belongs to the attested enclave. If any of the 14 mandatory checks fails or can't be run (NVIDIA's service down, say), your text is never sent.
2. **Then send.** The completion request goes out on a connection pinned to the TLS key in the gateway's attested quote, and the exact bytes of the request and response are kept.
3. **Check the reply.** The response signature must recover to the key the attestation vouched for, over the exact bytes sent and received. If it doesn't, the reply is thrown away: not shown, not saved, not paid for.
4. **Pay.** Frogg pays the request's real cost with a NEAR testnet transfer to one allowlisted account. This is an accounting transfer: NEAR AI bills the inference itself in its own off-chain credits. The receipt (model, cost, verdict) stays in the local encrypted store. Only the amount and the transaction go on chain.

## Everything you can try

| Do | What happens |
|---|---|
| `uv run pixl-memory polish "teh frog sit on the windw"` (after setting `NEAR_AI_API_KEY`) | The polished text plus the verdict. The response signature recovers to the attested model key |
| `uv run pixl-memory serve`, then `POST /polish` | JSON with the suggestion, the word diff and the full verification |
| Double-click the Pixl → **Ask** (⌃⌥Space): **"open Spotify"**, **"go to github.com"**, **"play Daft Punk on Spotify"** | Done on the Mac with no model: the app if it's installed, otherwise the site in a new tab |
| Load `extension/` unpacked in Chrome, select text, right-click **Save to Pixl Memory** (⌥⇧S) | Saved with a link that reopens the page highlighted at that passage ([`extension/README.md`](extension/README.md)) |
| On an article, Ask **"save the part about their transparent skin"** | The passage is found on the Mac (no model) and saved with a link that opens the page scrolled to it |
| Ask **"what did I save about glass frogs?"** | Your saves on that topic, ranked on the Mac, each with its link |
| Ask **"tell me a joke"** or **"what's new with NEAR AI this week?"** | The model searches the web when it needs to (NEAR AI's `web_context_search`, $0.005 a search) and lists its sources. These answers are signed by NEAR AI's attested gateway, not the model enclave, so the verdict says "partly verified" |
| Ask **"famous Chicago landmarks"** | The answer with small pictures of the places it names. Click one to enlarge it |
| Double-click the Pixl → **Play** | Two 60-second mini-games: Slugg's **Inevitable** (he crawls after your cursor) and Frogg's **Snap** (dodge his tongue). Typing or clicking another app ends a game at once ([`docs/DEMO.md`](docs/DEMO.md)) |
| Double-click the Pixl → **More** → **Send to device** | The Pixl hops to another Mac or a Mosaico. See [Trips to other devices](#trips-to-other-devices) |
| Double-click the Pixl → **Agents** | Watch and message your Claude Code sessions. See [Agent mode](#agent-mode-watch-and-message-your-claude-code-sessions) |

The local service on its own is documented in [`memory/README.md`](memory/README.md).

## Frogg's wallet

**Why a pet has a wallet:** give an AI agent money without giving it the keys to yours. Frogg's purse has a hard bottom: a sub-account holding only what you sent it. Each private request is logged with a payment from that purse, sized to the request's NEAR AI cost, to one allowlisted account, so every answer has an on-chain receipt. (NEAR AI bills the inference itself in its own credits; the transfer is the receipt, not the purchase.) You set a weekly limit or pause it in the Wallet bubble.

**The design: a plain NEAR sub-account that the owner funds.** Live on testnet: the owner account `pixlz-petz-faucet.testnet` created `frogg.pixlz-petz-faucet.testnet`, and Frogg pays `pixlz-petz.testnet` ([first payment](https://testnet.nearblocks.io/txns/GzuymmDA5kERz74Rj28GAs8KaSUqAiM8DtgvkBui9fzm)).

- **The owner creates Frogg's account from their own wallet and sends it a small amount.** The app never asks for a recovery phrase or private key, and NEAR gives a parent account's owner no control over a sub-account after it's created. Pixl Memory has no path to your main account.
- **The app holds only Frogg's key.** The most a stolen key can spend is the balance you gave Frogg. NEAR itself enforces that cap.
- **Frogg pays per request with a plain transfer.** The amount is the request's real cost from NEAR AI's `/v1/billing/costs`, converted at a rate you set. The app refuses to pay any account but the allowlisted one. (NEAR AI credits can't be bought on chain today, so the payee is whoever holds the credits.)
- **Before every payment** the app's own code (not a contract on chain) checks, in order: the per-request cap, the per-day cap, the payee allowlist and the reserve. A polish is refused up front once the daily cap is reached, so your text isn't sent if Frogg can't pay.
- **A second cap you can add:** a USD spend limit on your NEAR AI API key in the cloud.near.ai dashboard.

**Send NEAR to a friend, or top up a Pixl.** The Wallet card's **Send ↗** opens a local page (`/wallet/send`) where *your* wallet (Meteor) signs one plain transfer from your account to any `.testnet` account you type, or to one of your Pixls. The page checks the account id and that the account exists, and shows exactly what Meteor will ask you to approve. Pixl Memory never sees your keys and adds nothing to the transaction (`memory/src/pixl_memory/send_page.py`, test `test_send_page_asks_the_owners_wallet_for_one_plain_transfer`).

Every Pixl can have its own wallet the same way (`pixl-memory wallet init --pet kiti`, then the owner creates `kiti.<owner>.testnet`).

**How it's built** (`memory/src/pixl_memory/near.py`, `wallet.py`): Frogg's ed25519 key is generated on the Mac by `pixl-memory wallet init` and stored in `~/Library/Application Support/PixlMemory/frogg_key.json` with mode 0600. Transactions are signed in about 100 lines of Python, checked byte for byte against `near-api-js` in the tests.

**Owner setup** (testnet only):

1. `cd memory && uv run pixl-memory wallet init` creates Frogg's key and prints its public half.
2. Create Frogg's account under yours with the NEAR CLI (your key stays in your keychain):
   `near create-account frogg.<you>.testnet --use-account <you>.testnet --public-key <Frogg's public key> --initial-balance 1 --network-id testnet`
   No testnet NEAR? `near create-account <you>.testnet --use-faucet --network-id testnet` makes a funded account.
3. Set `FROGG_PARENT_ACCOUNT`, `FROGG_ACCOUNT` and `FROGG_PAYEE` in `.env`. `uv run pixl-memory wallet status` should end with READY.

The `/wallet/setup` page does step 2 from a browser wallet, but Meteor refuses transactions that add a full-access key, which Frogg's account needs. That's why the live setup used the CLI.

**Why not a NEAR Intents agent account?** We checked the Agent API on 2026-11-08 (docs.near-intents.org and the `NEAR-Intents-Agent-API` SDK).

| | NEAR Intents Agent API | Funded sub-account |
|---|---|---|
| Network | Mainnet only, real funds ("experimental, mainnet-only beta") | Testnet first, free |
| Credentials in the app | A partner API key the docs say must never ship in an app, so it needs a backend; plus a grant token | One key, for Frogg's account only |
| Limits | Rich server-side policy (destinations, budgets, schedules, freeze) | The balance is a hard cap enforced by the protocol; the payee allowlist is in our code |
| Code | SDK (Node 24), a backend proxy and an owner-signing flow | Sign and send one transfer |

Both keep your main funds out of reach. The sub-account does it with far less code, works on testnet and needs no server. The Agent API is the upgrade path if a Pixl ever holds a large balance. A smaller step, listed as optional hardening: a tiny policy contract on Frogg's account, with the app holding only a function-call key for `pay_inference`, so a stolen key could only pay the fixed payee within limits.

## Trips to other devices

A Pixl can leave this Mac and go to another Mac on the same network, or to an [ESP-Mosaico](https://github.com/esp-mosaico) display over Wi-Fi or Bluetooth LE, and come back. Only one copy of the Pixl exists at a time: the trip protocol hands it over with a checksum and never loses or duplicates it.

- **Mac to Mac.** Run Pixl on two Macs on the same Wi-Fi, or start a second copy on one Mac: `open -n --env PIXL_DEVICE_ID=demo --env "PIXL_DEVICE_NAME=Demo" ~/Applications/Pixl\ Memory.app`. Allow Local Network, then double-click the Pixl → More → **Send to device** → Demo. The other device asks "Catch …?". On yes, the Pixl leaps off this screen and springs out of the other one's menu bar. You can also Ask "what screens are available?" or "jump to Demo" (answered on the Mac, no model).
- **Mac to Mosaico.** The Mosaico app is in [`mosaico/`](mosaico/README.md): the trip protocol in C (`pixl_trip/`) and the Mosaico app (`pixlz_dock/`). On a real Mosaico, Frogg has gone Mac → Mosaico → Mac, and the Mosaico's edits to his state passed the Mac's checksum. Without hardware, `mosaico/sim.sh` runs the Mosaico in a browser simulator.
- **Who can take the Pixl.** A device you haven't trusted has to ask first, and only a trusted or paired device can call the Pixl away.
- **Pairing.** A Mosaico pairs with a Mac by showing the same 6-digit code on both screens (X25519 with a commitment, then HKDF; details in [`pt_pair.h`](mosaico/pixl_trip/include/pixl_trip/pt_pair.h)). A paired Mosaico can Allow or Deny your Claude Code agents' requests, with signed decisions.
- **Not done yet:** the trip link itself isn't encrypted or signed, so a device on your network can claim another device's name. A stranger can't make your Pixl leave (only a trusted or paired device can, and a copy you can reclaim always stays behind), but signing every frame with the pairing key is the next step.

## Agent mode: watch and message your Claude Code sessions

Agent mode lists the Claude Code sessions on this Mac, answers their permission requests, and lets you message them. Connect once: double-click the Pixl → **Agents** → **Connect Claude Code**. With your yes, it adds Pixlz hooks to `~/.claude/settings.json`.

| Do | What happens |
|---|---|
| Agents → pick a session → **Chat** | A panel beside the Pixl with the session's transcript (it refreshes), what it's doing, and a message field |
| Type a message while it works | Claude gets it at its next tool call, as "Message from the user via Pixlz: …" |
| When a session finishes a turn, the Pixl asks "\<project\>: done. Anything else?" → **Reply** | Your reply goes straight in and it carries on. No reply within 60 s (adjustable), or Dismiss: it stops as usual |
| Message a session that's closed or quiet for 2 minutes | Pixlz runs `claude -p --resume <id>` in its folder and streams the reply into the panel |
| Drag the panel's title bar | Tear it off into its own window, or dock it back. Size and position are remembered per session |

Only what you type in a chat panel can reach a session. Nothing the Pixl's AI, memory or NEAR inference produces can. Pixlz never blocks a stop twice in a row without a new message from you, so it can't loop a session. **Transcripts never leave your Mac.** They're read from `~/.claude/projects/` for the panel and never sent anywhere, including NEAR AI. If Pixlz isn't running, the hooks exit at once and Claude Code carries on.

## What's built and how it's tested

| Part | Status | Tests (all passing on 2026-11-13) |
|---|---|---|
| `memory/`: local service, attestation checks, encrypted store, web search, wallet, CLI | Working | 240: `cd memory && uv run pytest` (104 of them the fail-closed matrix in `tests/test_preflight_matrix.py`) |
| Frogg's wallet on NEAR testnet | Live: every answer pays its cost on chain | Included above (against a simulated chain) |
| `macos/PixlMemory/`: the Mac app | Built | 246: `swift test --package-path macos/PixlMemory`, plus an in-app click self-test: `scripts/build-mac-app.sh --selftest` |
| `PixlzCore/`: shared Swift core (pet state, behaviour, physics, trip protocol) | Built | 180: `swift test --package-path PixlzCore` |
| `extension/`: Chrome highlight → save → backlink, and the bridge to the Mac app | Built | 25: `cd extension && node --test` |
| `mosaico/pixl_trip/`: the trip protocol and pairing in C | Built, run on a real Mosaico | 323 checks: `make -C mosaico/pixl_trip test` |
| `mosaico/pixlz_dock/`: the Mosaico app | Built, run on a real Mosaico | 6,252 checks: `make -C mosaico/pixlz_dock/tests` |
| `scripts/check-secrets.sh` | Runs on every commit when enabled | `sh scripts/check-secrets.sh --all` |

**What the Mac app does.** Frogg perches on the active window, hops when you switch windows, and follows you to another Space. Each Pixl moves in its own way: Kiti walks, Mochi trots, Silky climbs walls and hangs on silk, Boo glides, and Slugg crawls along screen edges and window sides (he never hops) and leaves a slime trail that fades. Calm, Roam or Chaos sets how much they wander. They never move while you type and never sit over your text cursor. Pixls sleep when you're away (Frogg in his pond) and wake by the rules in [`docs/SPEC.md`](docs/SPEC.md) §6.2. Click to poke, double-click or right-click for the menu, drag to pick up and toss. Shortcuts: ⌃⌥P settings, ⌃⌥Space Ask, ⌃⌥H hide. They hide when an app goes full screen.

**Light on your Mac.** Typically 0.1% CPU idle (0.2% asleep in the pond), 1 to 5% while moving, and about 60 MB of memory, measured on an Apple-silicon MacBook Pro with `swift scripts/bench-energy.swift`. The script fails if idle CPU goes over the 1% budget.

## Scope of this submission

**In:** the Mac app, the Chrome extension and the local memory service, working end to end; Frogg's testnet wallet; and trips from Mac to Mac and from Mac to a Mosaico and back.

**Skins:** six Pixls with two alternate skins each, from the Pixlz design system. Switching keeps memory, wallet, position and settings. In this submission skins are a plain picker, not tokens.

**Next, after the hackathon, in this order:**

1. **On-chain skins.** Skins as NEAR NFTs (NEP-171) owned by your wallet, so a pet you own follows your account.
2. **Encrypted trips.** The trip link encrypted with the pairing key.
3. **iPhone companion.** Reuses `PixlzCore`: Frogg on a small stage, plus a widget. Not part of this submission.
4. **Mac ↔ iPhone travel,** on the trip protocol already in `PixlzCore`.
5. **Windows app,** built from [`docs/SPEC.md`](docs/SPEC.md).
6. **Travel across networks,** so a pet can move between Windows, Mac and iPhone anywhere.

Each step builds on the one before. Cross-network travel comes last because it's the only step that needs accounts and a backend.

## Keys and secrets

API keys live only in `.env`, which git ignores. Copy `.env.example` (empty values) to `.env` and fill in `NEAR_AI_API_KEY`. The service reads keys from that file only: not from code, arguments or the shell environment, and it never prints them.

`scripts/check-secrets.sh` blocks commits containing anything shaped like a key, or any `.env` file. Turn it on per clone with `git config core.hooksPath .githooks`. The test suite also runs it over every tracked file.

Frogg's NEAR key isn't an API key. It's stored outside the repository, in `~/Library/Application Support/PixlMemory/` with mode 0600.

## Security fixes after the first submission (2026-11-13)

A self-audit found that when NVIDIA's attestation service was unreachable, the GPU check came back "skipped" and the text **was still sent**. Now the preflight is an allow-list: 14 named properties must each be proven, or nothing leaves the Mac. Other fixes from the audit:

- A reply whose signature, byte binding or model name doesn't check out is thrown away (HTTP 502 `response_untrusted`), not shown as a result.
- Every NVIDIA attestation token's ES384 signature is checked against NVIDIA's published keys.
- The completion is pinned to the TLS key bound in the gateway's Intel-signed quote. Any other server is refused in the TLS handshake, before a byte is written.
- Malformed reports are refused cleanly.

`memory/tests/test_preflight_matrix.py` (104 tests) asserts on the wire that the completion endpoint is never called and the private text never appears in any outgoing request. Putting the old rule back makes 13 of them fail. Details, limits and the remaining trust are in [`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md).

## Baseline vs hackathon work

Before the hackathon, Pixlz was an early idea for a desktop pet that hadn't been built. One evening (2026-10-15 to 10-16, before the hackathon was announced) produced a written spec and a small core logic library, `PixlzCore`: pet needs, behaviour rules, physics and a trip protocol, with tests. There was no app, nothing on screen, no AI and nothing NEAR. Everything that makes this entry run was built during the hackathon, from 2026-11-08. About 6% of today's code (roughly 3,000 of 50,700 lines) traces back to that baseline.

This repository holds only what the entry needs to build, run and test. It's extracted from the private Pixlz repository with its history, so every commit keeps its original date. Left out: the Claude Design source (`design/`), the iOS and Windows plans, and product research notes. The pixel art is already exported into `assets/` and embedded in the app; `scripts/render-pixls.mjs`, which re-exports it, needs the design source and only runs in the private repository.

| | Commits | Dates |
|---|---|---|
| **Baseline**, tag [`pre-hackathon`](https://github.com/devluca999/pixlz-near/tree/pre-hackathon) | Every commit up to the tag | 2026-10-15 22:40 CT to 2026-10-16 02:48 CT, before the 2026-10-19 announcement |
| **Hackathon work**, tag [`hackathon-submission`](https://github.com/devluca999/pixlz-near/tree/hackathon-submission) | Everything after | From 2026-11-08 |

**All hackathon work as one diff:** https://github.com/devluca999/pixlz-near/compare/pre-hackathon...hackathon-submission

- **Baseline (spec and core logic only):** `PixlzCore/` (pet needs, behaviour, world map, physics, pet state, the travel protocol), `docs/SPEC.md`, `docs/DECISIONS.md`, and Frogg's first manifest in `assets/` (all the art was re-exported during the hackathon).
- **New in the hackathon:** `memory/`, `macos/PixlMemory/`, `extension/`, `mosaico/`, `showcase/`, `scripts/`, `.githooks/`, `.env.example`, `docs/PLAN-pixl-memory.md`, and this README.

Pixlz also plans a Solana layer. It isn't part of this submission. Our other, independent entry is **Evernear** (shipment escrow).

## Libraries and AI use

**`memory/`** (Python 3.12, managed with uv):

| Library | Used for |
|---|---|
| [FastAPI](https://fastapi.tiangolo.com) + [Uvicorn](https://www.uvicorn.org), Pydantic | The local HTTP API |
| [httpx](https://www.python-httpx.org) | HTTP client |
| [dcap-qvl](https://github.com/Phala-Network/dcap-qvl) (Phala) | Intel TDX quote verification |
| [eth-account](https://github.com/ethereum/eth-account) | EIP-191 signature recovery |
| [cryptography](https://cryptography.io) | AES-GCM at rest; ed25519 for the wallet |
| [python-dotenv](https://github.com/theskumar/python-dotenv) | Reads API keys from `.env` |
| pytest, hatchling | Tests, build |

Borsh and base58 for NEAR transactions are written in `near.py`; no NEAR library is used in Python. The `/wallet/setup` page loads [`@near-wallet-selector/core` and `meteor-wallet`](https://github.com/near/wallet-selector) 10.1.4 and `@near-js/transactions` / `@near-js/crypto` 2.5.1 from esm.sh.

**External services:** NEAR AI Cloud (inference, attestation, signatures), NVIDIA Remote Attestation Service (GPU evidence), Phala PCCS (Intel collateral).

**Swift (`macos/`, `PixlzCore/`):** Swift 6, AppKit, ApplicationServices (Accessibility, read-only), Swift Testing. No third-party packages. The pixel art is exported from the owner's private Claude Design engine and embedded as text, with no image files.

**`extension/`:** plain JavaScript modules, no libraries, no build step. Tests use Node's built-in `node --test`.

**`mosaico/`:** C with no dependencies outside the Mosaico SDK (ESP-IDF and Raylib Lite). X25519, SHA-256, HMAC and HKDF are written in `pixl_trip/` and checked against the RFC test vectors and Apple's CryptoKit.

**AI-generated content:**
- The hackathon code, tests and docs were written with **Claude Code** (Anthropic, Claude Opus 5.5), directed and reviewed by the owner.
- The pixel art was designed in Claude Design and exported by a script.
- The demo video's narration is a synthetic voice ([Chatterbox](https://github.com/resemble-ai/chatterbox), run locally by `showcase/narrate.py`). The cut, captions and the device render in its last scene were made by scripts in `showcase/`.
- `memory/tests/fixtures/attestation_report.json` is a real NEAR AI Cloud attestation response (with the TLS fingerprint binding), captured on 2026-11-14.

## The demo video

The demo video is recorded from the app itself. **Showcase mode** is a recording aid, on only with `--showcase` (or `PIXL_SHOWCASE=1`). It plays scenes made of beats, each a real feature triggered on cue. Random choices use a fixed seed so takes match, and a plain dark desk covers the desktop so nothing private is filmed. `showcase/record.sh` records a take, and `showcase/cut.py` assembles the 9:16 cut and the 16:9 judges' cut from `showcase/edit.json`. Scenes and narration: [`showcase/SHOTLIST.md`](showcase/SHOTLIST.md).

The video's last scene shows a Mosaico, a Mac and an iPhone side by side. That scene is a render. Trips to another Mac and to the Mosaico are in this submission. The iPhone is labelled "coming soon": it's under **Next**.

## For AI agents reading this repository

- **Entry points:** `memory/src/pixl_memory/` (the service: `verify.py` and `tdx.py` check attestation, `nearai.py` calls NEAR AI, `near.py` and `wallet.py` pay), `macos/PixlMemory/Sources/PixlMemory/AppController.swift` (the app), `PixlzCore/Sources/` (shared logic), `extension/`, `mosaico/pixl_trip/src/`.
- **Specs:** [`docs/SPEC.md`](docs/SPEC.md) is how a Pixl behaves on every platform; [`docs/DECISIONS.md`](docs/DECISIONS.md) records decisions by number (D1, D2, …), which code comments cite.
- **Rules the code enforces:** testnet only; text is never sent unless all 14 mandatory attestation checks pass (`verify.MANDATORY_CHECKS`; a skip is a failure); the completion is pinned to the attested gateway's TLS key; a reply that fails its signature is discarded; Frogg pays only the allowlisted payee (app code, not on chain); API keys come only from `.env`.
- **Trust model in one file:** [`docs/SECURITY-MODEL.md`](docs/SECURITY-MODEL.md), including a threat ledger marking each defense real or simulated.
- **Run every test:** the commands in [What's built and how it's tested](#whats-built-and-how-its-tested). None needs a key except `uv run pytest -m live`.

## Repository layout

```
memory/      Local service: NEAR AI private inference, verification, encrypted store, wallet
macos/       The Mac app (macos/PixlMemory/)
PixlzCore/   Shared Swift package: pet state, behaviour, physics, trip protocol (baseline)
extension/   Chrome extension: highlight → save → backlink
mosaico/     The ESP-Mosaico app and the trip protocol in C
showcase/    Demo video: shot list, recorder, cut, narration, demo pages
scripts/     Install, build, self-test, energy benchmark, secrets check
docs/        SPEC, DECISIONS, the plan, attacks log, demo script, screenshots
assets/      The Pixls' manifests and exported frames
```

## License

Copyright © 2026 Luca M. All rights reserved. See [`LICENSE`](LICENSE).
Published for NEAR Hackathon judging. No license is granted.
