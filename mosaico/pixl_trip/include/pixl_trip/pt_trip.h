// The trip protocol for one device (SPEC §10.3–§10.5), a C port of PixlzCore's `TravelNode`.
//
// The node never decodes PetState into fields. It keeps the state as the raw canonical bytes it
// received, hashes those bytes for the ack (SPEC §10.1), and when the Pixl leaves it splices
// `epoch`, `owner`, `savedAt` and `stats.trips` into them, which keeps them canonical.
//
// Single owner: one task drives a node; nothing here is thread-safe. The caller performs the
// outputs in order, and must persist every PT_OUT_SAVED before sending anything after it.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PT_PROTO 2
#define PT_ID_MAX 64
#define PT_NAME_MAX 96
#define PT_STATE_MAX 4096
#define PT_MSG_MAX (PT_STATE_MAX + 1024)
#define PT_OUT_MAX 4
#define PT_SENDER_TIMEOUT_MS 8000
#define PT_RECEIVER_TIMEOUT_MS 10000
/// A statusReply counts only from a peer we sent `status` to this recently.
#define PT_STATUS_TRUST_MS 60000
#define PT_ASKED_MAX 4
/// Envelopes with an epoch outside 0…PT_EPOCH_MAX are dropped (2^53: exact in JSON everywhere).
#define PT_EPOCH_MAX (INT64_C(1) << 53)

typedef struct {
    char id[PT_ID_MAX];
    char name[PT_NAME_MAX];
} pt_device_t;

typedef enum {
    PT_REC_NONE,    // never had a Pixl
    PT_REC_OWNED,   // the Pixl is here: `state` is it
    PT_REC_PENDING, // received, waiting for commit: `state` is it, not shown
    PT_REC_AWAY,    // it left: `state` is the tombstone (may be empty)
} pt_rec_kind_t;

/// What's on disk. Persist the whole struct (or its used part) on PT_OUT_SAVED.
typedef struct {
    pt_rec_kind_t kind;
    char pet_id[PT_ID_MAX];
    int64_t epoch;
    /// Away: the device that holds it. Pending: the device that sent it.
    char away_id[PT_ID_MAX];
    char away_name[PT_NAME_MAX];
    size_t state_len;
    char state[PT_STATE_MAX];
} pt_record_t;

typedef enum {
    PT_OUT_SEND,           // frame `body` and send it to `peer`
    PT_OUT_SAVED,          // persist node->record now
    PT_OUT_PLAY_EXIT,      // committed: play the exit toward `peer`
    PT_OUT_PLAY_ENTRANCE,  // the Pixl is owned here now
    PT_OUT_SHRUG,          // the trip didn't happen; `reason`
} pt_out_kind_t;

typedef struct {
    pt_out_kind_t kind;
    pt_device_t peer;
    const char *body;  // PT_OUT_SEND: points into the node, valid until the next call
    size_t len;
    char reason[32];
} pt_out_t;

typedef struct {
    pt_out_t items[PT_OUT_MAX];
    int count;
} pt_outs_t;

typedef enum {
    PT_SES_NONE,
    PT_SES_OFFERED,
    PT_SES_TRANSFERRED,
    PT_SES_COMMITTED,
    PT_SES_RECEIVING,
} pt_session_kind_t;

typedef void (*pt_random_fn)(void *ctx, uint8_t *out, size_t n);

typedef struct {
    pt_device_t me;
    pt_record_t record;
    /// iOS-style "can host right now"; the Mosaico sets it false while unplugged.
    bool can_host;
    /// The species this device can draw: `known_count` ids (default: "frogg").
    const char *const *known_species;
    int known_count;
    pt_random_fn random;
    void *random_ctx;
    /// Who may `call` the Pixl away from here, and whose status may make the copy here give way:
    /// "" = any peer, else only this device id (the paired Mac).
    char call_from[PT_ID_MAX];

    // In memory only; lost on a crash.
    struct {
        pt_session_kind_t kind;
        pt_device_t peer;
        char pet_id[PT_ID_MAX];
        int64_t epoch;
        int64_t deadline_ms;
        char checksum[65];
        size_t next_len;
        char next[PT_STATE_MAX];
    } session;

    /// Peers we sent `status` to, and when (for trusting their statusReply).
    struct {
        char id[PT_ID_MAX];
        int64_t at_ms;
    } asked[PT_ASKED_MAX];
    /// A newer copy asked during a trip: ask it back once the trip ends.
    bool ask_back;
    pt_device_t ask_back_peer;

    char msg[PT_OUT_MAX][PT_MSG_MAX];
    int msg_used;
    /// Scratch for building the new owner object (kept off the caller's stack).
    char scratch[2 * (PT_ID_MAX + PT_NAME_MAX) + 64];
} pt_node_t;

void pt_node_init(pt_node_t *n, const pt_device_t *me, pt_random_fn random, void *random_ctx);

/// End any trip now (save failed, leaving the app): sends `abort` with `reason` to the trip's
/// peer while offered, transferred or receiving; a committed trip just ends (no abort). The
/// record isn't touched. False when there was no trip.
bool pt_node_abort(pt_node_t *n, const char *reason, int64_t now_ms, pt_outs_t *out);
/// The user asked to send the Pixl to `peer` (or a tap, in the spike).
void pt_node_send(pt_node_t *n, const pt_device_t *peer, int64_t now_ms, pt_outs_t *out);
/// Ask the owner to send the Pixl here.
void pt_node_call(pt_node_t *n, const pt_device_t *owner, int64_t now_ms, pt_outs_t *out);
/// A swap: the Pixl here travels as `species` named `name` from now on (splices the saved state).
/// Only while owned here and not mid-trip; emits SAVED. False when nothing changed.
bool pt_node_restyle(pt_node_t *n, const char *species, const char *name, pt_outs_t *out);
/// Away, no trip, and a safety copy kept here: reclaim is possible.
bool pt_node_can_reclaim(const pt_node_t *n);
/// The holder is off or out of reach: own the Pixl again from the safety copy (epoch + 2).
/// Emits SAVED then PLAY_ENTRANCE (peer NULL). False when it can't.
bool pt_node_reclaim(pt_node_t *n, int64_t now_ms, pt_outs_t *out);
/// A peer connected (or a periodic re-check): ask it with `status`.
void pt_node_connected(pt_node_t *n, const pt_device_t *peer, int64_t now_ms, pt_outs_t *out);
/// One envelope arrived from `peer` (the JSON body of a frame).
void pt_node_received(pt_node_t *n, const pt_device_t *peer, const char *body, size_t len, int64_t now_ms,
                      pt_outs_t *out);
/// Call when `pt_node_deadline` has passed.
void pt_node_tick(pt_node_t *n, int64_t now_ms, pt_outs_t *out);

/// When to call `pt_node_tick` (unix ms); 0 = no timer needed.
int64_t pt_node_deadline(const pt_node_t *n);
bool pt_node_in_trip(const pt_node_t *n);
/// The owned Pixl has `policy.locked` set.
bool pt_node_locked(const pt_node_t *n);
/// Lock or unlock the owned Pixl (SPEC §10.6): inserts or removes `policy.locked` in the raw
/// state at its sorted place; unlocking with nothing else in `policy` drops `policy` entirely,
/// so the bytes return to what they were. Persist the record when this returns true.
bool pt_node_set_locked(pt_node_t *n, bool locked);

/// `{"hello":{"deviceId":…,"deviceName":…}}`, the spike's first frame each way.
size_t pt_hello_encode(const pt_device_t *me, char *buf, size_t cap);
bool pt_hello_parse(const char *body, size_t len, pt_device_t *out);

/// `yyyy-MM-ddTHH:mm:ss.SSSZ` (24 chars + terminator), the canonical date format.
void pt_format_date(int64_t unix_ms, char out[25]);

#ifdef __cplusplus
}
#endif
