// SPDX-License-Identifier: Apache-2.0
// Simulator platform: always on the network, the Mac's clock, and the record in a file
// written atomically (temp file, then rename). Never built for the device.
#define _DARWIN_C_SOURCE 1
#define _DEFAULT_SOURCE 1
#include <stdarg.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include "private/app_dock_platform.h"

enum { RECORD_MAGIC = 0x50584C31 }; /* "PXL1" */

typedef struct {
    uint32_t magic;
    uint32_t kind;
    int64_t epoch;
    char pet_id[PT_ID_MAX];
    char away_name[PT_NAME_MAX];
    uint32_t state_len;
} record_header_t;

static void record_path(char *out, size_t cap)
{
    const char *env = getenv("PIXLZ_DOCK_STATE");
    if (env && *env) {
        snprintf(out, cap, "%s", env);
        return;
    }
    const char *home = getenv("HOME");
    char dir[512];
    snprintf(dir, sizeof dir, "%s/Library/Application Support/PixlzDockSim", home ? home : ".");
    mkdir(dir, 0755);
    snprintf(out, cap, "%s/record.bin", dir);
}

void dock_platform_start(const pt_device_t *me)
{
    (void)me;
}

void dock_platform_stop(void) {}

bool dock_platform_enter_vibe_mode(void)
{
    dock_platform_log("pixlz: would restart into Vibe Mode (simulator: nothing happens)");
    return true;
}

bool dock_platform_net_ready(void)
{
    return true;
}

bool dock_platform_clock_ok(void)
{
    return true;
}

void dock_platform_offer_clock(int64_t unix_ms)
{
    (void)unix_ms; /* the Mac's own clock */
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
    arc4random_buf(out, n);
}

void dock_platform_device(pt_device_t *me)
{
    const char *id = getenv("PIXL_DEVICE_ID");
    const char *name = getenv("PIXL_DEVICE_NAME");
    snprintf(me->id, sizeof me->id, "%s", id && *id ? id : "MOSAICO-SIM");
    snprintf(me->name, sizeof me->name, "%s", name && *name ? name : "Mosaico (sim)");
}

bool dock_platform_load(pt_record_t *r)
{
    char path[600];
    record_path(path, sizeof path);
    FILE *f = fopen(path, "rb");
    if (!f) {
        return false;
    }
    record_header_t h;
    bool ok = fread(&h, sizeof h, 1, f) == 1 && h.magic == RECORD_MAGIC && h.state_len <= PT_STATE_MAX &&
              h.kind <= PT_REC_AWAY && fread(r->state, 1, h.state_len, f) == h.state_len;
    fclose(f);
    if (!ok) {
        return false;
    }
    r->kind = (pt_rec_kind_t)h.kind;
    r->epoch = h.epoch;
    memcpy(r->pet_id, h.pet_id, sizeof r->pet_id);
    memcpy(r->away_name, h.away_name, sizeof r->away_name);
    r->pet_id[PT_ID_MAX - 1] = r->away_name[PT_NAME_MAX - 1] = 0;
    r->state_len = h.state_len;
    return true;
}

bool dock_platform_save(const pt_record_t *r)
{
    char path[600], tmp[640];
    record_path(path, sizeof path);
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    record_header_t h;
    memset(&h, 0, sizeof h);
    h.magic = RECORD_MAGIC;
    h.kind = (uint32_t)r->kind;
    h.epoch = r->epoch;
    memcpy(h.pet_id, r->pet_id, sizeof h.pet_id);
    memcpy(h.away_name, r->away_name, sizeof h.away_name);
    h.state_len = (uint32_t)r->state_len;
    FILE *f = fopen(tmp, "wb");
    if (!f) {
        return false;
    }
    bool ok = fwrite(&h, sizeof h, 1, f) == 1 && fwrite(r->state, 1, r->state_len, f) == r->state_len &&
              fflush(f) == 0 && fsync(fileno(f)) == 0;
    ok = fclose(f) == 0 && ok;
    return ok && rename(tmp, path) == 0;
}

bool dock_platform_battery(int *percent, bool *on_battery)
{
    /* PIXLZ_SIM_BATTERY="18" simulates 18% on battery; unset = plugged in, unknown. */
    const char *env = getenv("PIXLZ_SIM_BATTERY");
    if (!env || !*env) {
        return false;
    }
    *percent = atoi(env);
    *on_battery = true;
    return true;
}

bool dock_platform_load_pair(pt_pair_record_t *rec)
{
    char path[620];
    record_path(path, sizeof path - 6);
    strcat(path, ".pair");
    FILE *f = fopen(path, "rb");
    if (!f) {
        return false;
    }
    bool ok = fread(rec, sizeof *rec, 1, f) == 1 && rec->paired;
    fclose(f);
    return ok;
}

bool dock_platform_save_pair(const pt_pair_record_t *rec)
{
    char path[620];
    record_path(path, sizeof path - 6);
    strcat(path, ".pair");
    if (!rec->paired) {
        return remove(path) == 0 || errno == ENOENT;
    }
    FILE *f = fopen(path, "wb");
    if (!f) {
        return false;
    }
    bool ok = fwrite(rec, sizeof *rec, 1, f) == 1;
    return fclose(f) == 0 && ok;
}

void dock_platform_load_look(char *out, size_t cap)
{
    char path[620];
    record_path(path, sizeof path - 6);
    strcat(path, ".look");
    FILE *f = fopen(path, "r");
    if (!f) {
        return;
    }
    if (!fgets(out, (int)cap, f)) {
        out[0] = 0;
    }
    out[strcspn(out, "\r\n")] = 0;
    fclose(f);
}

bool dock_platform_save_look(const char *id)
{
    char path[620];
    record_path(path, sizeof path - 6);
    strcat(path, ".look");
    FILE *f = fopen(path, "w");
    if (!f) {
        return false;
    }
    bool ok = fputs(id, f) >= 0;
    return fclose(f) == 0 && ok;
}

bool dock_platform_take_forget_request(void)
{
    return false; /* in the simulator, delete the record file instead */
}

void dock_platform_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}
