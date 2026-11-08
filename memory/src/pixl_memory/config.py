from __future__ import annotations

import os
import secrets
import sys
from dataclasses import dataclass
from pathlib import Path

from .nearai import DEFAULT_BASE_URL, DEFAULT_MODEL
from .store import load_or_create_secret

DEFAULT_PORT = 7341


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

    @classmethod
    def from_env(cls) -> "Config":
        data_dir = default_data_dir()
        key = os.environ.get("NEARAI_API_KEY")
        key_file = data_dir / "nearai_api_key"
        if not key and key_file.exists():
            key = key_file.read_text().strip() or None
        return cls(
            data_dir=data_dir,
            api_key=key,
            base_url=os.environ.get("NEARAI_BASE_URL", DEFAULT_BASE_URL),
            model=os.environ.get("PIXL_MODEL", DEFAULT_MODEL),
            host="127.0.0.1",  # never listen beyond this machine
            port=int(os.environ.get("PIXL_MEMORY_PORT", DEFAULT_PORT)),
        )

    def token(self) -> str:
        """Bearer token clients must send. Created on first use, mode 0600."""
        self.data_dir.mkdir(parents=True, exist_ok=True)
        return load_or_create_secret(self.data_dir / "token", lambda: secrets.token_hex(32).encode()).decode().strip()
