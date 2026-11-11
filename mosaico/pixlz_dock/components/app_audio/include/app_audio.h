// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Dictation (D22): the onboard microphone through the ES8311, 16 kHz mono, IMA ADPCM (4 bits a
 * sample), up to 30 s. Powered only while recording. One owner loop calls these. */
enum { APP_AUDIO_RATE = 16000, APP_AUDIO_MAX_SECONDS = 30 };

/** Start recording into a fresh clip. False when the microphone can't start (none in the simulator). */
bool app_audio_start(void);
/** Stop recording; the clip stays until the next start. */
void app_audio_stop(void);
bool app_audio_recording(void);
/** The recorded clip (ADPCM bytes) and its length. */
const uint8_t *app_audio_clip(size_t *len);
/** Loudness of the last moment, 0..100, for the mic button's meter. */
int app_audio_level(void);

#ifdef __cplusplus
}
#endif
