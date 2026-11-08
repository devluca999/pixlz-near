"""Against the real NEAR AI Cloud. Run with: uv run pytest -m live
Attestation needs only the network; polish needs NEARAI_API_KEY (and spends a fraction of a cent)."""

import os

import pytest

from pixl_memory import polish
from pixl_memory.nearai import DEFAULT_MODEL, NearAIClient

pytestmark = pytest.mark.live


def test_live_attestation():
    v = NearAIClient(os.environ.get("NEARAI_API_KEY")).attest(DEFAULT_MODEL)
    bad = [c for c in v.checks if c.status.value in ("fail", "skip")]
    assert not bad, bad
    assert v.model_signing_address and v.gateway_signing_address


@pytest.mark.skipif(not os.environ.get("NEARAI_API_KEY"), reason="needs NEARAI_API_KEY")
def test_live_polish_is_verified():
    c = NearAIClient(os.environ["NEARAI_API_KEY"])
    comp = c.chat(polish.messages("teh frog sit on the windw", None), DEFAULT_MODEL, temperature=0.3, max_tokens=256)
    v = comp.verification.to_dict()
    assert comp.content.strip()
    assert v["verdict"] in ("verified", "partial"), v
    assert {x["id"]: x["status"] for x in v["checks"]}.get("signature.hashes") == "pass", v
