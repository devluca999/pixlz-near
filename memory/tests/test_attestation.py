import hashlib
import json

import pytest

from pixl_memory import tdx
from pixl_memory.verify import Status, Verdict, verify_attestation

from .conftest import MODEL, FakeGpuVerifier, FakeQuoteVerifier, rebind


def by_id(v):
    return {c.id: c for c in v.checks}


def test_quote_fields_match_the_json(captured):
    gw = captured["report"]["gateway_attestation"]
    f = tdx.parse_td_quote(bytes.fromhex(gw["intel_quote"]))
    assert f.version == 4
    assert not f.debug
    assert f.report_data.hex() == gw["report_data"]
    assert f.rtmr[3].hex() == gw["info"]["tcb_info"]["rtmr3"]
    assert f.mr_td.hex() == gw["info"]["tcb_info"]["mrtd"]


@pytest.mark.parametrize("role", ["gateway", "model"])
def test_rtmr3_replay_and_compose_on_real_report(captured, role):
    r = captured["report"]
    att = r["gateway_attestation"] if role == "gateway" else r["model_attestations"][0]
    f = tdx.parse_td_quote(bytes.fromhex(att["intel_quote"]))
    events = tdx.parse_event_log(att["event_log"])
    assert tdx.replay_rtmr3(events) == f.rtmr[3]
    compose = att["info"]["tcb_info"]["app_compose"]
    assert f.mr_config_id == tdx.expected_mr_config_id(compose)
    assert tdx.runtime_events(events)["compose-hash"] == hashlib.sha256(compose.encode()).hexdigest()


def test_real_report_verifies(captured):
    gpu = FakeGpuVerifier()
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier(), gpu)
    assert v.verdict is Verdict.VERIFIED, [c for c in v.checks if c.status is not Status.PASS]
    assert v.model_signing_address == captured["report"]["model_attestations"][0]["signing_address"].lower()
    assert v.gateway_signing_address == captured["report"]["gateway_attestation"]["signing_address"].lower()
    assert gpu.payloads and gpu.payloads[0]["nonce"] == captured["nonce"]
    assert v.images and any("vllm" in i or "sglang" in i or "@sha256:" in i for i in v.images), v.images


def test_wrong_nonce_fails(captured):
    v = verify_attestation(captured["report"], "00" * 32, MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert v.verdict is Verdict.FAILED
    c = by_id(v)
    assert c["gateway.nonce"].status is Status.FAIL
    assert c["model.nonce"].status is Status.FAIL
    assert v.model_signing_address is None


def test_swapped_signer_fails(captured):
    r = captured["report"]
    r["model_attestations"][0]["signing_address"] = "0x" + "11" * 20
    v = verify_attestation(r, captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["model.signer"].status is Status.FAIL
    assert v.model_signing_address is None


def test_tampered_compose_fails(captured):
    r = captured["report"]
    tcb = r["model_attestations"][0]["info"]["tcb_info"]
    tcb["app_compose"] = tcb["app_compose"].replace("dstack", "dstock", 1)
    v = verify_attestation(r, captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["model.compose"].status is Status.FAIL


def test_tampered_event_log_fails(captured):
    gw = captured["report"]["gateway_attestation"]
    events = json.loads(gw["event_log"])
    ev = next(e for e in events if e["imr"] == 3 and e["event"] == "app-id")
    ev["event_payload"] = "00" * 20
    gw["event_log"] = json.dumps(events)
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["gateway.rtmr3"].status is Status.FAIL


def test_debug_td_fails(captured):
    att = captured["report"]["model_attestations"][0]
    q = bytearray(bytes.fromhex(att["intel_quote"]))
    q[48 + 120] |= 0x01
    att["intel_quote"] = q.hex()
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["model.debug"].status is Status.FAIL


def test_gpu_failure_and_bad_quote(captured):
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier(ok=False))
    assert by_id(v)["model.gpu"].status is Status.FAIL
    v = verify_attestation(captured["report"], captured["nonce"], MODEL,
                           FakeQuoteVerifier(error=RuntimeError("bad signature")), FakeGpuVerifier())
    assert by_id(v)["gateway.quote"].status is Status.FAIL
    assert v.verdict is Verdict.FAILED


def test_outdated_tcb_is_a_warning(captured):
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier("OutOfDate"), FakeGpuVerifier())
    assert by_id(v)["model.quote"].status is Status.WARN
    assert v.verdict is Verdict.VERIFIED
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier("Revoked"), FakeGpuVerifier())
    assert v.verdict is Verdict.FAILED


def test_model_without_tee_attestation_fails(captured):
    r = captured["report"]
    r["model_attestations"] = []
    v = verify_attestation(r, captured["nonce"], "openai/gpt-5", FakeQuoteVerifier(), FakeGpuVerifier())
    assert v.verdict is Verdict.FAILED
    assert "not run in a NEAR TEE" in by_id(v)["model.quote"].detail


def test_two_distinct_model_signers_fail(captured):
    r = captured["report"]
    second = rebind({"gateway_attestation": r["gateway_attestation"], "model_attestations": r["model_attestations"]},
                    captured["nonce"], model_address="0x" + "22" * 20)["model_attestations"][0]
    r["model_attestations"].append(second)
    v = verify_attestation(r, captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["model.unique"].status is Status.FAIL
    assert v.model_signing_address is None


def test_missing_gpu_evidence_fails(captured):
    captured["report"]["model_attestations"][0].pop("nvidia_payload")
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["model.gpu"].status is Status.FAIL


def test_deployment_log_verifies_and_detects_tampering(captured):
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["model.deploy"].status is Status.PASS
    assert "last deploy" in by_id(v)["model.deploy"].detail
    cm = captured["report"]["model_attestations"][0]["compose_manager_attestation"]
    cm["actions"][-1]["commit"] = "deadbeef"
    v = verify_attestation(captured["report"], captured["nonce"], MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert by_id(v)["model.deploy"].status is Status.FAIL


def test_rebind_keeps_report_valid(captured):
    nonce = "ab" * 32
    r = rebind(captured["report"], nonce, model_address="0x" + "33" * 20)
    v = verify_attestation(r, nonce, MODEL, FakeQuoteVerifier(), FakeGpuVerifier())
    assert v.verdict is Verdict.VERIFIED, [c for c in v.checks if c.status is not Status.PASS]
    assert v.model_signing_address == "0x" + "33" * 20
