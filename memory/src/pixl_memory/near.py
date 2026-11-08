"""Minimal NEAR transaction signing: ed25519 keys, Borsh encoding of a Transfer, RPC.

Small on purpose: Frogg only ever sends one kind of transaction (a Transfer from its
own account). The encoding is checked byte-for-byte against near-api-js in the tests.
"""

from __future__ import annotations

import base64
import hashlib
import json
import struct
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

YOCTO = 10**24
DEFAULT_RPC = "https://rpc.testnet.near.org"
EXPLORER = "https://testnet.nearblocks.io"

# --- base58 (Bitcoin alphabet, as NEAR uses) --------------------------------------------------

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(data: bytes) -> str:
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, r = divmod(n, 58)
        out = _B58[r] + out
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + out


def b58decode(s: str) -> bytes:
    n = 0
    for ch in s:
        n = n * 58 + _B58.index(ch)
    body = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\0" * (len(s) - len(s.lstrip("1"))) + body


# --- amounts ----------------------------------------------------------------------------------


def near_to_yocto(near: str | Decimal | float) -> int:
    return int((Decimal(str(near)) * YOCTO).to_integral_value())


def yocto_to_near(yocto: int) -> str:
    """Human string, trimmed: 1_500_000_000_000_000_000_000_000 → '1.5'."""
    d = Decimal(yocto) / YOCTO
    s = f"{d:.6f}".rstrip("0").rstrip(".")
    return s or "0"


# --- keys -------------------------------------------------------------------------------------


@dataclass(frozen=True)
class KeyPair:
    seed: bytes  # 32 bytes

    @classmethod
    def generate(cls) -> "KeyPair":
        raw = Ed25519PrivateKey.generate().private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        return cls(raw)

    @classmethod
    def from_secret(cls, secret: str) -> "KeyPair":
        """NEAR's 'ed25519:<base58 of seed‖public>' format."""
        if not secret.startswith("ed25519:"):
            raise ValueError("expected an ed25519: secret key")
        raw = b58decode(secret.removeprefix("ed25519:"))
        if len(raw) not in (32, 64):
            raise ValueError("bad ed25519 secret key length")
        return cls(raw[:32])

    @property
    def _priv(self) -> Ed25519PrivateKey:
        return Ed25519PrivateKey.from_private_bytes(self.seed)

    @property
    def public_bytes(self) -> bytes:
        return self._priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)

    @property
    def public_key(self) -> str:
        return "ed25519:" + b58encode(self.public_bytes)

    @property
    def secret_key(self) -> str:
        return "ed25519:" + b58encode(self.seed + self.public_bytes)

    def sign(self, msg: bytes) -> bytes:
        return self._priv.sign(msg)

    def __repr__(self) -> str:  # never print the secret
        return f"KeyPair({self.public_key})"


def save_key(path: Path, account_id: str, key: KeyPair) -> None:
    """Write Frogg's key file (mode 0600), refusing to overwrite an existing one."""
    import os

    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"account_id": account_id, "public_key": key.public_key, "private_key": key.secret_key}, f)


def load_key(path: Path) -> tuple[str, KeyPair] | None:
    if not path.exists():
        return None
    d = json.loads(path.read_text())
    key = KeyPair.from_secret(d["private_key"])
    if key.public_key != d["public_key"]:
        raise ValueError("key file is inconsistent")
    return d["account_id"], key


# --- Borsh ------------------------------------------------------------------------------------


def _string(s: str) -> bytes:
    b = s.encode()
    return struct.pack("<I", len(b)) + b


def _u128(n: int) -> bytes:
    if not 0 <= n < 2**128:
        raise ValueError("u128 out of range")
    return n.to_bytes(16, "little")


def encode_transfer(signer_id: str, public_key: bytes, nonce: int, receiver_id: str, block_hash: bytes,
                    deposit: int) -> bytes:
    """Borsh(Transaction V0) with a single Transfer action (action index 3)."""
    if len(public_key) != 32 or len(block_hash) != 32:
        raise ValueError("bad key or block hash length")
    return (
        _string(signer_id)
        + b"\x00" + public_key  # KeyType::ED25519
        + struct.pack("<Q", nonce)
        + _string(receiver_id)
        + block_hash
        + struct.pack("<I", 1)  # one action
        + b"\x03" + _u128(deposit)  # Action::Transfer
    )


def sign_transaction(tx: bytes, key: KeyPair) -> tuple[bytes, str]:
    """Returns (Borsh(SignedTransaction), base58 tx hash)."""
    digest = hashlib.sha256(tx).digest()
    return tx + b"\x00" + key.sign(digest), b58encode(digest)


# --- RPC --------------------------------------------------------------------------------------


class RpcError(Exception):
    pass


class UnknownAccount(RpcError):
    pass


class Rpc:
    def __init__(self, url: str = DEFAULT_RPC, http: httpx.Client | None = None):
        self.url = url
        self.http = http or httpx.Client(timeout=30)

    def call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        try:
            r = self.http.post(self.url, json={"jsonrpc": "2.0", "id": "pixl", "method": method, "params": params})
        except httpx.HTTPError as e:
            raise RpcError(f"NEAR RPC unreachable: {e}") from e
        body = r.json()
        if "error" in body:
            err = body["error"]
            cause = (err.get("cause") or {}).get("name", "")
            if cause == "UNKNOWN_ACCOUNT":
                raise UnknownAccount(str(err.get("data") or cause))
            raise RpcError(f"{cause or err.get('name')}: {err.get('data') or err.get('message')}")
        return body["result"]

    def balance(self, account_id: str) -> int:
        """Spendable yoctoNEAR (amount; locked stake excluded)."""
        r = self.call("query", {"request_type": "view_account", "finality": "final", "account_id": account_id})
        return int(r["amount"])

    def access_key(self, account_id: str, public_key: str) -> dict[str, Any] | None:
        try:
            return self.call("query", {"request_type": "view_access_key", "finality": "final",
                                       "account_id": account_id, "public_key": public_key})
        except RpcError as e:
            if "UNKNOWN_ACCESS_KEY" in str(e) or "does not exist" in str(e):
                return None
            raise

    def transfer(self, key: KeyPair, signer_id: str, receiver_id: str, deposit: int) -> dict[str, Any]:
        ak = self.access_key(signer_id, key.public_key)
        if ak is None:
            raise RpcError(f"Frogg's key is not on {signer_id}")
        tx = encode_transfer(signer_id, key.public_bytes, int(ak["nonce"]) + 1, receiver_id,
                             b58decode(ak["block_hash"]), deposit)
        signed, tx_hash = sign_transaction(tx, key)
        r = self.call("send_tx", {"signed_tx_base64": base64.b64encode(signed).decode(),
                                  "wait_until": "EXECUTED_OPTIMISTIC"})
        status = r.get("status") or {}
        if isinstance(status, dict) and "Failure" in status:
            raise RpcError(f"transfer failed on chain: {json.dumps(status['Failure'])[:200]}")
        return {"tx_hash": (r.get("transaction") or {}).get("hash", tx_hash), "explorer": f"{EXPLORER}/txns/{tx_hash}"}
