// SPDX-License-Identifier: Apache-2.0
#include "../include/pixl_trip/pt_pair.h"

#include <stdio.h>
#include <string.h>

#include "../include/pixl_trip/pt_crypto.h"
#include "../include/pixl_trip/pt_json.h"
#include "../include/pixl_trip/pt_sha256.h"

static void reset(pt_pair_t *p)
{
    memset(p, 0, sizeof *p);
}

static void reply(pt_pair_out_t *out, const char *step, const char *field, const uint8_t bytes[32])
{
    char hex[65];
    if (field) {
        pt_hex(bytes, 32, hex);
        snprintf(out->reply, sizeof out->reply, "{\"pair\":{\"step\":\"%s\",\"%s\":\"%s\"}}", step, field, hex);
    } else {
        snprintf(out->reply, sizeof out->reply, "{\"pair\":{\"step\":\"%s\"}}", step);
    }
}

static void cancel(pt_pair_t *p, pt_pair_out_t *out, bool tell)
{
    if (p->phase != PT_PAIR_IDLE) {
        out->cancelled = true;
        if (tell) reply(out, "cancel", NULL, NULL);
    }
    reset(p);
}

static void tag(const uint8_t key[32], const char *label, uint8_t out[32])
{
    pt_hmac_sha256(key, 32, label, strlen(label), out);
}

/* Both keys are known: derive K and the code. */
static bool derive(pt_pair_t *p, const pt_device_t *me, const uint8_t mac_pub[32])
{
    static uint8_t secret[32], t[32];
    static pt_sha256_t c;
    if (!pt_x25519(secret, p->priv, mac_pub)) return false;
    pt_sha256_init(&c);
    pt_sha256_update(&c, "pixlz-pair-v1", 13);
    pt_sha256_update(&c, p->commit, 32);
    pt_sha256_update(&c, p->pub, 32);
    pt_sha256_update(&c, mac_pub, 32);
    pt_sha256_update(&c, p->peer.id, strlen(p->peer.id));
    pt_sha256_update(&c, "", 1);
    pt_sha256_update(&c, me->id, strlen(me->id));
    pt_sha256_final(&c, t);
    pt_hkdf_sha256(secret, 32, t, 32, "pixlz-key", p->key);
    uint8_t sas[32];
    tag(p->key, "pixlz-sas", sas);
    uint32_t v = (uint32_t)sas[0] << 24 | (uint32_t)sas[1] << 16 | (uint32_t)sas[2] << 8 | sas[3];
    snprintf(p->code, sizeof p->code, "%06u", (unsigned)(v % 1000000u));
    memset(secret, 0, sizeof secret);
    memset(p->priv, 0, sizeof p->priv);
    return true;
}

static bool field32(const char *body, size_t len, const char *path, uint8_t out[32])
{
    pt_span_t v;
    char hex[80];
    return pt_json_find(body, len, path, &v) && pt_json_string(v, hex, sizeof hex) && pt_unhex(hex, out, 32);
}

bool pt_pair_receive(pt_pair_t *p, pt_pair_record_t *rec, const pt_device_t *me, const pt_device_t *peer,
                     const char *body, size_t len, const uint8_t random32[32], int64_t now_ms, pt_pair_out_t *out)
{
    memset(out, 0, sizeof *out);
    pt_span_t v;
    char step[16];
    if (!pt_json_find(body, len, "pair.step", &v) || !pt_json_string(v, step, sizeof step)) return false;
    const bool from_peer = p->phase != PT_PAIR_IDLE && strcmp(p->peer.id, peer->id) == 0;

    if (strcmp(step, "start") == 0) {
        if (p->phase != PT_PAIR_IDLE && !from_peer) {
            reply(out, "cancel", NULL, NULL);   /* busy pairing with someone else */
            return true;
        }
        reset(p);
        if (!field32(body, len, "pair.commit", p->commit)) return true;
        p->peer = *peer;
        memcpy(p->priv, random32, 32);
        pt_x25519_public(p->pub, p->priv);
        p->phase = PT_PAIR_KEYED;
        p->deadline = now_ms + PT_PAIR_TIMEOUT_MS;
        reply(out, "key", "pub", p->pub);
        return true;
    }
    if (!from_peer) return true;   /* nothing to do with a pairing in progress */

    if (strcmp(step, "cancel") == 0) {
        cancel(p, out, false);
    } else if (strcmp(step, "reveal") == 0 && p->phase == PT_PAIR_KEYED) {
        uint8_t mac_pub[32], h[32];
        pt_sha256_t c;
        if (!field32(body, len, "pair.pub", mac_pub)) { cancel(p, out, true); return true; }
        pt_sha256_init(&c);
        pt_sha256_update(&c, mac_pub, 32);
        pt_sha256_final(&c, h);
        if (!pt_equal(h, p->commit, 32) || !derive(p, me, mac_pub)) { cancel(p, out, true); return true; }
        p->phase = PT_PAIR_SHOWING;
        out->show_code = true;
    } else if (strcmp(step, "done") == 0 && p->phase == PT_PAIR_CONFIRMED) {
        uint8_t got[32], want[32];
        tag(p->key, "mac-ok", want);
        if (!field32(body, len, "pair.tag", got) || !pt_equal(got, want, 32)) { cancel(p, out, true); return true; }
        memset(rec, 0, sizeof *rec);
        rec->paired = true;
        snprintf(rec->mac_id, sizeof rec->mac_id, "%s", p->peer.id);
        snprintf(rec->mac_name, sizeof rec->mac_name, "%s", p->peer.name);
        memcpy(rec->key, p->key, 32);
        out->paired = true;
        reset(p);
    } else {
        cancel(p, out, true);   /* out of order */
    }
    return true;
}

void pt_pair_user(pt_pair_t *p, bool accept, pt_pair_out_t *out)
{
    memset(out, 0, sizeof *out);
    if (p->phase != PT_PAIR_SHOWING) return;
    if (!accept) { cancel(p, out, true); return; }
    uint8_t t[32];
    tag(p->key, "mosaico-ok", t);
    reply(out, "confirm", "tag", t);
    p->phase = PT_PAIR_CONFIRMED;
}

void pt_pair_tick(pt_pair_t *p, int64_t now_ms, pt_pair_out_t *out)
{
    memset(out, 0, sizeof *out);
    if (p->phase != PT_PAIR_IDLE && now_ms >= p->deadline) cancel(p, out, true);
}

void pt_pair_seen(const char *summary, const char *detail, char hex[65])
{
    pt_sha256_t c;
    uint8_t h[32];
    pt_sha256_init(&c);
    pt_sha256_update(&c, summary, strlen(summary));
    pt_sha256_update(&c, "\n", 1);
    pt_sha256_update(&c, detail, strlen(detail));
    pt_sha256_final(&c, h);
    pt_hex(h, 32, hex);
}

size_t pt_pair_sign_decision(pt_pair_record_t *rec, const pt_device_t *me, const char *req, const char *behavior,
                             const char *summary, const char *detail, char *out, size_t cap)
{
    if (!rec->paired || (strcmp(behavior, "allow") != 0 && strcmp(behavior, "deny") != 0)) return 0;
    for (const char *c = req; *c; c++) {   /* ids are the Mac's "req-N": nothing to escape */
        if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '-')) return 0;
    }
    if (!req[0] || strlen(req) > 32) return 0;
    static char msg[256];
    char seen[65], t[65];
    uint8_t mac[32];
    rec->counter++;
    pt_pair_seen(summary, detail, seen);
    int n = snprintf(msg, sizeof msg, "pixlz-decision-v1|%s|%u|%s|%s|%s", me->id, (unsigned)rec->counter, req,
                     behavior, seen);
    if (n < 0 || (size_t)n >= sizeof msg) return 0;
    pt_hmac_sha256(rec->key, 32, msg, (size_t)n, mac);
    pt_hex(mac, 32, t);
    n = snprintf(out, cap,
                 "{\"agentDecision\":{\"behavior\":\"%s\",\"id\":\"%s\",\"n\":%u,\"seen\":\"%s\",\"tag\":\"%s\"}}",
                 behavior, req, (unsigned)rec->counter, seen, t);
    return n > 0 && (size_t)n < cap ? (size_t)n : 0;
}
