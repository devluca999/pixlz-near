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
                 attest_nonce_override=None):
        self.report = captured["report"]
        self.model_key = Account.create()
        self.gw_key = Account.create()
        self.sign_with = sign_with  # None = the attested model key
        self.kind = kind
        self.reply = reply
        self.attest_nonce_override = attest_nonce_override
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
            return httpx.Response(200, json=rebind(self.report, nonce, self.model_key.address.lower(),
                                                   self.gw_key.address.lower()))
        if path == "/chat/completions":
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


def make(tmp_path, fake, api_key="sk-test"):
    http = httpx.Client(transport=httpx.MockTransport(fake.handler))
    client = NearAIClient(api_key, "https://cloud-api.near.ai/v1", http=http, quote_verifier=FakeQuoteVerifier(),
                          gpu_verifier=FakeGpuVerifier(), sleep=lambda s: None)
    store = Store(tmp_path)
    app = create_app(store, client, TOKEN, MODEL)
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
