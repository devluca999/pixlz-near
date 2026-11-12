from __future__ import annotations

import os
import re
import secrets
import sys
from dataclasses import dataclass
from pathlib import Path

from .nearai import DEFAULT_BASE_URL, DEFAULT_MODEL
from .store import load_or_create_secret

DEFAULT_PORT = 7341
SECRET_NAMES = ("NEAR_AI_API_KEY", "AGENT_CONNECT_API_KEY")


def find_env_file(start: Path | None = None) -> Path | None:
    """The repo's .env: searched upward from the working directory, then from this package."""
    roots = [start or Path.cwd(), Path(__file__).resolve().parent]
    for root in roots:
        for d in [root, *root.parents]:
            if (d / ".env").is_file():
                return d / ".env"
            if (d / ".git").exists():
                break  # stop at the repo root
    return None


def read_secret(name: str, env_file: Path | None = None) -> str | None:
    """API keys come only from .env (git-ignored), never from code, args or other files."""
    if name not in SECRET_NAMES:
        raise KeyError(name)
    from dotenv import dotenv_values

    path = env_file or find_env_file()
    if path is None:
        return None
    return (dotenv_values(path).get(name) or "").strip() or None


WALLET_SETTINGS = ("NEAR_NETWORK", "PIXL_PARENT_ACCOUNT", "FROGG_PARENT_ACCOUNT", "FROGG_ACCOUNT", "FROGG_PAYEE",
                   "FROGG_MAX_PER_REQUEST_NEAR", "FROGG_MAX_PER_DAY_NEAR", "FROGG_MAX_PER_WEEK_NEAR", "FROGG_RESERVE_NEAR",
                   "FROGG_FLAT_PRICE_NEAR", "PIXL_NEAR_PER_USD", "NEAR_RPC_URL")
WALLET_DEFAULTS = {"FROGG_MAX_PER_REQUEST_NEAR": "0.01", "FROGG_MAX_PER_DAY_NEAR": "0.1", "FROGG_MAX_PER_WEEK_NEAR": "0.5",
                   "FROGG_RESERVE_NEAR": "0.05",
                   "FROGG_FLAT_PRICE_NEAR": "0.0005", "PIXL_NEAR_PER_USD": "0.4",
                   "NEAR_RPC_URL": "https://rpc.testnet.near.org"}
_ACCOUNT_RE = re.compile(r"^(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$")  # NEAR account-id rules


class WalletConfigError(ValueError):
    pass


@dataclass(frozen=True)
class WalletConfig:
    """One Pixl's NEAR account: `<pet>.<owner>`, a sub-account the owner creates and funds.
    Public names only: no keys here (each pet's key lives in the data directory; the owner's
    keys never touch this machine). `frogg` is the account's name (kept for compatibility:
    Frogg was the first); `pet` says whose it is."""

    network: str
    parent: str
    frogg: str
    payee: str = ""
    pet: str = "frogg"
    max_per_request_near: str = WALLET_DEFAULTS["FROGG_MAX_PER_REQUEST_NEAR"]
    max_per_day_near: str = WALLET_DEFAULTS["FROGG_MAX_PER_DAY_NEAR"]
    max_per_week_near: str = WALLET_DEFAULTS["FROGG_MAX_PER_WEEK_NEAR"]
    reserve_near: str = WALLET_DEFAULTS["FROGG_RESERVE_NEAR"]
    flat_price_near: str = WALLET_DEFAULTS["FROGG_FLAT_PRICE_NEAR"]
    near_per_usd: str = WALLET_DEFAULTS["PIXL_NEAR_PER_USD"]
    rpc_url: str = WALLET_DEFAULTS["NEAR_RPC_URL"]

    @classmethod
    def from_env(cls, env_file: Path | None = None) -> "WalletConfig | None":
        from dotenv import dotenv_values

        path = env_file or find_env_file()
        values = dotenv_values(path) if path else {}
        got = {k: (values.get(k) or "").strip() for k in WALLET_SETTINGS}
        parent = got["PIXL_PARENT_ACCOUNT"] or got["FROGG_PARENT_ACCOUNT"]
        if not (parent or got["FROGG_ACCOUNT"]):
            return None
        base = cls.validated(got["NEAR_NETWORK"] or "testnet", parent, got["FROGG_ACCOUNT"] or f"frogg.{parent}",
                             got["FROGG_PAYEE"] or parent)
        extra = {}
        for env, field in [("FROGG_MAX_PER_REQUEST_NEAR", "max_per_request_near"), ("FROGG_MAX_PER_DAY_NEAR", "max_per_day_near"), ("FROGG_MAX_PER_WEEK_NEAR", "max_per_week_near"),
                           ("FROGG_RESERVE_NEAR", "reserve_near"), ("FROGG_FLAT_PRICE_NEAR", "flat_price_near"),
                           ("PIXL_NEAR_PER_USD", "near_per_usd")]:
            v = got[env] or WALLET_DEFAULTS[env]
            try:
                if float(v) < 0:
                    raise ValueError
            except ValueError:
                raise WalletConfigError(f"{env} must be a non-negative number, got {v!r}") from None
            extra[field] = v
        if float(extra["max_per_request_near"]) > float(extra["max_per_day_near"]):
            raise WalletConfigError("FROGG_MAX_PER_REQUEST_NEAR can't exceed FROGG_MAX_PER_DAY_NEAR")
        if float(extra["max_per_day_near"]) > float(extra["max_per_week_near"]):
            raise WalletConfigError("FROGG_MAX_PER_DAY_NEAR can't exceed FROGG_MAX_PER_WEEK_NEAR")
        rpc = got["NEAR_RPC_URL"] or WALLET_DEFAULTS["NEAR_RPC_URL"]
        if not rpc.startswith("https://") or "mainnet" in rpc:
            raise WalletConfigError(f"NEAR_RPC_URL must be an https testnet endpoint, got {rpc!r}")
        from dataclasses import replace

        return replace(base, rpc_url=rpc, **extra)

    @classmethod
    def validated(cls, network: str, parent: str, frogg: str, payee: str | None = None) -> "WalletConfig":
        if network != "testnet":
            raise WalletConfigError(f"NEAR_NETWORK must be testnet for now (got {network!r})")
        for name, acct in (("FROGG_PARENT_ACCOUNT", parent), ("FROGG_ACCOUNT", frogg)):
            if not (2 <= len(acct) <= 64 and _ACCOUNT_RE.match(acct)):
                raise WalletConfigError(f"{name} is not a valid NEAR account id: {acct!r}")
        if not parent.endswith(".testnet"):
            raise WalletConfigError(f"FROGG_PARENT_ACCOUNT must be a .testnet account (got {parent!r})")
        if frogg != f"frogg.{parent}":
            raise WalletConfigError(f"FROGG_ACCOUNT must be frogg.{parent} (a direct sub-account of the parent), got {frogg!r}")
        payee = payee or parent
        if not (2 <= len(payee) <= 64 and _ACCOUNT_RE.match(payee)) or not payee.endswith(".testnet"):
            raise WalletConfigError(f"FROGG_PAYEE must be a .testnet account, got {payee!r}")
        if payee == frogg:
            raise WalletConfigError("FROGG_PAYEE can't be Frogg itself")
        return cls(network, parent, frogg, payee)

    @property
    def account(self) -> str:
        return self.frogg

    @property
    def name(self) -> str:
        """The pet's name for messages ("Kiti has no key yet")."""
        return PET_NAMES.get(self.pet, self.pet.capitalize())

    def for_pet(self, pet: str) -> "WalletConfig":
        """The same owner, payee and caps, for another Pixl: its own `<pet>.<owner>` account."""
        from dataclasses import replace

        pet = pet.strip().lower()
        if not _PET_RE.match(pet):
            raise WalletConfigError(f"not a Pixl name: {pet!r} (lower-case letters, digits, - or _)")
        account = f"{pet}.{self.parent}"
        if len(account) > 64:
            raise WalletConfigError(f"{account} is too long for a NEAR account id")
        if account == self.payee:
            raise WalletConfigError(f"{account} is the payee: a Pixl can't pay itself")
        return replace(self, pet=pet, frogg=account)

    @property
    def explorer(self) -> str:
        return f"https://testnet.nearblocks.io/address/{self.frogg}"


# Pixls and the names their wallets are known by (the app's skin ids map onto these).
PET_NAMES = {"frogg": "Frogg", "kiti": "Kiti", "mochi": "Mochi", "boo": "Boo", "silky": "Silky", "slugg": "Slugg"}
_PET_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")


def default_data_dir() -> Path:
    if env := os.environ.get("PIXL_MEMORY_DIR"):
        return Path(env).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "PixlMemory"
    if sys.platform == "win32":  # the Windows app (docs/WINDOWS.md) reads the token from here too
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "PixlMemory"
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "pixl-memory"


@dataclass
class Config:
    data_dir: Path
    api_key: str | None
    base_url: str
    model: str
    host: str
    port: int

    def __repr__(self) -> str:  # never print the key
        return f"Config(data_dir={self.data_dir}, model={self.model}, api_key={'set' if self.api_key else 'unset'})"

    @classmethod
    def from_env(cls, env_file: Path | None = None) -> "Config":
        data_dir = default_data_dir()
        return cls(
            data_dir=data_dir,
            api_key=read_secret("NEAR_AI_API_KEY", env_file),
            base_url=os.environ.get("NEARAI_BASE_URL", DEFAULT_BASE_URL),
            model=os.environ.get("PIXL_MODEL", DEFAULT_MODEL),
            host="127.0.0.1",  # never listen beyond this machine
            port=int(os.environ.get("PIXL_MEMORY_PORT", DEFAULT_PORT)),
        )

    def token(self) -> str:
        """Bearer token clients must send. Created on first use, mode 0600."""
        self.data_dir.mkdir(parents=True, exist_ok=True)
        return load_or_create_secret(self.data_dir / "token", lambda: secrets.token_hex(32).encode()).decode().strip()
