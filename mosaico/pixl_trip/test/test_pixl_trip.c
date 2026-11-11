// Host tests for pixl_trip. Fixtures come from PixlzCore (`PixlzSend fixtures test/fixtures`),
// so these check the C side reads and writes exactly the bytes the Mac does.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pixl_trip/pt_frame.h"
#include "pixl_trip/pt_json.h"
#include "pixl_trip/pt_sha256.h"
#include "pixl_trip/pt_crypto.h"
#include "pixl_trip/pt_pair.h"
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

    const char *arr = "{\"a\":[ {\"t\":\"x\"}, 2 ,[3]],\"e\":[]}";
    pt_span_t list, item;
    CHECK(pt_json_find(arr, strlen(arr), "a", &list));
    CHECK(pt_json_array_item(list, 0, &item) && item.len == 9);
    CHECK(pt_json_array_item(list, 1, &item) && item.len == 1 && item.p[0] == '2');
    CHECK(pt_json_array_item(list, 2, &item) && item.len == 3);
    CHECK(!pt_json_array_item(list, 3, &item));
    CHECK(!pt_json_array_item(list, -1, &item));
    CHECK(pt_json_find(arr, strlen(arr), "e", &list) && !pt_json_array_item(list, 0, &item));
    CHECK(pt_json_find(arr, strlen(arr), "a.0", &list) == false);

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

static bool state_field(const pt_node_t *n, const char *key, char *out, size_t cap)
{
    pt_span_t v;
    return pt_json_find(n->record.state, n->record.state_len, key, &v) && pt_json_string(v, out, cap);
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

    // Reclaim: the Mac took him and went quiet. Bring him back from the tombstone, two epochs
    // up, so a copy the Mac made meanwhile (one up) gives way to ours.
    m = owning_mosaico();
    CHECK(!pt_node_can_reclaim(m));
    pt_node_send(m, &MAC, T1, &o);
    CHECK(!pt_node_can_reclaim(m));   // mid-trip
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "accept", 8, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    sum = load("return_state.sum", NULL);
    snprintf(payload, sizeof payload, "{\"checksum\":\"%s\"}", sum);
    free(sum);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "ack", 9, payload);
    pt_node_received(m, &MAC, msg, n, T1, &o);
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "commitAck", 9, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY && m->record.epoch == 9 && pt_node_can_reclaim(m));
    CHECK(pt_node_reclaim(m, T1, &o));
    CHECK(out_at(&o, 0, PT_OUT_SAVED) && out_at(&o, 1, PT_OUT_PLAY_ENTRANCE));
    CHECK(m->record.kind == PT_REC_OWNED && m->record.epoch == 11 && !pt_node_can_reclaim(m));
    CHECK(pt_json_find(m->record.state, m->record.state_len, "epoch", &v) && pt_json_int(v, &e) && e == 11);
    CHECK(!pt_node_reclaim(m, T1, &o));
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(m->record.kind == PT_REC_OWNED);   // ours is newer: the Mac gives way
    free(m);

    // The other way round: the Mac reclaimed while this device was off. On connect the device
    // asks, sees a newer owned copy, and gives way (no exit to play: he's just not here).
    m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "status");
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY && m->record.epoch == 10);
    CHECK_STR(m->record.away_name, MAC.name);
    free(m);

    // An offer of the Pixl we already own: "alreadyHere" (two copies), not just "busy".
    char held[16];
    m = owning_mosaico();
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "offer", 8, "{\"name\":\"Frogg\",\"species\":\"frogg\"}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", held, sizeof held));
    CHECK_STR(held, "alreadyHere");
    // Asked by a newer copy (epoch 12 > 8): answer, then ask back so its reply settles it.
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "status", 12, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "statusReply");
    CHECK(sent_field(out_at(&o, 1, PT_OUT_SEND), "type", type, sizeof type));
    CHECK_STR(type, "status");
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "statusReply", 12, "{\"held\":\"owned\",\"inTrip\":false}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY && m->record.epoch == 12);
    free(m);

    // A swap on the Mosaico: the Pixl travels as the new species from now on.
    m = owning_mosaico();
    CHECK(pt_node_restyle(m, "shiba", "Mochi", &o));
    CHECK(out_at(&o, 0, PT_OUT_SAVED));
    char sp[PT_ID_MAX], nm[PT_NAME_MAX];
    CHECK(state_field(m, "species", sp, sizeof sp) && state_field(m, "name", nm, sizeof nm));
    CHECK_STR(sp, "shiba");
    CHECK_STR(nm, "Mochi");
    CHECK(!pt_node_restyle(m, "shiba", "Mochi", &o));   // nothing changed
    pt_node_send(m, &MAC, T1, &o);
    CHECK(!pt_node_restyle(m, "cat", "Kiti", &o));      // mid-trip
    free(m);

    // Status from the Mac is answered with what we hold.
    m = owning_mosaico();
    n = env(msg, sizeof msg, &MAC, &MOSAICO, "status", 8, "{}");
    pt_node_received(m, &MAC, msg, n, T1, &o);
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

// A Mosaico holding Frogg as pending (transfer saved, no commit yet).
static pt_node_t *pending_mosaico(void)
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
    return m;
}

static bool sent_type(const pt_outs_t *o, int index, const char *want)
{
    char type[16] = "";
    return sent_field(out_at(o, index, PT_OUT_SEND), "type", type, sizeof type) && strcmp(type, want) == 0;
}

static void recv_env(pt_node_t *m, const pt_device_t *from, const char *type, int64_t epoch, const char *payload,
                     int64_t now, pt_outs_t *o)
{
    char msg[768];
    size_t n = env(msg, sizeof msg, from, &MOSAICO, type, epoch, payload);
    pt_node_received(m, from, msg, n, now, o);
}

static void ack_return(pt_node_t *m)
{
    pt_outs_t o;
    recv_env(m, &MAC, "accept", 8, "{}", T1, &o);
    char *sum = load("return_state.sum", NULL), payload[128];
    snprintf(payload, sizeof payload, "{\"checksum\":\"%s\"}", sum);
    free(sum);
    recv_env(m, &MAC, "ack", 9, payload, T1, &o);
}

// P1/P2: an away record remembers its holder and says who it is.
static void test_away_holder(void)
{
    pt_outs_t o;
    char buf[PT_NAME_MAX];
    pt_node_t *m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY);
    CHECK_STR(m->record.away_id, MAC.id);
    CHECK_STR(m->record.away_name, MAC.name);
    const pt_device_t other = {"MAC-0002", "Other Mac"};
    recv_env(m, &other, "status", 3, "{}", T1, &o);
    CHECK(sent_type(&o, 0, "statusReply"));
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.holderId", buf, sizeof buf));
    CHECK_STR(buf, MAC.id);
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.holderName", buf, sizeof buf));
    CHECK_STR(buf, MAC.name);
    // Keys stay sorted: held < holderId < holderName < inTrip.
    const pt_out_t *r = out_at(&o, 0, PT_OUT_SEND);
    const char *h = r ? strstr(r->body, "\"held\"") : NULL, *hi = r ? strstr(r->body, "\"holderId\"") : NULL;
    const char *hn = r ? strstr(r->body, "\"holderName\"") : NULL, *it = r ? strstr(r->body, "\"inTrip\"") : NULL;
    CHECK(h && hi && hn && it && h < hi && hi < hn && hn < it);
    free(m);

    // Owned: no holder fields.
    m = owning_mosaico();
    recv_env(m, &MAC, "status", 8, "{}", T1, &o);
    CHECK(!sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.holderId", buf, sizeof buf));
    free(m);

    // Sent away by a trip: the holder is the receiver.
    m = owning_mosaico();
    pt_node_send(m, &MAC, T1, &o);
    ack_return(m);
    CHECK(m->record.kind == PT_REC_AWAY);
    CHECK_STR(m->record.away_id, MAC.id);
    free(m);
}

// P3: give way to a newer copy, owned or away; the losing copy is not kept.
static void test_give_way(void)
{
    pt_outs_t o;
    const pt_device_t other = {"MAC-0002", "Other Mac"};

    // held away with a newer epoch: the holder is the one it names.
    pt_node_t *m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 9,
             "{\"held\":\"away\",\"holderId\":\"MAC-0002\",\"holderName\":\"Other Mac\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY && m->record.epoch == 9);
    CHECK(m->record.state_len == 0);   // never Bring-able
    CHECK(!pt_node_can_reclaim(m));
    CHECK_STR(m->record.away_id, other.id);
    CHECK_STR(m->record.away_name, other.name);
    CHECK(out_at(&o, 0, PT_OUT_SAVED));
    free(m);

    // held away with an equal epoch: ours stays.
    m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 8, "{\"held\":\"away\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_OWNED);
    free(m);

    // held owned, newer: the replying peer holds it; tombstone empty.
    m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 9, "{\"held\":\"owned\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY && m->record.state_len == 0);
    CHECK_STR(m->record.away_id, MAC.id);
    free(m);

    // held owned, same epoch: the smaller device id wins ("MAC-0001" < "MOSAICO-0001").
    m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 8, "{\"held\":\"owned\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY);
    free(m);
    const pt_device_t big = {"ZZZ", "Zed"};
    m = owning_mosaico();
    pt_node_connected(m, &big, T1, &o);
    recv_env(m, &big, "statusReply", 8, "{\"held\":\"owned\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_OWNED);
    free(m);

    // Giving way mid-offer ends the trip: abort to that peer, and a shrug so the screen stops waiting.
    m = owning_mosaico();
    pt_node_send(m, &other, T1, &o);
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_AWAY && !pt_node_in_trip(m));
    CHECK(out_at(&o, 0, PT_OUT_SAVED));
    CHECK(sent_type(&o, 1, "abort"));
    CHECK(out_at(&o, 1, PT_OUT_SEND) && strcmp(o.items[1].peer.id, other.id) == 0);
    CHECK(out_at(&o, 2, PT_OUT_SHRUG));
    if (out_at(&o, 2, PT_OUT_SHRUG)) CHECK_STR(o.items[2].reason, "gaveWay");
    free(m);
}

// P4: answer a status that's as new as ours, and ask back; during a trip, ask once it ends.
static void test_ask_back(void)
{
    pt_outs_t o;
    pt_node_t *m = owning_mosaico();
    recv_env(m, &MAC, "status", 8, "{}", T1, &o);   // equal epoch
    CHECK(sent_type(&o, 0, "statusReply") && sent_type(&o, 1, "status"));
    recv_env(m, &MAC, "status", 7, "{}", T1, &o);   // older: just answer
    CHECK(o.count == 1 && sent_type(&o, 0, "statusReply"));
    free(m);

    m = owning_mosaico();
    const pt_device_t other = {"MAC-0002", "Other Mac"};
    pt_node_send(m, &other, T1, &o);
    recv_env(m, &MAC, "status", 9, "{}", T1, &o);
    CHECK(o.count == 1 && sent_type(&o, 0, "statusReply"));
    pt_node_tick(m, T1 + PT_SENDER_TIMEOUT_MS, &o);   // the offer times out
    int k = -1;
    for (int i = 0; i < o.count; i++) {
        if (sent_type(&o, i, "status")) k = i;
    }
    CHECK(k >= 0 && strcmp(o.items[k].peer.id, MAC.id) == 0);
    pt_node_send(m, &other, T1, &o);
    pt_node_tick(m, T1 + 3 * PT_SENDER_TIMEOUT_MS, &o);
    k = -1;
    for (int i = 0; i < o.count; i++) {
        if (sent_type(&o, i, "status")) k = i;
    }
    CHECK(k < 0);   // once
    free(m);
}

// P5: a pending record is bound to its sender.
static void test_pending_binds_sender(void)
{
    pt_outs_t o;
    const pt_device_t other = {"MAC-0002", "Other Mac"};
    pt_node_t *m = pending_mosaico();
    CHECK(m->record.kind == PT_REC_PENDING);
    CHECK_STR(m->record.away_id, MAC.id);
    CHECK_STR(m->record.away_name, MAC.name);

    // Someone else's replies don't touch it.
    pt_node_connected(m, &other, T0, &o);
    recv_env(m, &other, "statusReply", 8, "{\"held\":\"away\",\"inTrip\":false}", T0, &o);
    CHECK(m->record.kind == PT_REC_PENDING);
    recv_env(m, &other, "statusReply", 0, "{\"held\":\"none\",\"inTrip\":false}", T0, &o);
    CHECK(m->record.kind == PT_REC_PENDING);
    recv_env(m, &other, "statusReply", 3, "{\"held\":\"owned\",\"inTrip\":false}", T0, &o);
    CHECK(m->record.kind == PT_REC_PENDING);
    // Nor a commit or abort from someone else.
    recv_env(m, &other, "commit", 8, "{}", T0, &o);
    CHECK(m->record.kind == PT_REC_PENDING && o.count == 0);
    recv_env(m, &other, "abort", 8, "{\"reason\":\"x\"}", T0, &o);
    CHECK(m->record.kind == PT_REC_PENDING);

    // The sender's "away" promotes only at the pending epoch.
    pt_node_connected(m, &MAC, T0, &o);
    recv_env(m, &MAC, "statusReply", 9, "{\"held\":\"away\",\"inTrip\":false}", T0, &o);
    CHECK(m->record.kind == PT_REC_PENDING);
    recv_env(m, &MAC, "statusReply", 8, "{\"held\":\"away\",\"inTrip\":false}", T0, &o);
    CHECK(m->record.kind == PT_REC_OWNED);
    free(m);

    // The sender holds nothing: ours is the only copy.
    m = pending_mosaico();
    pt_node_connected(m, &MAC, T0, &o);
    recv_env(m, &MAC, "statusReply", 0, "{\"held\":\"none\",\"inTrip\":false}", T0, &o);
    CHECK(m->record.kind == PT_REC_OWNED);
    free(m);

    // The sender still owns an older copy and isn't in a trip: discard ours.
    m = pending_mosaico();
    pt_node_connected(m, &MAC, T0, &o);
    recv_env(m, &MAC, "statusReply", 7, "{\"held\":\"owned\",\"inTrip\":true}", T0, &o);
    CHECK(m->record.kind == PT_REC_PENDING);
    recv_env(m, &MAC, "statusReply", 7, "{\"held\":\"owned\",\"inTrip\":false}", T0, &o);
    CHECK(m->record.kind == PT_REC_AWAY && m->record.state_len == 0);
    CHECK_STR(m->record.away_id, MAC.id);
    free(m);

    // A call can't be made for a pending Pixl.
    m = pending_mosaico();
    pt_node_call(m, &MAC, T0, &o);
    CHECK(o.count == 0);
    free(m);
}

// P7: whom to trust.
static void test_trust(void)
{
    pt_outs_t o;
    const pt_device_t other = {"MAC-0002", "Other Mac"};

    // A statusReply nobody asked for is ignored; an asked one counts for 60 s.
    pt_node_t *m = owning_mosaico();
    recv_env(m, &MAC, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_OWNED);
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}", T1 + PT_STATUS_TRUST_MS + 1, &o);
    CHECK(m->record.kind == PT_REC_OWNED);
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &other, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_OWNED);   // asked MAC, not other
    recv_env(m, &MAC, "statusReply", 10, "{\"held\":\"owned\",\"inTrip\":false}", T1 + 1000, &o);
    CHECK(m->record.kind == PT_REC_AWAY);
    free(m);

    // decline and abort only from the trip's peer.
    m = owning_mosaico();
    pt_node_send(m, &MAC, T1, &o);
    recv_env(m, &other, "decline", 8, "{\"reason\":\"busy\"}", T1, &o);
    CHECK(pt_node_in_trip(m) && o.count == 0);
    recv_env(m, &other, "abort", 8, "{\"reason\":\"x\"}", T1, &o);
    CHECK(pt_node_in_trip(m) && o.count == 0);
    recv_env(m, &MAC, "abort", 8, "{\"reason\":\"x\"}", T1, &o);
    CHECK(!pt_node_in_trip(m));
    free(m);

    // call: only from `call_from` when set (paired), else from anyone.
    m = owning_mosaico();
    snprintf(m->call_from, sizeof m->call_from, "%s", other.id);
    recv_env(m, &MAC, "call", 8, "{}", T1, &o);
    CHECK(o.count == 0 && !pt_node_in_trip(m));
    recv_env(m, &other, "call", 8, "{}", T1, &o);
    CHECK(sent_type(&o, 0, "offer") && pt_node_in_trip(m));
    free(m);
}

// Guards shared with the Swift side.
static void test_guards(void)
{
    pt_outs_t o;
    char reason[32];
    // No ping-pong: a peer we asked in the last 60 s isn't asked back.
    pt_node_t *m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "status", 8, "{}", T1 + 1000, &o);
    CHECK(o.count == 1 && sent_type(&o, 0, "statusReply"));
    recv_env(m, &MAC, "status", 8, "{}", T1 + PT_STATUS_TRUST_MS + 2000, &o);
    CHECK(o.count == 2 && sent_type(&o, 1, "status"));   // long ago: ask again
    free(m);

    // A reply that names us as the holder: we are it, nothing to give way to.
    m = owning_mosaico();
    pt_node_connected(m, &MAC, T1, &o);
    recv_env(m, &MAC, "statusReply", 9, "{\"held\":\"away\",\"holderId\":\"MOSAICO-0001\",\"inTrip\":false}", T1, &o);
    CHECK(m->record.kind == PT_REC_OWNED && o.count == 0);
    free(m);

    // A transfer of a species this device can't draw: abort, nothing saved.
    m = new_node(&MOSAICO);
    recv_env(m, &MAC, "offer", 7, "{\"name\":\"Frogg\",\"species\":\"frogg\"}", T0, &o);
    CHECK(sent_type(&o, 0, "accept"));
    recv_env(m, &MAC, "transfer", 8,
             "{\"state\":{\"epoch\":8,\"owner\":{\"deviceId\":\"MOSAICO-0001\",\"deviceName\":\"Mosaico\"},"
             "\"petId\":\"6F0E2C1A-0000-4000-8000-000000000001\",\"species\":\"cat\"}}", T0, &o);
    CHECK(o.count == 1 && sent_type(&o, 0, "abort"));
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "unsupportedSpecies");
    CHECK(m->record.kind == PT_REC_NONE && !pt_node_in_trip(m));
    free(m);
}

// P8 / F4: ending a trip on purpose.
static void test_abort(void)
{
    pt_outs_t o;
    char reason[32];
    pt_node_t *m = owning_mosaico();
    CHECK(!pt_node_abort(m, "saveFailed", T1, &o) && o.count == 0);
    pt_node_send(m, &MAC, T1, &o);
    CHECK(pt_node_abort(m, "saveFailed", T1, &o));
    CHECK(sent_type(&o, 0, "abort") && !pt_node_in_trip(m));
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "payload.reason", reason, sizeof reason));
    CHECK_STR(reason, "saveFailed");
    CHECK(m->record.kind == PT_REC_OWNED);
    free(m);

    // Receiving: abort to the sender with the trip's pet and epoch.
    m = new_node(&MOSAICO);
    size_t len;
    char *f = load("offer.json", &len);
    pt_node_received(m, &MAC, f, len, T0, &o);
    free(f);
    CHECK(pt_node_abort(m, "saveFailed", T0, &o));
    CHECK(sent_type(&o, 0, "abort"));
    char pet[PT_ID_MAX];
    CHECK(sent_field(out_at(&o, 0, PT_OUT_SEND), "petId", pet, sizeof pet));
    CHECK_STR(pet, PET);
    CHECK(sent_int(out_at(&o, 0, PT_OUT_SEND), "epoch") == 8);
    free(m);

    // Committed: just over, no abort (the receiver may already own it).
    m = owning_mosaico();
    pt_node_send(m, &MAC, T1, &o);
    ack_return(m);
    CHECK(pt_node_in_trip(m));
    CHECK(pt_node_abort(m, "leaving", T1, &o) && o.count == 0 && !pt_node_in_trip(m));
    free(m);
}

static void hexeq(const uint8_t *got, size_t n, const char *want, int line)
{
    char h[129];
    pt_hex(got, n, h);
    checks++;
    if (strcmp(h, want) != 0) { failures++; fprintf(stderr, "line %d: got %s\n  want %s\n", line, h, want); }
}
#define HEXEQ(got, n, want) hexeq(got, n, want, __LINE__)

// The same keys and ids as PixlzCore's PairingTests: both sides must show 635989.
static void test_pairing(void)
{
    const pt_device_t me = {"MOSAICO-1", "Mosaico 1"}, mac = {"MAC-1", "Test Mac"}, other = {"MAC-2", "Other"};
    uint8_t priv[32];
    CHECK(pt_unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb", priv, 32));
    static pt_pair_t p;
    static pt_pair_record_t rec;
    pt_pair_out_t out;
    memset(&p, 0, sizeof p);
    memset(&rec, 0, sizeof rec);
    const char *start = "{\"pair\":{\"step\":\"start\",\"commit\":\"300c9c9603b92a4b39ed3958bf9240114804db4fd373012c0ca47432d63425ae\"},\"from\":\"MAC-1\"}";
    CHECK(pt_pair_receive(&p, &rec, &me, &mac, start, strlen(start), priv, 1000, &out));
    CHECK(p.phase == PT_PAIR_KEYED);
    CHECK(strstr(out.reply, "\"pub\":\"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f\"") != NULL);
    // Someone else can't step in.
    CHECK(pt_pair_receive(&p, &rec, &me, &other, start, strlen(start), priv, 1000, &out) && strstr(out.reply, "cancel"));
    CHECK(p.phase == PT_PAIR_KEYED);
    // A reveal that doesn't match the commitment ends it.
    static pt_pair_t q;
    q = p;
    const char *bad = "{\"pair\":{\"step\":\"reveal\",\"pub\":\"de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f\"}}";
    pt_pair_receive(&q, &rec, &me, &mac, bad, strlen(bad), priv, 1000, &out);
    CHECK(out.cancelled && q.phase == PT_PAIR_IDLE);
    const char *reveal = "{\"pair\":{\"step\":\"reveal\",\"pub\":\"8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a\"}}";
    pt_pair_receive(&p, &rec, &me, &mac, reveal, strlen(reveal), priv, 2000, &out);
    CHECK(out.show_code && p.phase == PT_PAIR_SHOWING);
    CHECK_STR(p.code, "635989");
    HEXEQ(p.key, 32, "1b832b28e81b8ed9aeafb2e9167a45a7dc29d952534c9d23df19d19c065cfa09");
    // "done" before the user's yes is out of order.
    q = p;
    const char *done = "{\"pair\":{\"step\":\"done\",\"tag\":\"3d767fca6cb5cd31bf118fb5c59b539cc217365837e3d87600e697f10519ef3f\"}}";
    pt_pair_receive(&q, &rec, &me, &mac, done, strlen(done), priv, 2000, &out);
    CHECK(out.cancelled && !rec.paired);
    pt_pair_user(&p, true, &out);
    CHECK(strstr(out.reply, "66e447fafe1c13f8d2f62e112d2dc912a66a4e0fd6f2ca15085b0d6b7799bd83") != NULL);
    CHECK(p.phase == PT_PAIR_CONFIRMED);
    pt_pair_receive(&p, &rec, &me, &mac, done, strlen(done), priv, 3000, &out);
    CHECK(out.paired && rec.paired && p.phase == PT_PAIR_IDLE);
    CHECK_STR(rec.mac_id, "MAC-1");
    HEXEQ(rec.key, 32, "1b832b28e81b8ed9aeafb2e9167a45a7dc29d952534c9d23df19d19c065cfa09");

    // A no on the screen, and a timeout.
    pt_pair_receive(&p, &rec, &me, &mac, start, strlen(start), priv, 1000, &out);
    pt_pair_receive(&p, &rec, &me, &mac, reveal, strlen(reveal), priv, 1000, &out);
    pt_pair_user(&p, false, &out);
    CHECK(out.cancelled && strstr(out.reply, "cancel") && p.phase == PT_PAIR_IDLE);
    pt_pair_receive(&p, &rec, &me, &mac, start, strlen(start), priv, 1000, &out);
    pt_pair_tick(&p, 1000 + PT_PAIR_TIMEOUT_MS - 1, &out);
    CHECK(!out.cancelled);
    pt_pair_tick(&p, 1000 + PT_PAIR_TIMEOUT_MS, &out);
    CHECK(out.cancelled && p.phase == PT_PAIR_IDLE);

    // A signed decision, as PairingTests verifies it (key 07…, n = 1).
    static pt_pair_record_t k7;
    memset(&k7, 0, sizeof k7);
    char body[300];
    CHECK(pt_pair_sign_decision(&k7, &me, "req-3", "allow", "Run ls", "ls -la", body, sizeof body) == 0);   // not paired
    k7.paired = true;
    memset(k7.key, 7, 32);
    CHECK(pt_pair_sign_decision(&k7, &me, "req-3", "allow", "Run ls", "ls -la", body, sizeof body) > 0);
    CHECK(k7.counter == 1);
    CHECK(strstr(body, "\"seen\":\"f4a7c5a915b6f3223411f488a0e8979c2ce7f037124601058f3f56ffafa45305\"") != NULL);
    CHECK(strstr(body, "\"tag\":\"1ca12bc426098c0d24618af80088564b59e9cec06a131461f282b08032ae0bfe\"") != NULL);
    // A quick reply, as PairingTests.verifyReply checks it (n = 2 after the decision above).
    k7.counter = 0;
    const char *sid = "0d5c1f5e-1111-4222-8333-944455556666";
    CHECK(pt_pair_sign_reply(&k7, &me, sid, "Run the tests", body, sizeof body) > 0);
    CHECK(strncmp(body, "{\"agentReply\":{\"text\":\"Run the tests\",\"behavior\":\"reply\"", 51) == 0);
    CHECK(strstr(body, "\"seen\":\"39167a70b8bc685f4ef3bbcf52243f4af2befe26da4c88734383ff0b92150dfc\"") != NULL);
    CHECK(strstr(body, "\"tag\":\"a4ef693ac6022fd8e6ed1c91f3431177ca56354e73eaef9030d6bb4e4e37fbfc\"") != NULL);
    CHECK(pt_pair_sign_reply(&k7, &me, sid, "rm -rf /", body, sizeof body) == 0);
    CHECK(pt_pair_sign_decision(&k7, &me, "req\"x", "allow", "a", "b", body, sizeof body) == 0);
    CHECK(pt_pair_sign_decision(&k7, &me, "req-3", "maybe", "a", "b", body, sizeof body) == 0);
}

static void test_crypto(void)
{
    uint8_t k[32], u[32], out[32];
    // RFC 7748 §5.2
    CHECK(pt_unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4", k, 32));
    CHECK(pt_unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c", u, 32));
    CHECK(pt_x25519(out, k, u));
    HEXEQ(out, 32, "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552");
    // RFC 7748 §6.1: both sides reach the same secret.
    uint8_t a[32], b[32], ap[32], bp[32], s1[32], s2[32];
    CHECK(pt_unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a", a, 32));
    CHECK(pt_unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb", b, 32));
    pt_x25519_public(ap, a);
    pt_x25519_public(bp, b);
    HEXEQ(ap, 32, "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    HEXEQ(bp, 32, "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    CHECK(pt_x25519(s1, a, bp) && pt_x25519(s2, b, ap));
    HEXEQ(s1, 32, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
    CHECK(pt_equal(s1, s2, 32));
    // A low-order point gives all zeros: refused.
    uint8_t zero[32] = {0};
    CHECK(!pt_x25519(out, a, zero));
    // RFC 4231 test case 2
    pt_hmac_sha256((const uint8_t *)"Jefe", 4, "what do ya want for nothing?", 28, out);
    HEXEQ(out, 32, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    // RFC 5869 test case 1 (first 32 bytes of the 42)
    uint8_t ikm[22], salt[13];
    memset(ikm, 0x0b, sizeof ikm);
    for (int i = 0; i < 13; i++) salt[i] = (uint8_t)i;
    const char info[] = "\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9";
    pt_hkdf_sha256(ikm, sizeof ikm, salt, sizeof salt, info, out);
    HEXEQ(out, 32, "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf");
    CHECK(!pt_unhex("abc", out, 2) && !pt_unhex("zz", out, 1));
}

int main(int argc, char **argv)
{
    test_crypto();
    test_pairing();
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
    test_away_holder();
    test_give_way();
    test_ask_back();
    test_pending_binds_sender();
    test_trust();
    test_abort();
    test_guards();
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
