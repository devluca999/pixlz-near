// Pairing crypto (D20): X25519 (RFC 7748), HMAC-SHA256 (RFC 2104), HKDF-SHA256 (RFC 5869),
// hex, and a constant-time compare. Dependency-free like pt_sha256, so the host tests and the
// device run the same code; checked against the RFCs' vectors and against CryptoKit.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// out = X25519(scalar, point). False when the result is all zeros (a low-order point).
/// Not reentrant (uses static work space): one owner loop.
bool pt_x25519(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]);
/// The public key for a private scalar: X25519(scalar, 9).
void pt_x25519_public(uint8_t out[32], const uint8_t scalar[32]);

void pt_hmac_sha256(const uint8_t *key, size_t key_len, const void *msg, size_t msg_len, uint8_t out[32]);
/// HKDF-SHA256 with a 32-byte output.
void pt_hkdf_sha256(const uint8_t *ikm, size_t ikm_len, const uint8_t *salt, size_t salt_len, const char *info,
                    uint8_t out[32]);

/// Lowercase hex; `hex` holds 2*len+1.
void pt_hex(const uint8_t *bytes, size_t len, char *hex);
/// Exactly 2*len hex digits into `out`; false otherwise.
bool pt_unhex(const char *hex, uint8_t *out, size_t len);
/// Constant-time equality.
bool pt_equal(const uint8_t *a, const uint8_t *b, size_t len);

#ifdef __cplusplus
}
#endif
