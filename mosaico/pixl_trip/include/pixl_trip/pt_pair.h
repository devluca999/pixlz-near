// Pairing a Mac with this device (D20), and signing what the paired device decides.
//
// Numeric comparison, as Bluetooth does it: the Mac commits to its X25519 key, this device sends
// its key, the Mac reveals its own; both derive the key and the same 6-digit code, and the user
// confirms on both screens that the codes match. The commitment means an attacker in the middle
// gets one try in a million per attempt, and the code is no secret to guess offline.
//
// Frames (JSON bodies, framed like trip messages):
//   Mac → here  {"pair":{"step":"start","commit":hex(SHA256(macPub))},"from","fromName"}
//   here → Mac  {"pair":{"step":"key","pub":hex}}
//   Mac → here  {"pair":{"step":"reveal","pub":hex}}
//   (both show the code)
//   here → Mac  {"pair":{"step":"confirm","tag":hex(HMAC(K,"mosaico-ok"))}}   after the user's yes
//   Mac → here  {"pair":{"step":"done","tag":hex(HMAC(K,"mac-ok"))}}         after the Mac's yes
//   either      {"pair":{"step":"cancel"}}
// T = SHA256("pixlz-pair-v1" ‖ commit ‖ devicePub ‖ macPub ‖ macId ‖ 0 ‖ deviceId)
// K = HKDF-SHA256(X25519 secret, salt T, "pixlz-key"); code = BE32(HMAC(K,"pixlz-sas")) mod 10^6.
//
// A decision from here: {"agentDecision":{"id","behavior","n","seen","tag"}} where
// seen = hex(SHA256(summary ‖ "\n" ‖ detail)) as shown, and
// tag = hex(HMAC(K, "pixlz-decision-v1|deviceId|n|id|behavior|seen")); n only goes up.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "pt_trip.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PT_PAIR_TIMEOUT_MS 120000

/// What's saved: the one paired Mac.
typedef struct {
    bool paired;
    char mac_id[PT_ID_MAX];
    char mac_name[PT_NAME_MAX];
    uint8_t key[32];
    uint32_t counter;   ///< The last decision number used; persist after each signature.
} pt_pair_record_t;

typedef enum {
    PT_PAIR_IDLE = 0,
    PT_PAIR_KEYED,      ///< Sent our key; waiting for the Mac's reveal.
    PT_PAIR_SHOWING,    ///< Code on screen; waiting for the user here.
    PT_PAIR_CONFIRMED,  ///< The user said yes here; waiting for the Mac's yes.
} pt_pair_phase_t;

typedef struct {
    pt_pair_phase_t phase;
    pt_device_t peer;
    uint8_t commit[32], priv[32], pub[32], key[32];
    char code[7];
    int64_t deadline;
} pt_pair_t;

typedef struct {
    char reply[160];     ///< A frame body to send to the peer ("" = none).
    bool show_code;      ///< Show p->code and ask the user.
    bool cancelled;      ///< It's over without pairing (the Mac said no, a bad tag, a timeout).
    bool paired;         ///< `rec` now holds the new pairing: save it.
} pt_pair_out_t;

/// A frame from `peer`. False when it isn't a pairing frame. `random32` is fresh randomness
/// (used for a "start").
bool pt_pair_receive(pt_pair_t *p, pt_pair_record_t *rec, const pt_device_t *me, const pt_device_t *peer,
                     const char *body, size_t len, const uint8_t random32[32], int64_t now_ms, pt_pair_out_t *out);
/// The user's answer here: yes (codes match) or no.
void pt_pair_user(pt_pair_t *p, bool accept, pt_pair_out_t *out);
/// Gives up after PT_PAIR_TIMEOUT_MS.
void pt_pair_tick(pt_pair_t *p, int64_t now_ms, pt_pair_out_t *out);

/// hex(SHA256(summary "\n" detail)).
void pt_pair_seen(const char *summary, const char *detail, char hex[65]);
/// The signed decision frame body; bumps rec->counter (save the record). 0 when not paired.
size_t pt_pair_sign_decision(pt_pair_record_t *rec, const pt_device_t *me, const char *req, const char *behavior,
                             const char *summary, const char *detail, char *out, size_t cap);

/// A signed quick reply to a session: {"agentReply":{"id","text","n","seen","tag"}}, signed like a
/// decision with behavior "reply" over ("reply", text). 0 when not paired or `text` isn't plain.
size_t pt_pair_sign_reply(pt_pair_record_t *rec, const pt_device_t *me, const char *session, const char *text,
                          char *out, size_t cap);

#ifdef __cplusplus
}
#endif
