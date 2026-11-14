"""Regression tests for the 2026-11-13 audit: a GPU check that can't run never lets text out,
and the wallet survives a NEAR RPC that misbehaves."""

from __future__ import annotations

import threading

import httpx
import pytest

from pixl_memory.config import WalletConfig, WalletConfigError

from .conftest import MODEL, FakeQuoteVerifier
from fastapi.testclient import TestClient
from pixl_memory.nearai import NearAIClient
from pixl_memory.server import create_app
from pixl_memory.store import Store
from .test_flow import TOKEN, FakeNear
from pixl_memory.wallet import today
from .test_wallet import FROGG, N, FakeChain, ready


class RaisingGpu:
    def __init__(self, exc):
        self.exc = exc

    def verify(self, payload):
        raise self.exc


def _req():
    return httpx.Request("POST", "https://nras.attestation.nvidia.com/v3/attest/gpu")


@pytest.mark.parametrize("exc", [
    httpx.ConnectError("down", request=_req()),                                                  # NRAS unreachable
    httpx.HTTPStatusError("bad", request=_req(), response=httpx.Response(400, request=_req())),  # NRAS rejected it
    httpx.HTTPStatusError("busy", request=_req(), response=httpx.Response(503, request=_req())),
    ValueError("malformed JWT"),
])
def test_text_never_sent_when_the_gpu_check_cannot_pass(tmp_path, captured, exc):
    fake = FakeNear(captured)
    http = httpx.Client(transport=httpx.MockTransport(fake.handler))
    nc = NearAIClient("sk-test", "https://cloud-api.near.ai/v1", http=http, quote_verifier=FakeQuoteVerifier(),
                      gpu_verifier=RaisingGpu(exc), sleep=lambda s: None)
    tc = TestClient(create_app(Store(tmp_path / "s"), nc, TOKEN, MODEL, None), headers={"Authorization": f"Bearer {TOKEN}"})
    r = tc.post("/polish", json={"text": "my private note"})
    assert r.status_code == 409, r.text
    assert "/chat/completions" not in fake.calls


def test_rpc_that_returns_html_is_an_rpc_error_not_a_crash(tmp_path):
    w, chain = ready(tmp_path)
    w.rpc.http = httpx.Client(transport=httpx.MockTransport(lambda req: httpx.Response(502, text="<html>bad gateway</html>")))
    assert w.status()["ready"] is False
    r = w.pay(None, {})
    assert r["status"] == "refused" and "balance" in r["reason"]
    assert not chain.sent


def test_a_transfer_with_an_unknown_outcome_counts_against_the_caps(tmp_path):
    w, chain = ready(tmp_path, max_per_day_near="0.0006", max_per_request_near="0.0005")
    real = chain.handler

    def timeout_on_send(req):
        if b"send_tx" in req.content:
            real(req)  # the chain gets it...
            raise httpx.ReadTimeout("slow", request=req)  # ...but the reply never arrives
        return real(req)
    w.rpc.http = httpx.Client(transport=httpx.MockTransport(timeout_on_send))
    r = w.pay(None, {})
    assert r["status"] == "pending" and r["tx_hash"]
    assert w.spent_on(today()) == N("0.0005")
    assert w.pay(None, {})["status"] == "refused"  # the cap already holds the pending one
    assert len(chain.sent) == 1


def test_back_to_back_payments_never_reuse_a_nonce(tmp_path):
    w, chain = ready(tmp_path)
    real = chain.handler
    stale = {"nonce": chain.nonce}

    def lagging_key(req):  # the RPC keeps reporting the old nonce, as a just-finalized read would
        if b"view_access_key" in req.content:
            return httpx.Response(200, json={"result": {"nonce": stale["nonce"], "block_hash": "11111111111111111111111111111111"}})
        return real(req)
    w.rpc.http = httpx.Client(transport=httpx.MockTransport(lagging_key))
    assert w.pay(None, {})["status"] == "paid"
    assert w.pay(None, {})["status"] == "paid"
    assert [t["nonce"] for t in chain.sent] == [101, 102]


def test_concurrent_payments_respect_the_daily_cap(tmp_path):
    w, chain = ready(tmp_path, max_per_day_near="0.001", max_per_request_near="0.0005")
    out = []
    ts = [threading.Thread(target=lambda: out.append(w.pay(None, {})["status"])) for _ in range(6)]
    [t.start() for t in ts]; [t.join() for t in ts]
    assert out.count("paid") == 2 and len(chain.sent) == 2


@pytest.mark.parametrize("url", ["https://rpc.fastnear.com", "https://rpc.near.org", "https://rpc.mainnet.near.org"])
def test_rpc_url_must_be_a_testnet_endpoint(tmp_path, url):
    env = tmp_path / ".env"
    env.write_text(f"PIXL_PARENT_ACCOUNT=sylversurferr.testnet\nNEAR_RPC_URL={url}\n")
    with pytest.raises(WalletConfigError):
        WalletConfig.from_env(env)


@pytest.mark.parametrize("v", ["nan", "inf"])
def test_caps_must_be_finite(tmp_path, v):
    env = tmp_path / ".env"
    env.write_text(f"PIXL_PARENT_ACCOUNT=sylversurferr.testnet\nFROGG_MAX_PER_WEEK_NEAR={v}\n")
    with pytest.raises(WalletConfigError):
        WalletConfig.from_env(env)
