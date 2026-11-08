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


WALLET_SETTINGS = ("NEAR_NETWORK", "FROGG_PARENT_ACCOUNT", "FROGG_ACCOUNT")
_ACCOUNT_RE = re.compile(r"^(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$")  # NEAR account-id rules


class WalletConfigError(ValueError):
    pass


@dataclass(frozen=True)
class WalletConfig:
    """Frogg's NEAR account. Public names only: no keys here (Frogg's key lives in the
    data directory; the parent's keys never touch this machine)."""

    network: str
    parent: str
    frogg: str

    @classmethod
    def from_env(cls, env_file: Path | None = None) -> "WalletConfig | None":
        from dotenv import dotenv_values

        path = env_file or find_env_file()
        values = dotenv_values(path) if path else {}
        got = {k: (values.get(k) or "").strip() for k in WALLET_SETTINGS}
        if not any(got.values()):
            return None
        return cls.validated(got["NEAR_NETWORK"] or "testnet", got["FROGG_PARENT_ACCOUNT"], got["FROGG_ACCOUNT"])

    @classmethod
    def validated(cls, network: str, parent: str, frogg: str) -> "WalletConfig":
        if network != "testnet":
            raise WalletConfigError(f"NEAR_NETWORK must be testnet for now (got {network!r})")
        for name, acct in (("FROGG_PARENT_ACCOUNT", parent), ("FROGG_ACCOUNT", frogg)):
            if not (2 <= len(acct) <= 64 and _ACCOUNT_RE.match(acct)):
                raise WalletConfigError(f"{name} is not a valid NEAR account id: {acct!r}")
        if not parent.endswith(".testnet"):
            raise WalletConfigError(f"FROGG_PARENT_ACCOUNT must be a .testnet account (got {parent!r})")
        if frogg != f"frogg.{parent}":
            raise WalletConfigError(f"FROGG_ACCOUNT must be frogg.{parent} (a direct sub-account of the parent), got {frogg!r}")
        return cls(network, parent, frogg)

    @property
    def explorer(self) -> str:
        return f"https://testnet.nearblocks.io/address/{self.frogg}"


def default_data_dir() -> Path:
    if env := os.environ.get("PIXL_MEMORY_DIR"):
        return Path(env).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "PixlMemory"
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
