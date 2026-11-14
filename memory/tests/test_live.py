"""Against the real NEAR AI Cloud. Run with: uv run pytest -m live
Attestation needs only the network; polish needs NEAR_AI_API_KEY in .env (and spends a fraction of a cent)."""

import pytest

from pixl_memory import polish
from pixl_memory.config import read_secret
from pixl_memory.nearai import DEFAULT_MODEL, NearAIClient

pytestmark = pytest.mark.live


def test_live_attestation():
    v = NearAIClient(read_secret("NEAR_AI_API_KEY")).attest(DEFAULT_MODEL)
    bad = [c for c in v.checks if c.status.value in ("fail", "skip")]
    assert not bad, bad
    assert v.model_signing_address and v.gateway_signing_address


@pytest.mark.skipif(not read_secret("NEAR_AI_API_KEY"), reason="needs NEAR_AI_API_KEY in .env")
def test_live_polish_is_verified():
    c = NearAIClient(read_secret("NEAR_AI_API_KEY"))
    comp = c.chat(polish.messages("teh frog sit on the windw", None), DEFAULT_MODEL, temperature=0.3, max_tokens=256)
    v = comp.verification.to_dict()
    assert comp.content.strip()
    assert v["verdict"] in ("verified", "partial"), v
    assert {x["id"]: x["status"] for x in v["checks"]}.get("signature.hashes") == "pass", v


def test_live_tls_pin_matches_the_attested_gateway_and_rejects_another():
    """Free: attests (no key), then opens pinned connections to /models. No text is sent."""
    from pixl_memory.nearai import TlsPinMismatch

    c = NearAIClient(None)
    v = c.attest(DEFAULT_MODEL)
    assert v.attestation_ok, v.blocking_reasons()
    assert c._pinned("GET", f"{c.base_url}/models", v.tls_fingerprint).status_code == 200
    with pytest.raises(TlsPinMismatch):
        c._pinned("GET", f"{c.base_url}/models", "00" * 32)
