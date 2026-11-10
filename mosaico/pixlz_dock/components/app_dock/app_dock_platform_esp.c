// SPDX-License-Identifier: Apache-2.0
// Device platform: Wi-Fi (credentials from the shared sysmeta store, Kconfig fallback), mDNS
// `_pixlz._tcp` with TXT kind=mosaico, SNTP for the wall clock, and the record as one NVS blob
// in the application's own `nvs` partition. Never writes to sysmeta.
//
// Ownership: the dock's owner loop calls everything here, except the Wi-Fi/IP event handlers,
// which run on the default event task and only touch the atomics and mDNS.
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_random.h"
#include "esp_wifi.h"
#include "mdns.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "private/app_dock_platform.h"

static const char *TAG = "pixlz_dock";

#define SYSMETA_PARTITION "sysmeta"
#define SHARED_NAMESPACE "shared"
#define STORE_NAMESPACE "pixlz"
#define STORE_KEY "record"
#define RECORD_MAGIC 0x50584C31u /* "PXL1" */
#define CLOCK_VALID_AFTER 1735689600 /* 2025-01-01: anything earlier means SNTP hasn't run */

typedef struct {
    uint32_t magic;
    uint32_t kind;
    int64_t epoch;
    char pet_id[PT_ID_MAX];
    char away_name[PT_NAME_MAX];
    uint32_t state_len;
} record_header_t;

typedef struct {
    record_header_t header;
    char state[PT_STATE_MAX];
} record_blob_t;

static atomic_bool s_net_ready;
static bool s_started, s_store_ok, s_sntp_started, s_mdns_ours;
static pt_device_t s_me;
static record_blob_t s_blob;       /* single owner: the dock loop */
static wifi_config_t s_wifi_config; /* kept off the stack */

static void advertise(void)
{
    esp_err_t err = mdns_init();
    if (err == ESP_OK) {
        s_mdns_ours = true;
        char host[24];
        snprintf(host, sizeof host, "pixlz-%s", s_me.id + strlen(s_me.id) - 6);
        (void)mdns_hostname_set(host);
    } else if (err != ESP_ERR_INVALID_STATE) {
        ESP_LOGW(TAG, "mDNS init failed: %s", esp_err_to_name(err));
        return;
    }
    mdns_txt_item_t txt[] = {
        {"id", s_me.id}, {"name", s_me.name}, {"kind", "mosaico"}, {"proto", "2"},
    };
    err = mdns_service_add(s_me.name, "_pixlz", "_tcp", APP_DOCK_PORT, txt, sizeof txt / sizeof txt[0]);
    if (err != ESP_OK && err != ESP_ERR_INVALID_ARG) {
        ESP_LOGW(TAG, "mDNS service failed: %s", esp_err_to_name(err));
    }
}

static void on_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        (void)esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        atomic_store(&s_net_ready, false);
        (void)esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *ip = data;
        ESP_LOGI(TAG, "Wi-Fi ready: " IPSTR ", trips on port %d", IP2STR(&ip->ip_info.ip), APP_DOCK_PORT);
        if (!s_sntp_started) {
            esp_sntp_config_t config = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
            s_sntp_started = esp_netif_sntp_init(&config) == ESP_OK;
        }
        advertise();
        atomic_store(&s_net_ready, true);
    }
}

/* Credentials from the Mosaico's own setup (read-only), else Kconfig. */
static bool read_credentials(wifi_config_t *config)
{
    nvs_handle_t h;
    size_t ssid_len = sizeof config->sta.ssid, pass_len = sizeof config->sta.password;
    bool ok = false;
    if (nvs_flash_init_partition(SYSMETA_PARTITION) == ESP_OK &&
            nvs_open_from_partition(SYSMETA_PARTITION, SHARED_NAMESPACE, NVS_READONLY, &h) == ESP_OK) {
        ok = nvs_get_str(h, "wifi_ssid", (char *)config->sta.ssid, &ssid_len) == ESP_OK && config->sta.ssid[0];
        if (ok && nvs_get_str(h, "wifi_password", (char *)config->sta.password, &pass_len) != ESP_OK) {
            config->sta.password[0] = 0;
        }
        nvs_close(h);
    }
    if (ok) {
        ESP_LOGI(TAG, "using the Mosaico's saved Wi-Fi");
        return true;
    }
    if (CONFIG_PIXLZ_WIFI_SSID[0]) {
        strlcpy((char *)config->sta.ssid, CONFIG_PIXLZ_WIFI_SSID, sizeof config->sta.ssid);
        strlcpy((char *)config->sta.password, CONFIG_PIXLZ_WIFI_PASSWORD, sizeof config->sta.password);
        ESP_LOGI(TAG, "using Wi-Fi from Kconfig");
        return true;
    }
    ESP_LOGE(TAG, "no Wi-Fi credentials (set them in the Mosaico's settings or CONFIG_PIXLZ_WIFI_SSID)");
    return false;
}

static esp_err_t tolerate(esp_err_t err)
{
    return err == ESP_ERR_INVALID_STATE ? ESP_OK : err; /* already set up by someone else */
}

void dock_platform_start(const pt_device_t *me)
{
    if (s_started) {
        return;
    }
    s_started = true;
    s_me = *me;
    esp_err_t err = nvs_flash_init();
    s_store_ok = err == ESP_OK;
    if (!s_store_ok) {
        /* Never erase on our own: report and run without saving trips. */
        ESP_LOGE(TAG, "app NVS unavailable (%s); trips disabled", esp_err_to_name(err));
    }
    memset(&s_wifi_config, 0, sizeof s_wifi_config);
    if (!read_credentials(&s_wifi_config)) {
        return;
    }
    s_wifi_config.sta.threshold.authmode = s_wifi_config.sta.password[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (tolerate(esp_netif_init()) != ESP_OK || tolerate(esp_event_loop_create_default()) != ESP_OK ||
            !esp_netif_create_default_wifi_sta() || esp_wifi_init(&init) != ESP_OK ||
            esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL) != ESP_OK ||
            esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL) != ESP_OK ||
            esp_wifi_set_storage(WIFI_STORAGE_RAM) != ESP_OK || esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK ||
            esp_wifi_set_config(WIFI_IF_STA, &s_wifi_config) != ESP_OK || esp_wifi_start() != ESP_OK) {
        ESP_LOGE(TAG, "Wi-Fi start failed");
    }
}

void dock_platform_stop(void)
{
    /* Wi-Fi stays up: Iris shares the network interface. */
}

bool dock_platform_net_ready(void)
{
    return atomic_load(&s_net_ready);
}

bool dock_platform_clock_ok(void)
{
    return s_store_ok && time(NULL) > CLOCK_VALID_AFTER;
}

int64_t dock_platform_now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

void dock_platform_random(void *ctx, uint8_t *out, size_t n)
{
    (void)ctx;
    esp_fill_random(out, n);
}

void dock_platform_device(pt_device_t *me)
{
    uint8_t mac[6] = {0};
    (void)esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(me->id, sizeof me->id, "MOSAICO-%02X%02X%02X", mac[3], mac[4], mac[5]);
    snprintf(me->name, sizeof me->name, "Mosaico %02X%02X", mac[4], mac[5]);
}

bool dock_platform_load(pt_record_t *r)
{
    nvs_handle_t h;
    if (nvs_flash_init() != ESP_OK || nvs_open(STORE_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return false;
    }
    size_t len = sizeof s_blob;
    esp_err_t err = nvs_get_blob(h, STORE_KEY, &s_blob, &len);
    nvs_close(h);
    const record_header_t *hd = &s_blob.header;
    if (err != ESP_OK || len < sizeof *hd || hd->magic != RECORD_MAGIC || hd->state_len > PT_STATE_MAX ||
            len != sizeof *hd + hd->state_len || hd->kind > PT_REC_AWAY) {
        return false;
    }
    r->kind = (pt_rec_kind_t)hd->kind;
    r->epoch = hd->epoch;
    memcpy(r->pet_id, hd->pet_id, sizeof r->pet_id);
    memcpy(r->away_name, hd->away_name, sizeof r->away_name);
    r->pet_id[PT_ID_MAX - 1] = r->away_name[PT_NAME_MAX - 1] = 0;
    memcpy(r->state, s_blob.state, hd->state_len);
    r->state_len = hd->state_len;
    return true;
}

bool dock_platform_save(const pt_record_t *r)
{
    if (!s_store_ok) {
        return false;
    }
    record_header_t *hd = &s_blob.header;
    memset(hd, 0, sizeof *hd);
    hd->magic = RECORD_MAGIC;
    hd->kind = (uint32_t)r->kind;
    hd->epoch = r->epoch;
    memcpy(hd->pet_id, r->pet_id, sizeof hd->pet_id);
    memcpy(hd->away_name, r->away_name, sizeof hd->away_name);
    hd->state_len = (uint32_t)r->state_len;
    memcpy(s_blob.state, r->state, r->state_len);
    nvs_handle_t h;
    if (nvs_open(STORE_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) {
        return false;
    }
    /* One blob, one commit: NVS writes the new entry before dropping the old one. */
    bool ok = nvs_set_blob(h, STORE_KEY, &s_blob, sizeof *hd + r->state_len) == ESP_OK && nvs_commit(h) == ESP_OK;
    nvs_close(h);
    return ok;
}

void dock_platform_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    esp_log_writev(ESP_LOG_INFO, TAG, fmt, ap);
    va_end(ap);
    esp_log_write(ESP_LOG_INFO, TAG, "\n");
}
