"""Frogg's wallet against a fake NEAR testnet RPC that decodes and verifies every
signed transaction, so the tests prove what would actually reach the chain."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import struct

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from fastapi.testclient import TestClient

from pixl_memory.config import WalletConfig
from pixl_memory.near import Rpc, b58encode, near_to_yocto
from pixl_memory.server import create_app
from pixl_memory.store import Store
from pixl_memory.wallet import Policy, Wallet

PARENT, FROGG = "sylversurferr.testnet", "frogg.sylversurferr.testnet"
N = near_to_yocto


class FakeChain:
    def __init__(self, balance: int = N("1")):
        self.accounts: dict[str, int] = {FROGG: balance, PARENT: N("5")}
        self.keys: dict[str, set[str]] = {FROGG: set()}
        self.nonce = 100
        self.sent: list[dict] = []

    @staticmethod
    def decode(signed: bytes) -> dict:
        def string(b, i):
            n = struct.unpack_from("<I", b, i)[0]
            return b[i + 4:i + 4 + n].decode(), i + 4 + n
        signer, i = string(signed, 0)
        pub = signed[i + 1:i + 33]; i += 33
        nonce = struct.unpack_from("<Q", signed, i)[0]; i += 8
        receiver, i = string(signed, i)
        i += 32  # block hash
        assert struct.unpack_from("<I", signed, i)[0] == 1; i += 4
        assert signed[i] == 3, "only Transfer actions"; i += 1
        deposit = int.from_bytes(signed[i:i + 16], "little"); i += 16
        tx, sig = signed[:i], signed[i + 1:i + 65]
        Ed25519PublicKey.from_public_bytes(pub).verify(sig, hashlib.sha256(tx).digest())  # raises if forged
        return {"signer": signer, "pub": "ed25519:" + b58encode(pub), "nonce": nonce, "receiver": receiver,
                "deposit": deposit, "hash": b58encode(hashlib.sha256(tx).digest())}

    def handler(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        method, p = body["method"], body["params"]
        err = lambda name: httpx.Response(200, json={"jsonrpc": "2.0", "id": 1, "error": {  # noqa: E731
            "name": "HANDLER_ERROR", "cause": {"name": name}, "data": name}})
        if method == "query" and p["request_type"] == "view_account":
            if p["account_id"] not in self.accounts:
                return err("UNKNOWN_ACCOUNT")
            return httpx.Response(200, json={"result": {"amount": str(self.accounts[p["account_id"]])}})
        if method == "query" and p["request_type"] == "view_access_key":
            if p["account_id"] not in self.accounts:
                return err("UNKNOWN_ACCOUNT")
            if p["public_key"] not in self.keys.get(p["account_id"], set()):
                return err("UNKNOWN_ACCESS_KEY")
            return httpx.Response(200, json={"result": {"nonce": self.nonce, "block_hash": b58encode(bytes(32))}})
        if method == "send_tx":
            d = self.decode(base64.b64decode(p["signed_tx_base64"]))
            assert d["pub"] in self.keys[d["signer"]] and d["nonce"] == self.nonce + 1
            self.nonce += 1
            self.accounts[d["signer"]] -= d["deposit"]
            self.accounts[d["receiver"]] = self.accounts.get(d["receiver"], 0) + d["deposit"]
            self.sent.append(d)
            return httpx.Response(200, json={"result": {"status": {"SuccessValue": ""},
                                                        "transaction": {"hash": d["hash"]}}})
        raise AssertionError(f"unexpected RPC {method}")


def make_wallet(tmp_path, chain: FakeChain, **cfg) -> Wallet:
    w = WalletConfig.validated("testnet", PARENT, FROGG)
    from dataclasses import replace
    w = replace(w, **cfg)
    rpc = Rpc("https://rpc.testnet.near.org", http=httpx.Client(transport=httpx.MockTransport(chain.handler)))
    return Wallet(w, tmp_path, Store(tmp_path), rpc)


def ready(tmp_path, chain=None, **cfg) -> tuple[Wallet, FakeChain]:
    chain = chain or FakeChain()
    wallet = make_wallet(tmp_path, chain, **cfg)
    chain.keys[FROGG].add(wallet.init_key().public_key)  # what the owner's Meteor transaction does
    return wallet, chain


def test_key_is_created_once_owner_only_and_never_overwritten(tmp_path):
    w = make_wallet(tmp_path, FakeChain())
    k1 = w.init_key()
    assert oct(os.stat(w.key_path).st_mode & 0o777) == "0o600"
    assert w.init_key() == k1
    assert json.loads(w.key_path.read_text())["account_id"] == FROGG


def test_status_walks_through_setup(tmp_path):
    chain = FakeChain()
    del chain.accounts[FROGG]
    w = make_wallet(tmp_path, chain)
    assert "wallet init" in w.status()["setup"]
    key = w.init_key()
    assert "doesn't exist yet" in w.status()["setup"]
    chain.accounts[FROGG] = N("1")
    assert "isn't on" in w.status()["setup"]
    chain.keys[FROGG].add(key.public_key)
    s = w.status()
    assert s["ready"] and s["balance_near"] == "1" and s["spendable_near"] == "0.95"
    assert s["payee"] == PARENT and s["public_key"] == key.public_key


def test_pays_the_payee_from_froggs_account(tmp_path):
    w, chain = ready(tmp_path)
    r = w.pay(250_000, {"draft_id": "d1"})  # $0.00025 → 0.0001 NEAR at 0.4 NEAR/USD
    assert r["status"] == "paid", r
    assert r["amount_near"] == "0.0001" and r["priced_by"] == "cost"
    [tx] = chain.sent
    assert (tx["signer"], tx["receiver"], tx["deposit"]) == (FROGG, PARENT, N("0.0001"))
    assert r["tx_hash"] == tx["hash"] and r["explorer"].endswith(tx["hash"])
    assert r["balance_after_near"] == "0.9999" and r["spent_today_near"] == "0.0001"
    assert w.store.list_payments()[0]["status"] == "paid"


def test_unknown_cost_uses_the_flat_price(tmp_path):
    w, chain = ready(tmp_path)
    r = w.pay(None, {})
    assert r["priced_by"] == "flat" and chain.sent[0]["deposit"] == N("0.0005")


def test_per_request_cap_refuses_without_signing(tmp_path):
    w, chain = ready(tmp_path)
    r = w.pay(100_000_000_000, {})  # $100 → 40 NEAR
    assert r["status"] == "refused" and "per-request cap" in r["reason"]
    assert chain.sent == []


def test_daily_cap_stops_spending(tmp_path):
    w, chain = ready(tmp_path, flat_price_near="0.03", max_per_request_near="0.05")
    statuses = [w.pay(None, {})["status"] for _ in range(5)]
    assert statuses == ["paid", "paid", "paid", "refused", "refused"]  # 0.09 spent; a 4th would exceed 0.1
    assert len(chain.sent) == 3
    assert "today's cap" in w.blocked()


def test_reserve_keeps_froggs_account_alive(tmp_path):
    w, chain = ready(tmp_path, FakeChain(balance=N("0.0502")))
    r = w.pay(None, {})
    assert r["status"] == "refused" and "out of allowance" in r["reason"]
    assert chain.sent == []


def test_only_ever_pays_the_configured_payee(tmp_path):
    w, chain = ready(tmp_path)
    for _ in range(3):
        w.pay(None, {})
    assert {t["receiver"] for t in chain.sent} == {PARENT}
    assert not hasattr(w, "transfer_to")  # no API to pay anyone else


def test_no_key_means_no_payment_and_no_blocking(tmp_path):
    w = make_wallet(tmp_path, FakeChain())
    assert w.blocked() is None
    assert w.pay(None, {})["status"] == "refused"


def test_pricing_rounds_up_and_never_pays_zero():
    p = Policy(PARENT, N("0.01"), N("0.1"), N("0.05"), 0.4, N("0.0005"))
    assert p.price(1) == (400_000_000_000_000, "cost")  # 1 nano-USD → 4e14 yocto
    assert p.price(0) == (N("0.0005"), "flat")


# --- through the HTTP API ---------------------------------------------------------------------

from .conftest import MODEL  # noqa: E402
from .test_flow import FakeNear, make as make_app  # noqa: E402


def test_polish_pays_and_returns_a_receipt(tmp_path, captured):
    w, chain = ready(tmp_path)
    fake = FakeNear(captured)
    tc, store = make_app(tmp_path, fake, wallet=w)
    r = tc.post("/polish", json={"text": "teh frog"}).json()
    assert r["verification"]["verdict"] == "verified"
    assert r["receipt"]["status"] == "paid" and r["receipt"]["verdict"] == "verified"
    assert store.get_draft(r["draft_id"]).receipt["tx_hash"] == chain.sent[0]["hash"]
    assert tc.get("/wallet").json()["ready"] is True
    assert tc.get("/wallet/payments").json()["payments"][0]["status"] == "paid"


def test_out_of_allowance_refuses_before_sending_text(tmp_path, captured):
    w, chain = ready(tmp_path, flat_price_near="0.06", max_per_request_near="0.08")
    assert w.pay(None, {})["status"] == "paid"  # 0.06 of 0.1 spent; another 0.06 would exceed the day
    fake = FakeNear(captured)
    tc, _ = make_app(tmp_path, fake, wallet=w)
    r = tc.post("/polish", json={"text": "secret note"})
    assert r.status_code == 402 and r.json()["error"] == "frogg_out_of_allowance"
    assert "today's cap" in r.json()["message"]
    assert "/chat/completions" not in fake.calls


def test_setup_page_shows_only_public_data(tmp_path, captured):
    w, _ = ready(tmp_path)
    tc, _ = make_app(tmp_path, FakeNear(captured), wallet=w)
    page = tc.get("/wallet/setup", headers={"Authorization": ""})  # no token needed
    assert page.status_code == 200
    html = page.text
    assert PARENT in html and FROGG in html and w.key().public_key in html
    assert w.key().secret_key not in html and json.loads(w.key_path.read_text())["private_key"] not in html
    assert "createAccount" in html and "fullAccessKey" in html and 'network: "testnet"' in html
    assert tc.get("/wallet/setup", headers={"Host": "evil.example"}).status_code == 421
