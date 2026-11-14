"""NRAS token signatures: every JWT NVIDIA returns must verify against NVIDIA's JWKS (ES384)."""

from __future__ import annotations

import base64
import datetime as dt
import json
import time

import httpx
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.serialization import Encoding
from cryptography.x509.oid import NameOID

from pixl_memory.verify import NrasGpuVerifier, verify_es384_jwt

NONCE = "ab" * 32


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def cert(key, issuer_key, cn, issuer_cn):
    now = dt.datetime.now(dt.UTC)
    name = lambda c: x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, c)])  # noqa: E731
    return (x509.CertificateBuilder().subject_name(name(cn)).issuer_name(name(issuer_cn))
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - dt.timedelta(days=1)).not_valid_after(now + dt.timedelta(days=30))
            .sign(issuer_key, hashes.SHA384()))


class Nvidia:
    def __init__(self):
        self.inter = ec.generate_private_key(ec.SECP384R1())
        self.leaf = ec.generate_private_key(ec.SECP384R1())
        chain = [cert(self.leaf, self.inter, "NRAS leaf", "NRAS Intermediate"),
                 cert(self.inter, self.inter, "NRAS Intermediate", "NRAS Intermediate")]
        n = self.leaf.public_key().public_numbers()
        self.jwk = {"kty": "EC", "crv": "P-384", "kid": "kid-1", "x": b64u(n.x.to_bytes(48, "big")),
                    "y": b64u(n.y.to_bytes(48, "big")),
                    "x5c": [base64.b64encode(c.public_bytes(Encoding.DER)).decode() for c in chain]}

    def sign(self, claims, key=None, kid="kid-1"):
        h = b64u(json.dumps({"alg": "ES384", "kid": kid}).encode())
        p = b64u(json.dumps(claims).encode())
        r, s = decode_dss_signature((key or self.leaf).sign(f"{h}.{p}".encode(), ec.ECDSA(hashes.SHA384())))
        return f"{h}.{p}.{b64u(r.to_bytes(48, 'big') + s.to_bytes(48, 'big'))}"

    def reply(self, key=None):
        exp = time.time() + 600
        overall = self.sign({"x-nvidia-overall-att-result": True, "eat_nonce": NONCE, "exp": exp}, key)
        gpu = self.sign({"eat_nonce": NONCE, "secboot": True, "dbgstat": "disabled", "hwmodel": "GH100", "exp": exp}, key)
        return [["JWT", overall], {"GPU-0": gpu}]


def verifier(nv, reply):
    def handler(req):
        if req.url.path.endswith("jwks.json"):
            return httpx.Response(200, json={"keys": [nv.jwk]})
        return httpx.Response(200, json=reply)
    return NrasGpuVerifier(httpx.Client(transport=httpx.MockTransport(handler)))


def test_genuine_tokens_pass():
    nv = Nvidia()
    r = verifier(nv, nv.reply()).verify({"nonce": NONCE})
    assert r.ok and "signatures valid" in r.detail


def test_tokens_signed_by_another_key_fail():
    nv = Nvidia()
    r = verifier(nv, nv.reply(key=ec.generate_private_key(ec.SECP384R1()))).verify({"nonce": NONCE})
    assert not r.ok and "signature invalid" in r.detail


def test_unsigned_or_alg_none_tokens_fail():
    nv = Nvidia()
    tok = nv.sign({"x-nvidia-overall-att-result": True})
    h, p, _ = tok.split(".")
    none = b64u(json.dumps({"alg": "none", "kid": "kid-1"}).encode())
    assert verify_es384_jwt(f"{none}.{p}.", {"kid-1": nv.jwk}) is not None
    assert verify_es384_jwt(f"{h}.{p}.", {"kid-1": nv.jwk}) is not None
    assert verify_es384_jwt(tok, {}) is not None                      # unknown kid


def test_edited_claims_fail():
    nv = Nvidia()
    tok = nv.sign({"x-nvidia-overall-att-result": False})
    h, _, s = tok.split(".")
    forged = f"{h}.{b64u(json.dumps({'x-nvidia-overall-att-result': True}).encode())}.{s}"
    assert verify_es384_jwt(forged, {"kid-1": nv.jwk}) == "signature invalid"


def test_jwk_that_does_not_match_its_certificate_fails():
    nv = Nvidia()
    other = ec.generate_private_key(ec.SECP384R1()).public_key().public_numbers()
    bad = nv.jwk | {"x": b64u(other.x.to_bytes(48, "big")), "y": b64u(other.y.to_bytes(48, "big"))}
    assert "certificate" in verify_es384_jwt(nv.sign({}), {"kid-1": bad})


def test_a_key_minted_after_the_cache_is_fetched_once():
    """NVIDIA rotates signing keys every few minutes; an unknown kid triggers one JWKS refetch."""
    nv, fresh = Nvidia(), Nvidia()
    fresh.jwk = fresh.jwk | {"kid": "kid-2"}
    served = [[nv.jwk], [nv.jwk, fresh.jwk]]
    fetches = []

    def handler(req):
        if req.url.path.endswith("jwks.json"):
            fetches.append(1)
            return httpx.Response(200, json={"keys": served[min(len(fetches) - 1, 1)]})
        return httpx.Response(200, json=reply)

    v = NrasGpuVerifier(httpx.Client(transport=httpx.MockTransport(handler)))
    reply = nv.reply()
    assert v.verify({"nonce": NONCE}).ok and len(fetches) == 1
    exp = time.time() + 600
    reply = [["JWT", fresh.sign({"x-nvidia-overall-att-result": True, "eat_nonce": NONCE, "exp": exp}, kid="kid-2")],
             {"GPU-0": fresh.sign({"eat_nonce": NONCE, "secboot": True, "dbgstat": "disabled", "exp": exp}, kid="kid-2")}]
    assert v.verify({"nonce": NONCE}).ok and len(fetches) == 2
