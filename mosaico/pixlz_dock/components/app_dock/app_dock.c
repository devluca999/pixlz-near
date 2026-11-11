// SPDX-License-Identifier: Apache-2.0
// Portable part of the dock: nonblocking BSD sockets (macOS in the simulator, lwIP on the
// device), PixlzCore framing, the trip node, and the order of outputs (save before send).
#include "include/app_dock.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
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
    app_dock_event_t pending[8];
    int pending_count;
    /* Instance-owned scratch, so nothing large sits on the caller's task stack. */
    pt_outs_t outs;
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
        c->tx_len = 0;
        pt_framer_init(&c->framer, c->rx, sizeof c->rx);
        size_t n = pt_hello_encode(&d->node.me, d->hello, sizeof d->hello);
        if (n) {
            enqueue(c, d->hello, n);
        }
    }
}

static void handle_frame(app_dock_handle_t d, conn_t *c, const char *body, size_t len)
{
    if (!c->hello) {
        if (!pt_hello_parse(body, len, &c->peer)) {
            close_conn(c, "didn't say hello");
            return;
        }
        c->hello = true;
        pt_span_t ms_span;
        int64_t mac_ms = 0;
        if (pt_json_find(body, len, "hello.unixMs", &ms_span) && pt_json_int(ms_span, &mac_ms)) {
            dock_platform_offer_clock(mac_ms);
        }
        dock_platform_log("pixlz: %s connected (clock %s)", c->peer.name,
                          dock_platform_clock_ok() ? "set" : "not set");
        pt_node_connected(&d->node, &c->peer, dock_platform_now_ms(), &d->outs);
        perform(d, &d->outs);
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
    return s;
}
