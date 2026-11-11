// IMA ADPCM, mono, one continuous stream (no block headers): 16-bit samples in, 4 bits each out,
// low nibble first. Dictation audio from the Mosaico (D22) is sent this way; the Mac decodes it
// with the same tables (PixlzCore MosaicoDictation).
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t predictor;
    int32_t index;
} pt_adpcm_t;

/// Start a stream (predictor 0, step index 0).
void pt_adpcm_init(pt_adpcm_t *s);
/// Encode `n` samples (n even) into n/2 bytes. Returns bytes written.
size_t pt_adpcm_encode(pt_adpcm_t *s, const int16_t *pcm, size_t n, uint8_t *out);
/// Decode `n` bytes into 2n samples (for tests and the simulator).
size_t pt_adpcm_decode(pt_adpcm_t *s, const uint8_t *in, size_t n, int16_t *pcm);

#ifdef __cplusplus
}
#endif
