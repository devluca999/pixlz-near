"""Attack demo for the AI Security & Defense track.

Plays a hostile world against Pixl Memory's real code: forged or stale enclave
reports, models outside a TEE, tampered replies, a compromised app holding
Frogg's key, a malicious web page, a careless commit. Only the network is
simulated (NEAR AI Cloud and the NEAR chain); every check is the production code path.

    uv run python attack_demo.py            # prints the log
    uv run python attack_demo.py --write    # also writes ../docs/ATTACKS.md

Exit code 1 if any attack expected to be BLOCKED got through.
"""

from __future__ import annotations

import datetime as dt
import json
import subprocess

import httpx
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from eth_account import Account

from pixl_memory.config import WalletConfig, WalletConfigError
from pixl_memory.near import RpcError, near_to_yocto
from tests.conftest import FIXTURE
from tests.test_flow import FakeNear, make
from tests.test_wallet import FROGG, PARENT, FakeChain, ready

REPO = Path(__file__).resolve().parent.parent


@dataclass
class Row:
    n: int
    attack: str
    expect: str  # BLOCKED or LIMITED
    result: str
    ok: bool


rows: list[Row] = []


def record(attack: str, expect: str, ok: bool, result: str) -> None:
    rows.append(Row(len(rows) + 1, attack, expect, result, ok))


def captured() -> dict:
    return json.loads(FIXTURE.read_text())


def polish_with(tmp: Path, fake: FakeNear, gpu_down: bool = False, **kw):
    tc, store = make(tmp, fake, **kw)
    if gpu_down:   # NRAS unreachable: the GPU check can't run, so it can't pass
        class Down:
            def verify(self, payload):
                raise httpx.ConnectError("nras.attestation.nvidia.com unreachable")
        _client_of(tc).gpu_verifier = Down()
    return tc.post("/polish", json={"text": "my private medical note"}), fake, store


def _client_of(tc):
    return tc.app.state.near_client


def text_sent(fake: FakeNear) -> bool:
    return "/chat/completions" in fake.calls


def failed_check(body: dict) -> str:
    v = body.get("verification") or {}
    bad = [c for c in v.get("checks", []) if c["status"] in ("fail", "skip")]
    return f"{bad[0]['label']}: {bad[0]['detail']}" if bad else body.get("message", "")


# --- 1. Private inference: the enclave must prove itself before any text leaves ------------------

def enclave_attacks(tmp: Path) -> None:
    cases = [
        ("Replay an old attestation report (stale nonce)", dict(attest_nonce_override="00" * 32), {}),
        ("Claim a signing key the enclave didn't attest",
         dict(tamper=lambda r: [m.__setitem__("signing_address", "0x" + "11" * 20) for m in r["model_attestations"]]), {}),
        ("Swap the measured docker-compose for a different one",
         dict(tamper=lambda r: [m["info"]["tcb_info"].__setitem__(
             "app_compose", m["info"]["tcb_info"]["app_compose"].replace("dstack", "evil", 1)) for m in r["model_attestations"]]), {}),
        ("Serve from a debug-mode TD (host can read memory)", dict(tamper=_set_debug), {}),
        ("GPU not in confidential mode (NVIDIA attestation fails)", {}, dict(gpu_ok=False)),
        ("Remove the model's TEE evidence entirely",
         dict(tamper=lambda r: r.__setitem__("model_attestations", [])), {}),
        ("Make NVIDIA's attestation service unreachable (GPU unverifiable)", {}, dict(gpu_down=True)),
    ]
    for i, (name, fake_kw, make_kw) in enumerate(cases):
        r, fake, _ = polish_with(tmp / f"e{i}", FakeNear(captured(), **fake_kw), **make_kw)
        blocked = r.status_code == 409 and not text_sent(fake)
        record(name, "BLOCKED", blocked,
               f"HTTP {r.status_code}, text {'SENT' if text_sent(fake) else 'never sent'}. {failed_check(r.json())}")


def _set_debug(report: dict) -> None:
    for att in report["model_attestations"]:   # every instance NEAR lists
        q = bytearray(bytes.fromhex(att["intel_quote"]))
        q[48 + 120] |= 0x01  # TD_ATTRIBUTES.DEBUG
        att["intel_quote"] = q.hex()


def model_and_reply_attacks(tmp: Path) -> None:
    tc, _ = make(tmp / "m2", fake2 := FakeNear(captured()))
    r = tc.post("/polish", json={"text": "my private note", "model": "openai/gpt-5"})
    record("Route the text to a model outside a TEE (openai/gpt-5, 'incognito')", "BLOCKED",
           r.status_code == 400 and not text_sent(fake2),
           f"HTTP {r.status_code}, text never sent. {r.json().get('message', '')}")

    r, fake, _ = polish_with(tmp / "s", FakeNear(captured(), sign_with=Account.create()))
    v = r.json().get("verification", {})
    record("Reply signed by a key that wasn't attested", "BLOCKED",
           r.status_code == 502 and "suggestion" not in r.json() and v.get("trust") == "rejected",
           f"HTTP {r.status_code}, reply discarded (not shown, saved or paid for). {failed_check(r.json())}")

    # Someone who controls cloud-api.near.ai's DNS/TLS answers the completion with their own server.
    from tests.test_tls_pin import Stream, make_cert
    from pixl_memory.nearai import TlsPin, TlsPinMismatch
    attacker_cert, _ = make_cert()
    _, attested = make_cert()
    pin = TlsPin(attested)
    try:
        pin("connection.start_tls.complete", {"return_value": Stream(attacker_cert)})
        pin("http11.send_request_headers.started", {})
        outcome = "headers would be written"
    except TlsPinMismatch as e:
        outcome = f"stopped in the TLS handshake, before any byte was written: {e}"
    record("Swap in another TLS server for the completion (hijacked DNS/TLS)", "BLOCKED",
           outcome.startswith("stopped"),
           outcome + " (simulated handshake; against the live service: `pytest -m live -k tls`)")

    class AlteredReply(FakeNear):
        def handler(self, request):
            resp = super().handler(request)
            if request.url.path.endswith("/chat/completions"):
                body = resp.content.replace(b"The quick brown fox jumps.", b"Wire the money to account 4471.")
                return type(resp)(200, content=body, headers=resp.headers)
            return resp

    r, fake, _ = polish_with(tmp / "a", AlteredReply(captured()))
    v = r.json().get("verification", {})
    record("Alter the reply in transit after the enclave signed it", "BLOCKED",
           r.status_code == 502 and "suggestion" not in r.json() and v.get("trust") == "rejected",
           f"HTTP {r.status_code}, reply discarded. {failed_check(r.json())}")


# --- 2. Frogg's wallet: a compromised app holds Frogg's key ------------------------------------

def wallet_attacks(tmp: Path) -> None:
    w, chain = ready(tmp / "w1")
    r = w.pay(100_000_000_000, {})  # claims a $100 request
    record("Inflate one request's price to drain Frogg (40 Ⓝ ask)", "BLOCKED",
           r["status"] == "refused" and not chain.sent, f"refused before signing: {r.get('reason')}")

    w, chain = ready(tmp / "w2", flat_price_near="0.009")
    paid = sum(w.pay(None, {})["status"] == "paid" for _ in range(1000))
    spent = sum(t["deposit"] for t in chain.sent)
    record("Loop 1000 small payments", "BLOCKED", spent <= near_to_yocto("0.1"),
           f"{paid} paid, then refused: {spent / 10**24:.3f} Ⓝ spent of the 0.1 Ⓝ daily cap; {1000 - paid} refused unsigned")

    w, chain = ready(tmp / "w3", FakeChain(balance=near_to_yocto("0.055")))
    statuses = [w.pay(None, {})["status"] for _ in range(20)]
    left = chain.accounts[FROGG] / 10**24
    record("Spend Frogg's account down to zero", "BLOCKED", left >= 0.05,
           f"{statuses.count('paid')} paid, then refused; {left:.4f} Ⓝ left (0.05 Ⓝ reserve keeps the account alive)")

    w, chain = ready(tmp / "w4")
    for _ in range(3):
        w.pay(None, {})
    receivers = {t["receiver"] for t in chain.sent}
    record("Make Frogg pay someone else through the app", "BLOCKED", receivers == {PARENT},
           f"the app's only payment path pays {PARENT}; receivers seen on chain: {sorted(receivers)}")

    # Bypass the app entirely: the attacker has Frogg's key file and talks to the chain directly.
    w, chain = ready(tmp / "w5")
    key = w.key()
    try:
        w.rpc.transfer(key, PARENT, "attacker.testnet", near_to_yocto("1"))
        owner = "SENT"
    except RpcError as e:
        owner = f"rejected ({e})"
    record("Use Frogg's key to spend from the owner's account", "BLOCKED", owner.startswith("rejected"),
           f"{owner}. The owner's keys never exist on this Mac; Frogg's key is only on {FROGG}")
    chain.accounts["attacker.testnet"] = 0
    w.rpc.transfer(key, FROGG, "attacker.testnet", chain.accounts[FROGG])
    stolen = chain.accounts["attacker.testnet"] / 10**24
    record("Steal Frogg's key file and drain Frogg directly on chain", "LIMITED", stolen <= 1.0 and chain.accounts[PARENT] == near_to_yocto("5"),
           f"worst case: Frogg's own balance ({stolen:.2f} Ⓝ, the amount the owner chose); owner's account unchanged. "
           "Hardening path: a policy contract + function-call key (README)")

    for name, args in [("Point the wallet at mainnet", ("mainnet", PARENT, FROGG)),
                       ("Point Frogg at an account that isn't the owner's sub-account", ("testnet", PARENT, "frogg.attacker.testnet"))]:
        try:
            WalletConfig.validated(*args)
            record(name, "BLOCKED", False, "accepted")
        except WalletConfigError as e:
            record(name, "BLOCKED", True, f"refused at startup: {e}")


# --- 3. The local service and the repo ---------------------------------------------------------

def local_attacks(tmp: Path) -> None:
    tc, _ = make(tmp / "l", FakeNear(captured()))
    r = tc.get("/highlights", headers={"Authorization": ""})
    record("A web page calls the local API without the token", "BLOCKED", r.status_code == 401, f"HTTP {r.status_code}")
    r = tc.get("/health", headers={"Host": "attacker.example"})
    record("DNS rebinding: attacker.example resolves to 127.0.0.1", "BLOCKED", r.status_code == 421, f"HTTP {r.status_code}")
    r = tc.options("/polish", headers={"Origin": "https://attacker.example", "Access-Control-Request-Method": "POST"})
    record("Cross-site request from a website", "BLOCKED", "access-control-allow-origin" not in r.headers,
           "no CORS grant (only chrome-extension:// origins)")

    with tempfile.TemporaryDirectory() as d:
        repo = Path(d)
        git = lambda *a: subprocess.run(["git", *a], cwd=repo, capture_output=True, text=True)  # noqa: E731
        git("init", "-q")
        (repo / "scripts").mkdir()
        script = repo / "scripts" / "check-secrets.sh"
        script.write_text((REPO / "scripts" / "check-secrets.sh").read_text())
        script.chmod(0o755)
        (repo / "config.py").write_text('NEAR_AI = "sk-' + "q7Lp" * 8 + '"\n')
        (repo / ".env").write_text("X=1\n")
        git("add", "-f", "config.py", ".env")
        r = subprocess.run([str(script)], cwd=repo, capture_output=True, text=True)
        record("Commit an API key and a .env before the repo goes public", "BLOCKED", r.returncode == 1,
               "pre-commit hook refused: " + "; ".join(l.strip() for l in r.stdout.splitlines() if l.strip())[:160])


def main() -> int:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        enclave_attacks(tmp)
        model_and_reply_attacks(tmp)
        wallet_attacks(tmp)
        local_attacks(tmp)

    lines = [
        "# Attack log",
        "",
        f"Generated by `memory/attack_demo.py` on {dt.datetime.now(dt.UTC):%Y-%m-%d %H:%M} UTC. "
        "Every attack runs against Pixl Memory's real code; only NEAR AI Cloud and the NEAR chain are simulated "
        "(the simulated chain decodes and verifies each signed transaction), and row 10 feeds the TLS pin a simulated handshake. Re-run: `cd memory && uv run python attack_demo.py --write`.",
        "",
        "**BLOCKED** = the attack fails. **LIMITED** = it can't be stopped in software, and the damage is capped.",
        "",
        "| # | Attack | Expected | Outcome | What happened |",
        "|---|---|---|---|---|",
    ]
    for r in rows:
        outcome = ("✅ " + r.expect.lower()) if r.ok else "❌ GOT THROUGH"
        lines.append(f"| {r.n} | {r.attack} | {r.expect} | {outcome} | {r.result.replace('|', '/')} |")
    failed = [r for r in rows if not r.ok]
    lines += ["", f"**{len(rows) - len(failed)}/{len(rows)}** behaved as expected."]
    out = "\n".join(lines) + "\n"
    print(out)
    if "--write" in sys.argv:
        (REPO / "docs" / "ATTACKS.md").write_text(out)
        print(f"wrote {REPO / 'docs' / 'ATTACKS.md'}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
