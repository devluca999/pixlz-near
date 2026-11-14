# Judge walkthrough

## 90 seconds: what to look at

1. **The claim.** Pixlz checks that the remote model runs in an attested Intel TDX + NVIDIA
   confidential-GPU enclave *before* your text leaves the Mac. If it can't prove everything, it
   sends nothing.
2. **Run it yourself, free, no account:**
   ```sh
   git clone https://github.com/devluca999/pixlz-near && cd pixlz-near/memory
   uv run pixl-memory attest
   ```
   You get VERIFIED and 15 ✔ lines: 14 mandatory checks, from the gateway's TLS key in its quote
   to NVIDIA's signed GPU tokens, plus the deployment log.
3. **Watch it refuse:** `uv run python attack_demo.py`. 23 attacks against the real code with the
   upstream simulated, incl. "NVIDIA's attestation service unreachable" (this used to leak; fixed
   2026-11-13) and "hijacked TLS server" (stopped in the handshake).
4. **The pet has its own money:** each Pixl pays per request from its own NEAR testnet
   sub-account. The README links a receipt on nearblocks. The owner's key is never on the Mac.

## 5 minutes: reproduce the proof

| Step | Command (in `memory/`) | What you should see |
|---|---|---|
| 1 | `uv run pixl-memory attest` | VERIFIED. `Gateway TLS key bound`, `NVIDIA GPU attestation … NVIDIA token signatures valid` |
| 2 | `uv run pytest tests/test_preflight_matrix.py -q` | 104 passed: 27 attacks on Polish, Ask and web Ask, each asserting `/chat/completions` was never called and the private marker never left |
| 3 | `uv run pytest -m live -k "attestation or tls" -q` | 2 passed: the pinned connection accepts the attested key and rejects another (no text sent, no key needed) |
| 4 | `uv run python attack_demo.py` | 23/23 |
| 5 | `uv run pytest -q` | 240 passed |
| 6 | (Mac) `cd .. && scripts/install.sh`, select text in Mail, click Frogg → **Polish this** → **Show checks** | The diff, the badge, "Where your text went" (This Mac → Gateway TEE → Model TEE → GPUs → Signed reply), every check. Needs `NEAR_AI_API_KEY` in `.env` |
| 7 | Read `docs/SECURITY-MODEL.md` §4 | What attestation does **not** prove |

Mutation check (optional): in `verify.py` make `attestation_ok` return
`not any(c.status is Status.FAIL …)` (the pre-fix rule) and re-run step 2. 13 tests fail: the
GPU-unverifiable cases leak.

## Honest limits, up front

- The tests simulate NEAR AI Cloud. They prove the client's decisions, not the hardware. Live
  evidence is the `attest` run.
- Measurements aren't compared to reproducible builds. Caps and the payee rule live in app code,
  not on chain. The trip link isn't encrypted. The iPhone app is a plan.
