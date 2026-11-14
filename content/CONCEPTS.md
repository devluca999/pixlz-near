# Video concepts (directive §11)

**Series:** *Cute on the outside. Serious underneath.* Each episode opens on the pet being cute,
then turns to one thing the code really does, proves it on screen, and states its limit out loud.
Shot IDs (E01, H04, O05…) refer to RECORDING-BRIEF.md. Paths are relative to the repo root.

## Claim rules (apply to every script)

| Say | Never say |
|---|---|
| "Before any text leaves the Mac, it checks a fresh attestation: 13 required properties. If any one fails, is skipped or is missing, the text isn't sent." | "Nobody can ever see your data", "100 % private", "military-grade" |
| "The model runs remotely, inside a TEE on NEAR AI Cloud." | "Runs offline" / "on-device AI" |
| "Encrypted at rest on your Mac" (local SQLite store) | Mixing that with TEE privacy: they're two separate protections |
| "Frogg's testnet wallet makes an accounting payment, sized to the request's NEAR AI cost, to one allowed payee." | "He pays for his own AI" / "the transfer buys inference" (inference is billed off-chain in NEAR AI credits) |
| "Limits (per request, day, week, reserve, one payee) are enforced by the app." | "On-chain limits" / "the chain enforces the caps" |
| "A stolen key file can drain Frogg's own balance, never the owner's." | "Unhackable wallet" |
| "Trips run over local Wi-Fi. The link isn't encrypted yet." | "Secure transfer" / "encrypted trip" |
| "iPhone: planned." | Showing an iPhone running Pixlz as real |
| Test suite runs: "against a simulated NEAR AI Cloud: they prove the app's decisions, not the hardware." | Presenting `pytest` / `attack_demo` output as live attacks |

Existing copy that breaks these rules and must not be reused: `showcase/plan.json` L3 ("so nobody
else can see what he's thinking") and L5 ("They pay for their own thinking"); the shorts lines
"pays for his own private AI" (`pixlz-general`), "he pays for it himself" (`pixlz-crypto`) and
"It pays for its own AI" (`pixlz-not-a-chatbox`). See PIPELINE.md §5.

Captions (all episodes unless stated): the VO verbatim, 3–5 words at a time, keyword in green `#7CD93A`, inside the safe zone in PIPELINE.md §3; labels (SIMULATED, testnet, render, planned) stay on screen for the whole shot.

**Check counts on recording day:** HEAD (`25cfcfa`) has 13 entries in `MANDATORY_CHECKS`. An uncommitted change in the working tree (from another session, not this brief) adds `gateway.tls`, which would make 14. Every "13" below means "the number in `MANDATORY_CHECKS` when you record".

Platforms: **TT** TikTok, **IG** Reels, **X**, **YT** Shorts, **J** judges/README. All 9:16
masters export a 4:5 crop too (`showcase/shorts/tools/render.sh` already makes both).

---

## V1 · "Okay, Pixlz is cute. But is he actually useful?"

- **Hook (0–2 s):** Frogg catches a fly; caption "ok he's cute." Hard cut to a messy draft: "but is he useful?"
- **Arc:** cute → skeptical question → three real jobs in 30 s (polish in place, memory with a backlink, a refusal when it can't prove privacy) → "cute on the outside, serious underneath."
- **Tech (accurate):** Polish sends the selected text to a model in a NEAR AI Cloud TEE only after attestation passes. The card replaces your selection. Highlights are stored locally (encrypted at rest) with a `#:~:text=` link back to the passage.
- **Proof:** E05 (a real polish with its checks), H04 (the backlink), E02b (the refusal card).
- **Available:** `showcase/takes/F1/take-1.mov` (fly), `W1/take-1.mov`, `M1`–`M3` take-1, `docs/screenshots/backlink-the-frog.png`.
- **New shots:** H10, E05, H04, E02b.
- **VO:** "Okay, he's cute. But is he useful? Select something clunky, click Frogg: he rewrites it, and it drops right back where you were writing. Highlight a passage, and he remembers it, with a link straight back to the line. And if he can't prove the AI is running in a sealed enclave, he refuses to send your text at all. Cute on the outside. Serious underneath."
- **Storyboard:** 1) F1 tongue snap, 0–2 s · 2) H10 owner squints at the draft, 2–4 s · 3) E05 select → card → drag, 4–13 s · 4) H04 save → reopen highlighted, 13–21 s · 5) E02b orange "NOT SENT" card, 21–26 s · 6) Frogg blink plus the series title, 26–30 s.
- **On-screen text:** "polish in place" · "memory, with the source" · "no proof → not sent".
- **Thumbnail:** Frogg perched on a window next to a big orange "NOT SENT". Text: "cute… useful?"
- **Length / platform:** 30 s · TT, IG, YT. **CTA:** "Which job should he learn next?"

## V2 · "Your AI says it's private. Can it prove it?"

- **Hook:** a black screen with "We don't train on your data." stamped "CAN'T CHECK THAT." Cut to the terminal: "this one I can."
- **Arc:** the promise problem → a live attestation anyone can run with no key → what the 14 properties mean in plain words → refusal when one is missing → the limit.
- **Tech:** a fresh nonce goes to NEAR AI Cloud. The Mac checks the Intel TDX quote (signature and TCB via dcap-qvl), that the debug bit is off, that our nonce is inside the signed report, that the signing key is bound in the quote, the RTMR3 event-log replay, and that the docker-compose hash matches MRCONFIGID, for both the gateway and the model, plus NVIDIA GPU attestation through NRAS. All 13 must pass before text is sent. **Limit:** this proves which code and hardware NEAR AI runs. It relies on Intel's and NVIDIA's roots of trust and on NEAR AI's measured images; it doesn't make the model local.
- **Proof:** E01 (live), `docs/hackathon/evidence/live-attest-2026-11-13.txt`.
- **Available:** `F3/take-1.mov` (brain → attestation card), `docs/screenshots/polish-panel-checks.png`.
- **New shots:** E01, E02a, E05 (checks expanded).
- **VO:** "Every AI says it's private. Can it prove it? This command asks NEAR AI's servers for a fresh, signed hardware report, with no account and no API key. My Mac checks thirteen things: that Intel signed it, that debug mode is off, that it's fresh for this request, that the signing key lives inside, the exact software that's running, and that NVIDIA vouches for the GPUs. All thirteen pass, or my text never leaves. It doesn't make the AI local. It makes the promise checkable."
- **Storyboard:** 1) promise card, 0–3 s · 2) E01 typed command, 3–6 s · 3) E01 ✔ lines scroll; each property lights up with a plain-word label, 6–30 s · 4) E02a one ✘ → "Refused. Nothing was sent.", 30–38 s · 5) E05 the same checks in the app panel, 38–45 s · 6) end card with the command, 45–50 s.
- **On-screen text:** "13 required checks" · "1 fails → nothing sent" · "try it: `cd memory && uv run pixl-memory attest`".
- **Thumbnail:** a terminal of green ✔ with Frogg holding a magnifier; "PROVE IT."
- **Length / platform:** 45–50 s · X, TT, IG, YT. **CTA:** "Run it yourself, link below. No key needed."

## V3 · "I tried tricking my AI into leaking private text"

- **Hook:** "I found a way to make my private AI send text it shouldn't. Then I fixed it."
- **Arc:** the attack (make NVIDIA's attestation service unreachable) → **before:** the check was marked "skipped", the verdict said "Partly verified", and the text was still sent → the fix (a skipped GPU check now blocks; then an allow-list of 14 mandatory properties) → **after:** a live refusal → 104 simulated cases and 23 attacks prove the decision logic → the honest label.
- **Tech:** at commit `bf53f98`, `attestation_ok` refused only on FAIL, so SKIP passed. Fixed in `4c85d08` (a GPU SKIP blocks) and `8247283` (`MANDATORY_CHECKS`: every property must be present and must pass). **Limit:** before the fix, the text went to an enclave whose Intel TDX attestation passed but whose GPU couldn't be verified. It didn't go to an attacker. The test suites use a simulated NEAR AI Cloud.
- **Proof:** E04a (diff), E04b (old build says "Partly verified", exit 0), E02a/b (new build refuses, real network), E03 (`104 passed`, `23/23`).
- **Available:** `docs/ATTACKS.md` row 7, `docs/screenshots/polish-refused.png` (app view, rendered).
- **New shots:** E02, E03, E04.
- **VO:** "I tried to trick my desktop pet into leaking private text. The trick: block NVIDIA's attestation service, so the GPU can't be verified. In the old version, that check was just marked 'skipped', and my text still went out. To an enclave that passed every other check, but still. So I changed one rule: thirteen properties are mandatory, and skipped counts as failed. Same attack today: refused, nothing sent. Then I wrote ninety-seven test cases against a simulated cloud to make sure it stays that way."
- **Storyboard:** 1) Frogg looking smug, 0–2 s · 2) E02 `/etc/hosts` line, 2–6 s · 3) E04b "PARTIAL: Partly verified" plus a red stamp "BEFORE: text sent", 6–14 s · 4) E04a diff zoom on `SKIP`, 14–22 s · 5) E02a "Refused… Nothing was sent." plus a green stamp "AFTER", 22–30 s · 6) E02b app card, 30–35 s · 7) E03 `104 passed` / `23/23` with the SIMULATED label, 35–42 s · 8) undo and VERIFIED again, 42–46 s.
- **On-screen text:** "BEFORE: GPU unverified → sent anyway" · "AFTER: skipped = failed" · "SIMULATED NEAR AI CLOUD" (on E03 only).
- **Thumbnail:** split screen: "PARTLY VERIFIED → SENT" (red) / "NOT SENT" (green), Frogg in the middle.
- **Length / platform:** 45–55 s · X (lead post), TT, YT. **CTA:** "Commit and tests linked. Try to break it."

## V4 · "Why does my desktop pet have a crypto wallet?"

- **Hook:** a coin pops over Frogg: "why does a frog need a wallet?"
- **Arc:** the question → a sub-account the owner funds → a payment per request with a receipt on the explorer → the limits the app enforces → what a stolen key can and can't do → the honest bit about credits.
- **Tech:** `frogg.<owner>.testnet` holds only what the owner sent; the key lives on the Mac (`~/Library/Application Support/PixlMemory/`, mode 0600); the owner's key never touches the Mac. After each request, the app sends a transfer sized to that request's NEAR AI cost to one allow-listed payee (the owner, by default). It's an accounting record; NEAR AI bills inference separately in credits. The per-request, per-day and per-week caps, the reserve and the single payee are **app code**. Someone with the key file can drain Frogg's own balance, never the owner's.
- **Proof:** E06 (explorer), H07 (cap refuses before sending), `docs/ATTACKS.md` rows 11–16.
- **Available:** `F2/take-1.mov` (coin, wallet card, explorer), `docs/screenshots/wallet-setup.jpg`, the README's first payment link (testnet nearblocks `GzuymmDA…`).
- **New shots:** E06, H07, O06, H10.
- **VO:** "Why does my desktop pet have a crypto wallet? He has his own testnet account, under mine, holding only what I gave him. Every time he answers, he records the cost with a payment from his wallet, and there's a receipt on chain. The AI itself is billed in NEAR AI credits; this is the accounting. My limits live in the app: per request, per day, per week, one payee. If someone stole his key, the worst case is his pocket money. Never mine."
- **Storyboard:** 1) F2 coin pop, 0–3 s · 2) O06 `wallet status` READY, 3–8 s · 3) E05 polish → E06 receipt → explorer, 8–22 s · 4) H07 limit hit → "not sent", 22–30 s · 5) ATTACKS rows 16 and 15 highlighted, 30–37 s · 6) Frogg counting coins, end card, 37–42 s.
- **On-screen text:** "testnet" (always visible) · "limits: enforced by the app" · "stolen key → Frogg's balance only".
- **Thumbnail:** Frogg with a tiny wallet; "his money, not mine."
- **Length / platform:** 40–45 s · X, TT, IG. **CTA:** "Should pets get an allowance? Tell me."

## V5 · "I made my desktop pet jump between computers"

- **Hook:** a wide shot: Frogg leaps off the MacBook screen and lands on a tiny cube display.
- **Arc:** the leap (one unbroken take) → there's only ever one Frogg (a checksum handover) → he comes back → Mac to Mac too → the honest limit.
- **Tech:** Bonjour (`_pixlz._tcp`) or BLE finds the device; the trip protocol hands over state with a checksum, so he's never lost or duplicated; an untrusted device has to ask first; a 6-digit pairing code (X25519 + HKDF). **Limit:** the trip channel isn't encrypted (plaintext on the LAN), so a device on your network could read it; signing frames is next. The iPhone is planned, not built.
- **Proof:** E07 (unbroken), H01, O03.
- **Available:** `showcase/takes/intro-frogg.mp4`, `showcase/shorts/raw/clip1–4`, `showcase/takes/D1/wide-1.mov` (a render; label it).
- **New shots:** E07, H01, O03, O08.
- **VO:** "I made my desktop pet jump between computers. That's not an edit: one take. He leaves the Mac, lands on the Mosaico, and there's only ever one of him: the handover is checksummed, so he can't be lost or copied. Tap him, he comes home. Works Mac to Mac too. Honest part: the link isn't encrypted yet. That's next."
- **Storyboard:** 1) E07 0–12 s uncut, with a small "one take · real speed" chip · 2) O08 macro of Frogg, 12–15 s · 3) E07 return leg, 15–24 s · 4) H01 Mac → Mac, 24–30 s · 5) O03 pairing code, 30–34 s · 6) card "trip link: not encrypted yet · iPhone: planned", 34–38 s.
- **Thumbnail:** a frame from E07 mid-leap between the two screens.
- **Length / platform:** 35–40 s · TT, IG, YT, X. **CTA:** "Where should he go next?"

## V6 · "What actually happens to your data?"

- **Hook:** "I traced every place my text goes when my desktop pet edits it."
- **Arc:** a map with four stops: (1) your Mac: highlights and drafts in local SQLite, AES-256-GCM encrypted at rest; (2) the attestation check, before anything leaves; (3) NEAR AI Cloud: processed inside a TEE, reply signed; the Mac checks the ECDSA signature over sha256(request) + sha256(response) against the attested key; (4) the chain: only the amount and transaction hash, never the text. What stays local: Claude Code transcripts and "open Spotify"-style commands. Limits.
- **Tech limits:** at-rest encryption protects the database file; the key sits in the same data directory, so it doesn't protect against someone who already has your user account. TEE processing is a different protection from encryption at rest. When a reply fails its signature check, it's discarded (not shown, saved or paid for), but the text **did** reach the enclave, and the UI says so. Web-search answers are signed by the attested gateway, not the model enclave, and labelled "partly verified".
- **Proof:** E05, E06, O05, H02, `docs/screenshots/polish-reply-rejected.png` (app view), `ask-open-spotify.png`.
- **New shots:** E05, E06, O05, H02.
- **VO:** "What actually happens to your text? It starts on your Mac, where saved things sit in an encrypted local database. Before anything leaves, the Mac checks the cloud enclave's proof. Then the text is processed inside that enclave, and the reply comes back signed. If the signature doesn't match, the reply is thrown away, and the app tells you your text did reach the enclave. On chain: just a payment amount. Never your words. Simple commands like 'open Spotify' never leave the Mac at all."
- **Storyboard:** a pixel-art flow diagram built from the README's ASCII diagram; each stop cuts to its proof shot (O05 → E01 → E05 → reply-rejected still → E06 → `ask-open-spotify.png`).
- **On-screen text:** "local: encrypted at rest" ≠ "cloud: processed in a TEE" (two separate labels, never merged).
- **Thumbnail:** Frogg following a dotted line across four boxes; "where your text goes."
- **Length / platform:** 55–60 s · X, YT, IG. **CTA:** "Ask me about any step in the comments."

---

## V7–V18 · More episodes (all grounded in shipped code)

Each episode lists hook, the arc with its tech and limits, proof and new shots, available assets,
VO, storyboard (seconds), on-screen text, thumbnail, length and platform, and CTA.

**V7 · "My pet googles things, privately-ish"**
- Arc and tech: Ask → the model calls NEAR AI's `web_context_search` ($0.005 a search) → the
  sources are listed. Limit: these answers are signed by the attested **gateway**, not the model
  enclave, and the UI says "partly verified".
- Proof: H02. Assets: `docs/screenshots/ask-web-joke.png`.
- VO: "My pet can search the web. Watch the label, though: partly verified. The answer was signed
  by NEAR's attested gateway, not the model's own enclave, and he tells you that."
- Storyboard: hook card 0–2 · H02 typing 2–6 · answer and sources 6–14 · zoom on "partly
  verified" 14–20 · CTA 20–25.
- On-screen text: "partly verified = signed by the gateway". Thumbnail: Frogg reading a newspaper.
- Length / platform: 25 s · X, TT. CTA: "Would you trust partly verified?"

**V8 · "Ask him about a city, get pictures"**
- Arc and tech: answers that name places show thumbnails; click one to enlarge. Private inference
  as in V2.
- Proof: H03. Assets: `docs/screenshots/ask-pictures.png`.
- VO: "Ask Frogg about Chicago, and he answers with pictures. Tap one, it gets big."
- Storyboard: H03 typing 0–3 · thumbnails 3–9 · enlarge 9–13 · CTA 13–15.
- On-screen text: "answers with pictures". Thumbnail: a grid of landmarks.
- Length / platform: 15 s · TT, IG. CTA: "Pick a city."

**V9 · "He found the right 'the frog' out of 35"**
- Arc and tech: the Chrome extension saves a passage with a `#:~:text=` backlink. The link reopens
  the page scrolled to and highlighted at the exact occurrence. Saves are stored locally,
  encrypted at rest.
- Proof: H04. Assets: `docs/screenshots/backlink-the-frog.png`, `backlink-long-passage.png`,
  `ask-save-backlink.png`, takes `M1`–`M3`.
- VO: "This page says 'the frog' thirty-five times. I saved one of them. A week later, one click,
  and he takes me back to that exact line."
- Storyboard: page with 35 hits 0–4 · H04 select and save 4–10 · close the tab and ask 10–16 ·
  reopen highlighted 16–22 · CTA 22–25.
- On-screen text: "back to the exact line". Thumbnail: a highlighted passage with Frogg's tongue.
- Length / platform: 25 s · X, TT. CTA: "What would you save?"

**V10 · "The immortal snail is now on my computer"**
- Arc and tech: Slugg's Inevitable (60 s, he chases the cursor, clicking bonks him) and Frogg's
  Snap (dodge the tongue; feints after 20 s). Typing ends the game instantly.
- Proof: H05. Assets: `docs/DEMO.md`; `showcase/shorts/out/pixlz-immortal-snail/*` is a Remotion
  animation, so replace it with real capture.
- VO: "The immortal snail is on my Mac now. He crawls toward my cursor, forever. Click him and he
  hides, then comes back faster. He's still coming."
- Storyboard: Slugg appears 0–3 · chase 3–11 · bonk 11–14 · "squelch!" and crown 14–18 · loop
  back to start 18–20.
- On-screen text: "real game, real Mac". Thumbnail: Slugg wearing a crown.
- Length / platform: 20 s · TT, IG. CTA: "Best score?"

**V11 · "My pet guards my coding agents"**
- Arc and tech: Claude Code hooks. The pet alerts on permission requests (Allow/Deny), and a
  paired Mosaico can approve with signed decisions. Transcripts never leave the Mac and aren't sent
  to NEAR AI. Only what you type in the chat panel reaches a session.
- Proof: H06, plus takes `C1`–`C3`. Assets: `showcase/takes/C2/take-1.mov`,
  `showcase/shorts/out/pixlz-dev/*`.
- VO: "A coding session wants to run 'rm -rf build'. Slugg jumps on the terminal and asks me
  first. I'm across the room, so I approve it on the Mosaico. Signed, done. And the transcripts
  never leave this Mac."
- Storyboard: C1 Slugg climbing 0–4 · C2 alert 4–10 · H06 tap on the Mosaico 10–16 · terminal
  continues 16–22 · "transcripts stay local" card 22–27 · CTA 27–30.
- On-screen text: "transcripts stay on this Mac". Thumbnail: Slugg on top of a Terminal.
- Length / platform: 30 s · X, TT. CTA: "Would you let it run?"

**V12 · "Every bug becomes a test" (dev-log)**
- Arc and tech: the loop from PIPELINE §6, told through the NRAS bug: change → regression test →
  demo. The tests use a simulated cloud.
- Proof: E03, E04. Assets: `docs/ATTACKS.md`.
- VO: "Here's how a privacy bug becomes a test that can't come back. Find it, write the rule,
  write the test that fails on the old code, then show it live."
- Storyboard: E04a diff 0–10 · E03 pytest 10–20 · E02a live refusal 20–30 · loop diagram 30–40.
- On-screen text: SIMULATED label on E03. Thumbnail: "104 passed", big.
- Length / platform: 40 s · X, YT. CTA: "Follow for the next bug."

**V13 · "I set my pet's allowance"** (REHEARSE H07)
- Arc and tech: in the Wallet bubble, set a weekly limit or Pause. When he's out of allowance, the
  polish is refused **before** anything is sent. The limit is enforced by the app, not on chain.
- Proof: H07. Assets: `F2/take-1.mov`.
- VO: "Frogg gets a weekly limit. Hit it, and he stops before sending anything. The limit lives
  in the app, not on the chain, and I can pause him any time."
- Storyboard: F2 wallet 0–4 · set the limit 4–9 · polish refused 9–15 · `wallet status` 15–20.
- On-screen text: "limits: in the app". Thumbnail: Frogg with empty pockets.
- Length / platform: 20 s · TT, IG. CTA: "How much would you give him?"

**V14 · "My repo won't let me leak my API key"**
- Arc and tech: `.githooks/pre-commit` runs `scripts/check-secrets.sh`, which blocks `.env` files
  and key-shaped strings. Limit: it's opt-in per clone (`git config core.hooksPath .githooks`).
  The test suite also runs it over every tracked file.
- Proof: H08. Assets: `docs/ATTACKS.md` row 22.
- VO: "I tried to commit an API key on purpose. Fake key. The hook refused. You have to switch it
  on once per clone, and the tests check every file anyway."
- Storyboard: H08 echo 0–4 · commit 4–8 · refusal 8–13 · CTA 13–15.
- On-screen text: "fake key used". Thumbnail: a red ✘ over `.env`.
- Length / platform: 15 s · X. CTA: "Do you have one of these?"

**V15 · "A website tried to talk to my pet"**
- Arc and tech: the local API listens on 127.0.0.1 and requires a token (401). A DNS-rebinding
  host gets 421. There's no CORS grant except `chrome-extension://`.
- Proof: H09. Assets: `docs/ATTACKS.md` rows 19–21.
- VO: "Can a random website poke the AI on my laptop? No token: 401. A sneaky domain pointing at
  my own machine: 421. Other websites: no access."
- Storyboard: hook 0–3 · curl 401 3–8 · curl 421 8–14 · rows 19–21 14–18 · CTA 18–20.
- On-screen text: "401 · 421 · no CORS". Thumbnail: Frogg as a bouncer.
- Length / platform: 20 s · X. CTA: "What else should I test?"

**V16 · "Six pets, nineteen looks"**
- Arc and tech: pets and skins; switching keeps memory, wallet and position. Limit: skins are a
  plain picker today; NFT skins are planned.
- Proof: O01. Assets: `docs/screenshots/skins-grid.png`, `pixlz-lineup.png`, `*-frames.png`.
- VO: "Six Pixls, two or three skins each. Switch any time; he keeps his memory and his wallet.
  Skins as NFTs? Planned, not built."
- Storyboard: lineup 0–3 · O01 switching 3–11 · "planned" chip 11–14 · CTA 14–15.
- On-screen text: "NFT skins: planned". Thumbnail: the lineup.
- Length / platform: 15 s · TT, IG. CTA: "Which one is you?"

**V17 · "My desktop pet uses 0.1 % CPU"**
- Arc and tech: Settings ▸ Energy, and `swift scripts/bench-energy.swift`, which fails above a
  1 % idle budget. Measured on one Apple-silicon MacBook Pro.
- Proof: O02. Assets: `docs/screenshots/settings-energy.png`.
- VO: "A desktop pet that doesn't eat your battery: about a tenth of a percent CPU when idle,
  measured. The benchmark fails the build if it goes over one percent."
- Storyboard: Frogg roaming 0–3 · Energy sparkline 3–9 · bench output 9–13 · CTA 13–15.
- On-screen text: "measured on one MacBook Pro". Thumbnail: a sparkline with Frogg asleep.
- Length / platform: 15 s · X, r/macapps. CTA: "What does yours idle at?"

**V18 · "Calm, Roam, Chaos"**
- Arc and tech: three behaviour modes. He never moves while you type, hides in full screen, and
  sleeps when you're idle.
- Proof: O07. Assets: `F1` takes, `showcase/shorts/raw/p-sleeping.jpg`.
- VO: "Calm: he sits. Roam: he explores. Chaos: he invites you to play. In every mode he freezes
  while you type."
- Storyboard: Calm 0–4 · Roam 4–8 · Chaos 8–12 · typing freeze 12–15.
- On-screen text: one mode name per beat. Thumbnail: three Frogg panels.
- Length / platform: 15 s · TT, IG. CTA: "Which mode?"

---

## J1 · Cinematic judges' cut (75–90 s, 16:9 and 9:16)

| t (s) | Shot | VO / text |
|---|---|---|
| 0–6 | H10 desk push-in; Frogg on the window | "This is Frogg. He lives on your Mac." |
| 6–12 | F1 fly snack (existing) | — (sound effects only) |
| 12–24 | E05 select → polish → card dropped in | "He rewrites what you select. But only after he's checked where it's going." |
| 24–34 | E01 ✔ lines, punched in | "A fresh hardware proof from NEAR AI Cloud. Thirteen required checks: Intel, NVIDIA, the exact code running." |
| 34–44 | E02a/b refusal | "If one can't be proven, your text doesn't leave. Not even once." Chip: "real network · NVIDIA blocked locally" |
| 44–56 | E06 explorer receipt | "He has his own testnet wallet, under mine, and records every request's cost on chain. A stolen key can only spend his balance." Chip: "limits enforced in the app" |
| 56–72 | E07 one-take trip | "And he travels: Mac to Mosaico and back, one take." Chip: "local Wi-Fi · link not encrypted yet" |
| 72–80 | Lineup (E2 take) | "Pixlz. Cute on the outside. Serious underneath." |
| 80–85 | End card | "Built on NEAR AI Cloud and NEAR testnet." |

## J2 · Technical judges' walkthrough (3:30–4:30, 16:9, screen-first)

1. **0:00–0:20 Problem.** README "The problem"; H10 desk.
2. **0:20–0:55 Attestation.** E01 full, unbroken, then walk the 14 properties on the evidence file. State the trust roots (Intel, NVIDIA, NEAR AI's measured images).
3. **0:55–1:40 Fail-closed.** E02a/b (real refusal) → E04a diff (`bf53f98` → `4c85d08`, `8247283`) → E04b old build "Partly verified" → E03 `104 passed`, `23/23` with the SIMULATED label.
4. **1:40–2:10 Reply integrity.** The signature over sha256(request)+sha256(response) against the attested key; `polish-reply-rejected.png` (app view) + `ATTACKS.md` rows 9–10.
5. **2:10–2:50 Wallet.** O06 → E05 → E06; rows 11–16; the limits are app-side; the transfer is accounting and inference is billed in NEAR AI credits; why a sub-account and not NEAR Intents (the README table).
6. **2:50–3:20 Local hardening.** H09 (401/421), H08 (pre-commit), O05 (at rest ≠ TEE).
7. **3:20–3:50 Trips.** E07 + O03; the plaintext link, stated.
8. **3:50–4:15 Scope and tests.** O09; what's planned (iPhone, NFT skins, encrypted trips); repo link.
