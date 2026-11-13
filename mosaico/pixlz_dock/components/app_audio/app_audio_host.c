// SPDX-License-Identifier: Apache-2.0
// The simulator has no microphone.
#include "include/app_audio.h"

bool app_audio_start(void) { return false; }
void app_audio_stop(void) {}
bool app_audio_recording(void) { return false; }
const uint8_t *app_audio_clip(size_t *len) { *len = 0; return NULL; }
int app_audio_level(void) { return 0; }
