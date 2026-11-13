// SPDX-License-Identifier: Apache-2.0
#include "../include/pixl_trip/pt_adpcm.h"

static const int16_t k_steps[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
    97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
    724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660,
    4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
    18500, 20350, 22385, 24623, 27086, 29794, 32767};
static const int8_t k_index[16] = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};

void pt_adpcm_init(pt_adpcm_t *s)
{
    s->predictor = 0;
    s->index = 0;
}

/* Applies one 4-bit code to the state; returns the new sample. Shared by both directions. */
static int16_t step(pt_adpcm_t *s, uint8_t code)
{
    int32_t st = k_steps[s->index];
    int32_t diff = st >> 3;
    if (code & 4) diff += st;
    if (code & 2) diff += st >> 1;
    if (code & 1) diff += st >> 2;
    s->predictor += (code & 8) ? -diff : diff;
    if (s->predictor > 32767) s->predictor = 32767;
    if (s->predictor < -32768) s->predictor = -32768;
    s->index += k_index[code & 15];
    if (s->index < 0) s->index = 0;
    if (s->index > 88) s->index = 88;
    return (int16_t)s->predictor;
}

static uint8_t encode_one(pt_adpcm_t *s, int16_t sample)
{
    int32_t st = k_steps[s->index];
    int32_t diff = (int32_t)sample - s->predictor;
    uint8_t code = 0;
    if (diff < 0) {
        code = 8;
        diff = -diff;
    }
    if (diff >= st) { code |= 4; diff -= st; }
    st >>= 1;
    if (diff >= st) { code |= 2; diff -= st; }
    st >>= 1;
    if (diff >= st) { code |= 1; }
    (void)step(s, code);
    return code;
}

size_t pt_adpcm_encode(pt_adpcm_t *s, const int16_t *pcm, size_t n, uint8_t *out)
{
    size_t o = 0;
    for (size_t i = 0; i + 1 < n; i += 2) {
        uint8_t lo = encode_one(s, pcm[i]);
        uint8_t hi = encode_one(s, pcm[i + 1]);
        out[o++] = (uint8_t)(lo | (hi << 4));
    }
    return o;
}

size_t pt_adpcm_decode(pt_adpcm_t *s, const uint8_t *in, size_t n, int16_t *pcm)
{
    for (size_t i = 0; i < n; i++) {
        pcm[2 * i] = step(s, in[i] & 15);
        pcm[2 * i + 1] = step(s, in[i] >> 4);
    }
    return 2 * n;
}
