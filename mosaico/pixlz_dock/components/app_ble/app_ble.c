// SPDX-License-Identifier: Apache-2.0
#include "app_ble.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "lwip/sockets.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "pixlz_ble";

/* 6E1B000x-8F3C-4C6A-9B1E-70697868C0DE, little-endian as NimBLE wants it. */
#define PIXLZ_UUID(x) BLE_UUID128_INIT(0xDE, 0xC0, 0x68, 0x78, 0x69, 0x70, 0x1E, 0x9B, 0x6A, 0x4C, 0x3C, 0x8F, x, 0x00, 0x1B, 0x6E)
static const ble_uuid128_t s_svc = PIXLZ_UUID(0x01), s_rx = PIXLZ_UUID(0x02), s_tx = PIXLZ_UUID(0x03),
                           s_info_uuid = PIXLZ_UUID(0x04);

enum { RING = 8192, CHUNK_MAX = 512 };

static struct {
    char id[64], name[96], info[200], adv_name[16];
    uint16_t port;
    uint16_t conn;          /* BLE_HS_CONN_HANDLE_NONE when nobody is connected */
    bool subscribed;
    uint16_t tx_handle;
    uint8_t own_addr_type;
    int sock;               /* the loopback connection to the dock, or -1 */
    SemaphoreHandle_t lock;
    uint8_t *in;            /* bytes from the Mac, waiting for the socket */
    size_t in_len;
    uint8_t out[CHUNK_MAX]; /* one chunk read from the socket, not yet notified */
    size_t out_len;
    TickType_t last_rx;     /* when the Mac last wrote (it pings every 15 s) */
} s;

static void advertise(void);

static int on_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn;
    (void)attr;
    if (arg == &s_info_uuid && ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        return os_mbuf_append(ctxt->om, s.info, strlen(s.info)) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (arg == &s_rx && ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint16_t n = OS_MBUF_PKTLEN(ctxt->om);
        xSemaphoreTake(s.lock, portMAX_DELAY);
        int rc = 0;
        if (s.in_len + n > RING) {
            rc = BLE_ATT_ERR_PREPARE_QUEUE_FULL;   /* the Mac retries; the dock is behind */
        } else {
            uint16_t got = 0;
            ble_hs_mbuf_to_flat(ctxt->om, s.in + s.in_len, n, &got);
            s.in_len += got;
            s.last_rx = xTaskGetTickCount();
        }
        xSemaphoreGive(s.lock);
        return rc;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {.uuid = &s_rx.u, .access_cb = on_access, .arg = (void *)&s_rx,
             .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP},
            {.uuid = &s_tx.u, .access_cb = on_access, .arg = (void *)&s_tx, .flags = BLE_GATT_CHR_F_NOTIFY,
             .val_handle = &s.tx_handle},
            {.uuid = &s_info_uuid.u, .access_cb = on_access, .arg = (void *)&s_info_uuid, .flags = BLE_GATT_CHR_F_READ},
            {0},
        },
    },
    {0},
};

static void close_sock(void)
{
    if (s.sock >= 0) {
        close(s.sock);
        s.sock = -1;
    }
    xSemaphoreTake(s.lock, portMAX_DELAY);
    s.in_len = 0;
    s.out_len = 0;
    xSemaphoreGive(s.lock);
}

static int on_gap(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s.conn = event->connect.conn_handle;
            s.last_rx = xTaskGetTickCount();
            s.subscribed = false;
            ESP_LOGI(TAG, "a Mac connected over Bluetooth");
        } else {
            advertise();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "Bluetooth link closed (reason %d)", event->disconnect.reason);
        s.conn = BLE_HS_CONN_HANDLE_NONE;
        s.subscribed = false;
        advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s.tx_handle) {
            s.subscribed = event->subscribe.cur_notify;
        }
        break;
    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "Bluetooth MTU %d", event->mtu.value);
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;
    default:
        break;
    }
    return 0;
}

static void advertise(void)
{
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128 = (ble_uuid128_t *)&s_svc;
    fields.num_uuids128 = 1;
    fields.uuids128_is_complete = 1;
    if (ble_gap_adv_set_fields(&fields) != 0) {
        return;
    }
    struct ble_hs_adv_fields rsp = {0};
    rsp.name = (uint8_t *)s.adv_name;
    rsp.name_len = strlen(s.adv_name);
    rsp.name_is_complete = 1;
    (void)ble_gap_adv_rsp_set_fields(&rsp);
    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = BLE_GAP_ADV_ITVL_MS(200);   /* slow and cheap: a Mac reconnects within a second or two */
    params.itvl_max = BLE_GAP_ADV_ITVL_MS(300);
    int rc = ble_gap_adv_start(s.own_addr_type, NULL, BLE_HS_FOREVER, &params, on_gap, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGW(TAG, "advertising failed: %d", rc);
    }
}

static void on_sync(void)
{
    if (ble_hs_util_ensure_addr(0) != 0 || ble_hs_id_infer_auto(0, &s.own_addr_type) != 0) {
        ESP_LOGE(TAG, "no Bluetooth address");
        return;
    }
    advertise();
    ESP_LOGI(TAG, "advertising as %s", s.adv_name);
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

/* Moves bytes between the Bluetooth link and the dock's port, every few milliseconds. */
static void bridge_task(void *param)
{
    (void)param;
    for (;;) {
        const bool linked = s.conn != BLE_HS_CONN_HANDLE_NONE && s.subscribed;
        if (!linked) {
            if (s.sock >= 0) {
                close_sock();
            }
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }
        /* A Mac that's said nothing for 60 s is gone (it pings every 15 s): drop the link so it
         * can reconnect cleanly, instead of both sides holding a dead one. */
        if (xTaskGetTickCount() - s.last_rx > pdMS_TO_TICKS(60000)) {
            ESP_LOGW(TAG, "no word from the Mac for 60 s; dropping the Bluetooth link");
            s.last_rx = xTaskGetTickCount();
            (void)ble_gap_terminate(s.conn, BLE_ERR_REM_USER_CONN_TERM);
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        if (s.sock < 0) {
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(s.port)};
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
                fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
                s.sock = fd;
                ESP_LOGI(TAG, "bridging Bluetooth to port %d", s.port);
            } else {
                if (fd >= 0) close(fd);
                vTaskDelay(pdMS_TO_TICKS(200));
                continue;
            }
        }
        /* Mac → dock */
        xSemaphoreTake(s.lock, portMAX_DELAY);
        if (s.in_len) {
            int n = send(s.sock, s.in, s.in_len, 0);
            if (n > 0) {
                memmove(s.in, s.in + n, s.in_len - (size_t)n);
                s.in_len -= (size_t)n;
            }
        }
        xSemaphoreGive(s.lock);
        /* dock → Mac, one chunk at a time; a full controller queue is retried */
        if (!s.out_len) {
            const uint16_t mtu = ble_att_mtu(s.conn);
            size_t room = mtu > 3 ? (size_t)(mtu - 3) : 20;
            if (room > CHUNK_MAX) room = CHUNK_MAX;
            int n = recv(s.sock, s.out, room, 0);
            if (n > 0) {
                s.out_len = (size_t)n;
            } else if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
                ESP_LOGW(TAG, "the dock closed the bridge");
                close_sock();
                continue;
            }
        }
        if (s.out_len) {
            struct os_mbuf *om = ble_hs_mbuf_from_flat(s.out, s.out_len);
            if (om && ble_gatts_notify_custom(s.conn, s.tx_handle, om) == 0) {
                s.out_len = 0;
                continue;   /* more may be waiting: no sleep */
            }
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}

void app_ble_start(const char *device_id, const char *device_name, uint16_t port)
{
    snprintf(s.id, sizeof s.id, "%s", device_id);
    snprintf(s.name, sizeof s.name, "%s", device_name);
    snprintf(s.info, sizeof s.info, "{\"id\":\"%.63s\",\"name\":\"%.95s\"}", s.id, s.name);
    snprintf(s.adv_name, sizeof s.adv_name, "Pixlz %.4s", strlen(s.id) > 4 ? s.id + strlen(s.id) - 4 : s.id);
    s.port = port;
    s.conn = BLE_HS_CONN_HANDLE_NONE;
    s.sock = -1;
    s.lock = xSemaphoreCreateMutex();
    s.in = heap_caps_malloc(RING, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!s.lock || !s.in) {
        ESP_LOGE(TAG, "no memory for the Bluetooth bridge");
        return;
    }
    if (nimble_port_init() != ESP_OK) {
        ESP_LOGE(TAG, "Bluetooth didn't start");
        return;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    if (ble_gatts_count_cfg(s_services) != 0 || ble_gatts_add_svcs(s_services) != 0) {
        ESP_LOGE(TAG, "GATT service failed");
        return;
    }
    (void)ble_svc_gap_device_name_set(s.adv_name);
    (void)ble_att_set_preferred_mtu(517);
    nimble_port_freertos_init(host_task);
    xTaskCreate(bridge_task, "pixlz_ble", 4096, NULL, 4, NULL);
}
