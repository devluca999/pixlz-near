// SPDX-License-Identifier: Apache-2.0
// The onboard microphone (LMA2718B331) on the ES8311's ADC, read over I2S RX: MCLK 54, BCLK 37,
// WS 49. Which pin carries the codec's data is unclear: Espressif's pin table says DIN 52 (and
// DOUT 40), the vendor's board file drives the speaker on 52. So it tries 52, and if that's
// dead (exact zeros for a moment) it switches to 40 and remembers what worked. The codec is
// set up in ADC mode only and closed after each recording, so it draws nothing in between.
#include "include/app_audio.h"

#include <stdatomic.h>
#include <string.h>

#include "driver/i2c_master.h"
#include "driver/i2s_std.h"
#include "es8311_codec.h"
#include "esp_board_manager.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "../pixl_trip/include/pixl_trip/pt_adpcm.h"

static const char *TAG = "pixlz_mic";

enum { CLIP_MAX = APP_AUDIO_RATE * APP_AUDIO_MAX_SECONDS / 2, READ_SAMPLES = 512 };
#define CODEC_ADDR 0x32   /* ES8311 at 7-bit 0x19 (the library takes the 8-bit form) */

static struct {
    i2s_chan_handle_t rx;
    esp_codec_dev_handle_t dev;
    uint8_t *clip;
    size_t len;
    pt_adpcm_t adpcm;
    atomic_bool recording;
    atomic_int level;
    TaskHandle_t task;
    int16_t pcm[READ_SAMPLES];
    int din;               /* the data pin in use; 0 = not chosen yet */
    bool din_known;        /* it gave real sound before */
    uint8_t enc[READ_SAMPLES / 2];
} s;

static bool open_mic(int din);

static void close_mic(void)
{
    if (s.dev) {
        esp_codec_dev_delete(s.dev);
        s.dev = NULL;
    }
    if (s.rx) {
        i2s_del_channel(s.rx);
        s.rx = NULL;
    }
}

static bool open_mic(int din)
{
    i2c_master_bus_handle_t bus = NULL;
    if (esp_board_manager_get_periph_handle("i2c_master", (void **)&bus) != ESP_OK || !bus) {
        ESP_LOGE(TAG, "no I2C bus for the codec");
        return false;
    }
    i2s_chan_config_t chan = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_AUTO, I2S_ROLE_MASTER);
    if (i2s_new_channel(&chan, NULL, &s.rx) != ESP_OK) {
        ESP_LOGE(TAG, "no I2S channel");
        return false;
    }
    i2s_std_config_t std = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(APP_AUDIO_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO),
        .gpio_cfg = {.mclk = GPIO_NUM_54, .bclk = GPIO_NUM_37, .ws = GPIO_NUM_49, .dout = I2S_GPIO_UNUSED,
                     .din = (gpio_num_t)din},
    };
    std.clk_cfg.mclk_multiple = I2S_MCLK_MULTIPLE_256;
    s.din = din;
    if (i2s_channel_init_std_mode(s.rx, &std) != ESP_OK) {
        ESP_LOGE(TAG, "I2S RX setup failed (pins busy?)");
        i2s_del_channel(s.rx);
        s.rx = NULL;
        return false;
    }
    audio_codec_i2c_cfg_t i2c = {.addr = CODEC_ADDR, .bus_handle = bus};
    const audio_codec_ctrl_if_t *ctrl = audio_codec_new_i2c_ctrl(&i2c);
    audio_codec_i2s_cfg_t i2s = {.rx_handle = s.rx};
    const audio_codec_data_if_t *data = audio_codec_new_i2s_data(&i2s);
    es8311_codec_cfg_t es = {.ctrl_if = ctrl, .gpio_if = audio_codec_new_gpio()};
    es.pa_cfg.pa_pin = -1;   /* recording only: the speaker amplifier stays off */
    const audio_codec_if_t *codec = ctrl ? es8311_codec_new(&es) : NULL;
    esp_codec_dev_cfg_t dev = {.dev_type = ESP_CODEC_DEV_TYPE_IN, .codec_if = codec, .data_if = data};
    s.dev = codec && data ? esp_codec_dev_new(&dev) : NULL;
    if (!s.dev) {
        ESP_LOGE(TAG, "ES8311 didn't answer");
        i2s_del_channel(s.rx);
        s.rx = NULL;
        return false;
    }
    return true;
}

static void record_task(void *arg)
{
    (void)arg;
    int silent_reads = 0;
    while (atomic_load(&s.recording)) {
        if (esp_codec_dev_read(s.dev, s.pcm, sizeof s.pcm) != ESP_CODEC_DEV_OK) {
            vTaskDelay(pdMS_TO_TICKS(5));
            continue;
        }
        int peak = 0;
        for (int i = 0; i < READ_SAMPLES; i++) {
            int v = s.pcm[i] < 0 ? -s.pcm[i] : s.pcm[i];
            if (v > peak) peak = v;
        }
        /* A live microphone always has some noise. Exact zeros for ~0.3 s: wrong data pin. */
        if (!s.din_known) {
            if (peak > 0) {
                s.din_known = true;
                ESP_LOGI(TAG, "microphone data on GPIO%d", s.din);
            } else if (++silent_reads == 10) {
                const int other = s.din == 52 ? 40 : 52;
                ESP_LOGW(TAG, "GPIO%d gives only zeros; trying GPIO%d", s.din, other);
                esp_codec_dev_close(s.dev);
                close_mic();
                esp_codec_dev_sample_info_t fs = {.bits_per_sample = 16, .channel = 1, .sample_rate = APP_AUDIO_RATE};
                if (!open_mic(other) || esp_codec_dev_open(s.dev, &fs) != ESP_CODEC_DEV_OK) {
                    ESP_LOGE(TAG, "GPIO%d didn't open either", other);
                    atomic_store(&s.recording, false);
                    break;
                }
                (void)esp_codec_dev_set_in_gain(s.dev, 30.0f);
                s.len = 0;   /* drop the silence */
                pt_adpcm_init(&s.adpcm);
                continue;
            }
        }
        atomic_store(&s.level, peak * 100 / 32768);
        if (s.len + READ_SAMPLES / 2 > CLIP_MAX) {
            atomic_store(&s.recording, false);   /* 30 s: full */
            break;
        }
        s.len += pt_adpcm_encode(&s.adpcm, s.pcm, READ_SAMPLES, s.clip + s.len);
    }
    if (s.dev) {
        esp_codec_dev_close(s.dev);   /* powers the ADC down */
    }
    atomic_store(&s.level, 0);
    ESP_LOGI(TAG, "recorded %u bytes (%u ms)", (unsigned)s.len, (unsigned)(s.len * 2000 / APP_AUDIO_RATE));
    s.task = NULL;
    vTaskDelete(NULL);
}

bool app_audio_start(void)
{
    if (atomic_load(&s.recording) || s.task) {
        return false;
    }
    if (!s.clip) {
        s.clip = heap_caps_malloc(CLIP_MAX, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }
    if (!s.clip || (!s.dev && !open_mic(s.din ? s.din : 52))) {
        return false;
    }
    esp_codec_dev_sample_info_t fs = {.bits_per_sample = 16, .channel = 1, .sample_rate = APP_AUDIO_RATE};
    if (esp_codec_dev_open(s.dev, &fs) != ESP_CODEC_DEV_OK) {
        ESP_LOGE(TAG, "microphone didn't open");
        return false;
    }
    (void)esp_codec_dev_set_in_gain(s.dev, 30.0f);
    s.len = 0;
    pt_adpcm_init(&s.adpcm);
    atomic_store(&s.recording, true);
    if (xTaskCreate(record_task, "pixlz_mic", 4096, NULL, 5, &s.task) != pdPASS) {
        atomic_store(&s.recording, false);
        esp_codec_dev_close(s.dev);
        return false;
    }
    ESP_LOGI(TAG, "recording");
    return true;
}

void app_audio_stop(void)
{
    atomic_store(&s.recording, false);
}

bool app_audio_recording(void)
{
    return atomic_load(&s.recording) || s.task != NULL;
}

const uint8_t *app_audio_clip(size_t *len)
{
    *len = app_audio_recording() ? 0 : s.len;
    return s.clip;
}

int app_audio_level(void)
{
    return atomic_load(&s.level);
}
