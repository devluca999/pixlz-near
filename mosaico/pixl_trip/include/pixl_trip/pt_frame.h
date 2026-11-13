// Length-prefixed frames, the same as PixlzCore's `Framing`: a 4-byte big-endian length, then
// that many bytes of JSON. The framer owns no memory; the caller hands it a buffer.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *buf;
    size_t cap;
    size_t len;
    /// Set when a frame announces a body larger than the buffer can hold; the stream is unusable.
    bool too_large;
} pt_framer_t;

void pt_framer_init(pt_framer_t *f, uint8_t *buf, size_t cap);

/// Copies as many of `n` bytes as fit and returns how many were taken. Take whole frames out
/// with `pt_framer_next` / `pt_framer_pop`, then feed the rest.
size_t pt_framer_feed(pt_framer_t *f, const uint8_t *data, size_t n);

/// True when a whole frame is at the front; `body`/`len` point into the buffer until the next pop.
bool pt_framer_next(pt_framer_t *f, const uint8_t **body, size_t *len);

/// Drops the frame at the front.
void pt_framer_pop(pt_framer_t *f);

/// Writes the 4-byte header for a body of `len` bytes.
void pt_frame_header(uint32_t len, uint8_t out[4]);

#ifdef __cplusplus
}
#endif
