"""Local SQLite store for highlights and drafts, encrypted at rest.

Text columns are AES-256-GCM encrypted with a key kept in the data directory
(mode 0600). The associated data is "table:id:column", so a ciphertext can't be
moved to another row or column without failing to decrypt.
"""

from __future__ import annotations

import json
import os
import secrets
import sqlite3
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SCHEMA = """
CREATE TABLE IF NOT EXISTS highlights (
    id TEXT PRIMARY KEY,
    created_at REAL NOT NULL,
    text BLOB NOT NULL,
    url BLOB,
    title BLOB,
    fragment_url BLOB
);
CREATE TABLE IF NOT EXISTS drafts (
    id TEXT PRIMARY KEY,
    created_at REAL NOT NULL,
    model TEXT NOT NULL,
    chat_id TEXT,
    verdict TEXT NOT NULL,
    status TEXT NOT NULL,
    source BLOB NOT NULL,
    instruction BLOB NOT NULL,
    suggestion BLOB NOT NULL,
    verification BLOB NOT NULL,
    receipt BLOB
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS payments (
    id TEXT PRIMARY KEY,
    created_at REAL NOT NULL,
    day TEXT NOT NULL,
    amount_yocto TEXT NOT NULL,
    status TEXT NOT NULL,
    tx_hash TEXT,
    receipt BLOB NOT NULL
);
"""


def write_secret(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def load_or_create_secret(path: Path, make: callable) -> bytes:
    if not path.exists():
        try:
            write_secret(path, make())
        except FileExistsError:
            pass  # another process created it first
    return path.read_bytes()


@dataclass
class Highlight:
    id: str
    created_at: float
    text: str
    url: str | None
    title: str | None
    fragment_url: str | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class Draft:
    id: str
    created_at: float
    model: str
    chat_id: str | None
    verdict: str
    status: str  # "suggested" | "accepted" | "discarded"
    source: str
    instruction: str
    suggestion: str
    verification: dict[str, Any]
    receipt: dict[str, Any] | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class Store:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        data_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(data_dir, 0o700)
        self._aead = AESGCM(load_or_create_secret(data_dir / "store.key", lambda: AESGCM.generate_key(256)))
        old_umask = os.umask(0o077)  # DB, WAL and SHM files are owner-only
        try:
            self._db = sqlite3.connect(data_dir / "memory.db", check_same_thread=False, isolation_level=None)
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.executescript(SCHEMA)
        finally:
            os.umask(old_umask)

    # -- crypto --

    def _seal(self, table: str, row: str, col: str, value: str | None) -> bytes | None:
        if value is None:
            return None
        nonce = secrets.token_bytes(12)
        return nonce + self._aead.encrypt(nonce, value.encode(), f"{table}:{row}:{col}".encode())

    def _open(self, table: str, row: str, col: str, blob: bytes | None) -> str | None:
        if blob is None:
            return None
        return self._aead.decrypt(blob[:12], blob[12:], f"{table}:{row}:{col}".encode()).decode()

    # -- highlights --

    def add_highlight(self, text: str, url: str | None = None, title: str | None = None,
                      fragment_url: str | None = None) -> Highlight:
        h = Highlight(str(uuid.uuid4()), time.time(), text, url, title, fragment_url)
        s = lambda col, v: self._seal("highlights", h.id, col, v)  # noqa: E731
        self._db.execute(
            "INSERT INTO highlights VALUES (?,?,?,?,?,?)",
            (h.id, h.created_at, s("text", text), s("url", url), s("title", title), s("fragment_url", fragment_url)),
        )
        return h

    def _row_to_highlight(self, row: tuple) -> Highlight:
        hid, created, *blobs = row
        cols = ["text", "url", "title", "fragment_url"]
        vals = [self._open("highlights", hid, c, b) for c, b in zip(cols, blobs)]
        return Highlight(hid, created, *vals)

    def list_highlights(self, query: str | None = None, limit: int = 50) -> list[Highlight]:
        # Rows are encrypted, so search happens after decryption. Fine for a personal library.
        rows = self._db.execute("SELECT * FROM highlights ORDER BY created_at DESC").fetchall()
        out = []
        q = (query or "").casefold()
        for row in rows:
            h = self._row_to_highlight(row)
            if not q or q in h.text.casefold() or q in (h.title or "").casefold() or q in (h.url or "").casefold():
                out.append(h)
                if len(out) >= limit:
                    break
        return out

    def get_highlight(self, hid: str) -> Highlight | None:
        row = self._db.execute("SELECT * FROM highlights WHERE id=?", (hid,)).fetchone()
        return self._row_to_highlight(row) if row else None

    def delete_highlight(self, hid: str) -> bool:
        return self._db.execute("DELETE FROM highlights WHERE id=?", (hid,)).rowcount > 0

    # -- drafts --

    def add_draft(self, *, model: str, chat_id: str | None, source: str, instruction: str, suggestion: str,
                  verification: dict[str, Any], receipt: dict[str, Any] | None = None) -> Draft:
        d = Draft(str(uuid.uuid4()), time.time(), model, chat_id, verification["verdict"], "suggested",
                  source, instruction, suggestion, verification, receipt)
        s = lambda col, v: self._seal("drafts", d.id, col, v)  # noqa: E731
        self._db.execute(
            "INSERT INTO drafts VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (d.id, d.created_at, model, chat_id, d.verdict, d.status, s("source", source),
             s("instruction", instruction), s("suggestion", suggestion),
             s("verification", json.dumps(verification)), s("receipt", json.dumps(receipt) if receipt else None)),
        )
        return d

    def _row_to_draft(self, row: tuple) -> Draft:
        did, created, model, chat_id, verdict, status, src, ins, sug, ver, rec = row
        o = lambda col, b: self._open("drafts", did, col, b)  # noqa: E731
        receipt = o("receipt", rec)
        return Draft(did, created, model, chat_id, verdict, status, o("source", src), o("instruction", ins),
                     o("suggestion", sug), json.loads(o("verification", ver)), json.loads(receipt) if receipt else None)

    def get_draft(self, did: str) -> Draft | None:
        row = self._db.execute("SELECT * FROM drafts WHERE id=?", (did,)).fetchone()
        return self._row_to_draft(row) if row else None

    def list_drafts(self, limit: int = 50) -> list[Draft]:
        rows = self._db.execute("SELECT * FROM drafts ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
        return [self._row_to_draft(r) for r in rows]

    def set_draft_status(self, did: str, status: str) -> bool:
        if status not in ("suggested", "accepted", "discarded"):
            raise ValueError(f"bad status {status}")
        return self._db.execute("UPDATE drafts SET status=? WHERE id=?", (status, did)).rowcount > 0

    def set_draft_receipt(self, did: str, receipt: dict[str, Any]) -> bool:
        blob = self._seal("drafts", did, "receipt", json.dumps(receipt))
        return self._db.execute("UPDATE drafts SET receipt=? WHERE id=?", (blob, did)).rowcount > 0

    # -- payments (Frogg's wallet) --

    def add_payment(self, day: str, amount_yocto: int, status: str, tx_hash: str | None, receipt: dict[str, Any]) -> str:
        pid = str(uuid.uuid4())
        self._db.execute("INSERT INTO payments VALUES (?,?,?,?,?,?,?)",
                         (pid, time.time(), day, str(amount_yocto), status, tx_hash,
                          self._seal("payments", pid, "receipt", json.dumps(receipt))))
        return pid

    def spent_between(self, first_day: str, last_day: str) -> int:
        """Paid yoctoNEAR on days first_day…last_day inclusive (ISO dates sort as text)."""
        rows = self._db.execute("SELECT amount_yocto FROM payments WHERE day>=? AND day<=? AND status='paid'",
                                (first_day, last_day)).fetchall()
        return sum(int(r[0]) for r in rows)

    # -- small settings the user changes from the app (not secrets) --

    def get_setting(self, key: str) -> str | None:
        row = self._db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def set_setting(self, key: str, value: str | None) -> None:
        if value is None:
            self._db.execute("DELETE FROM settings WHERE key=?", (key,))
        else:
            self._db.execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                             (key, value))

    def spent_on(self, day: str) -> int:
        rows = self._db.execute("SELECT amount_yocto FROM payments WHERE day=? AND status='paid'", (day,)).fetchall()
        return sum(int(r[0]) for r in rows)

    def list_payments(self, limit: int = 20) -> list[dict[str, Any]]:
        rows = self._db.execute("SELECT id, created_at, receipt FROM payments ORDER BY created_at DESC LIMIT ?",
                                (limit,)).fetchall()
        return [{"id": i, "created_at": c, **json.loads(self._open("payments", i, "receipt", r))} for i, c, r in rows]

    def close(self) -> None:
        self._db.close()
