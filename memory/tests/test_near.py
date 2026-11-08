"""Frogg's transaction signing, checked byte-for-byte against near-api-js."""

import json
from pathlib import Path

import pytest

from pixl_memory.near import (KeyPair, b58decode, b58encode, encode_transfer, near_to_yocto, sign_transaction,
                              yocto_to_near)

VECTOR = json.loads((Path(__file__).parent / "fixtures" / "near_transfer_vector.json").read_text())
DUMMY = KeyPair(bytes(range(32)))  # test-only seed, never used on chain


def test_public_key_matches_near_api_js():
    assert DUMMY.public_key == VECTOR["pub"]
    assert KeyPair.from_secret(DUMMY.secret_key) == DUMMY
    assert "ed25519:" not in repr(DUMMY).replace(DUMMY.public_key, "")  # repr shows only the public key


def test_transfer_encoding_and_signature_match_near_api_js():
    tx = encode_transfer(VECTOR["signer"], DUMMY.public_bytes, VECTOR["nonce"], VECTOR["receiver"],
                         bytes.fromhex(VECTOR["block_hash_hex"]), int(VECTOR["deposit_yocto"]))
    assert tx.hex() == VECTOR["tx"]
    signed, tx_hash = sign_transaction(tx, DUMMY)
    assert signed[len(tx):].hex() == "00" + VECTOR["sig"]  # KeyType::ED25519 + 64-byte signature
    assert len(b58decode(tx_hash)) == 32


def test_base58_roundtrip_and_leading_zeros():
    for data in [b"", b"\0", b"\0\0abc", bytes(range(32)), b"\xff" * 40]:
        assert b58decode(b58encode(data)) == data
    assert b58encode(b"\0\0\x01") == "112"


def test_amounts():
    assert near_to_yocto("1.5") == 1_500_000_000_000_000_000_000_000
    assert near_to_yocto("0.000001") == 10**18
    assert yocto_to_near(1_500_000_000_000_000_000_000_000) == "1.5"
    assert yocto_to_near(0) == "0"
    assert yocto_to_near(400_000_000_000_000_000_000) == "0.0004"


def test_rejects_bad_inputs():
    with pytest.raises(ValueError):
        encode_transfer("a", b"short", 1, "b", bytes(32), 1)
    with pytest.raises(ValueError):
        encode_transfer("a", bytes(32), 1, "b", bytes(32), -1)
    with pytest.raises(ValueError):
        KeyPair.from_secret("secp256k1:abc")
