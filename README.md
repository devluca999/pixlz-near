# Pixl Memory

**Frogg, a pixel-art frog that sits on your Mac and edits your writing privately.** Select text in any app, click Frogg, and ask "polish this". Your text goes only to a model running inside a NEAR AI Cloud TEE (Intel TDX + NVIDIA confidential GPUs). Before any text leaves the Mac, Pixl Memory checks the hardware attestation. Every reply arrives with a verification result: which enclave produced it, whether it was fresh for this request, and whether its signature matches.

Frogg also has **its own NEAR account with a small balance it spends on its own inference**. The app holds only Frogg's key, never yours, so Frogg's balance is the most it can ever spend.

Built for the **NEAR Hackathon** (Nov 2026). Tracks: **Privacy & Private AI** (primary), Agent Economy, AI Security & Defense.

> Published publicly for NEAR Hackathon judging. No license is granted. See [`LICENSE`](LICENSE).

## The problem

Writing assistants see everything you write: unsent emails, medical notes, contracts. "We don't train on your data" is a promise you can't check. Pixl Memory lets you check: the model runs in an enclave whose code and hardware are attested, and your Mac verifies that **before** sending, not after.

## Try it

**The verification works today with no account:**

```sh
make -C memory                       # 41 tests, then starts the local service
# or
cd memory && uv run pixl-memory attest
```

Requires [uv](https://docs.astral.sh/uv/) (`brew install uv`). It installs Python 3.12 and every dependency.

| Do | See |
|---|---|
| `uv run pixl-memory attest` | 14 checks against the live NEAR AI Cloud: Intel TDX quote and TCB, your nonce inside the signed quote, signing key bound, RTMR3 replay, measured docker-compose, NVIDIA GPU attestation, deployment log |
| `cp .env.example .env`, set `NEAR_AI_API_KEY`, then `uv run pixl-memory polish "teh frog sit on the windw"` | the polished text plus the verdict; the response signature recovers to the attested model key |
| `uv run pixl-memory serve`, then `POST /polish` | JSON with suggestion, word diff, and the full verification |
| Load `extension/` unpacked in Chrome, paste the token from `uv run pixl-memory token`, select text → right-click **Save to Pixl Memory** | the frog toolbar popup lists it; its link reopens the page highlighted at that passage ([`extension/README.md`](extension/README.md)) |
| `scripts/build-mac-app.sh --open`, allow Accessibility, select text in any app, click Frogg → **Polish this** | Frogg hops onto the active window; the panel shows the word diff, the verdict and all 17 checks; drag the green-edged card into your text |
| `uv run pytest` | forged reports rejected: wrong nonce, swapped signer, tampered compose or event log, debug TD, failed GPU, unattested signer; "attestation fails → text is never sent" |

Full details: [`memory/README.md`](memory/README.md).

## How it works

```
 macOS overlay (Frogg)      Chrome extension
   select → polish → diff     highlight → save → #:~:text= backlink
        \                     /
         127.0.0.1:7341  pixl-memory  (encrypted SQLite, token auth)
                │  1. attest: nonce → Intel TDX + NVIDIA NRAS + signer binding
                │  2. only then: completion (exact bytes kept)
                │  3. signature over sha256(request):sha256(response) → attested key?
                ▼
        NEAR AI Cloud  ── gateway TEE ── model TEE (z-ai/glm-5.3-flash)
                │
        Frogg's wallet  frogg.sylversurferr.testnet  ── transfer(cost) ─▶ payee (allowlisted)
```

| Part | Status |
|---|---|
| `memory/`: local service, verification, encrypted store, CLI | **working**, 41 tests |
| Frogg's wallet: `frogg.sylversurferr.testnet`, funded by `sylversurferr.testnet`, pays per request | next (account names and checks in place, 8 tests) |
| `macos/PixlMemory/`: overlay app: Frogg perches on the active window; click → polish → diff → drag the result into your text | built, 16 tests; `scripts/build-mac-app.sh --open` |
| `extension/`: Chrome highlight → save → text-fragment backlink | built, 10 tests; first run in Chrome pending |

Plan and design notes: [`docs/PLAN-pixl-memory.md`](docs/PLAN-pixl-memory.md).

## Frogg's wallet: why your funds stay untouchable

**Choice: a plain NEAR sub-account that the owner funds: `frogg.sylversurferr.testnet`, under the owner's testnet account `sylversurferr.testnet`.** We considered a NEAR Intents agent account (the Agent API) and rejected it for this app.

**How it works:**
- **The owner creates `frogg.sylversurferr.testnet` from their own wallet (Meteor) and sends it a small amount.** The owner approves every transaction from their account in Meteor; the app never asks for a recovery phrase or private key. Your keys are never on the Mac, and NEAR gives a parent account no control over a sub-account after creation. Pixl Memory has no path to your main account.
- **The app holds only Frogg's own key, for Frogg's account.** The most a stolen key can spend is the balance you chose to give Frogg. That balance is the hard cap, enforced by NEAR itself.
- **Frogg pays per request with a plain NEAR transfer.** The recipient is the account that holds the NEAR AI credits (you, or whoever runs the service). There is no documented way to buy NEAR AI credits on-chain; they're bought in its dashboard. The amount is the request's real cost from `/v1/billing/costs`, converted at a rate you set. The app refuses to pay any other recipient.
- **Your balance and receipts appear in Frogg's thought bubble.** On chain is only the amount and transaction. The receipt itself (model, cost, verification verdict) stays in the local encrypted store.
- **A second cap you can add:** set a USD spend limit on your NEAR AI API key in the cloud.near.ai dashboard. NEAR AI enforces it per key.

**Why not a NEAR Intents agent account** (checked 2026-11-08 against docs.near-intents.org and the `NEAR-Intents-Agent-API` SDK and skills):

| | NEAR Intents Agent API | Funded sub-account |
|---|---|---|
| Network | **Mainnet only**, real funds ("experimental, mainnet-only beta") | **Testnet** first, free |
| Credentials in the app | A partner API key, which the docs say must **never ship in an app**, so it needs our own backend; plus a grant token | One key, for Frogg's account only |
| Setup | Owner-signed intents to create the account, set policy, issue a grant | One account-creation and one transfer, from your wallet |
| Limits | Rich policy (destinations, budgets, schedules, freeze), enforced by the service | Balance = hard cap, enforced by the protocol; recipient allowlist in our code |
| NEAR AI integration | None | None (same) |
| Code for us | SDK (Node 24) + backend proxy + owner-signing flow | Sign and send one transfer |

Both keep your main funds untouchable. The sub-account does it with far less code, works on testnet, and needs no server.
- The Agent API's server-side policy engine is the stronger tool for an agent that holds large balances. It is the upgrade path if Frogg ever does.
- A smaller step is to deploy a tiny policy contract on Frogg's account and give the app only a function-call key for its `pay_inference` method. NEAR function-call keys can't transfer NEAR or add keys, so a stolen key could then only pay the fixed payee within per-call and daily limits. We list that as optional hardening, not part of the first build.

Testnet first. No account is created or funded without the owner's go-ahead.

## Keys and secrets

This repo is public, so **API keys live only in `.env`**, which is git-ignored. Copy `.env.example` (empty values) to `.env` and fill in `NEAR_AI_API_KEY`. The service reads keys from that file only: not from code, arguments or the shell environment. It never prints them.

`scripts/check-secrets.sh` blocks commits containing anything key-shaped or any `.env` file. Turn it on per clone with `git config core.hooksPath .githooks`. The test suite runs it over every tracked file.

Frogg's own NEAR key isn't an API key. It's stored outside the repo, in `~/Library/Application Support/PixlMemory/` (mode 0600).

## Baseline vs hackathon work

Pixlz is the owner's existing desktop-pet project. This entry adds the NEAR integration on top of it.

| | Commits | Dates |
|---|---|---|
| **Baseline**, tag [`pre-hackathon`](https://github.com/devluca999/pixlz/tree/pre-hackathon) (`8f546ec`) | 14 | 2026-10-15 22:40 CT → 2026-10-16 02:48 CT, all before the 2026-10-19 announcement |
| **Hackathon work**, branch `near-hackathon`, tag `hackathon-submission` | everything after | started 2026-11-08 |

**Diff of all hackathon work:** https://github.com/devluca999/pixlz/compare/pre-hackathon...hackathon-submission

- **Baseline:** `PixlzCore/` (pet needs, behavior, world map, physics, PetState, Mac↔iPhone travel protocol), `docs/SPEC.md`, `docs/DECISIONS.md`, `docs/RESEARCH.md`, `design/`, `assets/`.
- **New in the hackathon:** `memory/`, `macos/PixlMemory/` (including the generated `FroggSpriteData.swift`), `extension/`, `scripts/`, `.githooks/`, `.env.example`, `docs/PLAN-pixl-memory.md`, decision D15, and this README.

Pixlz also plans a **Solana** layer. It is not part of this submission.

**Our other, independent entry: Evernear** (shipment escrow).

## Libraries and AI use

**`memory/`** (Python 3.12, managed with uv):

| Library | Used for |
|---|---|
| [FastAPI](https://fastapi.tiangolo.com) + [Uvicorn](https://www.uvicorn.org), Pydantic | local HTTP API |
| [httpx](https://www.python-httpx.org) | HTTP client |
| [dcap-qvl](https://github.com/Phala-Network/dcap-qvl) (Phala) | Intel TDX quote verification |
| [eth-account](https://github.com/ethereum/eth-account) | EIP-191 signature recovery |
| [cryptography](https://cryptography.io) | AES-GCM at rest |
| [python-dotenv](https://github.com/theskumar/python-dotenv) | reads API keys from `.env` |
| pytest, hatchling | tests, build |

**External services:**
- NEAR AI Cloud: inference, attestation, signatures.
- NVIDIA Remote Attestation Service: GPU evidence.
- Phala PCCS: Intel collateral.

**Baseline:** Swift 6, Swift Package Manager, no third-party Swift packages.

**`extension/`:** no libraries, no build step (plain JavaScript modules; tests use Node's built-in `node --test`).

**`macos/PixlMemory/`:** AppKit, ApplicationServices (Accessibility, read-only), Swift Testing, and the baseline `PixlzCore` (hop physics). No third-party packages. Frogg's frames are exported from the baseline Claude Design engine (`design/explorations/c3`) by `scripts/render-frogg.mjs` and embedded as text: no PNGs.

The wallet code will list its libraries here when it lands.

**AI-generated content:**
- The hackathon code, tests and docs in this branch were written with **Claude Code** (Anthropic, Claude Opus 5.5), directed and reviewed by the owner.
- `design/` is a snapshot of a Claude Design project.
- The test fixture `memory/tests/fixtures/attestation_report.json` is a real NEAR AI Cloud attestation response, captured 2026-11-08.

## Repository layout

```
memory/      Hackathon: local service, NEAR AI private inference + verification
macos/       macOS app; PixlMemory/ overlay is hackathon work
extension/   Hackathon: Chrome extension (highlight → save → backlink)
PixlzCore/   Baseline: shared Swift package (pet state, behavior, travel)
docs/        SPEC.md, DECISIONS.md, RESEARCH.md (baseline); PLAN-pixl-memory.md (hackathon)
design/ assets/ ios/ windows/   Baseline
```

Baseline core tests: `swift test --package-path PixlzCore`.

## License

Copyright © 2026 Luca M. All rights reserved. See [`LICENSE`](LICENSE).
Published publicly for NEAR Hackathon judging. No license is granted.
