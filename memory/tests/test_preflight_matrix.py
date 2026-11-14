"""Fail-closed preflight matrix (hackathon directive §3) and signed-reply integrity (§4).

Every case drives the real local service (create_app → NearAIClient → verify) against a fake
NEAR AI Cloud and asserts the one property that matters: when a mandatory attestation property
isn't proven, the completion endpoint is never called and the private text never appears in any
outgoing request. Assertions are on the wire, not on error messages.

Simulated: NEAR AI Cloud, Intel's collateral service (dcap-qvl) and NVIDIA NRAS. These tests prove
the client's decision logic, not the security of real TDX/H100 hardware.
"""

from __future__ import annotations

import base64
import copy
import json
import time

import httpx
import pytest
from eth_account import Account
from fastapi.testclient import TestClient

from pixl_memory.nearai import NearAIClient
from pixl_memory.server import create_app
from pixl_memory.store import Store
from pixl_memory.verify import GpuResult, MANDATORY_CHECKS, check_nras_response

from .conftest import MODEL, FakeGpuVerifier, FakeQuoteVerifier
from .test_flow import TOKEN, FakeNear

SECRET = "PRIVATE-NOTE-7f3a my bank PIN is 4471"


class Wire:
    """Wraps a FakeNear handler and records every request that left the client."""

    def __init__(self, handler):
        self.handler, self.sent = handler, []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.sent.append(request.url.path + "?" + str(request.url.query) + "\n" + request.content.decode("utf-8", "replace"))
        return self.handler(request)

    def leaked(self) -> bool:
        return any(SECRET in s or "PRIVATE-NOTE" in s for s in self.sent)


def run(tmp_path, fake, *, quote=None, gpu="ok", route="/polish", handler=None):
    wire = Wire(handler or fake.handler)
    http = httpx.Client(transport=httpx.MockTransport(wire))
    nc = NearAIClient("sk-test", "https://cloud-api.near.ai/v1", http=http,
                      quote_verifier=quote or FakeQuoteVerifier(),
                      gpu_verifier=FakeGpuVerifier() if gpu == "ok" else (gpu or FakeGpuVerifier()), sleep=lambda s: None)
    if gpu is None:
        nc.gpu_verifier = None   # the constructor swaps None for real NRAS; force "disabled" after
    store = Store(tmp_path)
    tc = TestClient(create_app(store, nc, TOKEN, MODEL, None), headers={"Authorization": f"Bearer {TOKEN}"})
    body = {"text": SECRET} if route == "/polish" else {"question": SECRET, "use_highlights": False}
    if route == "/ask-web":
        route, body = "/ask", body | {"web": True}
    r = tc.post(route, json=body)
    return r, fake, wire, store


def assert_not_sent(r, fake, wire, store):
    assert "/chat/completions" not in fake.calls, f"completion was called: {fake.calls}"
    assert not wire.leaked(), "private text left the Mac"
    assert r.status_code in (409, 502, 503), r.text
    body = r.json()
    if r.status_code == 409:
        assert body["error"] == "attestation_failed" and body["text_sent"] is False
        assert body["verification"]["may_send"] is False and body["verification"]["trust"] == "refused"
    assert store.list_drafts(10) == []


# --- helpers that build attacks on a bound report -------------------------------------------------

def model_att(r):
    return r["model_attestations"][0]


def set_debug(r):
    att = model_att(r)
    q = bytearray(bytes.fromhex(att["intel_quote"]))
    q[48 + 120] |= 0x01
    att["intel_quote"] = q.hex()


def gpu_payload(r, f):
    att = model_att(r)
    p = json.loads(att["nvidia_payload"])
    f(p)
    att["nvidia_payload"] = json.dumps(p)


def tamper_runtime_event(r):
    ev = next(e for e in model_att(r)["event_log"] if e.get("imr") == 3 and e["event"] == "app-id")
    ev["event_payload"] = "ab" * 20


def second_signer(r):
    """A second model candidate, fully valid in its own right, with a different bound key."""
    other = Account.create().address.lower()
    c = copy.deepcopy(model_att(r))
    q = bytearray(bytes.fromhex(c["intel_quote"]))
    q[48 + 520: 48 + 552] = bytes.fromhex(other[2:]).ljust(32, b"\0")
    c["intel_quote"], c["signing_address"] = q.hex(), other
    r["model_attestations"].append(c)


def jwt(claims):
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")  # noqa: E731
    return f"{enc({'alg': 'ES384'})}.{enc(claims)}.sig"


class NrasLike:
    """Runs the real NRAS response checks over a crafted NRAS reply."""

    def __init__(self, mutate):
        self.mutate = mutate

    def verify(self, payload):
        nonce = payload["nonce"]
        overall = {"x-nvidia-overall-att-result": True, "eat_nonce": nonce, "exp": time.time() + 600}
        gpu = {"eat_nonce": nonce, "secboot": True, "dbgstat": "disabled", "hwmodel": "GH100",
               "x-nvidia-gpu-attestation-report-signature-verified": True, "exp": time.time() + 600}
        self.mutate(overall, gpu)
        return check_nras_response([["JWT", jwt(overall)], {"GPU-0": jwt(gpu)}], nonce, time.time())


class Raising:
    def __init__(self, exc):
        self.exc = exc

    def verify(self, payload):
        raise self.exc


def _nras_req():
    return httpx.Request("POST", "https://nras.attestation.nvidia.com/v3/attest/gpu")


# --- the matrix --------------------------------------------------------------------------------------

CASES = {
    "nras_unavailable": dict(gpu=Raising(httpx.ConnectError("down", request=_nras_req()))),
    "nras_5xx": dict(gpu=Raising(httpx.HTTPStatusError("busy", request=_nras_req(),
                                                       response=httpx.Response(503, request=_nras_req())))),
    "nras_timeout": dict(gpu=Raising(httpx.ReadTimeout("slow", request=_nras_req()))),
    "gpu_verification_disabled": dict(gpu=None),
    "gpu_evidence_not_json": dict(tamper=lambda r: model_att(r).__setitem__("nvidia_payload", "{not json")),
    "gpu_evidence_missing": dict(tamper=lambda r: model_att(r).pop("nvidia_payload")),
    "gpu_rejected_by_nvidia": dict(gpu=FakeGpuVerifier(ok=False)),
    "gpu_different_nonce": dict(tamper=lambda r: gpu_payload(r, lambda p: p.__setitem__("nonce", "11" * 32))),
    "gpu_token_expired": dict(gpu=NrasLike(lambda o, g: g.__setitem__("exp", time.time() - 1))),
    "gpu_token_wrong_nonce": dict(gpu=NrasLike(lambda o, g: o.__setitem__("eat_nonce", "22" * 32))),
    "gpu_debug_enabled": dict(gpu=NrasLike(lambda o, g: g.__setitem__("dbgstat", "enabled"))),
    "tdx_quote_garbage": dict(tamper=lambda r: model_att(r).__setitem__("intel_quote", "zz")),
    "tdx_quote_truncated": dict(tamper=lambda r: model_att(r).__setitem__("intel_quote", model_att(r)["intel_quote"][:400])),
    "tdx_signature_chain_invalid": dict(quote=FakeQuoteVerifier(error=RuntimeError("bad Intel signature"))),
    "tcb_revoked": dict(quote=FakeQuoteVerifier(status="Revoked")),
    "debug_enclave": dict(tamper=set_debug),
    "missing_model_attestation": dict(tamper=lambda r: r.__setitem__("model_attestations", [])),
    "missing_gateway_attestation": dict(tamper=lambda r: r.pop("gateway_attestation")),
    "forged_signer": dict(tamper=lambda r: model_att(r).__setitem__("signing_address", "0x" + "11" * 20)),
    "incorrect_runtime_measurements": dict(tamper=tamper_runtime_event),
    "modified_deployment_config": dict(tamper=lambda r: model_att(r)["info"]["tcb_info"].__setitem__(
        "app_compose", model_att(r)["info"]["tcb_info"]["app_compose"].replace("dstack", "evil", 1))),
    "stale_nonce": dict(fake=dict(attest_nonce_override="00" * 32)),
    "wrong_model_identifier": dict(tamper=lambda r: model_att(r).__setitem__("model_name", "other/model")),
    "unnamed_model_report": dict(tamper=lambda r: model_att(r).pop("model_name")),
    "multiple_incompatible_signers": dict(tamper=second_signer),
}


@pytest.mark.parametrize("route", ["/polish", "/ask", "/ask-web"])
@pytest.mark.parametrize("name", list(CASES))
def test_mandatory_failure_sends_nothing(tmp_path, captured, name, route):
    case = CASES[name]
    fake = FakeNear(captured, tamper=case.get("tamper"), **case.get("fake", {}))
    r, fake, wire, store = run(tmp_path, fake, quote=case.get("quote"), gpu=case.get("gpu", "ok"), route=route)
    assert_not_sent(r, fake, wire, store)


def test_replay_of_an_old_genuine_report_sends_nothing(tmp_path, captured):
    """The captured report is real NEAR output bound to an old nonce: served as-is, it's a replay."""
    class Replay(FakeNear):
        def handler(self, request):
            if request.url.path.endswith("/attestation/report"):
                self.calls.append("/attestation/report")
                return httpx.Response(200, json=captured["report"])
            return super().handler(request)

    r, fake, wire, store = run(tmp_path, Replay(captured))
    assert_not_sent(r, fake, wire, store)


@pytest.mark.parametrize("payload", [b"", b"null", b"[]", b"{}", b"not json", b'{"gateway_attestation": 5}',
                                     b'{"gateway_attestation": {}, "model_attestations": [{"model_name": "z-ai/glm-5.3-flash", "info": 3}]}'])
def test_empty_or_malformed_report_sends_nothing(tmp_path, captured, payload):
    class Bad(FakeNear):
        def handler(self, request):
            if request.url.path.endswith("/attestation/report"):
                self.calls.append("/attestation/report")
                return httpx.Response(200, content=payload)
            return super().handler(request)

    r, fake, wire, store = run(tmp_path, Bad(captured))
    assert_not_sent(r, fake, wire, store)


@pytest.mark.parametrize("exc", [httpx.ConnectError, httpx.ReadTimeout])
def test_network_failure_during_preflight_sends_nothing(tmp_path, captured, exc):
    class Down(FakeNear):
        def handler(self, request):
            if request.url.path.endswith("/attestation/report"):
                raise exc("network down", request=request)
            return super().handler(request)

    r, fake, wire, store = run(tmp_path, Down(captured))
    assert_not_sent(r, fake, wire, store)


def test_attestation_endpoint_never_reads_as_permission_when_gpu_skipped(tmp_path, captured):
    """GET /attestation is informational; its may_send must agree with the send decision."""
    fake = FakeNear(captured)
    http = httpx.Client(transport=httpx.MockTransport(fake.handler))
    nc = NearAIClient("sk-test", "https://cloud-api.near.ai/v1", http=http, quote_verifier=FakeQuoteVerifier(),
                      gpu_verifier=FakeGpuVerifier(), sleep=lambda s: None)
    nc.gpu_verifier = None
    tc = TestClient(create_app(Store(tmp_path), nc, TOKEN, MODEL, None), headers={"Authorization": f"Bearer {TOKEN}"})
    v = tc.get("/attestation").json()
    assert v["may_send"] is False and v["trust"] == "refused" and v["verdict"] != "verified"
    assert any(b.startswith("model.gpu") for b in v["blocking"])


def test_every_mandatory_property_is_checked_on_the_happy_path(tmp_path, captured):
    r, fake, wire, store = run(tmp_path, FakeNear(captured))
    assert r.status_code == 200, r.text
    v = r.json()["verification"]
    ids = {c["id"]: c["status"] for c in v["checks"]}
    assert all(ids[c] == "pass" for c in MANDATORY_CHECKS), ids
    assert v["trust"] == "enclave_signed" and v["may_send"] is True
    # each request gets its own fresh preflight: no cached verdict is reused
    run(tmp_path / "2", f2 := FakeNear(captured))
    assert f2.calls.count("/attestation/report") == 1


def test_tcb_out_of_date_is_a_visible_warning_not_a_silent_pass(tmp_path, captured):
    r, *_ = run(tmp_path, FakeNear(captured), quote=FakeQuoteVerifier(status="OutOfDate"))
    v = r.json()["verification"]
    assert {c["id"]: c["status"] for c in v["checks"]}["model.quote"] == "warn"


# --- §4 signed reply integrity -------------------------------------------------------------------------

class AlteredReply(FakeNear):
    def handler(self, request):
        resp = super().handler(request)
        if request.url.path.endswith("/chat/completions"):
            return httpx.Response(200, content=resp.content.replace(b"quick brown", b"wire money"), headers=resp.headers)
        return resp


class WrongModelReply(FakeNear):
    """Signs honestly, but the reply names a different model than the one we attested."""
    def handler(self, request):
        if request.url.path.endswith("/chat/completions"):
            resp = super().handler(request)
            body = resp.content.replace(f'"model": "{MODEL}"'.encode(), b'"model": "cheap/other-model"')
            req = self.completions["chat123"][0]
            self.completions["chat123"] = (req, body)
            return httpx.Response(200, content=body, headers=resp.headers)
        return super().handler(request)


class NoSignature(FakeNear):
    def handler(self, request):
        if request.url.path.startswith("/v1/signature/"):
            self.calls.append("/signature")
            return httpx.Response(404)
        return super().handler(request)


class SignatureGarbage(FakeNear):
    def handler(self, request):
        if request.url.path.startswith("/v1/signature/"):
            self.calls.append("/signature")
            return httpx.Response(200, json={"text": "x", "signature": "0xdeadbeef", "signing_address": "0x" + "00" * 20,
                                             "signing_algo": "ecdsa", "signature_kind": "provider_tee"})
        return super().handler(request)


@pytest.mark.parametrize("fake_cls,kw,failed_check", [
    (FakeNear, dict(sign_with=Account.create()), "signature.bound"),          # signed by the wrong identity
    (AlteredReply, {}, "signature.hashes"),                                    # tampered in transit
    (SignatureGarbage, {}, "signature.hashes"),                                # incorrect signature
    (FakeNear, dict(kind="gateway", sign_with=Account.create()), "signature.bound"),  # forged "gateway" signature
    (WrongModelReply, {}, "response.model"),                                   # reply from another model
])
def test_bad_signature_never_yields_a_usable_result(tmp_path, captured, fake_cls, kw, failed_check):
    r, fake, wire, store = run(tmp_path, fake_cls(captured, **kw))
    assert r.status_code == 502 and r.json()["error"] == "response_untrusted", r.text
    body = r.json()
    assert body["text_sent"] is True                     # honest: the text did reach the attested enclave
    assert "suggestion" not in body and "answer" not in body
    assert body["verification"]["trust"] == "rejected"
    assert {c["id"]: c["status"] for c in body["verification"]["checks"]}[failed_check] == "fail"
    assert store.list_drafts(10) == []                   # never persisted as a result


def test_missing_signature_is_labelled_unsigned_not_verified(tmp_path, captured):
    r, *_ = run(tmp_path, NoSignature(captured))
    assert r.status_code == 200
    v = r.json()["verification"]
    assert v["trust"] == "unsigned" and v["verdict"] == "partial"
    assert "not signed" in v["summary"]


def test_gateway_signature_is_never_promoted_to_enclave(tmp_path, captured):
    r, *_ = run(tmp_path, FakeNear(captured, kind="gateway"))
    v = r.json()["verification"]
    assert v["trust"] == "gateway_signed" and v["verdict"] == "partial"
    assert "not by the model enclave" in v["summary"]


def test_a_signature_for_a_different_request_does_not_verify(tmp_path, captured):
    """Request-to-response binding: a genuine enclave signature over some other chat's bytes."""
    class Swapped(FakeNear):
        def handler(self, request):
            resp = super().handler(request)
            if request.url.path.endswith("/chat/completions"):
                req, body = self.completions["chat123"]
                self.completions["chat123"] = (req.replace(b"PRIVATE", b"public!"), body)
            return resp

    r, *_ = run(tmp_path, Swapped(captured))
    assert r.status_code == 502 and r.json()["verification"]["trust"] == "rejected"


def test_gpu_result_is_a_dataclass_contract():
    assert GpuResult(True, "x").ok
