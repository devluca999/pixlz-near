#include "../include/pixl_trip/pt_trip.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "../include/pixl_trip/pt_json.h"
#include "../include/pixl_trip/pt_sha256.h"

// ---------------------------------------------------------------------------------------------
// Small helpers

static void copy_str(char *dst, size_t cap, const char *src)
{
    if (cap == 0) return;
    size_t n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
}

static bool same_peer(const pt_device_t *a, const pt_device_t *b)
{
    return strcmp(a->id, b->id) == 0;
}

// Days from 1970-01-01 to y-m-d and back (Howard Hinnant's civil-from-days).
static void civil_from_days(int64_t z, int *y, unsigned *m, unsigned *d)
{
    z += 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t yy = (int64_t)yoe + era * 400;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    *d = doy - (153 * mp + 2) / 5 + 1;
    *m = mp < 10 ? mp + 3 : mp - 9;
    *y = (int)(yy + (*m <= 2));
}

void pt_format_date(int64_t unix_ms, char out[25])
{
    int64_t secs = unix_ms >= 0 ? unix_ms / 1000 : (unix_ms - 999) / 1000;
    int ms = (int)(unix_ms - secs * 1000);
    int64_t days = secs >= 0 ? secs / 86400 : (secs - 86399) / 86400;
    int sod = (int)(secs - days * 86400);
    int y;
    unsigned m, d;
    civil_from_days(days, &y, &m, &d);
    // Written digit by digit: always exactly 24 characters, whatever the compiler can prove.
    if (y < 0) y = 0;
    if (y > 9999) y = 9999;
    unsigned fields[7] = {(unsigned)y, m, d, (unsigned)(sod / 3600), (unsigned)(sod / 60 % 60), (unsigned)(sod % 60),
                          (unsigned)ms};
    static const unsigned widths[7] = {4, 2, 2, 2, 2, 2, 3};
    static const char seps[7] = {'-', '-', 'T', ':', ':', '.', 'Z'};
    int o = 0;
    for (int i = 0; i < 7; i++) {
        for (int k = (int)widths[i] - 1; k >= 0; k--) {
            unsigned v = fields[i];
            for (int j = 0; j < k; j++) v /= 10;
            out[o++] = (char)('0' + v % 10);
        }
        out[o++] = seps[i];
    }
    out[o] = 0;
}

// Swift encodes UUIDs in upper case.
static void make_uuid(pt_node_t *n, char out[37])
{
    uint8_t b[16];
    n->random(n->random_ctx, b, sizeof b);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    snprintf(out, 37, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X", b[0], b[1], b[2], b[3],
             b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
}

static pt_out_t *push(pt_outs_t *out, pt_out_kind_t kind, const pt_device_t *peer)
{
    if (out->count >= PT_OUT_MAX) {
        return NULL;
    }
    pt_out_t *o = &out->items[out->count++];
    memset(o, 0, sizeof *o);
    o->kind = kind;
    if (peer) {
        o->peer = *peer;
    }
    return o;
}

static void push_shrug(pt_outs_t *out, const pt_device_t *peer, const char *reason)
{
    pt_out_t *o = push(out, PT_OUT_SHRUG, peer);
    if (o) copy_str(o->reason, sizeof o->reason, reason);
}

// Optional payload members, written in sorted key order (canonical, like Swift's encoder).
typedef struct {
    const char *checksum;
    const char *held;
    const char *holder_id;
    const char *holder_name;
    int in_trip;       // -1 = absent
    const char *name;
    int proto;         // 0 = absent
    const char *reason;
    const char *species;
    const char *state; // raw JSON object
    size_t state_len;
} payload_t;

static void send_env(pt_node_t *n, pt_outs_t *out, const pt_device_t *peer, const char *type, const char *pet_id,
                     int64_t epoch, const payload_t *p, int64_t now_ms)
{
    if (n->msg_used >= PT_OUT_MAX) return;
    char *buf = n->msg[n->msg_used];
    char uuid[37], date[25];
    make_uuid(n, uuid);
    pt_format_date(now_ms, date);

    pt_jw_t w;
    pt_jw_init(&w, buf, PT_MSG_MAX);
    pt_jw_lit(&w, "{\"epoch\":");
    pt_jw_int(&w, epoch);
    pt_jw_lit(&w, ",\"from\":");
    pt_jw_str(&w, n->me.id);
    pt_jw_lit(&w, ",\"msgId\":");
    pt_jw_str(&w, uuid);
    pt_jw_lit(&w, ",\"payload\":{");
    bool first = true;
#define MEMBER(key)                                   \
    do {                                              \
        if (!first) pt_jw_lit(&w, ",");               \
        first = false;                                \
        pt_jw_lit(&w, "\"" key "\":");                \
    } while (0)
    if (p && p->checksum) { MEMBER("checksum"); pt_jw_str(&w, p->checksum); }
    MEMBER("fromName");
    pt_jw_str(&w, n->me.name);
    if (p && p->held) { MEMBER("held"); pt_jw_str(&w, p->held); }
    if (p && p->holder_id) { MEMBER("holderId"); pt_jw_str(&w, p->holder_id); }
    if (p && p->holder_name) { MEMBER("holderName"); pt_jw_str(&w, p->holder_name); }
    if (p && p->in_trip >= 0) { MEMBER("inTrip"); pt_jw_lit(&w, p->in_trip ? "true" : "false"); }
    if (p && p->name) { MEMBER("name"); pt_jw_str(&w, p->name); }
    if (p && p->proto) { MEMBER("proto"); pt_jw_int(&w, p->proto); }
    if (p && p->reason) { MEMBER("reason"); pt_jw_str(&w, p->reason); }
    if (p && p->species) { MEMBER("species"); pt_jw_str(&w, p->species); }
    if (p && p->state) { MEMBER("state"); pt_jw_raw(&w, p->state, p->state_len); }
#undef MEMBER
    pt_jw_lit(&w, "},\"petId\":");
    pt_jw_str(&w, pet_id);
    pt_jw_lit(&w, ",\"sentAt\":");
    pt_jw_str(&w, date);
    pt_jw_lit(&w, ",\"to\":");
    pt_jw_str(&w, peer->id);
    pt_jw_lit(&w, ",\"type\":");
    pt_jw_str(&w, type);
    pt_jw_lit(&w, ",\"v\":1}");
    if (!w.ok) return;

    pt_out_t *o = push(out, PT_OUT_SEND, peer);
    if (!o) return;
    n->msg_used++;
    o->body = buf;
    o->len = w.len;
}

static void payload_init(payload_t *p)
{
    memset(p, 0, sizeof *p);
    p->in_trip = -1;
}

static void send_reason(pt_node_t *n, pt_outs_t *out, const pt_device_t *peer, const char *type, const char *pet_id,
                        int64_t epoch, const char *reason, int64_t now_ms)
{
    payload_t p;
    payload_init(&p);
    p.reason = reason;
    send_env(n, out, peer, type, pet_id, epoch, &p, now_ms);
}

static void send_plain(pt_node_t *n, pt_outs_t *out, const pt_device_t *peer, const char *type, const char *pet_id,
                       int64_t epoch, int64_t now_ms)
{
    send_env(n, out, peer, type, pet_id, epoch, NULL, now_ms);
}

static void saved(pt_outs_t *out)
{
    push(out, PT_OUT_SAVED, NULL);
}

// `status` to `peer`, remembered so its statusReply is trusted for a while (P7).
static void send_status(pt_node_t *n, pt_outs_t *out, const pt_device_t *peer, int64_t now_ms)
{
    if (n->record.kind == PT_REC_NONE) return;
    int slot = 0;
    for (int i = 0; i < PT_ASKED_MAX; i++) {
        if (strcmp(n->asked[i].id, peer->id) == 0) {
            slot = i;
            break;
        }
        if (n->asked[i].at_ms < n->asked[slot].at_ms) slot = i;   // else the oldest
    }
    copy_str(n->asked[slot].id, sizeof n->asked[slot].id, peer->id);
    n->asked[slot].at_ms = now_ms;
    send_plain(n, out, peer, "status", n->record.pet_id, n->record.epoch, now_ms);
}

static bool asked_recently(const pt_node_t *n, const pt_device_t *peer, int64_t now_ms)
{
    for (int i = 0; i < PT_ASKED_MAX; i++) {
        if (n->asked[i].id[0] && strcmp(n->asked[i].id, peer->id) == 0) {
            return now_ms - n->asked[i].at_ms <= PT_STATUS_TRUST_MS;   // a clock step back still counts
        }
    }
    return false;
}

// A newer copy asked during a trip: now that the trip is over, ask it back.
static void flush_ask_back(pt_node_t *n, pt_outs_t *out, int64_t now_ms)
{
    if (!n->ask_back || n->session.kind != PT_SES_NONE) return;
    n->ask_back = false;
    send_status(n, out, &n->ask_back_peer, now_ms);
}

// ---------------------------------------------------------------------------------------------
// Editing raw state bytes

static bool splice(char *buf, size_t *len, const char *path, const char *text)
{
    pt_span_t at;
    if (!pt_json_find(buf, *len, path, &at)) return false;
    return pt_json_replace(buf, len, PT_STATE_MAX, at, text, strlen(text));
}

static bool splice_int(char *buf, size_t *len, const char *path, int64_t v)
{
    char tmp[24];
    snprintf(tmp, sizeof tmp, "%lld", (long long)v);
    return splice(buf, len, path, tmp);
}

static bool splice_date(char *buf, size_t *len, const char *path, int64_t ms)
{
    char d[25], q[28];
    pt_format_date(ms, d);
    snprintf(q, sizeof q, "\"%s\"", d);
    return splice(buf, len, path, q);
}

static bool splice_owner(char *buf, size_t *len, const pt_device_t *owner, char *tmp, size_t cap)
{
    pt_jw_t w;
    pt_jw_init(&w, tmp, cap);
    pt_jw_lit(&w, "{\"deviceId\":");
    pt_jw_str(&w, owner->id);
    pt_jw_lit(&w, ",\"deviceName\":");
    pt_jw_str(&w, owner->name);
    pt_jw_lit(&w, "}");
    pt_jw_raw(&w, "", 1);
    if (!w.ok) return false;
    return splice(buf, len, "owner", tmp);
}

static bool state_int(const char *s, size_t len, const char *path, int64_t *v)
{
    pt_span_t at;
    return pt_json_find(s, len, path, &at) && pt_json_int(at, v);
}

static bool state_str(const char *s, size_t len, const char *path, char *out, size_t cap)
{
    pt_span_t at;
    return pt_json_find(s, len, path, &at) && pt_json_string(at, out, cap);
}

/// A copy of `src` with a new epoch and owner, savedAt = now, and (if counting) one more trip.
static bool rewrite_state(pt_node_t *n, const char *src, size_t src_len, char *dst, size_t *dst_len, int64_t epoch,
                          const pt_device_t *owner, int64_t now_ms, bool count_trip)
{
    if (src_len > PT_STATE_MAX) return false;
    memcpy(dst, src, src_len);
    *dst_len = src_len;
    if (!splice_int(dst, dst_len, "epoch", epoch)) return false;
    if (!splice_owner(dst, dst_len, owner, n->scratch, sizeof n->scratch)) return false;
    if (count_trip) {
        int64_t trips = 0;
        if (!state_int(dst, *dst_len, "stats.trips", &trips)) return false;
        if (!splice_int(dst, dst_len, "stats.trips", trips + 1)) return false;
    }
    return splice_date(dst, dst_len, "savedAt", now_ms);
}

// ---------------------------------------------------------------------------------------------

void pt_node_init(pt_node_t *n, const pt_device_t *me, pt_random_fn random, void *random_ctx)
{
    memset(n, 0, sizeof *n);
    n->me = *me;
    n->record.kind = PT_REC_NONE;
    n->can_host = true;
    static const char *const frogg_only[] = {"frogg"};
    n->known_species = frogg_only;
    n->known_count = 1;
    n->random = random;
    n->random_ctx = random_ctx;
}

static void begin(pt_node_t *n, pt_outs_t *out)
{
    out->count = 0;
    n->msg_used = 0;
}

int64_t pt_node_deadline(const pt_node_t *n)
{
    return n->session.kind == PT_SES_NONE ? 0 : n->session.deadline_ms;
}

bool pt_node_in_trip(const pt_node_t *n)
{
    return n->session.kind != PT_SES_NONE;
}

bool pt_node_locked(const pt_node_t *n)
{
    pt_span_t v;
    return n->record.kind == PT_REC_OWNED &&
           pt_json_find(n->record.state, n->record.state_len, "policy.locked", &v) && pt_json_is_true(v);
}

bool pt_node_set_locked(pt_node_t *n, bool locked)
{
    pt_record_t *r = &n->record;
    if (r->kind != PT_REC_OWNED || pt_node_locked(n) == locked) return false;
    pt_span_t policy, v;
    bool has_policy = pt_json_find(r->state, r->state_len, "policy", &policy);
    bool free_roam = has_policy && pt_json_find(policy.p, policy.len, "freeRoam", &v) && pt_json_is_true(v);
    if (!has_policy) {
        /* "policy" sorts right after "petId" (SPEC §10.1): insert it after petId's value. */
        pt_span_t pet;
        if (!pt_json_find(r->state, r->state_len, "petId", &pet)) return false;
        static const char add[] = ",\"policy\":{\"locked\":true}";
        pt_span_t at = {pet.p + pet.len, 0};
        return pt_json_replace(r->state, &r->state_len, PT_STATE_MAX, at, add, sizeof add - 1);
    }
    if (locked || free_roam) {
        const char *value = locked ? (free_roam ? "{\"freeRoam\":true,\"locked\":true}" : "{\"locked\":true}")
                                   : "{\"freeRoam\":true}";
        return pt_json_replace(r->state, &r->state_len, PT_STATE_MAX, policy, value, strlen(value));
    }
    /* Unlocked with nothing else in it: drop `,"policy":{…}` entirely (writers omit defaults). */
    static const char key[] = ",\"policy\":";
    const size_t klen = sizeof key - 1;
    if (policy.p - r->state < (ptrdiff_t)klen || memcmp(policy.p - klen, key, klen) != 0) return false;
    pt_span_t whole = {policy.p - klen, klen + policy.len};
    return pt_json_replace(r->state, &r->state_len, PT_STATE_MAX, whole, "", 0);
}

static void abort_trip(pt_node_t *n, pt_outs_t *out, const pt_device_t *peer, const char *pet_id, int64_t epoch,
                       const char *reason, int64_t now_ms)
{
    n->session.kind = PT_SES_NONE;
    send_reason(n, out, peer, "abort", pet_id, epoch, reason, now_ms);
    push_shrug(out, peer, reason);
}

static void start_trip(pt_node_t *n, const pt_device_t *peer, int64_t now_ms, pt_outs_t *out)
{
    if (n->record.kind != PT_REC_OWNED) return;
    if (n->session.kind != PT_SES_NONE) {
        push_shrug(out, peer, "busy");
        return;
    }
    if (pt_node_locked(n)) {
        push_shrug(out, peer, "locked");
        return;
    }
    char species[32] = "", name[PT_NAME_MAX] = "";
    state_str(n->record.state, n->record.state_len, "species", species, sizeof species);
    state_str(n->record.state, n->record.state_len, "name", name, sizeof name);
    n->session.kind = PT_SES_OFFERED;
    n->session.peer = *peer;
    copy_str(n->session.pet_id, sizeof n->session.pet_id, n->record.pet_id);
    n->session.epoch = n->record.epoch;
    n->session.deadline_ms = now_ms + PT_SENDER_TIMEOUT_MS;
    payload_t p;
    payload_init(&p);
    p.species = species;
    p.name = name;
    p.proto = PT_PROTO;
    send_env(n, out, peer, "offer", n->record.pet_id, n->record.epoch, &p, now_ms);
}

bool pt_node_abort(pt_node_t *n, const char *reason, int64_t now_ms, pt_outs_t *out)
{
    begin(n, out);
    pt_session_kind_t kind = n->session.kind;
    if (kind == PT_SES_NONE) return false;
    n->session.kind = PT_SES_NONE;
    /* Committed: the receiver may own it already; an abort could make it drop the only copy. */
    if (kind != PT_SES_COMMITTED) {
        send_reason(n, out, &n->session.peer, "abort", n->session.pet_id, n->session.epoch, reason, now_ms);
    }
    flush_ask_back(n, out, now_ms);
    return true;
}

void pt_node_send(pt_node_t *n, const pt_device_t *peer, int64_t now_ms, pt_outs_t *out)
{
    begin(n, out);
    start_trip(n, peer, now_ms, out);
}

void pt_node_call(pt_node_t *n, const pt_device_t *owner, int64_t now_ms, pt_outs_t *out)
{
    begin(n, out);
    if (n->record.kind != PT_REC_AWAY) return;   // not while pending: it's on its way
    send_plain(n, out, owner, "call", n->record.pet_id, n->record.epoch, now_ms);
}

static void set_record(pt_node_t *n, pt_rec_kind_t kind, const char *pet_id, int64_t epoch, const pt_device_t *away,
                       const char *state, size_t state_len);

bool pt_node_restyle(pt_node_t *n, const char *species, const char *name, pt_outs_t *out)
{
    begin(n, out);
    pt_record_t *r = &n->record;
    if (n->session.kind != PT_SES_NONE || r->kind != PT_REC_OWNED || r->state_len == 0) return false;
    char now_species[PT_ID_MAX] = "", now_name[PT_NAME_MAX] = "";
    (void)state_str(r->state, r->state_len, "species", now_species, sizeof now_species);
    (void)state_str(r->state, r->state_len, "name", now_name, sizeof now_name);
    if (strcmp(now_species, species) == 0 && strcmp(now_name, name) == 0) return false;
    /* Work on a copy: a failed splice leaves the saved state as it was. */
    char *buf = n->session.next;
    size_t len = r->state_len;
    memcpy(buf, r->state, len);
    static char quoted[PT_NAME_MAX * 2 + 4];
    pt_jw_t w;
    pt_jw_init(&w, quoted, sizeof quoted);
    pt_jw_str(&w, species);
    if (!w.ok || !splice(buf, &len, "species", quoted)) return false;
    pt_jw_init(&w, quoted, sizeof quoted);
    pt_jw_str(&w, name);
    if (!w.ok || !splice(buf, &len, "name", quoted)) return false;
    set_record(n, PT_REC_OWNED, r->pet_id, r->epoch, NULL, buf, len);
    saved(out);
    return true;
}

bool pt_node_can_reclaim(const pt_node_t *n)
{
    return n->session.kind == PT_SES_NONE && n->record.kind == PT_REC_AWAY && n->record.state_len > 0;
}

// Its holder doesn't answer: come back from the safety copy, two epochs up, so this copy wins
// over one the holder may have made meanwhile (one epoch up). The holder gives way on its next
// status; its time with the Pixl is lost (SPEC §10.5).
bool pt_node_reclaim(pt_node_t *n, int64_t now_ms, pt_outs_t *out)
{
    begin(n, out);
    if (!pt_node_can_reclaim(n)) return false;
    pt_record_t *r = &n->record;
    int64_t epoch = r->epoch + 2;
    if (!rewrite_state(n, r->state, r->state_len, n->session.next, &n->session.next_len, epoch, &n->me, now_ms,
                       false)) {
        return false;
    }
    set_record(n, PT_REC_OWNED, r->pet_id, epoch, NULL, n->session.next, n->session.next_len);
    saved(out);
    push(out, PT_OUT_PLAY_ENTRANCE, NULL);
    return true;
}

void pt_node_connected(pt_node_t *n, const pt_device_t *peer, int64_t now_ms, pt_outs_t *out)
{
    begin(n, out);
    send_status(n, out, peer, now_ms);
}

// ---------------------------------------------------------------------------------------------
// Receiving

typedef struct {
    char type[16];
    char pet_id[PT_ID_MAX];
    int64_t epoch;
    pt_span_t payload;
} env_t;

static bool parse_env(const pt_node_t *n, const pt_device_t *peer, const char *body, size_t len, env_t *e)
{
    pt_span_t v;
    int64_t ver = 0;
    char from[PT_ID_MAX], to[PT_ID_MAX];
    if (!pt_json_find(body, len, "v", &v) || !pt_json_int(v, &ver) || ver != 1) return false;
    if (!pt_json_find(body, len, "from", &v) || !pt_json_string(v, from, sizeof from)) return false;
    if (!pt_json_find(body, len, "to", &v) || !pt_json_string(v, to, sizeof to)) return false;
    if (strcmp(to, n->me.id) != 0 || strcmp(from, peer->id) != 0) return false;
    if (!pt_json_find(body, len, "type", &v) || !pt_json_string(v, e->type, sizeof e->type)) return false;
    if (!pt_json_find(body, len, "petId", &v) || !pt_json_string(v, e->pet_id, sizeof e->pet_id)) return false;
    if (!pt_json_find(body, len, "epoch", &v) || !pt_json_int(v, &e->epoch)) return false;
    if (e->epoch < 0 || e->epoch > PT_EPOCH_MAX) return false;   // epoch ± 2 below must never overflow
    if (!pt_json_find(body, len, "payload", &e->payload)) {
        e->payload.p = "{}";
        e->payload.len = 2;
    }
    return true;
}

static bool payload_str(const env_t *e, const char *key, char *out, size_t cap)
{
    pt_span_t v;
    return pt_json_find(e->payload.p, e->payload.len, key, &v) && pt_json_string(v, out, cap);
}

static const char *decline_reason(const pt_node_t *n, const env_t *e)
{
    pt_span_t v;
    int64_t proto = 1;
    if (pt_json_find(e->payload.p, e->payload.len, "proto", &v)) pt_json_int(v, &proto);
    if (proto > PT_PROTO) return "needsUpdate";
    if (!n->can_host || n->session.kind != PT_SES_NONE) return "busy";
    char species[32] = "";
    payload_str(e, "species", species, sizeof species);
    bool known = false;
    for (int i = 0; i < n->known_count && !known; i++) known = strcmp(species, n->known_species[i]) == 0;
    if (!known) return "unsupportedSpecies";
    bool same = strcmp(n->record.pet_id, e->pet_id) == 0;
    switch (n->record.kind) {
    case PT_REC_NONE: return NULL;
    case PT_REC_OWNED: return same ? "alreadyHere" : "hasOtherPet";
    case PT_REC_PENDING: return "busy";
    case PT_REC_AWAY:
        if (!same) return "hasOtherPet";
        return e->epoch < n->record.epoch ? "busy" : NULL;
    }
    return NULL;
}

// `away` (NULL = nobody) is the holder when away, the sender when pending.
static void set_record(pt_node_t *n, pt_rec_kind_t kind, const char *pet_id, int64_t epoch, const pt_device_t *away,
                       const char *state, size_t state_len)
{
    pt_record_t *r = &n->record;
    pt_device_t who;
    memset(&who, 0, sizeof who);
    if (away) who = *away;   // `away` may point into the record
    // `state` may point into r->state already (memmove handles the overlap).
    if (state && state_len <= PT_STATE_MAX) {
        memmove(r->state, state, state_len);
        r->state_len = state_len;
    } else {
        r->state_len = 0;
    }
    r->kind = kind;
    if (pet_id != r->pet_id) copy_str(r->pet_id, sizeof r->pet_id, pet_id);
    r->epoch = epoch;
    copy_str(r->away_id, sizeof r->away_id, who.id);
    copy_str(r->away_name, sizeof r->away_name, who.name);
}

// The device a pending record came from. Records saved before it was kept have none: anyone.
static bool is_sender(const pt_node_t *n, const pt_device_t *peer)
{
    return !n->record.away_id[0] || strcmp(n->record.away_id, peer->id) == 0;
}

static void promote(pt_node_t *n, int64_t epoch, const char *pet_id, const pt_device_t *peer, int64_t now_ms,
                    pt_outs_t *out)
{
    pt_record_t *r = &n->record;
    if (r->kind == PT_REC_PENDING && strcmp(r->pet_id, pet_id) == 0 && r->epoch == epoch && is_sender(n, peer)) {
        // TODO(spike): Swift also records the travel/receive needs bumps and a `happy` emotion here.
        splice_date(r->state, &r->state_len, "savedAt", now_ms);
        set_record(n, PT_REC_OWNED, r->pet_id, r->epoch, NULL, r->state, r->state_len);
        if (n->session.kind == PT_SES_RECEIVING && same_peer(&n->session.peer, peer)) n->session.kind = PT_SES_NONE;
        saved(out);
        send_plain(n, out, peer, "commitAck", pet_id, epoch, now_ms);
        push(out, PT_OUT_PLAY_ENTRANCE, peer);
    } else if (r->kind == PT_REC_OWNED && strcmp(r->pet_id, pet_id) == 0 && r->epoch == epoch) {
        send_plain(n, out, peer, "commitAck", pet_id, epoch, now_ms);  // duplicate commit
    }
}

static void discard_pending(pt_node_t *n, const pt_device_t *sender, pt_outs_t *out)
{
    set_record(n, PT_REC_AWAY, n->record.pet_id, n->record.epoch - 1, sender, NULL, 0);
    saved(out);
}

// Whose status may make the copy here step aside: the paired Mac only (anyone while unpaired).
// Peer ids are self-declared, so this is what stops any device on the network from taking it.
static bool may_give_way_to(const pt_node_t *n, const pt_device_t *peer)
{
    return !n->call_from[0] || strcmp(n->call_from, peer->id) == 0;
}

// Another copy is newer: this one steps aside. It keeps its state as the tombstone (still owned
// by this device, so status never restores it by itself), so a wrong give-way can be undone with
// reclaim instead of losing the Pixl.
static void give_way(pt_node_t *n, const env_t *e, const pt_device_t *peer, const char *held, int64_t now_ms,
                     pt_outs_t *out)
{
    pt_record_t *r = &n->record;
    pt_device_t holder = *peer;
    if (strcmp(held, "away") == 0) {
        char id[PT_ID_MAX] = "", name[PT_NAME_MAX] = "";
        if (!payload_str(e, "holderId", id, sizeof id)) id[0] = 0;
        if (strcmp(id, n->me.id) == 0) return;   // it names us: we are the holder
        if (id[0]) {
            copy_str(holder.id, sizeof holder.id, id);
            if (!payload_str(e, "holderName", name, sizeof name)) copy_str(name, sizeof name, id);
            copy_str(holder.name, sizeof holder.name, name);
        }
    }
    pt_session_kind_t was = n->session.kind;
    n->session.kind = PT_SES_NONE;
    set_record(n, PT_REC_AWAY, r->pet_id, e->epoch, &holder, r->state, r->state_len);
    saved(out);
    if (was == PT_SES_OFFERED || was == PT_SES_TRANSFERRED) {
        send_reason(n, out, &n->session.peer, "abort", n->session.pet_id, n->session.epoch, "gaveWay", now_ms);
        push_shrug(out, &n->session.peer, "gaveWay");
    }
}

static void reconcile(pt_node_t *n, const env_t *e, const pt_device_t *peer, int64_t now_ms, pt_outs_t *out)
{
    pt_record_t *r = &n->record;
    char held[16];
    if (!asked_recently(n, peer, now_ms)) return;   // nobody asked it (P7)
    if (r->kind == PT_REC_NONE || strcmp(r->pet_id, e->pet_id) != 0 || !payload_str(e, "held", held, sizeof held)) return;
    pt_span_t v;
    bool peer_in_trip = pt_json_find(e->payload.p, e->payload.len, "inTrip", &v) && pt_json_is_true(v);
    int64_t pe = e->epoch;

    switch (r->kind) {
    case PT_REC_PENDING:
        if (!is_sender(n, peer)) return;   // only its sender knows (P5)
        char holder[PT_ID_MAX] = "";
        if (strcmp(held, "away") == 0 && pe == r->epoch && payload_str(e, "holderId", holder, sizeof holder) &&
            strcmp(holder, n->me.id) == 0) {
            // the sender committed to us (not to another device at the same epoch)
            promote(n, r->epoch, r->pet_id, peer, now_ms, out);
        } else if (strcmp(held, "owned") == 0 && pe < r->epoch && !peer_in_trip) {
            if (n->session.kind == PT_SES_RECEIVING && same_peer(&n->session.peer, peer)) n->session.kind = PT_SES_NONE;
            discard_pending(n, peer, out);
        }
        // held "none" settles nothing: its id is self-declared, and promoting on it could make a
        // second owner. The copy stays pending (kept, never shown) until the sender answers.
        break;

    case PT_REC_AWAY: {
        char tomb_owner[PT_ID_MAX];
        if (r->state_len == 0 || !state_str(r->state, r->state_len, "owner.deviceId", tomb_owner, sizeof tomb_owner) ||
            strcmp(tomb_owner, peer->id) != 0) {
            return;
        }
        if (strcmp(held, "pending") == 0 && pe == r->epoch) {
            send_plain(n, out, peer, "commit", r->pet_id, r->epoch, now_ms);
        } else if (strcmp(held, "none") == 0 || (strcmp(held, "away") == 0 && pe <= r->epoch)) {
            // The receiver never got it: come home from the safety copy.
            // The session buffer is free: any trip with this peer is over.
            n->session.kind = PT_SES_NONE;
            int64_t epoch = r->epoch + 1;
            if (!rewrite_state(n, r->state, r->state_len, n->session.next, &n->session.next_len, epoch, &n->me, now_ms,
                               false)) {
                return;
            }
            set_record(n, PT_REC_OWNED, r->pet_id, epoch, NULL, n->session.next, n->session.next_len);
            saved(out);
            push(out, PT_OUT_PLAY_ENTRANCE, peer);
        }
        break;
    }

    case PT_REC_OWNED: {
        bool owned = strcmp(held, "owned") == 0, away = strcmp(held, "away") == 0;
        bool peer_wins = ((owned || away) && pe > r->epoch) ||
                         (owned && pe == r->epoch && strcmp(peer->id, n->me.id) < 0);
        if (peer_wins && may_give_way_to(n, peer)) give_way(n, e, peer, held, now_ms, out);
        break;
    }

    case PT_REC_NONE:
        break;
    }
}

void pt_node_received(pt_node_t *n, const pt_device_t *peer, const char *body, size_t len, int64_t now_ms,
                      pt_outs_t *out)
{
    begin(n, out);
    env_t e;
    if (!parse_env(n, peer, body, len, &e)) return;
    pt_record_t *r = &n->record;
    const char *t = e.type;

    if (strcmp(t, "call") == 0) {
        if (r->kind != PT_REC_OWNED || strcmp(r->pet_id, e.pet_id) != 0) return;
        if (n->call_from[0] && strcmp(n->call_from, peer->id) != 0) return;   // only the paired Mac (P7)
        if (pt_node_locked(n)) {
            send_reason(n, out, peer, "decline", e.pet_id, e.epoch, "locked", now_ms);
            return;
        }
        start_trip(n, peer, now_ms, out);

    } else if (strcmp(t, "offer") == 0) {
        const char *reason = decline_reason(n, &e);
        if (reason) {
            send_reason(n, out, peer, "decline", e.pet_id, e.epoch, reason, now_ms);
            return;
        }
        n->session.kind = PT_SES_RECEIVING;
        n->session.peer = *peer;
        copy_str(n->session.pet_id, sizeof n->session.pet_id, e.pet_id);
        n->session.epoch = e.epoch + 1;
        n->session.deadline_ms = now_ms + PT_RECEIVER_TIMEOUT_MS;
        send_plain(n, out, peer, "accept", e.pet_id, e.epoch, now_ms);

    } else if (strcmp(t, "accept") == 0) {
        if (n->session.kind != PT_SES_OFFERED || !same_peer(&n->session.peer, peer) || e.epoch != n->session.epoch ||
            r->kind != PT_REC_OWNED || strcmp(r->pet_id, e.pet_id) != 0) {
            return;
        }
        int64_t next_epoch = n->session.epoch + 1;
        if (!rewrite_state(n, r->state, r->state_len, n->session.next, &n->session.next_len, next_epoch, peer, now_ms,
                           true)) {
            abort_trip(n, out, peer, r->pet_id, n->session.epoch, "encodingFailed", now_ms);
            return;
        }
        pt_sha256_hex(n->session.next, n->session.next_len, n->session.checksum);
        n->session.kind = PT_SES_TRANSFERRED;
        n->session.epoch = next_epoch;
        payload_t p;
        payload_init(&p);
        p.state = n->session.next;
        p.state_len = n->session.next_len;
        send_env(n, out, peer, "transfer", r->pet_id, next_epoch, &p, now_ms);

    } else if (strcmp(t, "decline") == 0) {
        if (n->session.kind != PT_SES_OFFERED || !same_peer(&n->session.peer, peer) || e.epoch != n->session.epoch) return;
        char reason[32] = "userDeclined";
        payload_str(&e, "reason", reason, sizeof reason);
        abort_trip(n, out, peer, e.pet_id, n->session.epoch, reason, now_ms);
        /* It's already there: two copies. Ask, so the older one steps aside. */
        if (strcmp(reason, "alreadyHere") == 0) send_status(n, out, peer, now_ms);

    } else if (strcmp(t, "transfer") == 0) {
        if (n->session.kind != PT_SES_RECEIVING || !same_peer(&n->session.peer, peer) || e.epoch != n->session.epoch) return;
        pt_span_t st;
        char st_pet[PT_ID_MAX], st_owner[PT_ID_MAX];
        int64_t st_epoch = 0;
        bool ok = pt_json_find(e.payload.p, e.payload.len, "state", &st) && st.len <= PT_STATE_MAX && st.p[0] == '{' &&
                  state_str(st.p, st.len, "petId", st_pet, sizeof st_pet) && strcmp(st_pet, e.pet_id) == 0 &&
                  state_int(st.p, st.len, "epoch", &st_epoch) && st_epoch == e.epoch &&
                  state_str(st.p, st.len, "owner.deviceId", st_owner, sizeof st_owner) &&
                  strcmp(st_owner, n->me.id) == 0;
        if (!ok) {
            n->session.kind = PT_SES_NONE;
            send_reason(n, out, peer, "abort", e.pet_id, e.epoch, "badTransfer", now_ms);
            return;
        }
        /* The state may say another species than the offer did: only keep what this device can draw. */
        char st_species[32] = "";
        bool known = false;
        if (state_str(st.p, st.len, "species", st_species, sizeof st_species)) {
            for (int i = 0; i < n->known_count && !known; i++) known = strcmp(st_species, n->known_species[i]) == 0;
        }
        if (!known) {
            n->session.kind = PT_SES_NONE;
            send_reason(n, out, peer, "abort", e.pet_id, e.epoch, "unsupportedSpecies", now_ms);
            return;
        }
        char sum[65];
        pt_sha256_hex(st.p, st.len, sum);  // the raw bytes as received (SPEC §10.1)
        set_record(n, PT_REC_PENDING, e.pet_id, e.epoch, peer, st.p, st.len);   // bound to its sender (P5)
        saved(out);
        payload_t p;
        payload_init(&p);
        p.checksum = sum;
        send_env(n, out, peer, "ack", e.pet_id, e.epoch, &p, now_ms);

    } else if (strcmp(t, "ack") == 0) {
        if (n->session.kind != PT_SES_TRANSFERRED || !same_peer(&n->session.peer, peer) || e.epoch != n->session.epoch) return;
        char sum[65] = "";
        payload_str(&e, "checksum", sum, sizeof sum);
        if (strcmp(sum, n->session.checksum) != 0) {
            abort_trip(n, out, peer, e.pet_id, e.epoch, "checksumMismatch", now_ms);
            return;
        }
        set_record(n, PT_REC_AWAY, r->pet_id, e.epoch, peer, n->session.next, n->session.next_len);
        n->session.kind = PT_SES_COMMITTED;
        n->session.deadline_ms += PT_SENDER_TIMEOUT_MS;
        saved(out);
        send_plain(n, out, peer, "commit", r->pet_id, e.epoch, now_ms);
        push(out, PT_OUT_PLAY_EXIT, peer);

    } else if (strcmp(t, "commit") == 0) {
        promote(n, e.epoch, e.pet_id, peer, now_ms, out);

    } else if (strcmp(t, "commitAck") == 0) {
        if (n->session.kind == PT_SES_COMMITTED && same_peer(&n->session.peer, peer) && n->session.epoch == e.epoch) {
            n->session.kind = PT_SES_NONE;
        }

    } else if (strcmp(t, "abort") == 0) {
        bool shrug = false;
        char reason[32] = "aborted";
        if (n->session.kind == PT_SES_RECEIVING && same_peer(&n->session.peer, peer)) n->session.kind = PT_SES_NONE;
        if ((n->session.kind == PT_SES_OFFERED || n->session.kind == PT_SES_TRANSFERRED) &&
            same_peer(&n->session.peer, peer)) {
            n->session.kind = PT_SES_NONE;
            payload_str(&e, "reason", reason, sizeof reason);
            shrug = true;
        }
        if (r->kind == PT_REC_PENDING && strcmp(r->pet_id, e.pet_id) == 0 && is_sender(n, peer) &&
            (r->epoch == e.epoch || r->epoch == e.epoch + 1)) {
            discard_pending(n, peer, out);
        }
        if (shrug) push_shrug(out, peer, reason);

    } else if (strcmp(t, "status") == 0) {
        const char *held = "none";
        int64_t epoch = 0;
        bool same = r->kind != PT_REC_NONE && strcmp(r->pet_id, e.pet_id) == 0;
        payload_t p;
        payload_init(&p);
        if (same) {
            epoch = r->epoch;
            held = r->kind == PT_REC_OWNED ? "owned" : r->kind == PT_REC_PENDING ? "pending" : "away";
            if (r->kind == PT_REC_AWAY && r->away_id[0]) {
                p.holder_id = r->away_id;
                p.holder_name = r->away_name[0] ? r->away_name : r->away_id;
            }
        }
        p.held = held;
        p.in_trip = pt_node_in_trip(n) ? 1 : 0;
        send_env(n, out, peer, "statusReply", e.pet_id, epoch, &p, now_ms);
        /* The asker's copy is as new as ours: ask back, so its answer settles it here too (P4).
         * Not if we asked it lately: two equal copies would ask each other forever. */
        if (same && e.epoch >= r->epoch && !asked_recently(n, peer, now_ms)) {
            n->ask_back = true;
            n->ask_back_peer = *peer;
        }

    } else if (strcmp(t, "statusReply") == 0) {
        reconcile(n, &e, peer, now_ms, out);
    }
    flush_ask_back(n, out, now_ms);
}

void pt_node_tick(pt_node_t *n, int64_t now_ms, pt_outs_t *out)
{
    begin(n, out);
    if (n->session.kind == PT_SES_NONE || now_ms < n->session.deadline_ms) return;
    const pt_device_t *peer = &n->session.peer;  // not changed by the calls below
    switch (n->session.kind) {
    case PT_SES_OFFERED:
    case PT_SES_TRANSFERRED:
        abort_trip(n, out, peer, n->session.pet_id, n->session.epoch, "timeout", now_ms);
        break;
    case PT_SES_COMMITTED:
        n->session.kind = PT_SES_NONE;  // no commitAck: stay away; the next status settles it
        break;
    case PT_SES_RECEIVING:
        n->session.kind = PT_SES_NONE;
        if (n->record.kind == PT_REC_PENDING) send_status(n, out, peer, now_ms);
        break;
    case PT_SES_NONE:
        break;
    }
    flush_ask_back(n, out, now_ms);
}

size_t pt_hello_encode(const pt_device_t *me, char *buf, size_t cap)
{
    pt_jw_t w;
    pt_jw_init(&w, buf, cap);
    pt_jw_lit(&w, "{\"hello\":{\"deviceId\":");
    pt_jw_str(&w, me->id);
    pt_jw_lit(&w, ",\"deviceName\":");
    pt_jw_str(&w, me->name);
    pt_jw_lit(&w, "}}");
    return w.ok ? w.len : 0;
}

bool pt_hello_parse(const char *body, size_t len, pt_device_t *out)
{
    pt_span_t v;
    return pt_json_find(body, len, "hello.deviceId", &v) && pt_json_string(v, out->id, sizeof out->id) &&
           pt_json_find(body, len, "hello.deviceName", &v) && pt_json_string(v, out->name, sizeof out->name);
}
