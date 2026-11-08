import base64
import json

from pixl_memory.verify import check_nras_response

NONCE = "ab" * 32
NOW = 1_800_000_000


def jwt(claims):
    enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()  # noqa: E731
    return f"{enc({'alg': 'ES384'})}.{enc(claims)}.sig"


def gpu(**over):
    c = {"eat_nonce": NONCE, "secboot": True, "dbgstat": "disabled", "hwmodel": "GH100", "exp": NOW + 3600,
         "x-nvidia-attestation-warning": None, "x-nvidia-gpu-attestation-report-signature-verified": True,
         "x-nvidia-gpu-driver-rim-signature-verified": True}
    return jwt(c | over)


def body(overall=None, **gpus):
    o = {"x-nvidia-overall-att-result": True, "eat_nonce": NONCE, "exp": NOW + 3600} | (overall or {})
    return [["JWT", jwt(o)], gpus or {"GPU-0": gpu(), "GPU-1": gpu()}]


def test_good_response():
    r = check_nras_response(body(), NONCE, NOW)
    assert r.ok and "2 × GH100" in r.detail


def test_each_failure_is_caught():
    assert not check_nras_response(body({"x-nvidia-overall-att-result": False}), NONCE, NOW).ok
    assert not check_nras_response(body({"eat_nonce": "00" * 32}), NONCE, NOW).ok
    assert not check_nras_response(body({"exp": NOW - 1}), NONCE, NOW).ok
    for bad in [dict(secboot=False), dict(dbgstat="enabled"), dict(eat_nonce="00"),
                {"x-nvidia-attestation-warning": "old driver"},
                {"x-nvidia-gpu-driver-rim-signature-verified": False}, dict(exp=NOW - 1)]:
        r = check_nras_response(body(**{"GPU-0": gpu(), "GPU-1": gpu(**bad)}), NONCE, NOW)
        assert not r.ok and r.detail.startswith("GPU-1"), bad
    assert not check_nras_response([["JWT", jwt({"x-nvidia-overall-att-result": True, "eat_nonce": NONCE,
                                                 "exp": NOW + 1})]], NONCE, NOW).ok
    assert not check_nras_response({}, NONCE, NOW).ok
