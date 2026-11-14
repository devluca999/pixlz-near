"""Shared fixtures: a real NEAR attestation report (captured 2026-11-14 02:47 UTC, with the TLS fingerprint binding; 3 model instances) and fakes
for the two network verifiers, so tests run offline."""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path

import pytest

from pixl_memory.verify import GpuResult, QuoteResult

FIXTURE = Path(__file__).parent / "fixtures" / "attestation_report.json"
MODEL = "z-ai/glm-5.3-flash"


class FakeQuoteVerifier:
    def __init__(self, status: str = "UpToDate", error: Exception | None = None):
        self.status, self.error, self.calls = status, error, 0

    def verify(self, raw_quote: bytes) -> QuoteResult:
        self.calls += 1
        if self.error:
            raise self.error
        return QuoteResult(self.status, [])


class FakeGpuVerifier:
    def __init__(self, ok: bool = True):
        self.ok, self.payloads = ok, []

    def verify(self, payload):
        self.payloads.append(payload)
        return GpuResult(self.ok, "fake NRAS: ok" if self.ok else "fake NRAS: failed")


@pytest.fixture(scope="session")
def _captured():
    return json.loads(FIXTURE.read_text())


@pytest.fixture
def captured(_captured):
    """{'nonce': str, 'report': dict} — a fresh deep copy per test so tests can tamper."""
    return copy.deepcopy(_captured)


FAKE_TLS_FP = "7e" * 32   # stands in for sha256(SPKI) of the gateway's TLS key


def rebind(report: dict, nonce: str, model_address: str | None = None, gateway_address: str | None = None,
           tls_fingerprint: str | None = FAKE_TLS_FP) -> dict:
    """Rewrite a captured report so its quotes carry `nonce` and the given signer
    addresses. Only useful with FakeQuoteVerifier (the Intel signature no longer
    covers the patched bytes), which lets tests drive the full flow with keys we own."""
    report = copy.deepcopy(report)

    def patch(att: dict, address: str | None, tls: str | None = None):
        q = bytearray(bytes.fromhex(att["intel_quote"]))
        start = 48 + 520
        if address:
            q[start : start + 32] = bytes.fromhex(address.removeprefix("0x")).ljust(32, b"\0")
            att["signing_address"] = address
        if tls:   # NEAR's include_tls_fingerprint binding: sha256(address ‖ sha256(SPKI))
            addr = bytes.fromhex(att["signing_address"].removeprefix("0x"))
            q[start : start + 32] = hashlib.sha256(addr + bytes.fromhex(tls)).digest()
            att["tls_cert_fingerprint"] = tls
        q[start + 32 : start + 64] = bytes.fromhex(nonce)
        att["intel_quote"] = q.hex()
        att["request_nonce"] = nonce
        if "report_data" in att:
            att["report_data"] = bytes(q[start : start + 64]).hex()
        if att.get("nvidia_payload"):
            p = json.loads(att["nvidia_payload"])
            p["nonce"] = nonce
            att["nvidia_payload"] = json.dumps(p)

        cm = att.get("compose_manager_attestation")
        if cm:
            cq = bytearray(bytes.fromhex(cm["quote"]))
            cq[start + 32 : start + 64] = bytes.fromhex(nonce)
            cm["quote"] = cq.hex()
            cm["nonce"] = nonce
            cm["report_data"] = bytes(cq[start : start + 64]).hex()

    patch(report["gateway_attestation"], gateway_address, tls_fingerprint)
    for m in report.get("model_attestations", []):
        patch(m, model_address, m.get("tls_cert_fingerprint") and "6d" * 32)
    return report
