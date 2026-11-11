// Host tests for pixl_trip. Fixtures come from PixlzCore (`PixlzSend fixtures test/fixtures`),
// so these check the C side reads and writes exactly the bytes the Mac does.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pixl_trip/pt_frame.h"
#include "pixl_trip/pt_json.h"
#include "pixl_trip/pt_sha256.h"
#include "pixl_trip/pt_trip.h"

static int failures, checks;

#define CHECK(cond)                                                          \
    do {                                                                     \
        checks++;                                                            \
        if (!(cond)) {                                                       \
            failures++;                                                      \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                    \
    } while (0)

#define CHECK_STR(a, b)                                                                         \
    do {                                                                                        \
        checks++;                                                                               \
        if (strcmp((a), (b)) != 0) {                                                            \
            failures++;                                                                         \
            fprintf(stderr, "%s:%d: \"%s\" != \"%s\"\n", __FILE__, __LINE__, (a), (b));         \
        }                                                                                       \
    } while (0)

static const char *fixture_dir = "test/fixtures";

static char *load(const char *name, size_t *len)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", fixture_dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "missing fixture %s (run: PixlzSend fixtures %s)\n", path, fixture_dir);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) exit(2);
    buf[n] = 0;
    fclose(f);
    if (len) *len = (size_t)n;
    return buf;
}

// Deterministic "random" for msgIds.
static void fake_random(void *ctx, uint8_t *out, size_t n)
{
    unsigned *s = ctx;
    for (size_t i = 0; i < n; i++) {
        *s = *s * 1103515245u + 12345u;
        out[i] = (uint8_t)(*s >> 16);
    }
}

static const pt_device_t MAC = {"MAC-0001", "Luca\xe2\x80\x99s \"Mac\""};
static const pt_device_t MOSAICO = {"MOSAICO-0001", "Mosaico"};
static const int64_t T0 = 1762790400123;  // the fixtures' t0
static const int64_t T1 = 1762790460456;  // the fixtures' t1
static const char *PET = "6F0E2C1A-0000-4000-8000-000000000001";

static unsigned seed = 1;

static pt_node_t *new_node(const pt_device_t *me)
{
    pt_node_t *n = malloc(sizeof *n);
    pt_node_init(n, me, fake_random, &seed);
    return n;
}

// The output of `kind` at `index`, or NULL.
static const pt_out_t *out_at(const pt_outs_t *o, int index, pt_out_kind_t kind)
{
    return index < o->count && o->items[index].kind == kind ? &o->items[index] : NULL;
}

static bool sent_field(const pt_out_t *o, const char *path, char *buf, size_t cap)
{
    pt_span_t v;
    return o && pt_json_find(o->body, o->len, path, &v) && pt_json_string(v, buf, cap);
}

static int64_t sent_int(const pt_out_t *o, const char *path)
{
    pt_span_t v;
    int64_t x = -1;
    if (o && pt_json_find(o->body, o->len, path, &v)) pt_json_int(v, &x);
    return x;
}

// An envelope from `from` to `to`, as the other side would write it.
static size_t env(char *buf, size_t cap, const pt_device_t *from, const pt_device_t *to, const char *type,
                  int64_t epoch, const char *payload)
{
    return (size_t)snprintf(buf, cap,
                            "{\"epoch\":%lld,\"from\":\"%s\",\"msgId\":\"00000000-0000-4000-8000-000000000000\","
                            "\"payload\":%s,\"petId\":\"%s\",\"sentAt\":\"2025-11-10T16:00:00.000Z\",\"to\":\"%s\","
                            "\"type\":\"%s\",\"v\":1}",
                            (long long)epoch, from->id, payload, PET, to->id, type);
}

// ---------------------------------------------------------------------------------------------

static void test_sha256(void)
{
    char hex[65];
    pt_sha256_hex("", 0, hex);
    CHECK_STR(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    pt_sha256_hex("abc", 3, hex);
    CHECK_STR(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    const char *m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    pt_sha256_hex(m, strlen(m), hex);
    CHECK_STR(hex, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    // Fed in odd-sized pieces.
    pt_sha256_t c;
    uint8_t d[32];
    pt_sha256_init(&c);
    for (size_t i = 0; i < strlen(m); i += 7) pt_sha256_update(&c, m + i, strlen(m) - i < 7 ? strlen(m) - i : 7);
    pt_sha256_final(&c, d);
    CHECK(d[0] == 0x24 && d[31] == 0xc1);
}

static void test_framer(void)
{
    uint8_t buf[64];
    pt_framer_t f;
    pt_framer_init(&f, buf, sizeof buf);
    const uint8_t stream[] = {0, 0, 0, 2, '{', '}', 0, 0, 0, 3, '[', '1', ']'};
    // One byte at a time.
    const uint8_t *body;
    size_t len;
    int frames = 0;
    for (size_t i = 0; i < sizeof stream; i++) {
        CHECK(pt_framer_feed(&f, stream + i, 1) == 1);
        while (pt_framer_next(&f, &body, &len)) {
            frames++;
            CHECK(len == (frames == 1 ? 2u : 3u));
            pt_framer_pop(&f);
        }
    }
    CHECK(frames == 2);
    CHECK(f.len == 0);

    // Two frames in one feed.
    CHECK(pt_framer_feed(&f, stream, sizeof stream) == sizeof stream);
    CHECK(pt_framer_next(&f, &body, &len) && len == 2 && memcmp(body, "{}", 2) == 0);
    pt_framer_pop(&f);
    CHECK(pt_framer_next(&f, &body, &len) && len == 3 && memcmp(body, "[1]", 3) == 0);
    pt_framer_pop(&f);
    CHECK(!pt_framer_next(&f, &body, &len));

    // A frame bigger than the buffer poisons the stream.
    const uint8_t big[] = {0, 0, 1, 0};
    pt_framer_feed(&f, big, 4);
    CHECK(f.too_large);
    CHECK(!pt_framer_next(&f, &body, &len));

    uint8_t h[4];
    pt_frame_header(0x01020304, h);
    CHECK(h[0] == 1 && h[3] == 4);
}

static void test_json(void)
{
    const char *j = "{\"a\":{\"b\":[1,{\"c\":2}],\"s\":\"x\\\"y\\u00e9\\ud83d\\udc38\"},\"n\":-42,\"t\":true}";
    pt_span_t v;
    CHECK(pt_json_find(j, strlen(j), "a.b", &v) && v.len == 11);
    CHECK(!pt_json_find(j, strlen(j), "a.c", &v));
    int64_t n = 0;
    CHECK(pt_json_find(j, strlen(j), "n", &v) && pt_json_int(v, &n) && n == -42);
    CHECK(pt_json_find(j, strlen(j), "t", &v) && pt_json_is_true(v));
    char s[32];
    CHECK(pt_json_find(j, strlen(j), "a.s", &v) && pt_json_string(v, s, sizeof s));
    CHECK_STR(s, "x\"y\xc3\xa9\xf0\x9f\x90\xb8");
    char tiny[3];
    CHECK(!pt_json_string(v, tiny, sizeof tiny));

    char buf[64] = "{\"epoch\":7,\"x\":1}";
    size_t len = strlen(buf);
    CHECK(pt_json_find(buf, len, "epoch", &v));
    CHECK(pt_json_replace(buf, &len, sizeof buf, v, "1234", 4));
    buf[len] = 0;
    CHECK_STR(buf, "{\"epoch\":1234,\"x\":1}");

    char out[64];
    pt_jw_t w;
    pt_jw_init(&w, out, sizeof out);
    pt_jw_str(&w, "a\"b\\c/d\n\x01");
    pt_jw_raw(&w, "", 1);
    CHECK(w.ok);
    CHECK_STR(out, "\"a\\\"b\\\\c/d\\n\\u0001\"");
    pt_jw_init(&w, out, 4);
    pt_jw_lit(&w, "12345");
    CHECK(!w.ok);
}

static void test_dates_and_hello(void)
{
    char d[25];
    pt_format_date(T0, d);
    CHECK_STR(d, "2025-11-10T16:00:00.123Z");
    pt_format_date(0, d);
    CHECK_STR(d, "1970-01-01T00:00:00.000Z");
    pt_format_date(951782400000 + 999, d);  // leap day
    CHECK_STR(d, "2000-02-29T00:00:00.999Z");

    char buf[256];
    size_t n = pt_hello_encode(&MAC, buf, sizeof buf);
    CHECK(n > 0);
    pt_device_t back;
    CHECK(pt_hello_parse(buf, n, &back));
    CHECK_STR(back.id, MAC.id);
    CHECK_STR(back.name, MAC.name);
}

// Mac → Mosaico with PixlzCore's own frames, then Mosaico → Mac and the bytes the Mac expects.
static void test_round_trip_with_pixlzcore(void)
{
    pt_node_t *m = new_node(&MOSAICO);
    pt_outs_t o;
    size_t len;
    char *offer = load("offer.json", &len);
    pt_node_received(m, &MAC, offer, len, T0, &o);
    const pt_out_t *accept = out_at(&o, 0, PT_OUT_SEND);
    char type[16] = "";
    CHECK(o.count == 1 && sent_field(accept, "type", type, sizeof type));
    CHECK_STR(type, "accept");
    CHECK(sent_int(accept, "epoch") == 7);
    CHECK(pt_node_in_trip(m));

    char *transfer = load("transfer.json", &len);
    char *expected_sum = load("transfer.sum", NULL);
    pt_node_received(m, &MAC, transfer, len, T0, &o);
    CHECK(o.count == 2 && out_at(&o, 0, PT_OUT_SAVED));
    CHECK(m->record.kind == PT_REC_PENDING && m->record.epoch == 8);
    char sum[65] = "";
    CHECK(sent_field(out_at(&o, 1, PT_OUT_SEND), "payload.checksum", sum, sizeof sum));
    CHECK_STR(sum, expected_sum);  // raw bytes as received hash to what the Mac computed

    char *commit = load("commit.json", &len);
    pt_node_received(m, &MAC, commit, len, T0, &o);
    CHECK(o.count == 3 && out_at(&o, 0, PT_OUT_SAVED) && out_at(&o, 2, PT_OUT_PLAY_ENTRANCE));
    CHECK(sent_field(out_at(&o, 1, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "commitAck");
    CHECK(m->record.kind == PT_REC_OWNED);
    CHECK(!pt_node_in_trip(m));
    // A duplicate commit is acked again and changes nothing.
    pt_node_received(m, &MAC, commit, len, T0, &o);
    CHECK(o.count == 1 && m->record.kind == PT_REC_OWNED);

    // Tap: send him home.
    pt_node_send(m, &MAC, T1, &o);
    const pt_out_t *offer_back = out_at(&o, 0, PT_OUT_SEND);
    CHECK(sent_field(offer_back, "type", type, sizeof type));
    CHECK_STR(type, "offer");
    CHECK(sent_int(offer_back, "payload.proto") == PT_PROTO);
    char species[16] = "";
    CHECK(sent_field(offer_back, "payload.species", species, sizeof species));
    CHECK_STR(species, "frogg");

    char msg[512];
    size_t n = env(msg, sizeof msg, &MAC, &MOSAICO, "accept", 8, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    const pt_out_t *tr = out_at(&o, 0, PT_OUT_SEND);
    pt_span_t st;
    CHECK(tr && pt_json_find(tr->body, tr->len, "payload.state", &st));
    size_t exp_len;
    char *expected = load("return_state.json", &exp_len);
    CHECK(st.len == exp_len && memcmp(st.p, expected, exp_len) == 0);  // canonical, byte for byte
    if (st.len != exp_len || memcmp(st.p, expected, exp_len) != 0) {
        fprintf(stderr, "got:      %.*s\nexpected: %s\n", (int)st.len, st.p, expected);
    }
    CHECK(sent_int(tr, "epoch") == 9);

    char *return_sum = load("return_state.sum", NULL);
    char payload[128];
    snprintf(payload, sizeof payload, "{\"checksum\":\"%s\"}", return_sum);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "ack", 9, payload);
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(o.count == 3 && out_at(&o, 0, PT_OUT_SAVED) && out_at(&o, 2, PT_OUT_PLAY_EXIT));
    CHECK(m->record.kind == PT_REC_AWAY && m->record.epoch == 9);
    CHECK_STR(m->record.away_name, MAC.name);
    CHECK(m->record.state_len == exp_len);  // the tombstone

    n = env(msg, sizeof msg, &MAC, &MOSAICO, "commitAck", 9, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(!pt_node_in_trip(m));

    free(offer); free(transfer); free(expected_sum); free(commit); free(expected); free(return_sum); free(m);
}

// A Mosaico that owns Frogg (from the fixtures' transfer + commit).
static pt_node_t *owning_mosaico(void)
{
    pt_node_t *m = new_node(&MOSAICO);
    pt_outs_t o;
    size_t len;
    char *f = load("offer.json", &len);
    pt_node_received(m, &MAC, f, len, T0, &o);
    free(f);
    f = load("transfer.json", &len);
    pt_node_received(m, &MAC, f, len, T0, &o);
    free(f);
    f = load("commit.json", &len);
    pt_node_received(m, &MAC, f, len, T0, &o);
    free(f);
    return m;
}

static void test_sender_failures(void)
{
    pt_outs_t o;
    char msg[512], type[16], reason[32];
    size_t n;

    // A wrong checksum aborts; Frogg stays.
    pt_node_t *m = owning_mosaico();
    pt_node_send(m, &MAC, T1, &o);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "accept", 8, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "ack", 9, "{\"checksum\":\"00\"}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(out_at(&o, 1, PT_OUT_SHRUG));
    CHECK_STR(o.items[1].reason, "checksumMismatch");
    CHECK(m->record.kind == PT_REC_OWNED && m->record.epoch == 8);
    free(m);

    // Decline passes the reason through.
    m = owning_mosaico();
    pt_node_send(m, &MAC, T1, &o);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "decline", 8, "{\"reason\":\"hasOtherPet\"}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "abort");
    CHECK(out_at(&o, 1, PT_OUT_SHRUG));
    CHECK_STR(o.items[1].reason, "hasOtherPet");
    CHECK(!pt_node_in_trip(m));

    // Timeout after 8 s with no accept.
    pt_node_send(m, &MAC, T1, &o);
    CHECK(pt_node_deadline(m) == T1 + PT_SENDER_TIMEOUT_MS);
    pt_node_tick(m, T1 + 1000, &o);
    CHECK(o.count == 0);
    pt_node_tick(m, T1 + PT_SENDER_TIMEOUT_MS, &o);
    CHECK(out_at(&o, 1, PT_OUT_SHRUG));
    CHECK_STR(o.items[1].reason, "timeout");
    CHECK(m->record.kind == PT_REC_OWNED);

    // A second send while one is running shrugs "busy".
    pt_node_send(m, &MAC, T1, &o);
    pt_node_send(m, &MAC, T1, &o);
    CHECK(out_at(&o, 0, PT_OUT_SHRUG));
    CHECK_STR(o.items[0].reason, "busy");
    free(m);

    // Locked: no offer starts, and a call is declined with `locked`.
    m = owning_mosaico();
    pt_record_t *r = &m->record;
    pt_span_t at;
    CHECK(pt_json_find(r->state, r->state_len, "petId", &at));
    // Insert "policy" at its sorted place: right after petId's value.
    const char *ins = ",\"policy\":{\"locked\":true}";
    pt_span_t after = {at.p + at.len, 0};
    CHECK(pt_json_replace(r->state, &r->state_len, PT_STATE_MAX, after, ins, strlen(ins)));
    CHECK(pt_node_locked(m));
    pt_node_send(m, &MAC, T1, &o);
    CHECK(out_at(&o, 0, PT_OUT_SHRUG));
    CHECK_STR(o.items[0].reason, "locked");
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "call", 8, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "decline");
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "locked");
    free(m);
}

static void test_receiver_declines(void)
{
    pt_outs_t o;
    char msg[512], reason[32];
    size_t n;

    pt_node_t *m = new_node(&MOSAICO);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 7, "{\"name\":\"Frogg\",\"proto\":3,\"species\":\"frogg\"}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "needsUpdate");
    CHECK(!pt_node_in_trip(m));

    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 7, "{\"name\":\"Kiti\",\"species\":\"cat\"}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "unsupportedSpecies");

    m->can_host = false;  // unplugged
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 7, "{\"name\":\"Frogg\",\"species\":\"frogg\"}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "busy");
    free(m);

    // Messages not addressed to us, or from someone else, are ignored.
    m = new_node(&MOSAICO);
    pt_device_t stranger = {"OTHER", "Other"};
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 7, "{\"species\":\"frogg\"}");
    pt_node_received(m, &stranger, msg, n, T0, &o);
    CHECK(o.count == 0);
    n = env(msg, sizeof msg, &MAC, &stranger, "offer", 7, "{\"species\":\"frogg\"}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    CHECK(o.count == 0);

    // A transfer for someone else is refused before anything is saved.
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 7, "{\"species\":\"frogg\"}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "transfer", 8,
            "{\"state\":{\"epoch\":8,\"owner\":{\"deviceId\":\"OTHER\",\"deviceName\":\"x\"},\"petId\":"
            "\"6F0E2C1A-0000-4000-8000-000000000001\"}}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    CHECK(o.count == 1 && sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "badTransfer");
    CHECK(m->record.kind == PT_REC_NONE);
    free(m);
}

static void test_recovery(void)
{
    pt_outs_t o;
    char msg[512], type[16];
    size_t len, n;

    // Pending but the commit never came: the receiver times out, asks for status, and the
    // sender's "away" reply promotes it.
    pt_node_t *m = new_node(&MOSAICO);
    char *f = load("offer.json", &len);
    pt_node_received(m, &MAC, f, len, T0, &o);
    free(f);
    f = load("transfer.json", &len);
    pt_node_received(m, &MAC, f, len, T0, &o);
    free(f);
    pt_node_tick(m, T0 + PT_RECEIVER_TIMEOUT_MS, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "status");
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "statusReply", 8, "{\"held\":\"away\",\"inTrip\":false}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    CHECK(m->record.kind == PT_REC_OWNED && out_at(&o, 2, PT_OUT_PLAY_ENTRANCE));
    free(m);

    // The Mosaico committed but the Mac never confirmed and holds nothing: come home from
    // the tombstone with epoch + 1, owned by the Mosaico again.
    m = owning_mosaico();
    pt_node_send(m, &MAC, T1, &o);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "accept", 8, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    char *sum = load("return_state.sum", NULL);
    char payload[128];
    snprintf(payload, sizeof payload, "{\"checksum\":\"%s\"}", sum);
    free(sum);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "ack", 9, payload);
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY);
    pt_node_connected(m, &MAC, T1, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "status");
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "statusReply", 0, "{\"held\":\"none\",\"inTrip\":false}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(m->record.kind == PT_REC_OWNED && m->record.epoch == 10);
    char owner[PT_ID_MAX];
    pt_span_t v;
    CHECK(pt_json_find(m->record.state, m->record.state_len, "owner.deviceId", &v) && pt_json_string(v, owner, sizeof owner));
    CHECK_STR(owner, MOSAICO.id);
    int64_t e = 0;
    CHECK(pt_json_find(m->record.state, m->record.state_len, "epoch", &v) && pt_json_int(v, &e) && e == 10);
    free(m);

    // Status from the Mac is answered with what we hold.
    m = owning_mosaico();
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "status", 8, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    char held[16];
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.held", held, sizeof held));
    CHECK_STR(held, "owned");
    CHECK(sent_int(out_at(&o, 0, PT_OUT_SEND), "epoch") == 8);
    free(m);
}

static void test_lock_and_species(void)
{
    pt_outs_t o;
    char msg[512], reason[32];
    size_t n;

    // Lock inserts policy at its sorted place; unlock restores the exact bytes.
    pt_node_t *m = owning_mosaico();
    char before[PT_STATE_MAX];
    size_t before_len = m->record.state_len;
    memcpy(before, m->record.state, before_len);
    CHECK(!pt_node_set_locked(m, false));            // already unlocked: no change
    CHECK(pt_node_set_locked(m, true));
    CHECK(pt_node_locked(m));
    pt_span_t pet, policy;
    CHECK(pt_json_find(m->record.state, m->record.state_len, "petId", &pet));
    CHECK(pt_json_find(m->record.state, m->record.state_len, "policy", &policy));
    CHECK(policy.p > pet.p);
    char *after_pet = strstr(m->record.state, "\"policy\"");
    char *saved_at = strstr(m->record.state, "\"savedAt\"");
    CHECK(after_pet && saved_at && after_pet < saved_at);   // petId < policy < savedAt
    CHECK(!pt_node_set_locked(m, true));
    CHECK(pt_node_set_locked(m, false));
    CHECK(!pt_node_locked(m));
    CHECK(m->record.state_len == before_len && memcmp(m->record.state, before, before_len) == 0);
    free(m);

    // Not owned: nothing to lock.
    m = new_node(&MOSAICO);
    CHECK(!pt_node_set_locked(m, true));
    free(m);

    // A device that draws more species accepts them; unknown ones are still declined.
    m = new_node(&MOSAICO);
    static const char *const six[] = {"frogg", "cat", "shiba", "ghost", "slugg", "widow"};
    m->known_species = six;
    m->known_count = 6;
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 7, "{\"name\":\"Kiti\",\"species\":\"cat\"}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    char type[16];
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "accept");
    free(m);
    m = new_node(&MOSAICO);
    m->known_species = six;
    m->known_count = 6;
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 7, "{\"name\":\"Rex\",\"species\":\"dino\"}");
    pt_node_received(m, &MAC, msg, n, T0, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "unsupportedSpecies");
    free(m);
}

int main(int argc, char **argv)
{
    if (argc > 1) fixture_dir = argv[1];
    test_sha256();
    test_framer();
    test_json();
    test_dates_and_hello();
    test_round_trip_with_pixlzcore();
    test_sender_failures();
    test_receiver_declines();
    test_recovery();
    test_lock_and_species();
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
