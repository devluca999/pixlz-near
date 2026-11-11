// SPDX-License-Identifier: Apache-2.0
// Portable part of the dock: nonblocking BSD sockets (macOS in the simulator, lwIP on the
// device), PixlzCore framing, the trip node, and the order of outputs (save before send).
#include "include/app_dock.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../pixl_trip/include/pixl_trip/pt_frame.h"
#include "../pixl_trip/include/pixl_trip/pt_json.h"
#include "../pixl_trip/include/pixl_trip/pt_trip.h"
#include "private/app_dock_platform.h"

enum { MAX_CONNS = 3, RX_CAP = PT_MSG_MAX + 4, TX_CAP = 2 * (PT_MSG_MAX + 4), HELLO_MAX = 512 };

#ifdef MSG_NOSIGNAL
#define SEND_FLAGS MSG_NOSIGNAL
#else
#define SEND_FLAGS 0
#endif

typedef struct {
    int fd;              /* -1 = free */
    bool hello;          /* the Mac said who it is */
    pt_device_t peer;
    pt_framer_t framer;
    uint8_t rx[RX_CAP];
    uint8_t tx[TX_CAP];
    size_t tx_len;
} conn_t;

struct app_dock {
    pt_node_t node;
    int listen_fd;
    conn_t conns[MAX_CONNS];
    bool send_requested;
    bool started;
    int battery_percent;
    bool on_battery;
    int64_t next_battery_ms;
    app_dock_event_t pending[8];
    int pending_count;
    /* Instance-owned scratch, so nothing large sits on the caller's task stack. */
    pt_outs_t outs;
    app_dock_feed_t feed;
    uint8_t io[512];
    char hello[HELLO_MAX];
};

static void queue_event(app_dock_handle_t d, app_dock_event_kind_t kind, const char *reason)
{
    if (d->pending_count >= (int)(sizeof d->pending / sizeof d->pending[0])) {
        return;
    }
    app_dock_event_t *e = &d->pending[d->pending_count++];
    e->kind = kind;
    e->reason[0] = 0;
    if (reason) {
        strncpy(e->reason, reason, sizeof e->reason - 1);
        e->reason[sizeof e->reason - 1] = 0;
    }
}

static void set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
#ifdef SO_NOSIGPIPE
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
}

static void close_conn(conn_t *c, const char *why)
{
    if (c->fd < 0) {
        return;
    }
    dock_platform_log("pixlz: %s %s", c->hello ? c->peer.name : "a connection", why);
    close(c->fd);
    c->fd = -1;
    c->hello = false;
    c->tx_len = 0;
}

static void close_all(app_dock_handle_t d)
{
    for (int i = 0; i < MAX_CONNS; i++) {
        close_conn(&d->conns[i], "closed");
    }
    if (d->listen_fd >= 0) {
        close(d->listen_fd);
        d->listen_fd = -1;
    }
}

/* Appends one frame to the connection's send buffer; flushed in poll. */
static bool enqueue(conn_t *c, const char *body, size_t len)
{
    if (c->tx_len + 4 + len > TX_CAP) {
        return false;
    }
    pt_frame_header((uint32_t)len, c->tx + c->tx_len);
    memcpy(c->tx + c->tx_len + 4, body, len);
    c->tx_len += 4 + len;
    return true;
}

static void flush(conn_t *c)
{
    while (c->fd >= 0 && c->tx_len > 0) {
        ssize_t n = send(c->fd, c->tx, c->tx_len, SEND_FLAGS);
        if (n > 0) {
            memmove(c->tx, c->tx + n, c->tx_len - (size_t)n);
            c->tx_len -= (size_t)n;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return;
        } else {
            close_conn(c, "send failed");
        }
    }
}

static conn_t *conn_for(app_dock_handle_t d, const char *peer_id)
{
    conn_t *found = NULL;
    for (int i = 0; i < MAX_CONNS; i++) {
        if (d->conns[i].fd >= 0 && d->conns[i].hello && strcmp(d->conns[i].peer.id, peer_id) == 0) {
            found = &d->conns[i];  /* the latest one wins */
        }
    }
    return found;
}

/* Performs a node call's outputs in order. A failed save stops everything after it, so a
 * message that depends on the save is never sent (SPEC §10.5). */
static void perform(app_dock_handle_t d, const pt_outs_t *outs)
{
    for (int i = 0; i < outs->count; i++) {
        const pt_out_t *o = &outs->items[i];
        switch (o->kind) {
        case PT_OUT_SAVED:
            if (!dock_platform_save(&d->node.record)) {
                dock_platform_log("pixlz: couldn't save the record; stopping this step");
                return;
            }
            break;
        case PT_OUT_SEND: {
            conn_t *c = conn_for(d, o->peer.id);
            if (!c || !enqueue(c, o->body, o->len)) {
                dock_platform_log("pixlz: no room to send to %s", o->peer.name);
            }
            break;
        }
        case PT_OUT_PLAY_EXIT:
            queue_event(d, APP_DOCK_EVENT_LEFT, NULL);
            break;
        case PT_OUT_PLAY_ENTRANCE:
            queue_event(d, APP_DOCK_EVENT_ARRIVED, NULL);
            break;
        case PT_OUT_SHRUG:
            queue_event(d, APP_DOCK_EVENT_SHRUG, o->reason);
            break;
        }
    }
}

app_dock_handle_t app_dock_create(void)
{
    app_dock_handle_t d = calloc(1, sizeof *d);
    if (!d) {
        return NULL;
    }
    pt_device_t me;
    dock_platform_device(&me);
    pt_node_init(&d->node, &me, dock_platform_random, NULL);
    if (!dock_platform_load(&d->node.record)) {
        d->node.record.kind = PT_REC_NONE;
    }
    d->listen_fd = -1;
    d->battery_percent = -1;
    for (int i = 0; i < MAX_CONNS; i++) {
        d->conns[i].fd = -1;
    }
    dock_platform_start(&me);
    d->started = true;
    dock_platform_log("pixlz: %s (%s) ready; holds %s", me.name, me.id,
                      d->node.record.kind == PT_REC_OWNED ? "the Pixl" : "no Pixl");
    return d;
}

void app_dock_destroy(app_dock_handle_t *handle)
{
    if (!handle || !*handle) {
        return;
    }
    close_all(*handle);
    if ((*handle)->started) {
        dock_platform_stop();
    }
    free(*handle);
    *handle = NULL;
}

static void open_listener(app_dock_handle_t d)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return;
    }
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(APP_DOCK_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 2) < 0) {
        dock_platform_log("pixlz: can't listen on port %d (errno %d)", APP_DOCK_PORT, errno);
        close(fd);
        return;
    }
    set_nonblocking(fd);
    d->listen_fd = fd;
    dock_platform_log("pixlz: listening on port %d", APP_DOCK_PORT);
}

static void accept_new(app_dock_handle_t d)
{
    for (;;) {
        int fd = accept(d->listen_fd, NULL, NULL);
        if (fd < 0) {
            return;
        }
        conn_t *c = NULL;
        for (int i = 0; i < MAX_CONNS && !c; i++) {
            if (d->conns[i].fd < 0) {
                c = &d->conns[i];
            }
        }
        if (!c) {
            close(fd);  /* full */
            continue;
        }
        set_nonblocking(fd);
        c->fd = fd;
        c->hello = false;
        memset(&c->peer, 0, sizeof c->peer);
        c->tx_len = 0;
        pt_framer_init(&c->framer, c->rx, sizeof c->rx);
        /* No greeting: a spike client (PixlzSend) says hello first and gets one back; the Mac
         * app's BonjourTransport sends envelopes straight away and never expects a hello. */
    }
}

/* The first frame says who the client is: a spike hello, or an envelope's `from` and
 * `payload.fromName` (how the Mac app's BonjourTransport identifies itself). */
static bool identify(app_dock_handle_t d, conn_t *c, const char *body, size_t len)
{
    if (pt_hello_parse(body, len, &c->peer)) {
        size_t n = pt_hello_encode(&d->node.me, d->hello, sizeof d->hello);
        if (n) {
            enqueue(c, d->hello, n);
        }
        pt_span_t ms_span;
        int64_t mac_ms = 0;
        if (pt_json_find(body, len, "hello.unixMs", &ms_span) && pt_json_int(ms_span, &mac_ms)) {
            dock_platform_offer_clock(mac_ms);
        }
        return true;
    }
    pt_span_t v;
    if (!pt_json_find(body, len, "from", &v) || !pt_json_string(v, c->peer.id, sizeof c->peer.id)) {
        return false;
    }
    if ((!pt_json_find(body, len, "payload.fromName", &v) && !pt_json_find(body, len, "fromName", &v)) ||
            !pt_json_string(v, c->peer.name, sizeof c->peer.name)) {
        snprintf(c->peer.name, sizeof c->peer.name, "%s", c->peer.id);
    }
    return false;  /* an envelope: handle it as one too */
}

/* `{"feed":{"answers":[{"q","a"}…],"highlights":[{"title","text"}…]}}` from a Mac. */
static void read_feed_list(pt_span_t feed, const char *path, const char *title_key, const char *body_key,
                           app_dock_feed_item_t *items, int *count)
{
    pt_span_t list, item, v;
    *count = 0;
    if (!pt_json_find(feed.p, feed.len, path, &list)) {
        return;
    }
    for (int i = 0; *count < APP_DOCK_FEED_ITEMS && pt_json_array_item(list, i, &item); i++) {
        app_dock_feed_item_t *out = &items[*count];
        out->title[0] = out->body[0] = 0;
        if (pt_json_find(item.p, item.len, title_key, &v)) {
            (void)pt_json_string(v, out->title, sizeof out->title);
        }
        if (pt_json_find(item.p, item.len, body_key, &v) && pt_json_string(v, out->body, sizeof out->body)) {
            (*count)++;
        }
    }
}

static bool handle_feed(app_dock_handle_t d, const conn_t *c, const char *body, size_t len)
{
    pt_span_t feed;
    if (!pt_json_find(body, len, "feed", &feed)) {
        return false;
    }
    read_feed_list(feed, "answers", "q", "a", d->feed.answers, &d->feed.answers_count);
    read_feed_list(feed, "highlights", "title", "text", d->feed.memory, &d->feed.memory_count);
    d->feed.version++;
    dock_platform_log("pixlz: feed from %s: %d answers, %d highlights", c->peer.name, d->feed.answers_count,
                      d->feed.memory_count);
    return true;
}

static void handle_frame(app_dock_handle_t d, conn_t *c, const char *body, size_t len)
{
    if (!c->hello) {
        bool was_hello = identify(d, c, body, len);
        if (!c->peer.id[0]) {
            close_conn(c, "didn't say who it is");
            return;
        }
        c->hello = true;
        dock_platform_log("pixlz: %s connected (clock %s)", c->peer.name,
                          dock_platform_clock_ok() ? "set" : "not set");
        // Ask who has the Pixl, whatever the first frame was: a Mac that brought it back while
        // this device was off owns a newer copy, and this one gives way (SPEC §10.5).
        pt_node_connected(&d->node, &c->peer, dock_platform_now_ms(), &d->outs);
        perform(d, &d->outs);
        if (was_hello) {
            return;
        }
    }
    if (handle_feed(d, c, body, len)) {
        return;
    }
    pt_node_received(&d->node, &c->peer, body, len, dock_platform_now_ms(), &d->outs);
    perform(d, &d->outs);
}

static void read_conn(app_dock_handle_t d, conn_t *c)
{
    uint8_t *buf = d->io;
    while (c->fd >= 0) {
        ssize_t n = recv(c->fd, buf, sizeof d->io, 0);
        if (n == 0) {
            close_conn(c, "hung up");
            return;
        }
        if (n < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                close_conn(c, "receive failed");
            }
            return;
        }
        size_t off = 0;
        while (off < (size_t)n && c->fd >= 0) {
            off += pt_framer_feed(&c->framer, buf + off, (size_t)n - off);
            const uint8_t *body;
            size_t len;
            while (c->fd >= 0 && pt_framer_next(&c->framer, &body, &len)) {
                handle_frame(d, c, (const char *)body, len);
                pt_framer_pop(&c->framer);
            }
            if (c->framer.too_large) {
                close_conn(c, "sent a frame too large");
            }
        }
    }
}

int app_dock_poll(app_dock_handle_t d, app_dock_event_t *events, int max)
{
    if (!d) {
        return 0;
    }
    d->node.can_host = dock_platform_clock_ok();
    if (dock_platform_take_forget_request()) {
        pt_rec_kind_t kind = d->node.record.kind;
        if (kind == PT_REC_AWAY || kind == PT_REC_NONE) {
            d->node.record.kind = PT_REC_NONE;
            d->node.record.state_len = 0;
            d->node.record.pet_id[0] = 0;
            dock_platform_log("pixlz: forgot the away record (%s)",
                              dock_platform_save(&d->node.record) ? "saved" : "not saved");
        } else {
            dock_platform_log("pixlz: refused to forget: a Pixl is here");
        }
    }
    int64_t now = dock_platform_now_ms();
    if (now >= d->next_battery_ms) {
        d->next_battery_ms = now + 5000;
        int pct;
        bool on_battery;
        if (dock_platform_battery(&pct, &on_battery)) {
            d->battery_percent = pct;
            d->on_battery = on_battery;
        }
    }
    if (dock_platform_net_ready()) {
        if (d->listen_fd < 0) {
            open_listener(d);
        }
        if (d->listen_fd >= 0) {
            accept_new(d);
        }
    } else if (d->listen_fd >= 0) {
        close_all(d);
    }
    for (int i = 0; i < MAX_CONNS; i++) {
        read_conn(d, &d->conns[i]);
    }

    pt_outs_t *outs = &d->outs;
    if (d->send_requested) {
        d->send_requested = false;
        conn_t *mac = NULL;
        for (int i = 0; i < MAX_CONNS && !mac; i++) {
            if (d->conns[i].fd >= 0 && d->conns[i].hello) {
                mac = &d->conns[i];
            }
        }
        if (!dock_platform_clock_ok()) {
            queue_event(d, APP_DOCK_EVENT_SHRUG, "noClock");
        } else if (!mac) {
            queue_event(d, APP_DOCK_EVENT_SHRUG, "noMac");
        } else {
            pt_node_send(&d->node, &mac->peer, dock_platform_now_ms(), outs);
            perform(d, outs);
            if (outs->count == 0) {
                queue_event(d, APP_DOCK_EVENT_SHRUG, "notHere");
            }
        }
    }
    int64_t deadline = pt_node_deadline(&d->node);
    if (deadline && dock_platform_now_ms() >= deadline) {
        pt_node_tick(&d->node, dock_platform_now_ms(), outs);
        perform(d, outs);
    }
    for (int i = 0; i < MAX_CONNS; i++) {
        flush(&d->conns[i]);
    }

    int n = 0;
    for (; n < d->pending_count && n < max; n++) {
        events[n] = d->pending[n];
    }
    memmove(d->pending, d->pending + n, (size_t)(d->pending_count - n) * sizeof d->pending[0]);
    d->pending_count -= n;
    return n;
}

bool app_dock_call(app_dock_handle_t d)
{
    if (!d || d->node.record.kind != PT_REC_AWAY) {
        return false;
    }
    for (int i = 0; i < MAX_CONNS; i++) {
        conn_t *c = &d->conns[i];
        if (c->fd >= 0 && c->hello) {
            pt_node_call(&d->node, &c->peer, dock_platform_now_ms(), &d->outs);
            perform(d, &d->outs);
            dock_platform_log("pixlz: calling the Pixl from %s", c->peer.name);
            return d->outs.count > 0;
        }
    }
    return false;
}

bool app_dock_bring(app_dock_handle_t d)
{
    if (!d) {
        return false;
    }
    char away[PT_NAME_MAX];
    snprintf(away, sizeof away, "%s", d->node.record.away_name);
    if (!pt_node_reclaim(&d->node, dock_platform_now_ms(), &d->outs)) {
        return false;
    }
    dock_platform_log("pixlz: brought the Pixl back (%s didn't answer)", away);
    perform(d, &d->outs);
    return true;
}

bool app_dock_exit(app_dock_handle_t d)
{
    if (!d) {
        return false;
    }
    for (int i = 0; i < MAX_CONNS; i++) {
        close_conn(&d->conns[i], "leaving for Vibe Mode");
    }
    return dock_platform_enter_vibe_mode();
}

void app_dock_send_home(app_dock_handle_t d)
{
    if (d) {
        d->send_requested = true;
    }
}

app_dock_status_t app_dock_status(app_dock_handle_t d)
{
    app_dock_status_t s = {0};
    if (!d) {
        return s;
    }
    s.network_ready = dock_platform_net_ready();
    s.clock_ok = dock_platform_clock_ok();
    for (int i = 0; i < MAX_CONNS; i++) {
        s.macs += d->conns[i].fd >= 0 && d->conns[i].hello;
    }
    s.in_trip = pt_node_in_trip(&d->node);
    s.owns_pet = d->node.record.kind == PT_REC_OWNED;
    s.battery_percent = d->battery_percent;
    s.on_battery = d->on_battery;
    s.locked = pt_node_locked(&d->node);
    s.can_call = d->node.record.kind == PT_REC_AWAY && s.macs > 0;
    s.can_bring = s.macs == 0 && pt_node_can_reclaim(&d->node);
    if (d->node.record.kind == PT_REC_AWAY) {
        snprintf(s.away_on, sizeof s.away_on, "%s", d->node.record.away_name);
    }
    return s;
}

const app_dock_feed_t *app_dock_feed(app_dock_handle_t d)
{
    return d ? &d->feed : NULL;
}

bool app_dock_set_locked(app_dock_handle_t d, bool locked)
{
    if (!d || !pt_node_set_locked(&d->node, locked)) {
        return false;
    }
    bool saved = dock_platform_save(&d->node.record);
    dock_platform_log("pixlz: %s (%s)", locked ? "locked to this device" : "unlocked", saved ? "saved" : "NOT saved");
    return true;
}

void app_dock_set_known_species(app_dock_handle_t d, const char *const *ids, int count)
{
    if (d && ids && count > 0) {
        d->node.known_species = ids;
        d->node.known_count = count;
    }
}

bool app_dock_pet_species(app_dock_handle_t d, char *out, int cap)
{
    pt_span_t v;
    return d && d->node.record.kind == PT_REC_OWNED &&
           pt_json_find(d->node.record.state, d->node.record.state_len, "species", &v) &&
           pt_json_string(v, out, (size_t)cap);
}

void app_dock_load_look(char *out, int cap)
{
    if (out && cap > 0) {
        out[0] = 0;
        dock_platform_load_look(out, (size_t)cap);
    }
}

void app_dock_save_look(const char *id)
{
    if (id && !dock_platform_save_look(id)) {
        dock_platform_log("pixlz: couldn't save the look");
    }
}
