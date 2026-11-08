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

Baseline = `PixlzCore/` (needs, behavior, world map, physics, PetState, travel protocol), `docs/SPEC.md`, `docs/DECISIONS.md`, `docs/RESEARCH.md`, `design/`. Everything under `memory/`, `wallet/`, `macos/PixlMemory/`, `extension/` and this file is new.

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
| `wallet/` | Rust, near-sdk (cargo-near) | `frogg-wallet` policy contract deployed **on Frogg's own account**. Setup and teardown scripts. |
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

### Facts that shape the design (docs.near.org, read 2026-11-08)

- Function-call keys: one `receiver_id`, optional method list, and an allowance that **covers gas only**. They **cannot attach a deposit and cannot transfer NEAR**.
- Full-access keys can transfer, add keys, deploy and delete.
- A parent has **no control** over a sub-account after creating it.
- Creating an account burns a fixed 0.007 Ⓝ.
- `DeleteAccount` to a missing beneficiary burns the balance.
- NEAR AI Cloud credits are bought **only in the dashboard**. No on-chain purchase path is documented. Staking-for-inference exists, but its contract and method aren't documented. Per-request cost **is** available: `POST /v1/billing/costs` with the `inference-id` header from the completion.

### Options considered

| Design | What a stolen app key can do | Verdict |
|---|---|---|
| App holds the user's key | Everything | Rejected |
| App holds a **full-access key on `frogg.<user>`** | Drain Frogg's whole balance to anyone, add keys, delete the account. Main account safe. | Cap holds, but the whole balance is exposed |
| App holds a **function-call key on `frogg.<user>`** for its own `frogg-wallet` contract, method `pay_inference` only | Pay the **fixed payee** at most `max_per_call` per call and `max_per_day` per UTC day, out of Frogg's balance. Nothing else: no other receivers, no new keys, no deploy, no delete. Gas comes from the key's allowance, which is also capped. | **Chosen** |

### Chosen design

- `frogg.<user>.testnet` is created and funded by the user from their own wallet or CLI. The setup script runs `near` CLI commands that the **user** signs. The app never sees the user's key.
- The user deploys `frogg-wallet` to Frogg's account and calls `new` with:
  - `owner` = the user;
  - `payee` = the account that holds the NEAR AI credits (the user, or whoever runs the service);
  - `max_per_call`, `max_per_day`.
- The user adds one **function-call key** for the app: receiver `frogg.<user>.testnet`, methods `["pay_inference"]`, allowance 0.25 Ⓝ for gas. The app generates this key pair locally and only shows its public key.
- The full-access key used for setup stays with the user; it lets them sweep or delete Frogg later. The README tells them to keep it offline, or remove it to make the account policy-only. They can add one back only with the full-access key they still hold.
- `pay_inference(amount, receipt_hash)`:
  - only callable by the account itself (that is, the function-call key);
  - asserts the amount is within both limits;
  - transfers to `payee`;
  - emits a NEP-297 event `{amount, receipt_hash, spent_today}`.
- Owner-only methods: `set_limits`, `set_payee`, `pause`, `sweep(to_owner)`.
- **Hard cap, in layers:** Frogg's balance; then the per-call and per-day limits in the contract; then the gas allowance on the key. The user's main account is untouchable because no key for it ever touches the Mac.
- **Pricing:** NEAR AI bills in USD. `memory/` asks `/v1/billing/costs` for the request's `costNanoUsd` and converts at a fixed rate the user sets (`PIXL_NEAR_PER_USD`). If the cost isn't visible yet, it uses a flat per-request price. Real-time oracle pricing is out of scope.
- **Privacy of receipts:** the chain is public, so only `amount` and a **salted hash** of the receipt go on chain. The full receipt (inference id, model, cost, response hash, verdict, tx hash) stays in the local encrypted DB. The user can reveal one by publishing the salt.
- **Order:** inference first, then payment. If the payment fails (cap reached, paused), Frogg shows "I'm out of allowance" and refuses further polishes until topped up. The finished result is still shown.
- **Signing from Python:** a function-call transaction built and signed in `memory/` (Borsh + ed25519), using `py-near` or `near-kit` after a spike. If neither fits, a ~150-line encoder tested against near-cli output.
- **Testnet first.** Mainnet only if there's time, with tiny amounts.

**I will ask the owner before creating or funding any account, testnet included.** Contract tests run in near-workspaces' local sandbox, which creates no real accounts.

## Storage

SQLite at `~/Library/Application Support/PixlMemory/memory.db` (override: `PIXL_MEMORY_DIR`). Text fields use AES-256-GCM with a local key file (0600). The associated data is `table:id:column`, so encrypted values can't be swapped between rows. Frogg's function-call key lives in the same directory (0600). Nothing leaves the Mac except:
- the text of a polish request, sent to the attested enclave;
- a payment transaction carrying an amount and a hash.

## Tests

- `memory/`: `uv run pytest`, offline by default.
  - Fixture: a real attestation report captured 2026-11-08, plus forged variants: wrong nonce, swapped signer, tampered compose, tampered event, debug TD, GPU fail.
  - Signature tests use a locally generated secp256k1 key.
  - The HTTP flow runs end to end against a fake NEAR server (`httpx.MockTransport`), including "attestation fails → text never sent".
  - Live tests (`-m live`): attestation needs only the network; polish needs `NEARAI_API_KEY`.
- `wallet/`: `cargo test` unit tests plus near-workspaces sandbox tests. Limits, payee lock, pause, an attacker calling from another account, and a function-call key trying to transfer, add a key or delete — each must fail.
- `extension/`: text-fragment builder with `node --test`.
- `macos/`: diff and layout logic unit-tested; the overlay checked by hand.

## Security demo (AI Security & Defense)

A script with a logged run. It plays a compromised app holding Frogg's function-call key:
- `Transfer` → rejected by the protocol;
- `AddKey` → rejected;
- `pay_inference` to itself → payee is fixed;
- 1000× `pay_inference` → per-day limit;
- calling the user's account → wrong receiver.

Each attempt fails. The log goes in `wallet/ATTACKS.md`.

## Order

| Day | Work |
|---|---|
| Nov 8 | Plan, tag, branch. `memory/` core: verification, store, polish, server, CLI, tests. `pixl-memory attest` works with no key. |
| Nov 9 | `wallet/` contract and sandbox tests. Python signing spike. **Ask owner → create and fund `frogg.<user>.testnet`.** Extension. |
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
