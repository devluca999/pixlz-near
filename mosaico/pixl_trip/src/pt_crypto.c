// SPDX-License-Identifier: Apache-2.0
// X25519 after TweetNaCl's crypto_scalarmult (public domain): 16 limbs of 16 bits, constant
// time ladder. HMAC and HKDF over pt_sha256.
#include "../include/pixl_trip/pt_crypto.h"

#include <string.h>

#include "../include/pixl_trip/pt_sha256.h"

typedef int64_t gf[16];

static const gf k121665 = {0xDB41, 1};

static void car25519(gf o)
{
    for (int i = 0; i < 16; i++) {
        o[i] += (int64_t)1 << 16;
        int64_t c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        o[i] -= c * 65536;
    }
}

static void sel25519(gf p, gf q, int64_t b)
{
    int64_t c = ~(b - 1);
    for (int i = 0; i < 16; i++) {
        int64_t t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

static void pack25519(uint8_t o[32], const gf n)
{
    gf m, t;
    memcpy(t, n, sizeof t);
    car25519(t);
    car25519(t);
    car25519(t);
    for (int j = 0; j < 2; j++) {
        m[0] = t[0] - 0xffed;
        for (int i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        int64_t b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        sel25519(t, m, 1 - b);
    }
    for (int i = 0; i < 16; i++) {
        o[2 * i] = (uint8_t)(t[i] & 0xff);
        o[2 * i + 1] = (uint8_t)(t[i] >> 8);
    }
}

static void unpack25519(gf o, const uint8_t n[32])
{
    for (int i = 0; i < 16; i++) {
        o[i] = n[2 * i] + ((int64_t)n[2 * i + 1] << 8);
    }
    o[15] &= 0x7fff;
}

static void add(gf o, const gf a, const gf b)
{
    for (int i = 0; i < 16; i++) o[i] = a[i] + b[i];
}

static void sub(gf o, const gf a, const gf b)
{
    for (int i = 0; i < 16; i++) o[i] = a[i] - b[i];
}

static void mul(gf o, const gf a, const gf b)
{
    int64_t t[31] = {0};
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
    for (int i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
    for (int i = 0; i < 16; i++) o[i] = t[i];
    car25519(o);
    car25519(o);
}

static void sqr(gf o, const gf a) { mul(o, a, a); }

static void inv25519(gf o, const gf in)
{
    gf c;
    memcpy(c, in, sizeof c);
    for (int a = 253; a >= 0; a--) {
        sqr(c, c);
        if (a != 2 && a != 4) mul(c, c, in);
    }
    memcpy(o, c, sizeof c);
}

/* Work space kept off the caller's stack (the device's tasks have small stacks). */
static struct {
    uint8_t z[32];
    gf x, a, b, c, d, e, f;
} s_w;

bool pt_x25519(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32])
{
    uint8_t *z = s_w.z;
    memcpy(z, scalar, 32);
    z[31] = (uint8_t)((scalar[31] & 127) | 64);
    z[0] &= 248;
    unpack25519(s_w.x, point);
    memcpy(s_w.b, s_w.x, sizeof(gf));
    memset(s_w.a, 0, sizeof(gf));
    memset(s_w.c, 0, sizeof(gf));
    memset(s_w.d, 0, sizeof(gf));
    s_w.a[0] = s_w.d[0] = 1;
    for (int i = 254; i >= 0; --i) {
        int64_t r = (z[i >> 3] >> (i & 7)) & 1;
        sel25519(s_w.a, s_w.b, r);
        sel25519(s_w.c, s_w.d, r);
        add(s_w.e, s_w.a, s_w.c);
        sub(s_w.a, s_w.a, s_w.c);
        add(s_w.c, s_w.b, s_w.d);
        sub(s_w.b, s_w.b, s_w.d);
        sqr(s_w.d, s_w.e);
        sqr(s_w.f, s_w.a);
        mul(s_w.a, s_w.c, s_w.a);
        mul(s_w.c, s_w.b, s_w.e);
        add(s_w.e, s_w.a, s_w.c);
        sub(s_w.a, s_w.a, s_w.c);
        sqr(s_w.b, s_w.a);
        sub(s_w.c, s_w.d, s_w.f);
        mul(s_w.a, s_w.c, k121665);
        add(s_w.a, s_w.a, s_w.d);
        mul(s_w.c, s_w.c, s_w.a);
        mul(s_w.a, s_w.d, s_w.f);
        mul(s_w.d, s_w.b, s_w.x);
        sqr(s_w.b, s_w.e);
        sel25519(s_w.a, s_w.b, r);
        sel25519(s_w.c, s_w.d, r);
    }
    inv25519(s_w.c, s_w.c);
    mul(s_w.a, s_w.a, s_w.c);
    pack25519(out, s_w.a);
    memset(&s_w, 0, sizeof s_w);
    uint8_t any = 0;
    for (int i = 0; i < 32; i++) any |= out[i];
    return any != 0;
}

void pt_x25519_public(uint8_t out[32], const uint8_t scalar[32])
{
    static const uint8_t nine[32] = {9};
    (void)pt_x25519(out, scalar, nine);
}

void pt_hmac_sha256(const uint8_t *key, size_t key_len, const void *msg, size_t msg_len, uint8_t out[32])
{
    static uint8_t k[64], pad[64], inner[32];
    static pt_sha256_t c;
    memset(k, 0, sizeof k);
    if (key_len > 64) {
        pt_sha256_init(&c);
        pt_sha256_update(&c, key, key_len);
        pt_sha256_final(&c, k);
    } else if (key_len) {
        memcpy(k, key, key_len);
    }
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x36;
    pt_sha256_init(&c);
    pt_sha256_update(&c, pad, 64);
    pt_sha256_update(&c, msg, msg_len);
    pt_sha256_final(&c, inner);
    for (int i = 0; i < 64; i++) pad[i] = k[i] ^ 0x5c;
    pt_sha256_init(&c);
    pt_sha256_update(&c, pad, 64);
    pt_sha256_update(&c, inner, 32);
    pt_sha256_final(&c, out);
    memset(k, 0, sizeof k);
}

void pt_hkdf_sha256(const uint8_t *ikm, size_t ikm_len, const uint8_t *salt, size_t salt_len, const char *info,
                    uint8_t out[32])
{
    static uint8_t prk[32], msg[96];
    static const uint8_t zeros[32] = {0};
    pt_hmac_sha256(salt_len ? salt : zeros, salt_len ? salt_len : 32, ikm, ikm_len, prk);
    size_t n = strlen(info);
    if (n > sizeof msg - 1) n = sizeof msg - 1;
    memcpy(msg, info, n);
    msg[n] = 1;
    pt_hmac_sha256(prk, 32, msg, n + 1, out);
    memset(prk, 0, sizeof prk);
}

void pt_hex(const uint8_t *bytes, size_t len, char *hex)
{
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        hex[2 * i] = digits[bytes[i] >> 4];
        hex[2 * i + 1] = digits[bytes[i] & 15];
    }
    hex[2 * len] = 0;
}

static int nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool pt_unhex(const char *hex, uint8_t *out, size_t len)
{
    if (!hex || strlen(hex) != 2 * len) return false;
    for (size_t i = 0; i < len; i++) {
        int hi = nibble(hex[2 * i]), lo = nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)(hi << 4 | lo);
    }
    return true;
}

bool pt_equal(const uint8_t *a, const uint8_t *b, size_t len)
{
    uint8_t d = 0;
    for (size_t i = 0; i < len; i++) d |= a[i] ^ b[i];
    return d == 0;
}
