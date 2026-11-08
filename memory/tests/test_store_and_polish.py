import os
import sqlite3

import pytest
from cryptography.exceptions import InvalidTag

from pixl_memory import polish
from pixl_memory.store import Store


def test_store_encrypts_at_rest(tmp_path):
    s = Store(tmp_path)
    h = s.add_highlight("a secret sentence about my diagnosis", "https://example.com/p", "Example")
    d = s.add_draft(model="m", chat_id="c1", source="my draft text", instruction="polish",
                    suggestion="My draft text.", verification={"verdict": "verified", "checks": []})
    raw = (tmp_path / "memory.db").read_bytes()
    for plain in [b"secret sentence", b"example.com", b"my draft text", b"My draft text."]:
        assert plain not in raw
    assert s.get_highlight(h.id).text == "a secret sentence about my diagnosis"
    assert s.get_draft(d.id).suggestion == "My draft text."
    assert oct(os.stat(tmp_path / "store.key").st_mode & 0o777) == "0o600"


def test_ciphertext_cannot_move_between_rows(tmp_path):
    s = Store(tmp_path)
    a = s.add_highlight("alpha")
    b = s.add_highlight("beta")
    db = sqlite3.connect(tmp_path / "memory.db")
    blob = db.execute("SELECT text FROM highlights WHERE id=?", (a.id,)).fetchone()[0]
    db.execute("UPDATE highlights SET text=? WHERE id=?", (blob, b.id))
    db.commit()
    with pytest.raises(InvalidTag):
        s.get_highlight(b.id)


def test_search_delete_and_status(tmp_path):
    s = Store(tmp_path)
    s.add_highlight("Frogs absorb water through their skin", title="Frogs")
    s.add_highlight("Unrelated")
    assert [h.text for h in s.list_highlights("skin")] == ["Frogs absorb water through their skin"]
    assert len(s.list_highlights()) == 2
    h = s.list_highlights("unrelated")[0]
    assert s.delete_highlight(h.id) and not s.delete_highlight(h.id)
    d = s.add_draft(model="m", chat_id=None, source="x", instruction="y", suggestion="z",
                    verification={"verdict": "partial", "checks": []})
    assert s.set_draft_status(d.id, "accepted")
    assert s.get_draft(d.id).status == "accepted"
    s2 = Store(tmp_path)  # same key file, reopens fine
    assert s2.get_draft(d.id).suggestion == "z"


def test_word_diff_roundtrip():
    a, b = "teh quick brown fox jump over the dog", "The quick brown fox jumps over the lazy dog."
    ops = polish.word_diff(a, b)
    assert "".join(o["text"] for o in ops if o["op"] != "insert") == a
    assert "".join(o["text"] for o in ops if o["op"] != "delete") == b
    assert {"op": "insert", "text": "lazy "} in ops or any("lazy" in o["text"] for o in ops if o["op"] == "insert")
    assert polish.diff_stats(ops)["inserted_words"] >= 3


@pytest.mark.parametrize("out", ['"Fixed text."', "<text>\nFixed text.\n</text>", "<think>hmm</think>Fixed text."])
def test_clean_strips_wrappers(out):
    assert polish.clean(out, "fixd text") == "Fixed text."


def test_clean_keeps_surrounding_whitespace():
    assert polish.clean("Hello.", "  hello\n") == "  Hello.\n"


def test_prompt_puts_text_in_tags():
    m = polish.messages("hi", None)
    assert m[0]["role"] == "system" and "<text>\nhi\n</text>" in m[1]["content"]
    assert polish.DEFAULT_INSTRUCTION in m[1]["content"]


def test_db_files_are_owner_only(tmp_path):
    s = Store(tmp_path)
    s.add_highlight("x")
    for name in ["memory.db", "memory.db-wal", "memory.db-shm"]:
        p = tmp_path / name
        if p.exists():
            assert oct(os.stat(p).st_mode & 0o777) == "0o600", name
