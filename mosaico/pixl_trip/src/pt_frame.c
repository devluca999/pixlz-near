#include "../include/pixl_trip/pt_frame.h"

#include <string.h>

void pt_framer_init(pt_framer_t *f, uint8_t *buf, size_t cap)
{
    f->buf = buf;
    f->cap = cap;
    f->len = 0;
    f->too_large = false;
}

static size_t front_length(const pt_framer_t *f)
{
    return (size_t)f->buf[0] << 24 | (size_t)f->buf[1] << 16 | (size_t)f->buf[2] << 8 | f->buf[3];
}

size_t pt_framer_feed(pt_framer_t *f, const uint8_t *data, size_t n)
{
    if (f->too_large) {
        return 0;
    }
    size_t take = f->cap - f->len < n ? f->cap - f->len : n;
    memcpy(f->buf + f->len, data, take);
    f->len += take;
    if (f->len >= 4 && front_length(f) > f->cap - 4) {
        f->too_large = true;
    }
    return take;
}

bool pt_framer_next(pt_framer_t *f, const uint8_t **body, size_t *len)
{
    if (f->too_large || f->len < 4) {
        return false;
    }
    size_t n = front_length(f);
    if (n > f->cap - 4) {
        f->too_large = true;
        return false;
    }
    if (f->len < 4 + n) {
        return false;
    }
    *body = f->buf + 4;
    *len = n;
    return true;
}

void pt_framer_pop(pt_framer_t *f)
{
    if (f->len < 4) {
        return;
    }
    size_t n = 4 + front_length(f);
    if (n > f->len) {
        n = f->len;
    }
    memmove(f->buf, f->buf + n, f->len - n);
    f->len -= n;
    if (f->len >= 4 && front_length(f) > f->cap - 4) {
        f->too_large = true;
    }
}

void pt_frame_header(uint32_t len, uint8_t out[4])
{
    out[0] = (uint8_t)(len >> 24);
    out[1] = (uint8_t)(len >> 16);
    out[2] = (uint8_t)(len >> 8);
    out[3] = (uint8_t)len;
}
