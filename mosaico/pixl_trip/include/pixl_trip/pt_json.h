// The little JSON the trip needs, without a DOM: find a value's span by a dotted key path,
// read strings and numbers, write envelopes, and splice new values into raw bytes.
//
// Spans point into the caller's text; nothing here allocates.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *p;
    size_t len;
} pt_span_t;

/// Finds the value at `path` ("payload.state", "owner.deviceId") inside the object `json`.
/// Keys are compared byte for byte (the protocol's keys have no escapes).
bool pt_json_find(const char *json, size_t len, const char *path, pt_span_t *out);

/// Decodes a JSON string value into `out` (UTF-8, terminated). False if it isn't a string or doesn't fit.
bool pt_json_string(pt_span_t v, char *out, size_t cap);

/// A JSON integer (no fraction or exponent).
bool pt_json_int(pt_span_t v, int64_t *out);

/// `true` → true; `false`, `null` or anything else → false.
bool pt_json_is_true(pt_span_t v);

/// Replaces the bytes of `at` (a span inside `buf`) with `text`. `*len` is the used length of `buf`.
bool pt_json_replace(char *buf, size_t *len, size_t cap, pt_span_t at, const char *text, size_t tlen);

/// A bounded writer. After an overflow every call is a no-op and `ok` stays false.
typedef struct {
    char *buf;
    size_t cap;
    size_t len;
    bool ok;
} pt_jw_t;

void pt_jw_init(pt_jw_t *w, char *buf, size_t cap);
void pt_jw_raw(pt_jw_t *w, const char *s, size_t n);
void pt_jw_lit(pt_jw_t *w, const char *s);
/// A quoted string, escaped the way Swift's JSONEncoder does with `.withoutEscapingSlashes`.
void pt_jw_str(pt_jw_t *w, const char *s);
void pt_jw_int(pt_jw_t *w, int64_t v);

#ifdef __cplusplus
}
#endif
