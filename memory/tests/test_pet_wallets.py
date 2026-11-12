"""Every Pixl has its own wallet: `<pet>.<owner>`, created and funded by the owner, paying for
its own inference from its own account. Nothing is hardcoded to Frogg."""

from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient

from pixl_memory.config import WalletConfig, WalletConfigError
from pixl_memory.near import Rpc, near_to_yocto
from pixl_memory.server import create_app
from pixl_memory.store import Store
from pixl_memory.wallet import Wallet, Wallets
from tests.test_wallet import FROGG, PARENT, FakeChain

N = near_to_yocto
KITI = f"kiti.{PARENT}"


def registry(tmp_path, chain: FakeChain) -> Wallets:
    rpc = Rpc("https://rpc.testnet.near.org", http=httpx.Client(transport=httpx.MockTransport(chain.handler)))
    return Wallets(WalletConfig.validated("testnet", PARENT, FROGG), tmp_path, Store(tmp_path), rpc)


def fund(chain: FakeChain, wallet: Wallet, amount: str = "1") -> None:
    """What the owner's create-account transaction does: the account, the balance, the pet's key."""
    chain.accounts[wallet.cfg.account] = N(amount)
    chain.keys.setdefault(wallet.cfg.account, set()).add(wallet.init_key().public_key)


def test_each_pet_gets_its_own_sub_account_and_key(tmp_path):
    ws = registry(tmp_path, FakeChain())
    frogg, kiti = ws.for_pet("frogg"), ws.for_pet("Kiti")
    assert frogg.cfg.account == FROGG and kiti.cfg.account == KITI
    assert kiti.cfg.parent == PARENT and kiti.cfg.payee == PARENT and kiti.cfg.name == "Kiti"
    assert frogg.key_path.name == "frogg_key.json"                     # Frogg's key stays where it was
    assert kiti.key_path == tmp_path / "keys" / "kiti.json"
    assert frogg.init_key().public_key != kiti.init_key().public_key   # never shared
    assert ws.for_pet(None) is frogg and ws.for_pet("kiti") is kiti


def test_a_pet_pays_from_its_own_account_only(tmp_path):
    chain = FakeChain()
    ws = registry(tmp_path, chain)
    kiti = ws.for_pet("kiti")
    fund(chain, kiti)
    r = kiti.pay(250_000, {"kind": "ask"})
    assert r["status"] == "paid" and r["from"] == KITI
    [tx] = chain.sent
    assert (tx["signer"], tx["receiver"]) == (KITI, PARENT)
    assert chain.accounts[FROGG] == N("1")                              # Frogg's balance untouched


def test_spending_and_limits_are_per_pet(tmp_path):
    chain = FakeChain()
    ws = registry(tmp_path, chain)
    frogg, kiti = ws.for_pet("frogg"), ws.for_pet("kiti")
    chain.keys[FROGG].add(frogg.init_key().public_key)
    fund(chain, kiti)
    kiti.pay(250_000, {})
    assert kiti.status()["spent_today_near"] == "0.0001"
    assert frogg.status()["spent_today_near"] == "0"                    # Kiti's spending isn't Frogg's
    kiti.limits.update(paused=True)
    assert kiti.limits.paused and not frogg.limits.paused
    assert "paused" in kiti.pay(250_000, {})["reason"]
    assert frogg.pay(250_000, {})["status"] == "paid"
    assert [p["from"] for p in kiti.payments()] == [KITI, KITI] and [p["from"] for p in frogg.payments()] == [FROGG]


def test_a_pet_without_an_account_is_just_not_set_up(tmp_path):
    ws = registry(tmp_path, FakeChain())
    boo = ws.for_pet("boo")
    assert "wallet init --pet boo" in boo.status()["setup"]
    boo.init_key()
    s = boo.status()
    assert not s["ready"] and "boo." + PARENT in s["setup"]
    assert "Boo has no key yet" not in str(s)


@pytest.mark.parametrize("bad", ["Frogg.Kiti", "../x", "a" * 40, "kiti!"])
def test_pet_names_are_checked(tmp_path, bad):
    with pytest.raises(WalletConfigError):
        registry(tmp_path, FakeChain()).for_pet(bad)


def test_the_payee_is_never_a_pet(tmp_path):
    cfg = WalletConfig.validated("testnet", PARENT, FROGG, payee=f"mochi.{PARENT}")
    with pytest.raises(WalletConfigError):
        cfg.for_pet("mochi")


def test_the_service_charges_the_pet_that_asks(tmp_path, captured):
    from tests.test_flow import FakeNear, make   # the attested NEAR AI double the flow tests use
    chain = FakeChain()
    ws = registry(tmp_path, chain)
    fund(chain, ws.for_pet("kiti"))
    chain.keys[FROGG].add(ws.for_pet("frogg").init_key().public_key)
    c, _ = make(tmp_path, FakeNear(captured), wallet=ws)
    r = c.post("/ask", json={"question": "hi", "name": "Kiti", "personality": "a cat", "pet": "kiti"})
    assert r.status_code == 200, r.text
    assert r.json()["receipt"]["from"] == KITI and r.json()["receipt"]["status"] == "paid"
    assert c.get("/wallet", params={"pet": "kiti"}).json()["account"] == KITI
    assert c.get("/wallet").json()["account"] == FROGG                  # no pet named: Frogg, as before
    assert c.get("/wallet", params={"pet": "../x"}).status_code == 400
    assert [p["from"] for p in c.get("/wallet/payments", params={"pet": "kiti"}).json()["payments"]] == [KITI]
