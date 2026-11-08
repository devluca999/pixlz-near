"""End to end against a fake NEAR AI Cloud: attest → complete → sign → verify → store."""

import hashlib
import json

import httpx
import pytest
from eth_account import Account
from eth_account.messages import encode_defunct
from fastapi.testclient import TestClient

from pixl_memory.nearai import NearAIClient
from pixl_memory.server import create_app
from pixl_memory.store import Store

from .conftest import MODEL, FakeGpuVerifier, FakeQuoteVerifier, rebind

TOKEN = "t" * 64


class FakeNear:
    """Serves /models, /attestation/report, /chat/completions and /signature/{id}."""

    def __init__(self, captured, *, reply="The quick brown fox jumps.", sign_with=None, kind="provider_tee",
                 attest_nonce_override=None, no_credits=False, tamper=None):
        self.report = captured["report"]
        self.model_key = Account.create()
        self.gw_key = Account.create()
        self.sign_with = sign_with  # None = the attested model key
        self.kind = kind
        self.reply = reply
        self.attest_nonce_override = attest_nonce_override
        self.no_credits = no_credits
        self.tamper = tamper  # called on each attestation report after binding, to simulate attacks
        self.calls: list[str] = []
        self.completions: dict[str, tuple[bytes, bytes]] = {}

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path.removeprefix("/v1")
        self.calls.append(path)
        if path == "/models":
            return httpx.Response(200, json={"data": [
                {"id": MODEL, "owned_by": "nearai"},
                {"id": "openai/gpt-5", "owned_by": "openai"},
            ]})
        if path == "/attestation/report":
            nonce = self.attest_nonce_override or request.url.params["nonce"]
            report = rebind(self.report, nonce, self.model_key.address.lower(), self.gw_key.address.lower())
            if self.tamper:
                self.tamper(report)
            return httpx.Response(200, json=report)
        if path == "/chat/completions":
            if self.no_credits:
                return httpx.Response(402, json={"error": {"message": "No spending limit configured.",
                                                           "type": "no_limit_configured"}})
            assert request.headers["authorization"] == "Bearer sk-test"
            body = json.loads(request.content)
            assert body["stream"] is False and body["model"] == MODEL
            resp = json.dumps({"id": "chat123", "object": "chat.completion", "model": MODEL,
                               "choices": [{"index": 0, "message": {"role": "assistant", "content": self.reply},
                                            "finish_reason": "stop"}],
                               "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}).encode()
            self.completions["chat123"] = (request.content, resp)
            return httpx.Response(200, content=resp, headers={"inference-id": "inf-1"})
        if path.startswith("/signature/"):
            req, resp = self.completions[path.rsplit("/", 1)[1]]
            h = lambda b: hashlib.sha256(b).hexdigest()  # noqa: E731
            text = f"{MODEL}:{h(req)}:{h(resp)}" if self.kind == "provider_tee" else f"{h(req)}:{h(resp)}"
            key = self.sign_with or (self.model_key if self.kind == "provider_tee" else self.gw_key)
            sig = Account.sign_message(encode_defunct(text=text), key.key).signature.hex()
            return httpx.Response(200, json={"text": text, "signature": "0x" + sig.removeprefix("0x"),
                                             "signing_address": key.address, "signing_algo": "ecdsa",
                                             "signature_kind": self.kind})
        return httpx.Response(404)


def make(tmp_path, fake, api_key="sk-test", wallet=None, gpu_ok=True):
    http = httpx.Client(transport=httpx.MockTransport(fake.handler))
    client = NearAIClient(api_key, "https://cloud-api.near.ai/v1", http=http, quote_verifier=FakeQuoteVerifier(),
                          gpu_verifier=FakeGpuVerifier(ok=gpu_ok), sleep=lambda s: None)
    store = wallet.store if wallet else Store(tmp_path)
    app = create_app(store, client, TOKEN, MODEL, wallet)
    return TestClient(app, headers={"Authorization": f"Bearer {TOKEN}"}), store


def test_polish_verified_end_to_end(tmp_path, captured):
    fake = FakeNear(captured)
    tc, store = make(tmp_path, fake)
    r = tc.post("/polish", json={"text": "teh quick brown fox jump."})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["suggestion"] == "The quick brown fox jumps."
    assert body["verification"]["verdict"] == "verified", [c for c in body["verification"]["checks"] if c["status"] != "pass"]
    assert body["verification"]["signature_kind"] == "provider_tee"
    assert any(o["op"] == "insert" for o in body["diff"])
    assert fake.calls.index("/attestation/report") < fake.calls.index("/chat/completions")
    d = store.get_draft(body["draft_id"])
    assert d.verdict == "verified" and d.source == "teh quick brown fox jump."
    assert tc.get("/drafts").json()["drafts"][0]["id"] == d.id
    assert tc.post(f"/drafts/{d.id}/status", json={"status": "accepted"}).status_code == 200


def test_text_never_sent_when_attestation_fails(tmp_path, captured):
    fake = FakeNear(captured, attest_nonce_override="00" * 32)  # stale/replayed report
    tc, _ = make(tmp_path, fake)
    r = tc.post("/polish", json={"text": "my private note"})
    assert r.status_code == 409
    assert r.json()["error"] == "attestation_failed"
    assert r.json()["verification"]["verdict"] == "failed"
    assert "/chat/completions" not in fake.calls


def test_signature_from_unattested_key_marks_failed(tmp_path, captured):
    fake = FakeNear(captured, sign_with=Account.create())
    tc, _ = make(tmp_path, fake)
    r = tc.post("/polish", json={"text": "hello"})
    assert r.status_code == 200
    v = r.json()["verification"]
    assert v["verdict"] == "failed"
    assert {c["id"]: c["status"] for c in v["checks"]}["signature.bound"] == "fail"


def test_gateway_signature_is_partial(tmp_path, captured):
    tc, _ = make(tmp_path, FakeNear(captured, kind="gateway"))
    v = tc.post("/polish", json={"text": "hello"}).json()["verification"]
    assert v["verdict"] == "partial"


def test_incognito_model_refused_before_anything_is_sent(tmp_path, captured):
    fake = FakeNear(captured)
    tc, _ = make(tmp_path, fake)
    r = tc.post("/polish", json={"text": "hello", "model": "openai/gpt-5"})
    assert r.status_code == 400 and r.json()["error"] == "not_private"
    assert fake.calls == ["/models"]


def test_no_api_key(tmp_path, captured):
    fake = FakeNear(captured)
    tc, _ = make(tmp_path, fake, api_key=None)
    r = tc.post("/polish", json={"text": "hello"})
    assert r.status_code == 412
    assert fake.calls == []
    assert tc.get("/attestation").json()["verdict"] == "verified"  # attestation needs no key


def test_auth_and_host_guard(tmp_path, captured):
    tc, _ = make(tmp_path, FakeNear(captured))
    assert tc.get("/health").status_code == 200
    assert tc.get("/highlights", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert tc.get("/highlights", headers={"Authorization": ""}).status_code == 401
    assert tc.get("/health", headers={"Host": "evil.example"}).status_code == 421


def test_highlights_api(tmp_path, captured):
    tc, _ = make(tmp_path, FakeNear(captured))
    r = tc.post("/highlights", json={"text": "Frogs breathe through skin", "url": "https://en.wikipedia.org/wiki/Frog",
                                     "fragment_url": "https://en.wikipedia.org/wiki/Frog#:~:text=Frogs%20breathe"})
    assert r.status_code == 201
    hid = r.json()["id"]
    assert tc.get("/highlights", params={"q": "skin"}).json()["highlights"][0]["id"] == hid
    assert tc.delete(f"/highlights/{hid}").status_code == 204
    assert tc.delete(f"/highlights/{hid}").status_code == 404
    assert tc.post("/highlights", json={"text": ""}).status_code == 422


def test_cors_allows_only_extensions(tmp_path, captured):
    tc, _ = make(tmp_path, FakeNear(captured))
    ext = "chrome-extension://" + "a" * 32
    r = tc.options("/highlights", headers={"Origin": ext, "Access-Control-Request-Method": "POST"})
    assert r.headers.get("access-control-allow-origin") == ext
    r = tc.options("/highlights", headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "POST"})
    assert "access-control-allow-origin" not in r.headers


def test_no_credits_is_a_clear_402(tmp_path, captured):
    tc, store = make(tmp_path, FakeNear(captured, no_credits=True))
    r = tc.post("/polish", json={"text": "hello"})
    assert r.status_code == 402
    assert r.json()["error"] == "no_credits" and "cloud.near.ai" in r.json()["message"]
    assert store.list_drafts() == []


def test_ask_is_verified_and_uses_highlights_as_context(tmp_path, captured):
    fake = FakeNear(captured, reply="Frogs breathe partly through their skin.")
    tc, store = make(tmp_path, fake)
    store.add_highlight("Frogs absorb oxygen through their skin")
    r = tc.post("/ask", json={"question": "how do frogs breathe?", "personality": "a deadpan frog"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["answer"] == "Frogs breathe partly through their skin."
    assert body["verification"]["verdict"] == "verified" and body["used_highlights"] == 1
    sent = json.loads(fake.completions["chat123"][0])
    assert "a deadpan frog" in sent["messages"][0]["content"]
    assert "Frogs absorb oxygen" in sent["messages"][0]["content"]  # context went only to the enclave
    assert sent["messages"][1]["content"] == "how do frogs breathe?"


def test_ask_sends_the_matching_highlights_and_returns_their_backlinks(tmp_path, captured):
    fake = FakeNear(captured, reply="You saved that tree frogs can change colour.")
    tc, store = make(tmp_path, fake)
    store.add_highlight("Tree frogs can change colour to match their surroundings", "https://ex.org/frogs", "Frogs",
                        "https://ex.org/frogs#:~:text=Tree%20frogs%20can%20change")
    for i in range(8):
        store.add_highlight(f"Unrelated note number {i} about invoices", f"https://ex.org/{i}", "Work", None)
    r = tc.post("/ask", json={"question": "What did I save about tree frogs?"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert [h["fragment_url"] for h in body["highlights"]] == ["https://ex.org/frogs#:~:text=Tree%20frogs%20can%20change"]
    assert body["used_highlights"] == 1
    sent = json.loads(fake.completions["chat123"][0])["messages"][0]["content"]
    assert "Tree frogs can change colour" in sent and "invoices" not in sent  # only what matters leaves the Mac


def test_ask_with_no_matching_highlight_sends_a_few_recent_and_claims_no_sources(tmp_path, captured):
    fake = FakeNear(captured, reply="Hello!")
    tc, store = make(tmp_path, fake)
    for i in range(6):
        store.add_highlight(f"Note {i} about invoices")
    body = tc.post("/ask", json={"question": "hi there"}).json()
    assert body["highlights"] == [] and body["used_highlights"] == 3


def test_rank_highlights_prefers_more_shared_words_then_newest():
    from types import SimpleNamespace as H

    from pixl_memory.polish import rank_highlights
    hs = [H(text="frog pond", title=None), H(text="tree frog pond colour", title=None), H(text="cats", title="Frogs")]
    got, matched = rank_highlights("tree frogs in a pond", hs)
    assert matched and [h.text for h in got] == ["tree frog pond colour", "frog pond", "cats"]
    assert rank_highlights("the and of", hs) == (hs[:3], False)  # stopwords only: no match


def test_ask_refuses_before_sending_when_attestation_fails(tmp_path, captured):
    fake = FakeNear(captured, attest_nonce_override="00" * 32)
    tc, _ = make(tmp_path, fake)
    r = tc.post("/ask", json={"question": "secret?"})
    assert r.status_code == 409 and "/chat/completions" not in fake.calls


def test_folders_nest_filter_move_and_stay_encrypted(tmp_path, captured):
    tc, store = make(tmp_path, FakeNear(captured))
    a = tc.post("/highlights", json={"text": "Glass frogs hide their blood", "folder": " Research / Glass  frogs "}).json()
    tc.post("/highlights", json={"text": "Tree frogs change colour", "folder": "Research"})
    tc.post("/highlights", json={"text": "Invoice due Friday", "folder": "Work"})
    tc.post("/highlights", json={"text": "No folder at all"})
    assert a["folder"] == "Research/Glass frogs"                              # trimmed, spaces collapsed
    assert tc.get("/folders").json()["folders"] == [{"name": "Research", "count": 1}, {"name": "Research/Glass frogs", "count": 1},
                                                    {"name": "Work", "count": 1}]
    research = [h["text"] for h in tc.get("/highlights", params={"folder": "Research"}).json()["highlights"]]
    assert sorted(research) == ["Glass frogs hide their blood", "Tree frogs change colour"]   # includes subfolders
    assert tc.patch(f"/highlights/{a['id']}", json={"folder": "Work/Frogs"}).json()["folder"] == "Work/Frogs"
    work = {h["text"] for h in tc.get("/highlights", params={"folder": "Work"}).json()["highlights"]}
    assert work == {"Glass frogs hide their blood", "Invoice due Friday"}      # moved in, subfolder included
    assert tc.patch("/highlights/nope", json={"folder": "x"}).status_code == 404
    raw = (tmp_path / "memory.db").read_bytes()
    assert b"Research" not in raw and b"Work/Frogs" not in raw                 # folder names are encrypted too


def test_folder_paths_are_tamed():
    from pixl_memory.store import normalize_folder
    assert normalize_folder("  ") is None and normalize_folder(None) is None
    assert normalize_folder("a/../b//c/./d/e/f") == "a/b/c/d"                 # no traversal, at most 4 levels
    assert normalize_folder("x" * 60) == "x" * 40


class OfflineNear:
    """No internet: every request fails to connect."""

    def handler(self, request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("nodename nor servname provided", request=request)


def test_offline_polish_says_offline_and_sends_nothing(tmp_path):
    tc, _ = make(tmp_path, OfflineNear())
    r = tc.post("/polish", json={"text": "teh fox"})
    assert r.status_code == 503 and r.json()["error"] == "offline"


def test_offline_ask_still_finds_what_you_saved(tmp_path):
    tc, store = make(tmp_path, OfflineNear())
    store.add_highlight("Glass frogs hide their red blood cells in the liver", "https://ex.org/g", "Glass frogs",
                        "https://ex.org/g#:~:text=Glass%20frogs")
    body = tc.post("/ask", json={"question": "what about glass frogs?"}).json()
    assert body["offline"] is True and body["verification"]["verdict"] == "offline" and body["receipt"] is None
    assert [h["fragment_url"] for h in body["highlights"]] == ["https://ex.org/g#:~:text=Glass%20frogs"]
    # nothing matched: a plain offline error
    r = tc.post("/ask", json={"question": "weather tomorrow"})
    assert r.status_code == 503 and r.json()["error"] == "offline"
