# Pixlz security model

What Pixlz proves, what it enforces, and what you still have to trust. Every claim here points at
the code or test that backs it. Updated 2026-11-13.

**In one line:** before your text leaves the Mac, the local service proves the remote model runs in
a genuine, production Intel TDX + NVIDIA confidential-GPU enclave bound to this request. If it
can't prove all of it, nothing is sent. After the reply, it checks the enclave's signature over
the exact bytes. If that fails, the reply is thrown away.

## 1. Trust boundaries

```
 YOUR MAC (you control it)                     NEAR AI CLOUD (remote; attested)                 NEAR TESTNET (public)
 ┌──────────────────────────────┐   HTTPS      ┌──────────────────────────────────┐            ┌──────────────────────┐
 │ selected text                │ ───────────▶ │ gateway   Intel TDX VM           │            │ frogg.<owner>.testnet│
 │ Pixl app (Swift)             │  only after  │   (TLS ends here)                │            │  → payee transfer    │
 │   │ localhost + token        │  preflight   │      │                           │            │  amount, accounts,   │
 │ pixl-memory service (Python) │  passes      │ model     Intel TDX + 8×H100 CC  │            │  time, tx hash       │
 │   preflight + signature check│ ◀─────────── │   signs sha256(req)+sha256(resp) │            │  (no text, no prompt)│
 │ encrypted store (AES-256-GCM)│   reply +    └──────────────────────────────────┘            └──────────────────────┘
 │ store.key, Pixl wallet key,  │   signature        ▲ Intel PCS (TCB collateral)
 │ NEAR AI API key (.env)       │                    ▲ NVIDIA NRAS (GPU verdict, signed JWTs)
 └──────────────────────────────┘
```

| Where | Protection | What it means | What it does **not** mean |
|---|---|---|---|
| Mac, at rest | Highlights and drafts sealed with AES-256-GCM (`store.py`); key in `store.key`, mode 0600, same folder | A copied `memory.db` alone is unreadable | Not protection from malware running as you: it can read `store.key` too |
| Mac, wallet | Pixl's ed25519 key in `frogg_key.json`, mode 0600, created `O_EXCL` (`near.py`) | Only the Pixl's sub-account is ever at risk | The key is not in the Keychain or Secure Enclave |
| Mac, API key | `.env`, read by the service; a pre-commit hook blocks committing it (`scripts/check-secrets.sh`) | | Same as above: readable by anything running as you |
| Remote, in use | Confidential processing in an attested TEE | Your text is processed inside hardware-isolated memory whose code identity was measured | It is **not** a local or offline model. Your text does leave the Mac, encrypted in transit to an enclave. |
| Chain | Public transfer from the Pixl's account | Anyone can see that a Pixl paid, how much, and when | Your text, the prompt, the reply and the model output are **never** on chain |

"Encrypted at rest on the Mac" and "confidential processing in a remote TEE" are different
protections against different attackers. Pixlz uses both and never presents one as the other.

## 2. The preflight: what must be proven before any text is sent

`memory/src/pixl_memory/verify.py` → `MANDATORY_CHECKS`. Every one of these must be present and
`pass` (or `warn`: passed with a caveat shown to the user). A `fail`, a `skip` (could not be
checked) or a missing check refuses. The decision is made in the local service
(`NearAIClient.chat`, `nearai.py`), not in the UI, and every path that sends text (Polish, Ask,
Ask with web search) goes through `chat()`.

| Check id | Property | How |
|---|---|---|
| `gateway.quote`, `model.quote` | Quote signed by Intel; TCB not revoked | dcap-qvl verifies the quote's signature chain and TCB against Intel PCS collateral. `UpToDate` passes; `OutOfDate`/`SWHardeningNeeded`/config-needed are a visible **warn**; anything else fails |
| `*.debug` | Production TD | `TD_ATTRIBUTES` debug bit is 0 |
| `*.nonce` | Fresh for this request | Our random 32-byte nonce is in the signed `report_data`. A new nonce for every request, no cached verdicts |
| `*.signer` | Signing key bound to the enclave | The reported signing address is the first 32 bytes of the signed `report_data` |
| `*.rtmr3` | Runtime event log is genuine | Replaying the event log reproduces RTMR3 from the quote |
| `*.compose` | Deployed config is the one shown | sha256(app_compose) matches MRCONFIGID and the compose-hash event |
| `model.gpu` | GPUs are in confidential mode | Evidence nonce must match ours. NVIDIA NRAS verdict: overall true, secure boot on, debug off, every `x-nvidia-*` check true, no warning, not expired, our nonce on every token. **Every token's ES384 signature is verified against NVIDIA's JWKS** |
| (extra) `model.unique` | One identity | Several verified candidates with different keys refuse |
| (extra) `model.deploy` | Deployment log | When present, the compose-manager quote must come from the same TD and carry the log hash + nonce |

The model report must name the exact model requested. A report with no `model_name` can't stand in
for ours. Only models `owned_by: nearai` (NEAR's own TEE fleet) are allowed at all.

### Fixed today: a skipped GPU check let text out

At `bf53f98` (the tagged submission), `Verification.attestation_ok` rejected only `fail`. When NRAS
was unreachable, or the GPU verifier was off, `model.gpu` was `skip` and **the text was sent**.
Reproduced by mutation: putting the old rule back makes 13 tests in `tests/test_preflight_matrix.py`
fail (NRAS down, NRAS 5xx, NRAS timeout and GPU verifier disabled, on Polish, Ask and web Ask, plus
`/attestation` claiming `may_send`). The rule is now an allow-list.

`GET /attestation` returns `may_send`, `trust` and `blocking`, so a verdict label can't be mistaken
for permission.

## 3. The reply: signature lifecycle

`verify_signature` + `NearAIClient.chat`:

1. The request body is serialized once (`encode_body`). Those exact bytes are sent and hashed.
2. The raw response bytes are kept before parsing. For web search, the raw SSE stream is kept.
3. `GET /v1/signature/{chat_id}` is retried on 404 for up to 8 s.
4. The signed text must equal `"{model}:{sha256(req)}:{sha256(resp)}"` (model enclave) or
   `"{sha256(req)}:{sha256(resp)}"` (gateway). A signature for another chat, a duplicated chat id,
   or edited bytes doesn't match.
5. ECDSA recovery must give the claimed address, and that address must be the one **attested in
   this request's preflight**: the model key for `provider_tee`, the gateway key for `gateway`.
6. The reply must name the model we attested (`x-no-aliasing: true` is sent).

| Outcome | `trust` | What the user gets |
|---|---|---|
| Model enclave signed our exact bytes | `enclave_signed` | Result, "Verified in TEE" |
| Attested gateway signed them | `gateway_signed` | Result, labelled "Gateway-signed". Never promoted to enclave |
| No signature within 8 s | `unsigned` | Result, labelled "Attested · reply unsigned" (the preflight did pass) |
| Wrong signer, bad signature, edited bytes, wrong model | `rejected` | **No result.** HTTP 502 `response_untrusted`. Not shown, not saved as a draft, not paid for. The UI says the text *did* reach the attested enclave and the reply was discarded |
| Preflight failed | `refused` | HTTP 409 `attestation_failed`, `text_sent: false` |

## 4. What attestation does not prove (remaining trust)

- **Measurements are not pinned to known-good values.** Pixlz proves a genuine, production,
  fresh TDX enclave whose config hash, event log and keys are consistent. It does not compare MRTD,
  RTMRs or the compose hash to a reproducible build of NEAR's stack. The images and the deployment
  commit are shown to the user, not enforced. Measurement-to-source provenance relies on NEAR
  publishing those builds.
- **Upstream verifiers are trusted.** Intel PCS collateral (via dcap-qvl) and NVIDIA NRAS. NRAS
  token signatures are checked against NVIDIA's JWKS, fetched over TLS from
  `nras.attestation.nvidia.com`. NVIDIA's root CA is not in the JWKS, so it isn't pinned here.
- **TLS isn't bound to the attested gateway.** The preflight and the completion POST are two HTTPS
  requests to `cloud-api.near.ai`, linked only by TLS and DNS. Someone who controls that hostname's
  TLS could answer the preflight correctly (it's a replayable proof only for *their* nonce, so they
  would need a real enclave) and route the completion elsewhere. The reply signature then fails
  and the reply is discarded, but **the text has already been sent**. NEAR publishes an attested
  OHTTP key (`ohttp_attestation` in the report). Encrypting the request to it would close this.
  Not implemented yet.
- **The gateway sees plaintext.** TLS ends in NEAR's gateway, which is itself an attested TDX VM
  (checked above), then forwards to the model enclave.
- **Web search sends the model's search query to NEAR's search provider**, server-side. The search
  results are inside the signed stream.
- **Tests use a simulated NEAR AI Cloud.** `test_preflight_matrix.py` and `attack_demo.py` prove the
  client's decision logic, not the security of real hardware. Live evidence:
  `docs/hackathon/evidence/live-attest-2026-11-13.txt` (all 13 mandatory checks pass, 8 × GH100,
  TCB UpToDate, NVIDIA token signatures valid).

## 5. The Pixl's wallet

| Layer | Enforced by | Holds against |
|---|---|---|
| The Pixl's balance (what the owner sent to `<pet>.<owner>.testnet`) | **NEAR protocol** | Everything, including a stolen key: the worst case is that balance |
| The owner's account | **NEAR protocol**: no key for it exists on the Mac | Everything on the Mac |
| Per-request / per-day / per-week caps, the reserve, pause | **App code** (`wallet.py`), checked before signing; pending transfers count | A buggy or compromised *service request*. **Not** local malware, which can edit `.env` or use the key file directly |
| One payee | **App code**: the only transfer the app builds goes to the configured payee | Same as above. Not on chain |

- **Not on chain:** the caps and the payee rule are not an on-chain policy contract, so they are not
  immutable. The hardening path is a policy contract plus a function-call access key (not built).
- **What the payment is:** a NEAR testnet transfer from the Pixl to its payee, sized to that
  request's NEAR AI cost (or a flat price), as an accounting record. **NEAR AI inference is billed
  off-chain in NEAR AI credits.** The transfer does not buy the inference.
- **Retries:** a transfer whose outcome is unknown (timeout, unreadable reply after sending) is
  recorded `pending` with its hash and still counts toward the caps. It is not retried
  automatically, so there's no duplicate payment. Nonces never repeat in a process (`near.py`).
- **Rejected replies are not paid for.** Testnet only: mainnet RPCs and non-sub-account Pixls are
  refused at startup.

## 6. Local service and browser

| Attack | Defense | Test |
|---|---|---|
| A web page calls `127.0.0.1:7341` | Bearer token (0600 file), constant-time compare | `attack_demo` #19 |
| DNS rebinding | `Host` must be `127.0.0.1`/`localhost`, else 421 | #20 |
| Cross-origin from a site | CORS only for `chrome-extension://` origins | #21 |
| Prompt injection from saved highlights | Highlights go only to the attested enclave as quoted context. Ask can't make the service send anywhere else or pay anyone else | Limitation: a poisoned highlight can still steer the *answer* |
| Malicious backlink (`fragment_url`) | Stored as text; opened by the browser like any link | Limitation: open links you trust |
| Committing secrets | pre-commit hook | #22 |

## 7. Device trips (Mac ↔ Mac, Mac ↔ Mosaico)

- **Pairing** (Mac ↔ Mosaico): the same 6-digit code shows on both screens. X25519 with a
  commitment, then HKDF (`mosaico/pixl_trip/include/pixl_trip/pt_pair.h`). A paired Mosaico's
  Allow/Deny decisions for Claude Code agent requests are signed.
- **Who can take a Pixl:** only a trusted or paired device can call it away. Any other device has
  to ask, and a copy you can reclaim always stays behind (`PixlzCore/.../Travel.swift`).
- **Integrity of a trip:** `offer → transfer → ack(checksum) → commit → commitAck`. A checksum
  mismatch aborts and the Pixl stays home. Epochs settle which copy is newer.
- **Transport is not encrypted or signed.** It's Bonjour/TCP on the LAN. A device on your network
  can read a trip packet (the Pixl's name, skin and state) or claim another device's name. No text,
  keys or highlights travel with a Pixl. Signing every frame with the pairing key is the next step.
  It is not claimed.
- The iPhone app is a plan (`docs/IOS-PLAN.md`), not part of this submission.

## 8. Test results (2026-11-13, this Mac)

| Suite | Result |
|---|---|
| `memory`: `uv run pytest -q` | 227 passed (includes 97 preflight-matrix and 5 NRAS-signature tests) |
| `memory`: `uv run python attack_demo.py` | 22/22 behaved as expected (`docs/ATTACKS.md`) |
| `memory`: live attest-only (`pixl-memory attest`) | VERIFIED, all mandatory checks pass |
| `macos/PixlMemory`: `swift test` | 197 + 12 + 37 passed |
| `PixlzCore`: `swift test` | 157 + 23 passed |
| `extension`: `node --test` | all passed |

Preflight matrix (`tests/test_preflight_matrix.py`). Each row runs on Polish, Ask and web Ask, and
asserts that `/chat/completions` was never called, the private marker string appears in no outgoing
request, and no draft was saved.

| Case | Private payload sent |
|---|---|
| NRAS unreachable / 5xx / timeout | NO |
| GPU verification disabled | NO |
| GPU evidence missing / not JSON / rejected by NVIDIA | NO |
| GPU evidence for a different nonce; NRAS token with a different nonce | NO |
| NRAS token expired; GPU debug enabled | NO |
| NRAS token forged / edited / alg:none / unknown key (`test_nras_signature.py`) | NO (GPU check fails) |
| TDX quote garbage / truncated / bad Intel signature chain | NO |
| TCB revoked | NO |
| Debug-mode TD | NO |
| Model attestation missing; gateway attestation missing | NO |
| Forged signer address | NO |
| Tampered runtime event (RTMR3 mismatch) | NO |
| Modified docker-compose | NO |
| Stale nonce; replay of a genuine old report | NO |
| Wrong model name; unnamed model report | NO |
| Two verified candidates with different signers | NO |
| Empty / `null` / `[]` / `{}` / non-JSON / wrongly typed report | NO |
| Network failure or timeout during preflight | NO |
| Reply signed by the wrong key, tampered, garbage signature, forged gateway signature, other model | Sent (preflight passed), **reply discarded** |
