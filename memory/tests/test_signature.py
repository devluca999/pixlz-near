import hashlib

from eth_account import Account
from eth_account.messages import encode_defunct

from pixl_memory.verify import Check, Status, Verdict, Verification, combine, verify_signature

MODEL = "z-ai/glm-5.3-flash"
REQ, RESP = b'{"model":"m"}', b'{"id":"abc"}'


def h(b):
    return hashlib.sha256(b).hexdigest()


def attested(model_addr=None, gw_addr=None):
    return Verification(Verdict.VERIFIED, [Check("model.quote", "Model quote", Status.PASS)], MODEL, "00" * 32,
                        gateway_signing_address=gw_addr, model_signing_address=model_addr)


def sign(acct, text, kind="provider_tee"):
    sig = Account.sign_message(encode_defunct(text=text), acct.key).signature.hex()
    return {"text": text, "signature": "0x" + sig.removeprefix("0x"), "signing_address": acct.address,
            "signing_algo": "ecdsa", "signature_kind": kind}


def test_provider_tee_signature_verifies():
    acct = Account.create()
    att = attested(model_addr=acct.address.lower())
    checks, kind = verify_signature(sign(acct, f"{MODEL}:{h(REQ)}:{h(RESP)}"), MODEL, REQ, RESP, att)
    assert kind == "provider_tee"
    assert all(c.status is Status.PASS for c in checks), checks
    assert combine(att, checks, kind).verdict is Verdict.VERIFIED


def test_changed_response_bytes_fail():
    acct = Account.create()
    att = attested(model_addr=acct.address.lower())
    checks, _ = verify_signature(sign(acct, f"{MODEL}:{h(REQ)}:{h(RESP)}"), MODEL, REQ, RESP + b" ", att)
    assert {c.id: c.status for c in checks}["signature.hashes"] is Status.FAIL


def test_unattested_signer_fails():
    acct, other = Account.create(), Account.create()
    att = attested(model_addr=other.address.lower())
    checks, kind = verify_signature(sign(acct, f"{MODEL}:{h(REQ)}:{h(RESP)}"), MODEL, REQ, RESP, att)
    assert {c.id: c.status for c in checks}["signature.bound"] is Status.FAIL
    assert combine(att, checks, kind).verdict is Verdict.FAILED


def test_forged_address_claim_fails():
    acct, other = Account.create(), Account.create()
    sig = sign(acct, f"{MODEL}:{h(REQ)}:{h(RESP)}")
    sig["signing_address"] = other.address  # claims the attested key, signed with another
    att = attested(model_addr=other.address.lower())
    checks, _ = verify_signature(sig, MODEL, REQ, RESP, att)
    assert {c.id: c.status for c in checks}["signature.valid"] is Status.FAIL


def test_gateway_signature_is_partial():
    gw = Account.create()
    att = attested(model_addr="0x" + "11" * 20, gw_addr=gw.address.lower())
    checks, kind = verify_signature(sign(gw, f"{h(REQ)}:{h(RESP)}", kind="gateway"), MODEL, REQ, RESP, att)
    assert all(c.status is Status.PASS for c in checks)
    v = combine(att, checks, kind)
    assert v.verdict is Verdict.PARTIAL
    assert "gateway" in v.to_dict()["summary"]


def test_missing_signature_is_partial():
    att = attested(model_addr="0x" + "11" * 20)
    checks, kind = verify_signature({"error_code": "not_found", "message": "nope"}, MODEL, REQ, RESP, att)
    assert checks[0].status is Status.SKIP
    assert combine(att, checks, kind).verdict is Verdict.PARTIAL
