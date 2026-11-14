"""TLS pinning: the completion's connection must present the TLS key bound in the gateway's quote,
checked during the handshake, before a single request byte is written."""

from __future__ import annotations

import datetime as dt
import hashlib

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.x509.oid import NameOID

from pixl_memory.nearai import TlsPin, TlsPinMismatch, spki_sha256


def make_cert():
    key = ec.generate_private_key(ec.SECP256R1())
    now = dt.datetime.now(dt.UTC)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "cloud-api.near.ai")])
    c = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
         .serial_number(1).not_valid_before(now).not_valid_after(now + dt.timedelta(days=1)).sign(key, hashes.SHA256()))
    fp = hashlib.sha256(key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)).hexdigest()
    return c.public_bytes(Encoding.DER), fp


class Stream:
    def __init__(self, der):
        self.der = der

    def get_extra_info(self, name):
        if name != "ssl_object":
            return None
        der = self.der

        class Ssl:
            def getpeercert(self, binary):
                return der
        return Ssl()


def test_spki_fingerprint_matches_nears_definition():
    der, fp = make_cert()
    assert spki_sha256(der) == fp


def test_matching_key_lets_the_request_through():
    der, fp = make_cert()
    pin = TlsPin(fp)
    pin("connection.start_tls.complete", {"return_value": Stream(der)})
    pin("http11.send_request_headers.started", {})
    assert pin.ok


def test_another_key_stops_before_any_byte_is_written():
    der, _ = make_cert()
    _, attested = make_cert()
    pin = TlsPin(attested)
    with pytest.raises(TlsPinMismatch):
        pin("connection.start_tls.complete", {"return_value": Stream(der)})
    assert not pin.ok


def test_a_reused_unchecked_connection_is_refused():
    pin = TlsPin("ab" * 32)
    with pytest.raises(TlsPinMismatch):
        pin("http11.send_request_headers.started", {})


def test_no_attested_fingerprint_refuses():
    der, _ = make_cert()
    with pytest.raises(TlsPinMismatch):
        TlsPin("")("connection.start_tls.complete", {"return_value": Stream(der)})
