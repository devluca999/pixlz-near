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
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "driver/i2c_master.h"
#include "esp_board_manager.h"
#include "esp_event.h"
#include "esp_iris.h"
#include "iris_ota_support.h"
#include "app_ble.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "mdns.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "private/app_dock_platform.h"

/* Our own label: the engine logs display statistics under the game id ("pixlz_dock") every
 * 10 s; those are turned down to warnings so pairing and trip events stay in the log ring. */
static const char *TAG = "pixlz";

#define SYSMETA_PARTITION "sysmeta"
#define SHARED_NAMESPACE "shared"
#define STORE_NAMESPACE "pixlz"
#define STORE_KEY "record"
#define BAD_KEY "record_bad"     /* an unreadable record, kept once for a look later */
#define RECORD_MAGIC_V1 0x50584C31u /* "PXL1": no holder id */
#define RECORD_MAGIC 0x50584C32u /* "PXL2" */
#define CLOCK_VALID_AFTER 1735689600 /* 2025-01-01: anything earlier means SNTP hasn't run */

/* PXL1, as older firmware saved it: still loaded, never written. */
typedef struct {
    uint32_t magic;
    uint32_t kind;
    int64_t epoch;
    char pet_id[PT_ID_MAX];
    char away_name[PT_NAME_MAX];
    uint32_t state_len;
} record_header_v1_t;

typedef struct {
    uint32_t magic;
    uint32_t kind;
    int64_t epoch;
    char pet_id[PT_ID_MAX];
    char away_id[PT_ID_MAX];
    char away_name[PT_NAME_MAX];
    uint32_t state_len;
} record_header_t;

typedef struct {
    record_header_t header;
    char state[PT_STATE_MAX];
} record_blob_t;

static atomic_bool s_net_ready;
static atomic_bool s_forget_requested;

/* Maintenance over USB (python mosaico.py iris rpc 0x5058 1): forget a record of a Pixl that
 * isn't here (an "away" record blocks hosting a different Pixl). Runs on the Iris task, so it
 * only raises a flag; the dock loop decides, and never drops a Pixl it holds. */
#define FORGET_SERVICE_ID 0x5058 /* "PX" */
#define FORGET_METHOD_ID 1

static esp_err_t forget_rpc(const esp_iris_rpc_request_t *request, uint8_t *response, size_t capacity,
                            size_t *response_size, void *ctx)
{
    (void)request;
    (void)ctx;
    atomic_store(&s_forget_requested, true);
    static const char reply[] = "queued";
    size_t n = sizeof reply - 1 < capacity ? sizeof reply - 1 : capacity;
    memcpy(response, reply, n);
    *response_size = n;
    return ESP_OK;
}
static bool s_started, s_store_ok, s_sntp_started, s_service_added;
static esp_netif_t *s_netif;
static i2c_master_dev_handle_t s_gauge;
static bool s_gauge_failed;
static int s_power_save = -1; /* last Wi-Fi power-save mode applied: -1 none yet */

/* BQ27220 fuel gauge on the board's shared I2C bus (the touch controller's bus). Read-only:
 * the standard commands Vibe Mode reads, never a control or configuration write, so the gauge
 * profile Vibe Mode maintains is left alone. */
#define GAUGE_ADDR 0x55
#define GAUGE_SPEED_HZ 400000
#define GAUGE_VOLTAGE 0x08
#define GAUGE_FLAGS 0x0a
#define GAUGE_SOC 0x2c
#define GAUGE_AVG_CURRENT 0x0c   /* signed mA: + charging, - discharging (standard read-only command) */
#define GAUGE_FLAG_DSG (1u << 0)     /* discharging */
#define GAUGE_FLAG_BATTPRES (1u << 3)
static pt_device_t s_me;
static record_blob_t s_blob;       /* single owner: the dock loop */
static wifi_config_t s_wifi_config; /* kept off the stack */

static void on_time_sync(struct timeval *tv)
{
    char date[25];
    pt_format_date((int64_t)tv->tv_sec * 1000 + tv->tv_usec / 1000, date);
    ESP_LOGI(TAG, "clock set from SNTP: %s", date);
}

/* mDNS starts before Wi-Fi connects: the component enables its responder on an interface when
 * that interface's IP event fires, so starting it later leaves it silent. */
static void mdns_start(void)
{
    esp_err_t err = mdns_init();
    if (err == ESP_OK) {
        char host[24];
        snprintf(host, sizeof host, "pixlz-%s", s_me.id + strlen(s_me.id) - 6);
        (void)mdns_hostname_set(host);
        ESP_LOGI(TAG, "mDNS host %s.local", host);
    } else if (err != ESP_ERR_INVALID_STATE) {
        ESP_LOGW(TAG, "mDNS init failed: %s", esp_err_to_name(err));
    }
}

/* Once we have an address: enable and announce on the Wi-Fi interface (harmless if the
 * component already did), and add the trip service once (SPEC §10.3). */
static void advertise(void)
{
    if (s_netif) {
        (void)mdns_netif_action(s_netif, MDNS_EVENT_ENABLE_IP4 | MDNS_EVENT_ANNOUNCE_IP4);
    }
    if (s_service_added) {
        return;
    }
    mdns_txt_item_t txt[] = {
        {"id", s_me.id}, {"name", s_me.name}, {"kind", "mosaico"}, {"proto", "2"},
    };
    esp_err_t err = mdns_service_add(s_me.name, "_pixlz", "_tcp", APP_DOCK_PORT, txt, sizeof txt / sizeof txt[0]);
    s_service_added = err == ESP_OK;
    ESP_LOGI(TAG, "mDNS _pixlz._tcp %s", s_service_added ? "advertised" : esp_err_to_name(err));
}

static atomic_int s_wifi_tries;
static esp_timer_handle_t s_retry_timer;

static void retry_wifi(void *arg)
{
    (void)arg;
    (void)esp_wifi_connect();
}

static void on_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        (void)esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        /* Retry with growing pauses: back-to-back attempts on a weak network hog the radio the
         * Bluetooth link shares (the coexistence policy favours a Wi-Fi reconnect). */
        static const uint32_t pause_s[] = {2, 5, 15, 30, 60};
        const wifi_event_sta_disconnected_t *d = data;
        const int k = atomic_load(&s_wifi_tries);
        const uint32_t wait = pause_s[k < 4 ? k : 4];
        atomic_store(&s_wifi_tries, k + 1);
        ESP_LOGW(TAG, "Wi-Fi lost (reason %d, rssi %d dBm); retrying in %u s", d ? d->reason : -1, d ? d->rssi : 0,
                 (unsigned)wait);
        atomic_store(&s_net_ready, false);
        if (s_retry_timer) {
            (void)esp_timer_stop(s_retry_timer);
            (void)esp_timer_start_once(s_retry_timer, (uint64_t)wait * 1000000ULL);
        } else {
            (void)esp_wifi_connect();
        }
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *ip = data;
        ESP_LOGI(TAG, "Wi-Fi ready: " IPSTR ", trips on port %d", IP2STR(&ip->ip_info.ip), APP_DOCK_PORT);
        if (!s_sntp_started) {
            esp_sntp_config_t config = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
            config.sync_cb = on_time_sync;
            s_sntp_started = esp_netif_sntp_init(&config) == ESP_OK;
            ESP_LOGI(TAG, "SNTP %s", s_sntp_started ? "started" : "failed to start");
        }
        advertise();
        atomic_store(&s_net_ready, true);
        atomic_store(&s_wifi_tries, 0);
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
    esp_log_level_set("pixlz_dock", ESP_LOG_WARN);
    esp_log_level_set("native_game", ESP_LOG_WARN);
    esp_log_level_set("video_present", ESP_LOG_WARN);
    esp_err_t rpc = esp_iris_rpc_register(FORGET_SERVICE_ID, FORGET_METHOD_ID, forget_rpc, NULL);
    if (rpc != ESP_OK) {
        ESP_LOGW(TAG, "maintenance RPC unavailable: %s", esp_err_to_name(rpc));
    }
    esp_err_t err = nvs_flash_init();
    s_store_ok = err == ESP_OK;
    if (!s_store_ok) {
        /* Never erase on our own: report and run without saving trips. */
        ESP_LOGE(TAG, "app NVS unavailable (%s); trips disabled", esp_err_to_name(err));
    }
    /* Bluetooth first: it carries trips and agents to the Mac even with no Wi-Fi at all (D21). */
    app_ble_start(me->id, me->name, APP_DOCK_PORT);
    memset(&s_wifi_config, 0, sizeof s_wifi_config);
    if (!read_credentials(&s_wifi_config)) {
        return;
    }
    s_wifi_config.sta.threshold.authmode = s_wifi_config.sta.password[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    if (tolerate(esp_netif_init()) != ESP_OK || tolerate(esp_event_loop_create_default()) != ESP_OK ||
            !(s_netif = esp_netif_create_default_wifi_sta())) {
        ESP_LOGE(TAG, "network interface setup failed");
        return;
    }
    const esp_timer_create_args_t retry = {.callback = retry_wifi, .name = "pixlz_wifi"};
    if (esp_timer_create(&retry, &s_retry_timer) != ESP_OK) {
        s_retry_timer = NULL;   /* then it retries at once, as before */
    }
    mdns_start();
    if (esp_wifi_init(&init) != ESP_OK ||
            esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_event, NULL) != ESP_OK ||
            esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_event, NULL) != ESP_OK ||
            esp_wifi_set_storage(WIFI_STORAGE_RAM) != ESP_OK || esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK ||
            esp_wifi_set_config(WIFI_IF_STA, &s_wifi_config) != ESP_OK || esp_wifi_start() != ESP_OK) {
        ESP_LOGE(TAG, "Wi-Fi start failed");
        return;
    }
    /* Plugged in (the spike has no battery rules yet, SPEC §12.1): no modem sleep, so a Mac's
     * connection and trip messages aren't delayed by power-save beacons. */
    (void)esp_wifi_set_ps(WIFI_PS_NONE);
}

void dock_platform_stop(void)
{
    /* Wi-Fi stays up: Iris shares the network interface. */
}

bool dock_platform_enter_vibe_mode(void)
{
    /* Schedule first (boot intent saved, restart in 500 ms), then go quiet on the network before
     * the restart: switching with mDNS and Wi-Fi still busy has tripped the interrupt watchdog. */
    esp_err_t err = iris_ota_support_enter_recovery();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "can't switch to Vibe Mode: %s", esp_err_to_name(err));
        return false;
    }
    ESP_LOGI(TAG, "leaving for Vibe Mode");
    atomic_store(&s_net_ready, false);
    if (s_started) {
        mdns_free();
        (void)esp_wifi_disconnect();
        (void)esp_wifi_stop();
    }
    return true;
}

bool dock_platform_net_ready(void)
{
    return atomic_load(&s_net_ready);
}

bool dock_platform_clock_ok(void)
{
    return s_store_ok && time(NULL) > CLOCK_VALID_AFTER;
}

void dock_platform_offer_clock(int64_t unix_ms)
{
    if (time(NULL) > CLOCK_VALID_AFTER || unix_ms / 1000 <= CLOCK_VALID_AFTER) {
        return; /* SNTP (or an earlier Mac) already set it, or the offer is nonsense */
    }
    struct timeval tv = {.tv_sec = (time_t)(unix_ms / 1000), .tv_usec = (suseconds_t)(unix_ms % 1000) * 1000};
    if (settimeofday(&tv, NULL) == 0) {
        char date[25];
        pt_format_date(unix_ms, date);
        ESP_LOGI(TAG, "clock set from the Mac's hello: %s (SNTP will refine it)", date);
    }
}

int64_t dock_platform_uptime_ms(void)
{
    return esp_timer_get_time() / 1000;
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

/* An unreadable record: copy it to BAD_KEY once, so nothing is lost when it's forgotten. */
static void keep_bad_blob(void)
{
    nvs_handle_t h;
    if (!s_store_ok || nvs_open(STORE_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) {
        return;
    }
    size_t size = 0;
    if (nvs_get_blob(h, BAD_KEY, NULL, &size) == ESP_OK) {
        nvs_close(h);
        return;   /* kept already */
    }
    size = 0;
    if (nvs_get_blob(h, STORE_KEY, NULL, &size) == ESP_OK && size > 0) {
        void *buf = malloc(size);
        bool ok = buf && nvs_get_blob(h, STORE_KEY, buf, &size) == ESP_OK &&
                  nvs_set_blob(h, BAD_KEY, buf, size) == ESP_OK && nvs_commit(h) == ESP_OK;
        free(buf);
        ESP_LOGW(TAG, "saved Pixl unreadable (%u bytes); %s", (unsigned)size, ok ? "copied to " BAD_KEY : "copy failed");
    }
    nvs_close(h);
}

dock_load_t dock_platform_load(pt_record_t *r)
{
    nvs_handle_t h;
    if (nvs_flash_init() != ESP_OK || nvs_open(STORE_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return DOCK_LOAD_NONE;   /* no namespace yet: nothing was ever saved */
    }
    size_t len = sizeof s_blob;
    esp_err_t err = nvs_get_blob(h, STORE_KEY, &s_blob, &len);
    nvs_close(h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return DOCK_LOAD_NONE;
    }
    static record_header_t hd;      /* single owner (the dock loop); kept off the stack */
    static record_header_v1_t v1;
    const char *state = NULL;
    memset(&hd, 0, sizeof hd);
    if (err == ESP_OK && len >= sizeof(record_header_v1_t) && s_blob.header.magic == RECORD_MAGIC_V1) {
        memcpy(&v1, &s_blob, sizeof v1);
        hd.magic = v1.magic;
        hd.kind = v1.kind;
        hd.epoch = v1.epoch;
        memcpy(hd.pet_id, v1.pet_id, sizeof hd.pet_id);
        memcpy(hd.away_name, v1.away_name, sizeof hd.away_name);
        hd.state_len = v1.state_len;
        state = (const char *)&s_blob + sizeof v1;
        if (len != sizeof v1 + hd.state_len) {
            state = NULL;
        }
    } else if (err == ESP_OK && len >= sizeof hd && s_blob.header.magic == RECORD_MAGIC) {
        hd = s_blob.header;
        state = len == sizeof hd + hd.state_len ? s_blob.state : NULL;
    }
    if (!state || hd.state_len > PT_STATE_MAX || hd.kind > PT_REC_AWAY) {
        keep_bad_blob();
        return DOCK_LOAD_BAD;
    }
    r->kind = (pt_rec_kind_t)hd.kind;
    r->epoch = hd.epoch;
    memcpy(r->pet_id, hd.pet_id, sizeof r->pet_id);
    memcpy(r->away_id, hd.away_id, sizeof r->away_id);
    memcpy(r->away_name, hd.away_name, sizeof r->away_name);
    r->pet_id[PT_ID_MAX - 1] = r->away_id[PT_ID_MAX - 1] = r->away_name[PT_NAME_MAX - 1] = 0;
    memcpy(r->state, state, hd.state_len);
    r->state_len = hd.state_len;
    return DOCK_LOAD_OK;
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
    memcpy(hd->away_id, r->away_id, sizeof hd->away_id);
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

static bool gauge_word(uint8_t command, uint16_t *out)
{
    uint8_t bytes[2];
    if (i2c_master_transmit_receive(s_gauge, &command, 1, bytes, 2, 100) != ESP_OK) {
        return false;
    }
    *out = (uint16_t)bytes[0] | (uint16_t)bytes[1] << 8;
    return true;
}

/* A single-cell lithium battery's rough charge from its voltage (resting-ish; under load it
 * reads a little low, which errs on the side of warning). */
static int percent_from_mv(unsigned mv)
{
    static const uint16_t mv_at[] = {3400, 3500, 3600, 3700, 3750, 3800, 3850, 3900, 4000, 4100, 4200};
    static const uint8_t pct_at[] = {0, 5, 12, 25, 35, 45, 55, 65, 80, 92, 100};
    if (mv <= mv_at[0]) return 0;
    for (int i = 1; i < (int)(sizeof mv_at / sizeof mv_at[0]); i++) {
        if (mv <= mv_at[i]) {
            return pct_at[i - 1] + (int)((mv - mv_at[i - 1]) * (unsigned)(pct_at[i] - pct_at[i - 1]) / (mv_at[i] - mv_at[i - 1]));
        }
    }
    return 100;
}

bool dock_platform_battery(int *percent, bool *on_battery)
{
    if (!s_gauge && !s_gauge_failed) {
        i2c_master_bus_handle_t bus = NULL;
        const i2c_device_config_t config = {
            .dev_addr_length = I2C_ADDR_BIT_LEN_7,
            .device_address = GAUGE_ADDR,
            .scl_speed_hz = GAUGE_SPEED_HZ,
        };
        if (esp_board_manager_get_periph_handle("i2c_master", (void **)&bus) != ESP_OK || !bus ||
                i2c_master_bus_add_device(bus, &config, &s_gauge) != ESP_OK) {
            s_gauge_failed = true;
            ESP_LOGW(TAG, "battery gauge unavailable; no low-battery warning");
            return false;
        }
    }
    if (!s_gauge) {
        return false;
    }
    uint16_t mv = 0, flags = 0, soc = 0;
    if (!gauge_word(GAUGE_VOLTAGE, &mv) || !gauge_word(GAUGE_FLAGS, &flags) || !gauge_word(GAUGE_SOC, &soc) ||
            !(flags & GAUGE_FLAG_BATTPRES) || mv == 0 || soc > 100) {
        return false;
    }
    *on_battery = (flags & GAUGE_FLAG_DSG) != 0;
    /* The gauge's own percentage drifts when it loses its learned capacity (it said 10% at
     * 4.18 V while topping off). Check it against the voltage; far apart, trust the voltage. */
    const int by_volts = percent_from_mv(mv);
    const bool gauge_off = soc + 30 < by_volts || soc > by_volts + 30;
    *percent = gauge_off ? by_volts : soc;
    /* Once a minute: what it's doing with power, for diagnosing drain (read-only). */
    static int64_t next_log_us;
    const int64_t now_us = esp_timer_get_time();
    if (now_us >= next_log_us) {
        next_log_us = now_us + 60LL * 1000000;
        uint16_t raw = 0;
        const int ma = gauge_word(GAUGE_AVG_CURRENT, &raw) ? (int)(int16_t)raw : 0;
        ESP_LOGI(TAG, "battery %u%% (gauge) / ~%d%% (voltage)%s, %u mV, %d mA (%s), flags 0x%04x", (unsigned)soc,
                 by_volts, gauge_off ? " -> using voltage" : "", (unsigned)mv, ma,
                 ma > 0 ? "charging" : ma < 0 ? "draining" : "idle", (unsigned)flags);
    }
    /* Unplugged: let Wi-Fi sleep between beacons (trips get slower, the battery lasts).
     * Plugged in: no power save, so trips stay snappy on a weak signal. */
    int mode = *on_battery ? WIFI_PS_MIN_MODEM : WIFI_PS_NONE;
    if (mode != s_power_save && esp_wifi_set_ps((wifi_ps_type_t)mode) == ESP_OK) {
        s_power_save = mode;
        ESP_LOGI(TAG, "%s (%d%%, %u mV): Wi-Fi power save %s", *on_battery ? "on battery" : "plugged in",
                 *percent, mv, *on_battery ? "on" : "off");
    }
    return true;
}

#define LOOK_KEY "look"

#define PAIR_KEY "pair"
#define PAIR_MAGIC 0x50584C50u /* "PXLP" */
typedef struct {
    uint32_t magic;
    pt_pair_record_t rec;
} pair_blob_t;
static pair_blob_t s_pair_blob;

bool dock_platform_load_pair(pt_pair_record_t *rec)
{
    nvs_handle_t h;
    if (nvs_open(STORE_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return false;
    }
    size_t len = sizeof s_pair_blob;
    esp_err_t err = nvs_get_blob(h, PAIR_KEY, &s_pair_blob, &len);
    nvs_close(h);
    if (err != ESP_OK || len != sizeof s_pair_blob || s_pair_blob.magic != PAIR_MAGIC || !s_pair_blob.rec.paired) {
        return false;
    }
    *rec = s_pair_blob.rec;
    rec->mac_id[PT_ID_MAX - 1] = rec->mac_name[PT_NAME_MAX - 1] = 0;
    return true;
}

bool dock_platform_save_pair(const pt_pair_record_t *rec)
{
    if (!s_store_ok) {
        return false;
    }
    nvs_handle_t h;
    if (nvs_open(STORE_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) {
        return false;
    }
    bool ok;
    if (rec->paired) {
        s_pair_blob.magic = PAIR_MAGIC;
        s_pair_blob.rec = *rec;
        ok = nvs_set_blob(h, PAIR_KEY, &s_pair_blob, sizeof s_pair_blob) == ESP_OK;
        memset(&s_pair_blob, 0, sizeof s_pair_blob);
    } else {
        esp_err_t err = nvs_erase_key(h, PAIR_KEY);
        ok = err == ESP_OK || err == ESP_ERR_NVS_NOT_FOUND;
    }
    ok = ok && nvs_commit(h) == ESP_OK;
    nvs_close(h);
    return ok;
}

void dock_platform_load_look(char *out, size_t cap)
{
    nvs_handle_t h;
    if (nvs_open(STORE_NAMESPACE, NVS_READONLY, &h) != ESP_OK) {
        return;
    }
    size_t len = cap;
    if (nvs_get_str(h, LOOK_KEY, out, &len) != ESP_OK) {
        out[0] = 0;
    }
    nvs_close(h);
}

bool dock_platform_save_look(const char *id)
{
    nvs_handle_t h;
    if (!s_store_ok || nvs_open(STORE_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) {
        return false;
    }
    bool ok = nvs_set_str(h, LOOK_KEY, id) == ESP_OK && nvs_commit(h) == ESP_OK;
    nvs_close(h);
    return ok;
}

bool dock_platform_take_forget_request(void)
{
    return atomic_exchange(&s_forget_requested, false);
}

void dock_platform_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    esp_log_writev(ESP_LOG_INFO, TAG, fmt, ap);
    va_end(ap);
    esp_log_write(ESP_LOG_INFO, TAG, "\n");
}
