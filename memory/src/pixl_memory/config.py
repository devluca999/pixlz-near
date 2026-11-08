from __future__ import annotations

import os
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
