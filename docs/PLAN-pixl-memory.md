# Pixl Memory — hackathon plan

NEAR Hackathon (rulebook: https://nearhackathon.com/HACKATHON.md, re-read 2026-11-08).
Submission closes **2026-11-14 23:59 UTC**. Judging Nov 16–18.
Tracks: **Privacy & Private AI** (primary, id `privacy`), **Agent Economy** (`agents`), **AI Security & Defense** (`security`).

Pixl Memory forks Pixlz. Frogg sits on the window you're working in, keeps the passages you save, and rewrites your text using models that run inside NEAR AI Cloud TEEs. Every answer comes with a verification result you can open. Frogg also has **its own NEAR account with a small balance**. It pays for each inference from that balance, and the app can never spend more than that, nor touch your main account.

## Baseline vs hackathon work

| | |
|---|---|
| Baseline | 14 commits, 2026-10-15 22:40 CT → 2026-10-16 02:48 CT, all before the 2026-10-19 announcement. Tag `pre-hackathon` = `8f546ec`. |
| Hackathon | Started 2026-11-08 on branch `near-hackathon`. Tag `hackathon-submission` at the end. |
| Diff | `https://github.com/devluca999/pixlz/compare/pre-hackathon...hackathon-submission` |

Baseline = `PixlzCore/` (needs, behavior, world map, physics, PetState, travel protocol), `docs/SPEC.md`, `docs/DECISIONS.md`, `docs/RESEARCH.md`, `design/`. Everything under `memory/`, `macos/PixlMemory/`, `extension/`, `scripts/`, `.githooks/`, `.env.example` and this file is new.

## What the user sees

1. Select text anywhere on the Mac, click Frogg, pick **Polish this**.
2. A panel shows the word diff and a badge: **Verified in TEE** / **Partly verified** / **Not verified**, with each check listed.
3. Drag the suggestion from the panel into the text field. Pixl Memory never types or pastes for you (SPEC R4).
4. Frogg's thought bubble shows its balance (e.g. "0.42 Ⓝ left") and a receipt for the request: cost, tx link, verdict.
5. In Chrome: select a passage → right-click **Save to Pixl Memory**. It is stored with a text-fragment link (`#:~:text=…`) that reopens the page scrolled to that passage.

## Components

| Dir | Stack | Job |
|---|---|---|
| `memory/` | Python 3.12 (uv), FastAPI, SQLite | Local service on `127.0.0.1:7341`. Stores highlights and drafts (encrypted at rest). Runs every inference through NEAR AI Cloud and verifies it. Pays per request from Frogg's wallet. CLI: `pixl-memory serve · attest · polish · wallet · token`. |
| `macos/PixlMemory/` | Swift 6, AppKit, SwiftPM executable using `PixlzCore` | Overlay panel per SPEC §12: borderless, non-activating, click-through except Frogg's opaque pixels. Perches on the frontmost window's top edge (§7.1). Click → menu (§11.2) → Polish → diff panel → drag source. Thought bubble (§11.6) for balance and receipts. |
| `extension/` | Chrome MV3, no build step | Context menu and popup. Builds text-fragment URLs and posts them to `memory/`. |

All three clients talk to `memory/` over localhost with a bearer token (`~/Library/Application Support/PixlMemory/token`, mode 0600). Without it, any web page could call the service.

## Private inference and verification (memory/)

Sources: docs.near.ai/cloud/verification/*, read 2026-11-08 and checked against the live API that day. Gateway quote: TCB `UpToDate`. Model GPU attestation: NRAS `true` on 8 GPUs. Nonce and signer bound in both quotes. RTMR3 replays.

Per polish request:

1. **Preflight, before any text leaves the Mac.** Fresh 32-byte nonce, then `GET /v1/attestation/report?model=…&provider=near&signing_algo=ecdsa&nonce=…` with `x-no-aliasing: true`. Checks for the gateway and every model candidate:
   - Intel TDX quote verified with `dcap-qvl` (TCB `UpToDate`; other statuses pass with a warning, revoked fails).
   - Debug bit off.
   - `report_data` from the **verified quote bytes**: our nonce in bytes 32–64, `signing_address` in bytes 0–20.
   - RTMR3 replayed from the event log. NEAR ships the IMR3 digests empty, so we recompute them from the event content.
   - `MRCONFIGID = 0x01 ‖ sha256(app_compose)`, which pins the exact docker-compose and images.
   - Model only: NVIDIA evidence nonce = ours, and NRAS `x-nvidia-overall-att-result: true`.
   - Exactly one distinct verified model signer.

   **If attestation fails, the text is never sent.**
2. **Completion,** non-streaming. With streaming, the gateway re-signs, which doesn't prove the model enclave ran. We keep the exact request and response bytes.
3. **Signature:** `GET /v1/signature/{id}`. Checks:
   - signed text = `model:sha256(req):sha256(resp)`;
   - EIP-191 recovery gives `signing_address`;
   - that address = the model signer attested in step 1, before the request.
4. **Verdict:** `verified` only if every check passes and the signature is `provider_tee`. A gateway signature or any check that couldn't run → `partial`. Any failure → `failed`, and the suggestion is marked untrusted.

Only NEAR-hosted (`owned_by: nearai`) models are allowed. "Incognito" models (OpenAI, Anthropic, …) are refused because their upstream runs outside a TEE. Default `z-ai/glm-5.3-flash`, the model NEAR's own verification examples use.

## Frogg's wallet

**Decision (2026-11-08, after reading docs.near.org, docs.near-intents.org, and the NEAR-Intents-Agent-API skills and SDK): a funded NEAR sub-account.** The README explains the choice for judges.

Facts that decided it:
- **NEAR Intents Agent API: mainnet-only beta, real funds.** Its partner key must never ship in an app, so we'd need a backend proxy. Creating the account, setting policy and issuing grants are all owner-signed intents. It has no NEAR AI integration. "Agent Connect" itself is linked from the SDK README, but its repo couldn't be read (GitHub 504). Its server-side policy engine (destinations, budgets, freeze) is the upgrade path for large balances.
- **NEAR accounts:** a parent has no control over a sub-account after creation. A function-call key cannot transfer NEAR or attach a deposit, and its allowance covers only gas.
- **NEAR AI Cloud:**
  - Credits are bought only in the dashboard; there's no documented on-chain purchase, x402 or Intents path.
  - Per-request cost: `POST /v1/billing/costs` with the `inference-id` header.
  - Per-API-key USD spend limits exist (`PATCH /v1/workspaces/{id}/api-keys/{key}/spend-limit`, session token only), so the user sets them in the dashboard.

Design:
- **Setup.** The user creates `frogg.<user>.testnet` and funds it with a small balance from their own wallet or CLI. The app generates Frogg's key pair locally and shows the public key; the user adds it when creating the account. The private key stays in the data directory (0600), never in the repo and never in `.env`.
- **Payment.** Per polish, after the result is shown:
  - cost = `costNanoUsd` × `PIXL_NEAR_PER_USD`, or a flat fallback price if billing hasn't caught up;
  - one `Transfer` from Frogg to the allowlisted payee;
  - the payee comes from config, and the app refuses any other recipient.
- **Caps.**
  1. Frogg's balance: protocol-enforced; the user's main account is unreachable.
  2. Per-request maximum and daily maximum: enforced in the app.
  3. Optional NEAR AI per-key USD spend limit: enforced by NEAR AI.
- **Receipts.**
  - On chain: amount and transaction hash only.
  - Stored locally, encrypted with the draft: inference id, model, cost, verdict, tx hash.
  - The thought bubble shows the balance (`view_account`) and the last receipt with a testnet explorer link.
- **Out of allowance.** If the balance or the daily cap is reached, Frogg says so and refuses further polishes until topped up.
- **Signing.** One `Transfer` transaction (Borsh + ed25519), via `py-near` or `near-kit` after a spike, or a small encoder tested against near-cli output.
- **Optional hardening, if time allows.** A tiny policy contract on Frogg's account; the app then holds only a function-call key for `pay_inference` (fixed payee, per-call and daily caps enforced on chain). A stolen app key could then pay nobody but the payee.
- **Testnet first.** **Ask the owner before creating or funding any account.**

## Storage

SQLite at `~/Library/Application Support/PixlMemory/memory.db` (override: `PIXL_MEMORY_DIR`). Text fields use AES-256-GCM with a local key file (0600). The associated data is `table:id:column`, so encrypted values can't be swapped between rows. Frogg's function-call key lives in the same directory (0600). Nothing leaves the Mac except:
- the text of a polish request, sent to the attested enclave;
- a payment transaction carrying an amount and a hash.

## Tests

- `memory/`: `uv run pytest`, offline by default.
  - Fixture: a real attestation report captured 2026-11-08, plus forged variants: wrong nonce, swapped signer, tampered compose, tampered event, debug TD, GPU fail.
  - Signature tests use a locally generated secp256k1 key.
  - The HTTP flow runs end to end against a fake NEAR server (`httpx.MockTransport`), including "attestation fails → text never sent".
  - Live tests (`-m live`): attestation needs only the network; polish needs `NEAR_AI_API_KEY` in `.env`.
- Wallet: transaction encoding checked against near-cli output; payee allowlist, per-request and daily caps, and out-of-balance handling unit-tested; one live testnet payment (after owner approval).
- Secrets: `.env` is the only key source; `.env*` ignored; `scripts/check-secrets.sh --all` passes over tracked files (run by pytest).
- `extension/`: text-fragment builder with `node --test`.
- `macos/`: diff and layout logic unit-tested; the overlay checked by hand.

## Security demo (AI Security & Defense)

A logged script, saved in `docs/ATTACKS.md`, plays a compromised Pixl Memory. Each attempt must fail:
- Attestation preflight:
  - forged or replayed TEE report: text not sent;
  - incognito model: refused;
  - reply signed by an unattested key: marked failed.
- Wallet:
  - pay a recipient that isn't on the allowlist: refused;
  - exceed the per-request or daily cap: refused;
  - spend more than Frogg's balance: rejected by NEAR;
  - reach the user's main account: no key on the Mac.
- Secrets: commit a key or a `.env`: blocked by the hook.

## Order

| Day | Work |
|---|---|
| Nov 8 | Plan, tag, branch. `memory/` core: verification, store, polish, server, CLI, tests. `pixl-memory attest` works with no key. |
| Nov 9 | Wallet: signing spike, payments, receipts, caps (tests offline). **Ask owner → create and fund `frogg.<user>.testnet`.** Extension. |
| Nov 10 | `memory/` payments and receipts, end to end on testnet. Live polish with an API key. |
| Nov 11–12 | macOS overlay: perch, click menu, AX selection, polish panel, diff, drag, thought bubble. |
| Nov 13 | Attack demo log, README, screenshots, demo video. |
| Nov 14 | Tag `hackathon-submission`. Owner makes the repo public, posts on X and submits the form. All before 23:59 UTC. |

## README must include (rules Q-002, Q-003, Q-005, Q-012, Q-015)

- What it does and the problem; "do X → see Y" steps; one-command run plus tests for `memory/`.
- **Baseline vs hackathon work**: the dates above and the compare link.
- Pixlz also plans a Solana layer; it is not part of this submission.
- Our other independent entry: **Evernear** (shipment escrow).
- Every library used and anything AI-generated (code written with Claude Code; placeholder Frogg pixels drawn in code).
- "Published publicly for NEAR Hackathon judging. No license is granted." The LICENSE stays proprietary.
- The wallet design and why it keeps main funds untouchable.

## Things only the owner can do

- Create and fund `frogg.<user>.testnet` (I'll prepare the exact commands and ask first).
- Create a NEAR AI Cloud API key and buy credits (cloud.near.ai → Credits → API Keys).
- Make the repo public before Nov 14 23:59 UTC; write and publish the X post (@NEARProtocol, #NEARHackathon, video); submit the form with a mainnet payout address.

## Risks

- **License:** rule Q-014 says "Any … add a LICENSE file". We have one (proprietary). "No license granted" isn't addressed in the rules; if in doubt, ask organizers via the request-changes page.
- **Timing:** the rulebook says commits must postdate the 10-19 announcement; the heading says 11-01. Our baseline predates both, and all new work is from 11-08, so either reading is fine.
- NEAR AI per-request cost can lag a few seconds; we fall back to a flat price and fix the receipt later.
- Unsigned `swift run` builds ask for Accessibility under Terminal.
