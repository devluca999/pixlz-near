#include "pixl_trip/pt_json.h"

#include <stdio.h>
#include <string.h>

static void skip_ws(const char *s, size_t n, size_t *i)
{
    while (*i < n && (s[*i] == ' ' || s[*i] == '\t' || s[*i] == '\n' || s[*i] == '\r')) {
        (*i)++;
    }
}

// Advances past one string starting at s[*i] == '"'.
static bool skip_string(const char *s, size_t n, size_t *i)
{
    if (*i >= n || s[*i] != '"') {
        return false;
    }
    for ((*i)++; *i < n; (*i)++) {
        if (s[*i] == '\\') {
            (*i)++;
        } else if (s[*i] == '"') {
            (*i)++;
            return true;
        }
    }
    return false;
}

// Advances past one value of any kind.
static bool skip_value(const char *s, size_t n, size_t *i)
{
    skip_ws(s, n, i);
    if (*i >= n) {
        return false;
    }
    char c = s[*i];
    if (c == '"') {
        return skip_string(s, n, i);
    }
    if (c == '{' || c == '[') {
        int depth = 0;
        while (*i < n) {
            char d = s[*i];
            if (d == '"') {
                if (!skip_string(s, n, i)) {
                    return false;
                }
                continue;
            }
            if (d == '{' || d == '[') {
                depth++;
            } else if (d == '}' || d == ']') {
                depth--;
                if (depth == 0) {
                    (*i)++;
                    return true;
                }
            }
            (*i)++;
        }
        return false;
    }
    // number, true, false, null
    size_t start = *i;
    while (*i < n && s[*i] != ',' && s[*i] != '}' && s[*i] != ']' && s[*i] != ' ' && s[*i] != '\n' &&
           s[*i] != '\r' && s[*i] != '\t') {
        (*i)++;
    }
    return *i > start;
}

// Finds `key` (length klen) among the members of the object starting at s[0] == '{'.
static bool find_member(const char *s, size_t n, const char *key, size_t klen, pt_span_t *out)
{
    size_t i = 0;
    skip_ws(s, n, &i);
    if (i >= n || s[i] != '{') {
        return false;
    }
    i++;
    for (;;) {
        skip_ws(s, n, &i);
        if (i < n && s[i] == '}') {
            return false;
        }
        size_t kstart = i;
        if (!skip_string(s, n, &i)) {
            return false;
        }
        bool match = (i - kstart - 2 == klen) && memcmp(s + kstart + 1, key, klen) == 0;
        skip_ws(s, n, &i);
        if (i >= n || s[i] != ':') {
            return false;
        }
        i++;
        skip_ws(s, n, &i);
        size_t vstart = i;
        if (!skip_value(s, n, &i)) {
            return false;
        }
        if (match) {
            out->p = s + vstart;
            out->len = i - vstart;
            return true;
        }
        skip_ws(s, n, &i);
        if (i < n && s[i] == ',') {
            i++;
        } else {
            return false;
        }
    }
}

bool pt_json_find(const char *json, size_t len, const char *path, pt_span_t *out)
{
    pt_span_t cur = {json, len};
    const char *k = path;
    while (*k) {
        const char *dot = strchr(k, '.');
        size_t klen = dot ? (size_t)(dot - k) : strlen(k);
        if (!find_member(cur.p, cur.len, k, klen, &cur)) {
            return false;
        }
        k += klen + (dot ? 1 : 0);
    }
    *out = cur;
    return true;
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool put(char *out, size_t cap, size_t *o, char c)
{
    if (*o + 1 >= cap) {
        return false;
    }
    out[(*o)++] = c;
    return true;
}

bool pt_json_string(pt_span_t v, char *out, size_t cap)
{
    if (cap == 0 || v.len < 2 || v.p[0] != '"' || v.p[v.len - 1] != '"') {
        return false;
    }
    size_t o = 0;
    for (size_t i = 1; i + 1 < v.len; i++) {
        char c = v.p[i];
        if (c != '\\') {
            if (!put(out, cap, &o, c)) return false;
            continue;
        }
        if (++i + 1 >= v.len) return false;
        char e = v.p[i];
        char lit = e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == 'b' ? '\b' : e == 'f' ? '\f' : e;
        if (e != 'u') {
            if (!put(out, cap, &o, lit)) return false;
            continue;
        }
        if (i + 4 >= v.len) return false;
        unsigned cp = 0;
        for (int k = 1; k <= 4; k++) {
            int h = hexval(v.p[i + k]);
            if (h < 0) return false;
            cp = cp << 4 | (unsigned)h;
        }
        i += 4;
        // Surrogate pairs.
        if (cp >= 0xD800 && cp < 0xDC00 && i + 6 < v.len && v.p[i + 1] == '\\' && v.p[i + 2] == 'u') {
            unsigned lo = 0;
            for (int k = 3; k <= 6; k++) {
                int h = hexval(v.p[i + k]);
                if (h < 0) return false;
                lo = lo << 4 | (unsigned)h;
            }
            if (lo >= 0xDC00 && lo < 0xE000) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 6;
            }
        }
        if (cp < 0x80) {
            if (!put(out, cap, &o, (char)cp)) return false;
        } else if (cp < 0x800) {
            if (!put(out, cap, &o, (char)(0xC0 | cp >> 6)) || !put(out, cap, &o, (char)(0x80 | (cp & 0x3F)))) return false;
        } else if (cp < 0x10000) {
            if (!put(out, cap, &o, (char)(0xE0 | cp >> 12)) || !put(out, cap, &o, (char)(0x80 | ((cp >> 6) & 0x3F))) ||
                !put(out, cap, &o, (char)(0x80 | (cp & 0x3F)))) return false;
        } else {
            if (!put(out, cap, &o, (char)(0xF0 | cp >> 18)) || !put(out, cap, &o, (char)(0x80 | ((cp >> 12) & 0x3F))) ||
                !put(out, cap, &o, (char)(0x80 | ((cp >> 6) & 0x3F))) || !put(out, cap, &o, (char)(0x80 | (cp & 0x3F)))) return false;
        }
    }
    out[o] = 0;
    return true;
}

bool pt_json_int(pt_span_t v, int64_t *out)
{
    if (v.len == 0) {
        return false;
    }
    size_t i = 0;
    bool neg = false;
    if (v.p[0] == '-') {
        neg = true;
        i = 1;
    }
    if (i >= v.len) {
        return false;
    }
    int64_t r = 0;
    for (; i < v.len; i++) {
        if (v.p[i] < '0' || v.p[i] > '9') {
            return false;
        }
        r = r * 10 + (v.p[i] - '0');
    }
    *out = neg ? -r : r;
    return true;
}

bool pt_json_is_true(pt_span_t v)
{
    return v.len == 4 && memcmp(v.p, "true", 4) == 0;
}

bool pt_json_replace(char *buf, size_t *len, size_t cap, pt_span_t at, const char *text, size_t tlen)
{
    size_t off = (size_t)(at.p - buf);
    if (at.p < buf || off + at.len > *len) {
        return false;
    }
    size_t newlen = *len - at.len + tlen;
    if (newlen > cap) {
        return false;
    }
    memmove(buf + off + tlen, buf + off + at.len, *len - off - at.len);
    memcpy(buf + off, text, tlen);
    *len = newlen;
    return true;
}

void pt_jw_init(pt_jw_t *w, char *buf, size_t cap)
{
    w->buf = buf;
    w->cap = cap;
    w->len = 0;
    w->ok = true;
}

void pt_jw_raw(pt_jw_t *w, const char *s, size_t n)
{
    if (!w->ok || w->len + n > w->cap) {
        w->ok = false;
        return;
    }
    memcpy(w->buf + w->len, s, n);
    w->len += n;
}

void pt_jw_lit(pt_jw_t *w, const char *s)
{
    pt_jw_raw(w, s, strlen(s));
}

void pt_jw_str(pt_jw_t *w, const char *s)
{
    pt_jw_raw(w, "\"", 1);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"': pt_jw_raw(w, "\\\"", 2); break;
        case '\\': pt_jw_raw(w, "\\\\", 2); break;
        case '\n': pt_jw_raw(w, "\\n", 2); break;
        case '\r': pt_jw_raw(w, "\\r", 2); break;
        case '\t': pt_jw_raw(w, "\\t", 2); break;
        case '\b': pt_jw_raw(w, "\\b", 2); break;
        case '\f': pt_jw_raw(w, "\\f", 2); break;
        default:
            if (*p < 0x20) {
                char esc[7];
                snprintf(esc, sizeof esc, "\\u%04x", *p);
                pt_jw_raw(w, esc, 6);
            } else {
                pt_jw_raw(w, (const char *)p, 1);
            }
        }
    }
    pt_jw_raw(w, "\"", 1);
}

void pt_jw_int(pt_jw_t *w, int64_t v)
{
    char tmp[24];
    int n = snprintf(tmp, sizeof tmp, "%lld", (long long)v);
    pt_jw_raw(w, tmp, (size_t)n);
}
