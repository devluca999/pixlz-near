# Pixl Memory

**Frogg, a pixel-art frog that sits on your Mac and edits your writing privately.** Select text in any app, click Frogg, and ask "polish this". Your text goes only to a model running inside a NEAR AI Cloud TEE (Intel TDX + NVIDIA confidential GPUs). Before any text leaves the Mac, Pixl Memory checks the hardware attestation. Every reply arrives with a verification result: which enclave produced it, whether it was fresh for this request, and whether its signature matches.

Frogg also has **its own NEAR account with a small balance it spends on its own inference**. The app holds only a narrowly scoped key for that account, never yours.

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
| `NEARAI_API_KEY=sk-… uv run pixl-memory polish "teh frog sit on the windw"` | the polished text plus the verdict; the response signature recovers to the attested model key |
| `uv run pixl-memory serve`, then `POST /polish` | JSON with suggestion, word diff, and the full verification |
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
        Frogg's wallet  frogg.<you>.testnet  ── pay_inference(amount, receipt_hash) ─▶ payee
```

| Part | Status |
|---|---|
| `memory/`: local service, verification, encrypted store, CLI | **working**, 41 tests |
| `wallet/`: Frogg's spending-capped NEAR account and policy contract | in progress |
| `macos/PixlMemory/`: overlay app: perch, polish, diff, drag | in progress |
| `extension/`: Chrome highlight → save → text-fragment backlink | in progress |

Plan and design notes: [`docs/PLAN-pixl-memory.md`](docs/PLAN-pixl-memory.md).

## Frogg's wallet: why your funds stay untouchable

- **You create and fund `frogg.<you>.testnet` yourself.** NEAR gives a parent account no control over a sub-account after creation, and the app never sees your keys.
- **The app holds one function-call key on Frogg's account.** It is scoped to Frogg's own `frogg-wallet` contract and to the single method `pay_inference`. NEAR enforces three things at the protocol level:
  - a function-call key **cannot transfer NEAR or attach a deposit**;
  - it **cannot add keys, deploy or delete**;
  - its allowance covers gas only.
- **The contract limits what that one method can do.** It pays a **fixed payee**, at most `max_per_call` per call and `max_per_day` per day, and only while not paused.
- **The worst case is small.** If the app is compromised, the attacker can pay your chosen payee up to the daily limit, until Frogg's small balance runs out. Your main account is never at risk.
- **Rejected alternative:** a full-access key on Frogg's account would also protect your main account, but whoever stole it could send Frogg's entire balance anywhere.
- **NEAR AI Cloud bills in USD credits bought in its dashboard.** There's no documented way to buy them on-chain. So Frogg pays the account that holds the credits: you, or whoever runs the service. The price is the request's real cost from `/v1/billing/costs`, converted at a rate you set.
- **Receipts stay private.** Only the amount and a salted hash of the receipt go on chain. The full receipt (model, cost, verdict, tx) stays in the local encrypted store.

Testnet first. No account is created or funded without the owner's go-ahead.

## Baseline vs hackathon work

Pixlz is the owner's existing desktop-pet project. This entry adds the NEAR integration on top of it.

| | Commits | Dates |
|---|---|---|
| **Baseline**, tag [`pre-hackathon`](https://github.com/devluca999/pixlz/tree/pre-hackathon) (`8f546ec`) | 14 | 2026-10-15 22:40 CT → 2026-10-16 02:48 CT, all before the 2026-10-19 announcement |
| **Hackathon work**, branch `near-hackathon`, tag `hackathon-submission` | everything after | started 2026-11-08 |

**Diff of all hackathon work:** https://github.com/devluca999/pixlz/compare/pre-hackathon...hackathon-submission

- **Baseline:** `PixlzCore/` (pet needs, behavior, world map, physics, PetState, Mac↔iPhone travel protocol), `docs/SPEC.md`, `docs/DECISIONS.md`, `docs/RESEARCH.md`, `design/`, `assets/`.
- **New in the hackathon:** `memory/`, `wallet/`, `macos/PixlMemory/`, `extension/`, `docs/PLAN-pixl-memory.md`, decision D15, and this README.

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
| pytest, hatchling | tests, build |

**External services:**
- NEAR AI Cloud: inference, attestation, signatures.
- NVIDIA Remote Attestation Service: GPU evidence.
- Phala PCCS: Intel collateral.

**Baseline:** Swift 6, Swift Package Manager, no third-party Swift packages.

`wallet/`, `macos/` and `extension/` will list their libraries here as they land.

**AI-generated content:**
- The hackathon code, tests and docs in this branch were written with **Claude Code** (Anthropic, Claude Opus 5.5), directed and reviewed by the owner.
- `design/` is a snapshot of a Claude Design project.
- The test fixture `memory/tests/fixtures/attestation_report.json` is a real NEAR AI Cloud attestation response, captured 2026-11-08.

## Repository layout

```
memory/      Hackathon: local service, NEAR AI private inference + verification
wallet/      Hackathon: Frogg's NEAR wallet contract and scripts (in progress)
macos/       macOS app; PixlMemory/ overlay is hackathon work (in progress)
extension/   Hackathon: Chrome extension (in progress)
PixlzCore/   Baseline: shared Swift package (pet state, behavior, travel)
docs/        SPEC.md, DECISIONS.md, RESEARCH.md (baseline); PLAN-pixl-memory.md (hackathon)
design/ assets/ ios/ windows/   Baseline
```

Baseline core tests: `swift test --package-path PixlzCore`.

## License

Copyright © 2026 Luca M. All rights reserved. See [`LICENSE`](LICENSE).
Published publicly for NEAR Hackathon judging. No license is granted.
