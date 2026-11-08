"""Frogg's wallet: pays for each private inference from Frogg's own testnet account.

Caps, in order of strength:
  1. Frogg's balance: the owner chose it; NEAR enforces it. The owner's account is
     unreachable: no key for it ever exists on this machine.
  2. Per-request and per-day maximums, and a reserve that keeps the account alive:
     enforced here, before anything is signed.
  3. One payee: every transfer goes to the configured payee, nothing else.
"""

from __future__ import annotations

import datetime as dt
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import WalletConfig
from .near import KeyPair, Rpc, RpcError, UnknownAccount, load_key, near_to_yocto, save_key, yocto_to_near
from .store import Store


@dataclass(frozen=True)
class Policy:
    payee: str
    max_per_request: int  # yocto
    max_per_day: int  # yocto
    reserve: int  # yocto kept in Frogg's account (storage + gas)
    near_per_usd: float
    flat_price: int  # yocto, when NEAR AI hasn't reported the cost yet

    @classmethod
    def from_config(cls, w: WalletConfig) -> "Policy":
        return cls(payee=w.payee, max_per_request=near_to_yocto(w.max_per_request_near),
                   max_per_day=near_to_yocto(w.max_per_day_near), reserve=near_to_yocto(w.reserve_near),
                   near_per_usd=float(w.near_per_usd), flat_price=near_to_yocto(w.flat_price_near))

    def price(self, cost_nano_usd: int | None) -> tuple[int, str]:
        """yoctoNEAR to pay for one request, and how it was priced."""
        if cost_nano_usd and cost_nano_usd > 0:
            yocto = math.ceil(cost_nano_usd * self.near_per_usd * 10**15)  # nano-USD × NEAR/USD × 1e24 / 1e9
            return max(yocto, 1), "cost"
        return self.flat_price, "flat"


class PaymentRefused(Exception):
    """A cap would be exceeded; nothing was signed."""


def today() -> str:
    return dt.datetime.now(dt.UTC).date().isoformat()


class Wallet:
    def __init__(self, cfg: WalletConfig, data_dir: Path, store: Store, rpc: Rpc | None = None):
        self.cfg = cfg
        self.policy = Policy.from_config(cfg)
        self.key_path = data_dir / "frogg_key.json"
        self.store = store
        self.rpc = rpc or Rpc(cfg.rpc_url)

    # -- key --

    def key(self) -> KeyPair | None:
        loaded = load_key(self.key_path)
        if loaded is None:
            return None
        account, key = loaded
        if account != self.cfg.frogg:
            raise ValueError(f"key file belongs to {account}, not {self.cfg.frogg}")
        return key

    def init_key(self) -> KeyPair:
        """Create Frogg's key once. Its private half never leaves the data directory."""
        existing = self.key()
        if existing:
            return existing
        key = KeyPair.generate()
        save_key(self.key_path, self.cfg.frogg, key)
        return key

    # -- state --

    def status(self) -> dict[str, Any]:
        key = self.key()
        s: dict[str, Any] = {
            "network": self.cfg.network, "account": self.cfg.frogg, "parent": self.cfg.parent,
            "payee": self.policy.payee, "public_key": key.public_key if key else None,
            "explorer": self.cfg.explorer,
            "caps": {"per_request_near": yocto_to_near(self.policy.max_per_request),
                     "per_day_near": yocto_to_near(self.policy.max_per_day),
                     "reserve_near": yocto_to_near(self.policy.reserve)},
            "spent_today_near": yocto_to_near(self.store.spent_on(today())),
        }
        if key is None:
            return s | {"ready": False, "setup": "run `pixl-memory wallet init` to create Frogg's key"}
        try:
            balance = self.rpc.balance(self.cfg.frogg)
        except UnknownAccount:
            return s | {"ready": False, "setup": f"{self.cfg.frogg} doesn't exist yet: open /wallet/setup and approve in Meteor"}
        except RpcError as e:
            return s | {"ready": False, "setup": f"NEAR RPC: {e}"}
        s["balance_near"] = yocto_to_near(balance)
        s["spendable_near"] = yocto_to_near(max(0, balance - self.policy.reserve))
        if self.rpc.access_key(self.cfg.frogg, key.public_key) is None:
            return s | {"ready": False, "setup": f"Frogg's key isn't on {self.cfg.frogg} yet"}
        return s | {"ready": True, "setup": None}

    def can_pay(self, amount: int) -> str | None:
        """Why a payment of `amount` would be refused, or None. Nothing is signed here."""
        if amount <= 0:
            return "nothing to pay"
        if amount > self.policy.max_per_request:
            return f"{yocto_to_near(amount)} Ⓝ is over the {yocto_to_near(self.policy.max_per_request)} Ⓝ per-request cap"
        spent = self.store.spent_on(today())
        if spent + amount > self.policy.max_per_day:
            return f"today's cap of {yocto_to_near(self.policy.max_per_day)} Ⓝ is reached"
        return None

    # -- paying --

    def pay(self, cost_nano_usd: int | None, about: dict[str, Any]) -> dict[str, Any]:
        """Pay the payee for one request. Returns a receipt; never raises for a refusal."""
        amount, priced_by = self.policy.price(cost_nano_usd)
        receipt: dict[str, Any] = {
            "from": self.cfg.frogg, "to": self.policy.payee, "network": self.cfg.network,
            "amount_near": yocto_to_near(amount), "amount_yocto": str(amount), "priced_by": priced_by,
            "cost_nano_usd": cost_nano_usd, **about,
        }
        why = self.can_pay(amount)
        key = self.key()
        if why is None and key is None:
            why = "Frogg has no key yet"
        if why is None:
            try:
                balance = self.rpc.balance(self.cfg.frogg)
            except RpcError as e:
                why = f"can't read Frogg's balance: {e}"
            else:
                if balance - amount < self.policy.reserve:
                    why = f"Frogg is out of allowance ({yocto_to_near(balance)} Ⓝ left, {yocto_to_near(self.policy.reserve)} Ⓝ reserved)"
        if why:
            receipt |= {"status": "refused", "reason": why}
            self.store.add_payment(today(), 0, "refused", None, receipt)
            return receipt
        assert key is not None
        try:
            sent = self.rpc.transfer(key, self.cfg.frogg, self.policy.payee, amount)
        except RpcError as e:
            receipt |= {"status": "failed", "reason": str(e)}
            self.store.add_payment(today(), 0, "failed", None, receipt)
            return receipt
        receipt |= {"status": "paid", **sent}
        try:
            receipt["balance_after_near"] = yocto_to_near(self.rpc.balance(self.cfg.frogg))
        except RpcError:
            pass
        self.store.add_payment(today(), amount, "paid", sent["tx_hash"], receipt)
        receipt["spent_today_near"] = yocto_to_near(self.store.spent_on(today()))
        return receipt

    def blocked(self) -> str | None:
        """If Frogg can't afford even a flat-priced request, polishing is refused up front."""
        if self.key() is None:
            return None  # wallet not set up: polishing stays free until it is
        return self.can_pay(self.policy.flat_price)
