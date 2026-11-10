// SHA-256 (FIPS 180-4). Small and dependency-free so the trip module builds the same on the
// host and on the device. Travel acks carry the hex digest of the raw payload.state bytes.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t h[8];
    uint64_t bits;
    uint8_t block[64];
    size_t used;
} pt_sha256_t;

void pt_sha256_init(pt_sha256_t *c);
void pt_sha256_update(pt_sha256_t *c, const void *data, size_t len);
void pt_sha256_final(pt_sha256_t *c, uint8_t out[32]);

/// One-shot: lowercase hex digest into `hex` (65 bytes with the terminator).
void pt_sha256_hex(const void *data, size_t len, char hex[65]);

#ifdef __cplusplus
}
#endif
