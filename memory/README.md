# pixl-memory

The local service behind Pixl Memory. It stores your highlights and drafts on your Mac, encrypted at rest, and runs every inference through a NEAR AI Cloud model inside a TEE. Before any text leaves the Mac, it checks that the TEE is genuine.

## Run

Requires [uv](https://docs.astral.sh/uv/). It fetches Python 3.12 and the dependencies itself.

```sh
make -C memory            # run the tests, then start the service on 127.0.0.1:7341
```

Or step by step:

```sh
cd memory
uv run pytest             # 41 offline tests (fixture: a real NEAR attestation report)
uv run pytest -m live     # against the real NEAR AI Cloud
uv run pixl-memory attest # verify the TEE now; no API key needed
cp ../.env.example ../.env  # then set NEAR_AI_API_KEY (cloud.near.ai → Credits → API Keys)
uv run pixl-memory polish "teh frog sit on the windw"
uv run pixl-memory serve
```

`pixl-memory attest` prints every check:

```
VERIFIED: Verified: the model enclave is attested (Intel TDX + NVIDIA GPU) and bound to this session's nonce.

  ✔ Gateway Intel TDX quote            signed by Intel, TCB UpToDate
  ✔ Gateway fresh for this request     our nonce is in the signed report data
  ✔ Gateway signing key bound          0xb98a…e779 is bound in the quote
  ✔ Gateway event log replay           10 runtime events reproduce RTMR3
  ✔ Gateway app config measured        compose sha256 cdb77275… matches MRCONFIGID
  ✔ Model Intel TDX quote              signed by Intel, TCB UpToDate
  ✔ Model signing key bound            0x3b75…fa0c is bound in the quote
  ✔ NVIDIA GPU attestation             NVIDIA NRAS: overall result true for 8 GPU(s)
  ✔ Model deployment log               214 signed actions, last deploy prod/small-models.yaml @ f2b0b35c
  …
```

## What is checked, per request

1. **Before sending anything:**
   - A fresh 32-byte nonce, then `GET /v1/attestation/report` for the gateway and the model.
   - For each report:
     - the Intel TDX quote is verified with `dcap-qvl` (signature chain and TCB status);
     - the debug bit is off;
     - our nonce and the signing key are inside the quote's signed `report_data`;
     - RTMR3 is replayed from the event log;
     - `MRCONFIGID` equals `sha256(app_compose)`;
     - the NVIDIA GPU evidence is checked by NVIDIA NRAS;
     - the compose-manager deployment log is hash-bound to the same enclave.
   - Models that aren't served from NEAR's own TEEs (`owned_by != "nearai"`) are refused. **If any check fails, the text is not sent.**
2. **Completion:** non-streaming. We keep the exact request and response bytes.
3. **Signature:** `GET /v1/signature/{id}`. The signed text must equal `model:sha256(our request):sha256(their response)`. The ECDSA signature must recover to the model key attested in step 1.

Verdicts:

| Verdict | Means |
|---|---|
| `verified` | Every check passed and the model enclave signed the reply. |
| `partial` | Something couldn't be checked (e.g. a gateway-only signature, or the signature not available yet). |
| `failed` | A check failed. The suggestion is shown as untrusted. |

## API (127.0.0.1 only)

Every route except `/health` needs `Authorization: Bearer $(uv run pixl-memory token)`. Requests with a `Host` other than localhost are rejected (DNS-rebinding guard). CORS allows only `chrome-extension://` origins.

| Route | |
|---|---|
| `GET /health` | status, model, whether an API key is set |
| `GET /attestation?model=` | run and return a full verification |
| `GET /models` | NEAR-hosted TEE models |
| `POST /highlights` `{text, url?, title?, fragment_url?}` | save a highlight |
| `GET /highlights?q=&limit=` · `DELETE /highlights/{id}` | list / search / delete |
| `POST /polish` `{text, instruction?, model?}` | `{draft_id, suggestion, diff, stats, verification}`; 409 with the verification if attestation failed (text not sent), 412 without an API key |
| `GET /drafts` · `GET /drafts/{id}` · `POST /drafts/{id}/status` | history; mark accepted or discarded |

## Storage

`~/Library/Application Support/PixlMemory/` (override with `PIXL_MEMORY_DIR`). The directory is 0700 and its files 0600.
- `memory.db`: SQLite. Every text column is AES-256-GCM encrypted, with `table:id:column` as associated data.
- `store.key`: the encryption key.
- `token`: the API token.

## Configuration

API keys are read **only** from the repo's `.env` (git-ignored; template: `.env.example`): `NEAR_AI_API_KEY`. Other settings are ordinary environment variables:

| Env | Default |
|---|---|
| `PIXL_MODEL` | `z-ai/glm-5.3-flash` |
| `PIXL_MEMORY_PORT` | `7341` |
| `PIXL_MEMORY_DIR` | see above |
| `PIXL_PCCS_URL` | Phala PCCS (dcap-qvl default) |
| `NEARAI_BASE_URL` | `https://cloud-api.near.ai/v1` |

## Layout

| File | |
|---|---|
| `src/pixl_memory/tdx.py` | TDX quote fields, RTMR3 replay, MRCONFIGID, deployment-log hash |
| `src/pixl_memory/verify.py` | checks and verdicts; Intel (dcap-qvl) and NVIDIA (NRAS) verifiers |
| `src/pixl_memory/nearai.py` | client: attest → complete → signature |
| `src/pixl_memory/polish.py` | prompt, output cleanup, word diff |
| `src/pixl_memory/store.py` | encrypted SQLite store |
| `src/pixl_memory/server.py` | FastAPI app |
| `src/pixl_memory/cli.py` | `pixl-memory` |
| `tests/` | offline suite plus `-m live` |
