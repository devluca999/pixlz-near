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
#if defined(__has_include)
#if __has_include(<netinet/tcp.h>)
#include <netinet/tcp.h>
#endif
#endif

#include "../pixl_trip/include/pixl_trip/pt_frame.h"
#include "../pixl_trip/include/pixl_trip/pt_json.h"
#include "../pixl_trip/include/pixl_trip/pt_pair.h"
#include "../pixl_trip/include/pixl_trip/pt_trip.h"
#include "private/app_dock_platform.h"

enum { MAX_CONNS = 3, RX_CAP = PT_MSG_MAX + 4, TX_CAP = 2 * (PT_MSG_MAX + 4), HELLO_MAX = 512 };
/* A Wi-Fi connection that says nothing for 5 minutes is gone (TCP keepalive finds most sooner). */
enum { IDLE_CLOSE_MS = 5 * 60 * 1000, RECHECK_MS = 60 * 1000 };

#ifdef MSG_NOSIGNAL
#define SEND_FLAGS MSG_NOSIGNAL
#else
#define SEND_FLAGS 0
#endif

typedef struct {
    int fd;              /* -1 = free */
    bool hello;          /* the Mac said who it is */
    bool local;          /* from this device (the Bluetooth bridge, 127.0.0.1): survives Wi-Fi loss */
    int64_t last_rx_ms;  /* uptime of the last bytes received */
    int64_t hello_ms;    /* uptime when it said who it is */
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
    bool net_was_ready;
    bool started;
    bool exited;              /* switched to Vibe Mode: nothing more to do */
    bool store_bad;           /* a saved record exists but can't be read (kept aside) */
    int battery_percent;
    bool on_battery;
    int64_t next_battery_ms;
    int64_t next_recheck_ms;  /* pending: ask the Macs again (uptime) */
    app_dock_event_t pending[8];
    int pending_count;
    /* Instance-owned scratch, so nothing large sits on the caller's task stack. */
    pt_outs_t outs;
    pt_outs_t outs_fail;      /* what a failed save sends (perform's own outs are abandoned) */
    pt_record_t record_copy;  /* lock and forget: commit to memory only once saved */
    app_dock_feed_t feed;
    char feed_from[PT_ID_MAX];
    app_dock_agents_t agents;
    char agents_from[PT_ID_MAX];
    app_dock_chat_t chat;
    app_dock_transcript_t transcript;
    struct {                       /* a dictation clip streaming to the Mac */
        const uint8_t *clip;
        size_t len, sent;
        int part;
        bool active;
    } up;
    uint32_t dictation_n;
    char frame[2400];
    pt_pair_t pair;
    pt_pair_record_t paired;
    pt_pair_record_t pair_new;  /* a pairing until it's saved */
    pt_pair_out_t pair_out;
    uint8_t rnd[32];
    char decision[400];
    uint8_t io[512];
    char hello[HELLO_MAX];
};

static void copy_str(char *dst, size_t cap, const char *src)
{
    size_t n = 0;
    while (src && n + 1 < cap && src[n]) {
        n++;
    }
    memcpy(dst, src ? src : "", n);
    dst[n] = 0;
}

static void queue_event(app_dock_handle_t d, app_dock_event_kind_t kind, const char *reason)
{
    if (d->pending_count >= (int)(sizeof d->pending / sizeof d->pending[0])) {
        return;
    }
    app_dock_event_t *e = &d->pending[d->pending_count++];
    e->kind = kind;
    copy_str(e->reason, sizeof e->reason, reason);   /* cut to fit */
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

/* A Mac that drops off Wi-Fi without closing is noticed in ~1 min: idle 30 s, then 3 probes 10 s apart. */
static void keep_alive(int fd)
{
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
#if defined(TCP_KEEPIDLE)
    int idle = 30;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof idle);
#elif defined(TCP_KEEPALIVE)
    int idle = 30;   /* macOS's name for it */
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof idle);
#endif
#if defined(TCP_KEEPINTVL)
    int interval = 10;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof interval);
#endif
#if defined(TCP_KEEPCNT)
    int count = 3;
    (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof count);
#endif
}

static bool id_connected(app_dock_handle_t d, const char *peer_id)
{
    for (int i = 0; i < MAX_CONNS; i++) {
        if (d->conns[i].fd >= 0 && d->conns[i].hello && strcmp(d->conns[i].peer.id, peer_id) == 0) {
            return true;
        }
    }
    return false;
}

/* The agents list, its chat and the feed belong to the Mac that sent them: when it's gone, so are they. */
static void drop_from(app_dock_handle_t d, const char *peer_id)
{
    if (!peer_id[0] || id_connected(d, peer_id)) {
        return;
    }
    if (strcmp(d->agents_from, peer_id) == 0) {
        d->agents.count = d->agents.waiting = 0;
        d->agents.alerts = false;
        d->agents.version++;
        d->agents_from[0] = 0;
        d->chat.id[0] = d->chat.title[0] = 0;
        d->chat.count = 0;
        d->chat.version++;
    }
    if (strcmp(d->feed_from, peer_id) == 0) {
        d->feed.answers_count = d->feed.memory_count = 0;
        d->feed.version++;
        d->feed_from[0] = 0;
    }
}

static void close_conn(app_dock_handle_t d, conn_t *c, const char *why)
{
    if (c->fd < 0) {
        return;
    }
    dock_platform_log("pixlz: %.*s %s", PT_NAME_MAX - 1, c->hello ? c->peer.name : "a connection", why);
    close(c->fd);
    c->fd = -1;
    const bool was = c->hello;
    c->hello = false;
    c->tx_len = 0;
    if (was) {
        drop_from(d, c->peer.id);
    }
}

static void close_all(app_dock_handle_t d)
{
    for (int i = 0; i < MAX_CONNS; i++) {
        close_conn(d, &d->conns[i], "closed");
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

static void flush(app_dock_handle_t d, conn_t *c)
{
    while (c->fd >= 0 && c->tx_len > 0) {
        ssize_t n = send(c->fd, c->tx, c->tx_len, SEND_FLAGS);
        if (n > 0) {
            memmove(c->tx, c->tx + n, c->tx_len - (size_t)n);
            c->tx_len -= (size_t)n;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return;
        } else {
            close_conn(d, c, "send failed");
        }
    }
}

/* The identified connection to `peer_id`; the most recent one when there are two. */
static conn_t *conn_for(app_dock_handle_t d, const char *peer_id)
{
    conn_t *found = NULL;
    for (int i = 0; peer_id && peer_id[0] && i < MAX_CONNS; i++) {
        conn_t *c = &d->conns[i];
        if (c->fd >= 0 && c->hello && strcmp(c->peer.id, peer_id) == 0 && (!found || c->hello_ms >= found->hello_ms)) {
            found = c;
        }
    }
    return found;
}

/* The device holding the Pixl, if it's connected: by id, else (older records) by name. */
static conn_t *holder_conn(app_dock_handle_t d)
{
    const pt_record_t *r = &d->node.record;
    if (r->kind != PT_REC_AWAY) {
        return NULL;
    }
    conn_t *c = conn_for(d, r->away_id);
    for (int i = 0; !c && !r->away_id[0] && r->away_name[0] && i < MAX_CONNS; i++) {
        conn_t *o = &d->conns[i];
        if (o->fd >= 0 && o->hello && strcmp(o->peer.name, r->away_name) == 0) {
            c = o;
        }
    }
    return c;
}

/* Reads the saved record into the node. Unreadable: no Pixl in memory, and offers are declined
 * until it's forgotten (the platform keeps the bytes). */
static void load_record(app_dock_handle_t d)
{
    pt_record_t *r = &d->node.record;
    dock_load_t got = dock_platform_load(r);
    if (got == DOCK_LOAD_OK) {
        return;
    }
    if (got == DOCK_LOAD_BAD) {
        d->store_bad = true;
        dock_platform_log("pixlz: the saved Pixl can't be read; kept aside, offers declined until it's forgotten");
    }
    r->kind = PT_REC_NONE;
    r->epoch = 0;
    r->state_len = 0;
    r->pet_id[0] = r->away_id[0] = r->away_name[0] = 0;
}

static bool perform(app_dock_handle_t d, const pt_outs_t *outs);

/* A save failed: what's on disk is the truth. Reload it, end any trip, and say so. */
static void save_failed(app_dock_handle_t d)
{
    dock_platform_log("pixlz: couldn't save the record; back to the saved one");
    load_record(d);
    if (pt_node_abort(&d->node, "saveFailed", dock_platform_now_ms(), &d->outs_fail)) {
        (void)perform(d, &d->outs_fail);   /* sends only */
    }
    queue_event(d, APP_DOCK_EVENT_SHRUG, "saveFailed");
}

/* Performs a node call's outputs in order. A failed save stops everything after it, so a
 * message that depends on the save is never sent (SPEC §10.5). False when a save failed. */
static bool perform(app_dock_handle_t d, const pt_outs_t *outs)
{
    for (int i = 0; i < outs->count; i++) {
        const pt_out_t *o = &outs->items[i];
        switch (o->kind) {
        case PT_OUT_SAVED:
            if (!dock_platform_save(&d->node.record)) {
                save_failed(d);
                return false;
            }
            break;
        case PT_OUT_SEND: {
            conn_t *c = conn_for(d, o->peer.id);
            if (!c || !enqueue(c, o->body, o->len)) {
                dock_platform_log("pixlz: no room to send to %.*s", PT_NAME_MAX - 1, o->peer.name);
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
    return true;
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
    load_record(d);
    if (!dock_platform_load_pair(&d->paired)) {
        memset(&d->paired, 0, sizeof d->paired);
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
        struct sockaddr_in from;
        socklen_t from_len = sizeof from;
        int fd = accept(d->listen_fd, (struct sockaddr *)&from, &from_len);
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
        c->local = from.sin_family == AF_INET && ntohl(from.sin_addr.s_addr) == INADDR_LOOPBACK;
        if (!c->local) {
            keep_alive(fd);
        }
        c->last_rx_ms = dock_platform_uptime_ms();
        c->hello_ms = 0;
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
        copy_str(c->peer.name, sizeof c->peer.name, c->peer.id);
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
    copy_str(d->feed_from, sizeof d->feed_from, c->peer.id);
    dock_platform_log("pixlz: feed from %.*s: %d answers, %d highlights", PT_NAME_MAX - 1, c->peer.name,
                      d->feed.answers_count, d->feed.memory_count);
    return true;
}

static void copy_field(pt_span_t o, const char *key, char *out, size_t cap)
{
    pt_span_t v;
    out[0] = 0;
    if (pt_json_find(o.p, o.len, key, &v) && !pt_json_string(v, out, cap)) {
        out[0] = 0;
    }
}

/* `{"agents":{"alerts":bool,"sessions":[{id,project,doing,req?,summary?,detail?,answerable?}]}}` */
static bool handle_agents(app_dock_handle_t d, const conn_t *c, const char *body, size_t len)
{
    pt_span_t agents, list, item, v;
    if (!pt_json_find(body, len, "agents", &agents)) {
        return false;
    }
    app_dock_agents_t *a = &d->agents;
    a->alerts = pt_json_find(agents.p, agents.len, "alerts", &v) && pt_json_is_true(v);
    a->count = a->waiting = 0;
    if (pt_json_find(agents.p, agents.len, "sessions", &list)) {
        for (int i = 0; a->count < APP_DOCK_AGENTS && pt_json_array_item(list, i, &item); i++) {
            app_dock_agent_t *s = &a->items[a->count];
            copy_field(item, "id", s->id, sizeof s->id);
            copy_field(item, "project", s->project, sizeof s->project);
            copy_field(item, "doing", s->doing, sizeof s->doing);
            copy_field(item, "req", s->req, sizeof s->req);
            copy_field(item, "summary", s->summary, sizeof s->summary);
            copy_field(item, "detail", s->detail, sizeof s->detail);
            s->answerable = pt_json_find(item.p, item.len, "answerable", &v) && pt_json_is_true(v);
            s->reply_open = pt_json_find(item.p, item.len, "reply", &v) && pt_json_is_true(v);
            copy_field(item, "queued", s->queued, sizeof s->queued);
            if (!s->id[0]) {
                continue;
            }
            a->waiting += s->req[0] != 0;
            a->count++;
        }
    }
    a->version++;
    if (strcmp(d->agents_from, c->peer.id) != 0) {
        d->chat.id[0] = 0;   /* another Mac's sessions: the chat asked for isn't one of them */
        d->chat.count = 0;
        d->chat.version++;
    }
    copy_str(d->agents_from, sizeof d->agents_from, c->peer.id);
    dock_platform_log("pixlz: agents from %.*s: %d sessions, %d waiting", PT_NAME_MAX - 1, c->peer.name, a->count,
                      a->waiting);
    return true;
}

/* What pt_pair asked for: a reply, the code on screen, saving, or an end. The new pairing is
 * used only once it's saved. */
static void apply_pair(app_dock_handle_t d, conn_t *c, const char *peer_name)
{
    pt_pair_out_t *o = &d->pair_out;
    if (o->reply[0] && c) {
        (void)enqueue(c, o->reply, strlen(o->reply));
    }
    if (o->show_code) {
        queue_event(d, APP_DOCK_EVENT_PAIR_CODE, d->pair.code);
    }
    if (o->paired) {
        if (dock_platform_save_pair(&d->pair_new)) {
            d->paired = d->pair_new;
            dock_platform_log("pixlz: paired with %.*s (saved)", PT_NAME_MAX - 1, d->paired.mac_name);
            queue_event(d, APP_DOCK_EVENT_PAIRED, d->paired.mac_name);
        } else {
            dock_platform_log("pixlz: pairing with %.*s couldn't be saved; not paired", PT_NAME_MAX - 1, peer_name);
            queue_event(d, APP_DOCK_EVENT_PAIR_ENDED, "saveFailed");
        }
    }
    memset(&d->pair_new, 0, sizeof d->pair_new);   /* no key copy left behind */
    if (o->cancelled) {
        dock_platform_log("pixlz: pairing with %.*s ended", PT_NAME_MAX - 1, peer_name);
        queue_event(d, APP_DOCK_EVENT_PAIR_ENDED, NULL);
    }
}

static bool handle_pair(app_dock_handle_t d, conn_t *c, const char *body, size_t len)
{
    dock_platform_random(NULL, d->rnd, sizeof d->rnd);
    d->pair_new = d->paired;
    bool used = pt_pair_receive(&d->pair, &d->pair_new, &d->node.me, &c->peer, body, len, d->rnd,
                                dock_platform_now_ms(), &d->pair_out);
    memset(d->rnd, 0, sizeof d->rnd);
    if (used) {
        apply_pair(d, c, c->peer.name);
    } else {
        memset(&d->pair_new, 0, sizeof d->pair_new);
    }
    return used;
}

/* `{"chat":{"id","title","lines":[{"r","t"}]}}`: the chat this device asked for, from the Mac it asked. */
static bool handle_chat(app_dock_handle_t d, const conn_t *c, const char *body, size_t len)
{
    pt_span_t chat, list, item, v;
    if (!pt_json_find(body, len, "chat", &chat)) {
        return false;
    }
    app_dock_chat_t *ch = &d->chat;
    char id[44];
    copy_field(chat, "id", id, sizeof id);
    if (!ch->id[0] || strcmp(id, ch->id) != 0 || strcmp(c->peer.id, d->agents_from) != 0) {
        return true;   /* an answer to an older question, or from another Mac */
    }
    copy_field(chat, "title", ch->title, sizeof ch->title);
    ch->count = 0;
    if (pt_json_find(chat.p, chat.len, "lines", &list)) {
        for (int i = 0; ch->count < APP_DOCK_CHAT_LINES && pt_json_array_item(list, i, &item); i++) {
            app_dock_chat_line_t *l = &ch->lines[ch->count];
            char r[4];
            copy_field(item, "r", r, sizeof r);
            l->role = r[0] ? r[0] : 't';
            if (pt_json_find(item.p, item.len, "t", &v) && pt_json_string(v, l->text, sizeof l->text)) {
                ch->count++;
            }
        }
    }
    ch->version++;
    return true;
}

/* `{"replyResult":{"id","state"}}`: what the Mac did with a reply (sent, queued, failed). */
static bool handle_reply_result(app_dock_handle_t d, const char *body, size_t len)
{
    pt_span_t r;
    if (!pt_json_find(body, len, "replyResult", &r)) {
        return false;
    }
    char state[16];
    copy_field(r, "state", state, sizeof state);
    queue_event(d, APP_DOCK_EVENT_REPLY_RESULT, state);
    return true;
}

/* `{"transcript":{"id","session","text"}}` or `{"transcript":{"id","error"}}` from the Mac. */
static bool handle_transcript(app_dock_handle_t d, const char *body, size_t len)
{
    pt_span_t t;
    if (!pt_json_find(body, len, "transcript", &t)) {
        return false;
    }
    app_dock_transcript_t *tr = &d->transcript;
    char id[16];
    copy_field(t, "id", id, sizeof id);
    if (strcmp(id, tr->id) != 0) {
        return true;   /* an older dictation */
    }
    copy_field(t, "text", tr->text, sizeof tr->text);
    copy_field(t, "error", tr->error, sizeof tr->error);
    tr->pending = false;
    tr->version++;
    dock_platform_log("pixlz: transcript %s: %d chars%s", tr->id, (int)strlen(tr->text), tr->error[0] ? " (error)" : "");
    return true;
}

static void base64(const uint8_t *in, size_t n, char *out)
{
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16 | (i + 1 < n ? (uint32_t)in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
        out[o++] = t[v >> 18 & 63];
        out[o++] = t[v >> 12 & 63];
        out[o++] = i + 1 < n ? t[v >> 6 & 63] : '=';
        out[o++] = i + 2 < n ? t[v & 63] : '=';
    }
    out[o] = 0;
}

/* Streams the clip: one part per call while the send buffer has room, then "done". */
static void pump_dictation(app_dock_handle_t d)
{
    enum { PART = 1536 };   /* 2048 base64 characters a frame */
    if (!d->up.active) {
        return;
    }
    conn_t *c = conn_for(d, d->agents_from);
    if (!c) {
        d->up.active = false;
        d->transcript.pending = false;
        snprintf(d->transcript.error, sizeof d->transcript.error, "Lost the Mac while sending");
        d->transcript.version++;
        return;
    }
    for (int k = 0; k < 4 && d->up.active; k++) {
        int n;
        if (d->up.sent < d->up.len) {
            size_t take = d->up.len - d->up.sent < PART ? d->up.len - d->up.sent : PART;
            static char b64[PART / 3 * 4 + 8];
            base64(d->up.clip + d->up.sent, take, b64);
            n = snprintf(d->frame, sizeof d->frame,
                         "{\"dictation\":{\"id\":\"%.15s\",\"session\":\"%.43s\",\"part\":%d,\"data\":\"%s\"}}",
                         d->transcript.id, d->transcript.session, d->up.part, b64);
            if (n <= 0 || (size_t)n >= sizeof d->frame || !enqueue(c, d->frame, (size_t)n)) {
                return;   /* full: next poll */
            }
            d->up.sent += take;
            d->up.part++;
        } else {
            n = snprintf(d->frame, sizeof d->frame,
                         "{\"dictation\":{\"id\":\"%.15s\",\"session\":\"%.43s\",\"done\":true,\"parts\":%d,"
                         "\"rate\":16000,\"codec\":\"ima-adpcm\"}}",
                         d->transcript.id, d->transcript.session, d->up.part);
            if (n <= 0 || (size_t)n >= sizeof d->frame || !enqueue(c, d->frame, (size_t)n)) {
                return;
            }
            d->up.active = false;
            dock_platform_log("pixlz: dictation %s sent (%d parts)", d->transcript.id, d->up.part);
        }
    }
}

static void handle_frame(app_dock_handle_t d, conn_t *c, const char *body, size_t len)
{
    if (!c->hello) {
        bool was_hello = identify(d, c, body, len);
        if (!c->peer.id[0]) {
            close_conn(d, c, "didn't say who it is");
            return;
        }
        c->hello = true;
        c->hello_ms = dock_platform_uptime_ms();
        /* The same Mac again (it reconnected): its old Wi-Fi connection is dead or about to be. */
        for (int i = 0; i < MAX_CONNS; i++) {
            conn_t *o = &d->conns[i];
            if (o != c && o->fd >= 0 && o->hello && !o->local && strcmp(o->peer.id, c->peer.id) == 0) {
                close_conn(d, o, "replaced by a newer connection");
            }
        }
        dock_platform_log("pixlz: %.*s connected (clock %s)", PT_NAME_MAX - 1, c->peer.name,
                          dock_platform_clock_ok() ? "set" : "not set");
        /* Tell it whether this device is paired with it, so a Mac whose key no longer matches
         * finds out now, not when Allow fails. */
        {
            const bool with_it = d->paired.paired && strcmp(d->paired.mac_id, c->peer.id) == 0;
            const char *ps = with_it ? "{\"pairState\":{\"paired\":true}}" : "{\"pairState\":{\"paired\":false}}";
            (void)enqueue(c, ps, strlen(ps));
        }
        // Ask who has the Pixl, whatever the first frame was: a Mac that brought it back while
        // this device was off owns a newer copy, and this one gives way (SPEC §10.5).
        pt_node_connected(&d->node, &c->peer, dock_platform_now_ms(), &d->outs);
        (void)perform(d, &d->outs);
        if (was_hello) {
            return;
        }
    }
    if (handle_pair(d, c, body, len) || handle_feed(d, c, body, len) || handle_agents(d, c, body, len) ||
            handle_chat(d, c, body, len) || handle_transcript(d, body, len) || handle_reply_result(d, body, len)) {
        return;
    }
    pt_node_received(&d->node, &c->peer, body, len, dock_platform_now_ms(), &d->outs);
    (void)perform(d, &d->outs);
}

static void read_conn(app_dock_handle_t d, conn_t *c)
{
    uint8_t *buf = d->io;
    while (c->fd >= 0) {
        ssize_t n = recv(c->fd, buf, sizeof d->io, 0);
        if (n == 0) {
            close_conn(d, c, "hung up");
            return;
        }
        if (n < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                close_conn(d, c, "receive failed");
            }
            return;
        }
        c->last_rx_ms = dock_platform_uptime_ms();
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
                close_conn(d, c, "sent a frame too large");
            }
        }
    }
}

/* Maintenance "forget" (USB): drop a record of a Pixl that isn't here, or an unreadable one. */
static void forget_if_asked(app_dock_handle_t d)
{
    if (!dock_platform_take_forget_request()) {
        return;
    }
    const pt_rec_kind_t kind = d->node.record.kind;
    if (kind == PT_REC_OWNED || kind == PT_REC_PENDING) {
        dock_platform_log("pixlz: refused to forget: a Pixl is %s", kind == PT_REC_OWNED ? "here" : "arriving");
        return;
    }
    pt_record_t *r = &d->record_copy;
    memset(r, 0, sizeof *r);
    r->kind = PT_REC_NONE;
    if (!dock_platform_save(r)) {
        dock_platform_log("pixlz: couldn't forget the record (not saved)");
        return;
    }
    d->node.record = *r;
    d->store_bad = false;
    dock_platform_log("pixlz: forgot the record");
}

/* The device the Pixl goes home to: the paired Mac, else the one whose agents are shown, else
 * the one that connected last. */
static conn_t *home_conn(app_dock_handle_t d)
{
    conn_t *c = d->paired.paired ? conn_for(d, d->paired.mac_id) : NULL;
    if (!c) {
        c = conn_for(d, d->agents_from);
    }
    if (!c) {
        for (int i = 0; i < MAX_CONNS; i++) {
            conn_t *o = &d->conns[i];
            if (o->fd >= 0 && o->hello && (!c || o->hello_ms > c->hello_ms)) {
                c = o;
            }
        }
    }
    return c;
}

int app_dock_poll(app_dock_handle_t d, app_dock_event_t *events, int max)
{
    if (!d || d->exited) {
        return 0;
    }
    pump_dictation(d);
    d->node.can_host = dock_platform_clock_ok() && !d->store_bad;
    /* Paired: only that Mac may call the Pixl away (P7). */
    copy_str(d->node.call_from, sizeof d->node.call_from, d->paired.paired ? d->paired.mac_id : "");
    if (d->pair.phase != PT_PAIR_IDLE) {
        pt_pair_t was = d->pair;
        pt_pair_tick(&d->pair, dock_platform_now_ms(), &d->pair_out);
        apply_pair(d, conn_for(d, was.peer.id), was.peer.name);
    }
    forget_if_asked(d);
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
    /* Always listening: the Bluetooth bridge reaches this port over loopback without Wi-Fi.
     * When Wi-Fi goes, its connections go; the bridge's stay. */
    if (d->listen_fd < 0) {
        open_listener(d);
    }
    if (d->listen_fd >= 0) {
        accept_new(d);
    }
    const bool net = dock_platform_net_ready();
    if (!net && d->net_was_ready) {
        for (int i = 0; i < MAX_CONNS; i++) {
            if (!d->conns[i].local) {
                close_conn(d, &d->conns[i], "lost with Wi-Fi");
            }
        }
    }
    d->net_was_ready = net;
    for (int i = 0; i < MAX_CONNS; i++) {
        read_conn(d, &d->conns[i]);
    }
    const int64_t up = dock_platform_uptime_ms();
    for (int i = 0; i < MAX_CONNS; i++) {
        conn_t *c = &d->conns[i];
        if (c->fd >= 0 && !c->local && up - c->last_rx_ms > IDLE_CLOSE_MS) {
            close_conn(d, c, "quiet for 5 minutes");
        }
    }

    pt_outs_t *outs = &d->outs;
    /* Pending: keep asking, so a lost commit is settled without waiting for a reconnect (P6). */
    if (d->node.record.kind != PT_REC_PENDING || pt_node_in_trip(&d->node)) {
        d->next_recheck_ms = up + RECHECK_MS;
    } else if (up >= d->next_recheck_ms) {
        d->next_recheck_ms = up + RECHECK_MS;
        for (int i = 0; i < MAX_CONNS && d->node.record.kind == PT_REC_PENDING; i++) {
            if (d->conns[i].fd >= 0 && d->conns[i].hello) {
                pt_node_connected(&d->node, &d->conns[i].peer, dock_platform_now_ms(), outs);
                (void)perform(d, outs);
            }
        }
    }
    if (d->send_requested) {
        d->send_requested = false;
        conn_t *mac = home_conn(d);
        if (!dock_platform_clock_ok()) {
            queue_event(d, APP_DOCK_EVENT_SHRUG, "noClock");
        } else if (!mac) {
            queue_event(d, APP_DOCK_EVENT_SHRUG, "noMac");
        } else {
            pt_node_send(&d->node, &mac->peer, dock_platform_now_ms(), outs);
            (void)perform(d, outs);
            if (outs->count == 0) {
                queue_event(d, APP_DOCK_EVENT_SHRUG, "notHere");
            }
        }
    }
    int64_t deadline = pt_node_deadline(&d->node);
    if (deadline && dock_platform_now_ms() >= deadline) {
        pt_node_tick(&d->node, dock_platform_now_ms(), outs);
        (void)perform(d, outs);
    }
    for (int i = 0; i < MAX_CONNS; i++) {
        flush(d, &d->conns[i]);
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
    if (!d || d->exited || d->node.record.kind != PT_REC_AWAY) {
        return false;
    }
    conn_t *c = holder_conn(d);
    if (!c) {
        dock_platform_log("pixlz: can't call: %.*s isn't connected", PT_NAME_MAX - 1, d->node.record.away_name);
        return false;
    }
    pt_node_call(&d->node, &c->peer, dock_platform_now_ms(), &d->outs);
    (void)perform(d, &d->outs);
    dock_platform_log("pixlz: calling the Pixl from %.*s", PT_NAME_MAX - 1, c->peer.name);
    return d->outs.count > 0;
}

static bool online(app_dock_handle_t d)
{
    bool link = false;
    for (int i = 0; i < MAX_CONNS; i++) {
        link |= d->conns[i].fd >= 0 && d->conns[i].local;
    }
    return dock_platform_net_ready() || link;
}

/* Bring needs a reachable world (so a holder that's on could answer) and its holder not here to ask. */
static bool can_bring(app_dock_handle_t d)
{
    int macs = 0;
    for (int i = 0; i < MAX_CONNS; i++) {
        macs += d->conns[i].fd >= 0 && d->conns[i].hello;
    }
    const bool holder_known = d->node.record.away_id[0] != 0;
    return pt_node_can_reclaim(&d->node) && online(d) && !holder_conn(d) && (holder_known || macs == 0);
}

bool app_dock_bring(app_dock_handle_t d)
{
    if (!d || d->exited || !can_bring(d)) {
        return false;
    }
    char away[PT_NAME_MAX];
    copy_str(away, sizeof away, d->node.record.away_name);
    if (!pt_node_reclaim(&d->node, dock_platform_now_ms(), &d->outs)) {
        return false;
    }
    if (!perform(d, &d->outs)) {
        return false;
    }
    dock_platform_log("pixlz: brought the Pixl back (%.*s didn't answer)", PT_NAME_MAX - 1, away);
    return true;
}

bool app_dock_exit(app_dock_handle_t d)
{
    if (!d) {
        return false;
    }
    if (d->exited) {
        return true;
    }
    /* A trip still running: end it out loud, so the other side doesn't wait on a device that's gone. */
    if (pt_node_abort(&d->node, "leaving", dock_platform_now_ms(), &d->outs)) {
        (void)perform(d, &d->outs);
    }
    for (int i = 0; i < MAX_CONNS; i++) {
        flush(d, &d->conns[i]);
    }
    if (!dock_platform_enter_vibe_mode()) {
        return false;
    }
    for (int i = 0; i < MAX_CONNS; i++) {
        close_conn(d, &d->conns[i], "leaving for Vibe Mode");
    }
    d->exited = true;
    return true;
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
    const pt_record_t *r = &d->node.record;
    s.network_ready = dock_platform_net_ready();
    s.online = online(d);
    s.clock_ok = dock_platform_clock_ok();
    for (int i = 0; i < MAX_CONNS; i++) {
        s.macs += d->conns[i].fd >= 0 && d->conns[i].hello;
    }
    s.in_trip = pt_node_in_trip(&d->node);
    s.owns_pet = r->kind == PT_REC_OWNED;
    s.battery_percent = d->battery_percent;
    s.on_battery = d->on_battery;
    s.locked = pt_node_locked(&d->node);
    s.can_call = r->kind == PT_REC_AWAY && holder_conn(d) != NULL;
    s.can_reclaim = pt_node_can_reclaim(&d->node);
    s.can_bring = can_bring(d);
    s.store_bad = d->store_bad;
    s.paired = d->paired.paired;
    s.agents_paired = d->paired.paired && d->agents_from[0] && strcmp(d->paired.mac_id, d->agents_from) == 0;
    if (s.paired) {
        copy_str(s.paired_with, sizeof s.paired_with, d->paired.mac_name);
    }
    if (r->kind == PT_REC_AWAY) {
        copy_str(s.away_on, sizeof s.away_on, r->away_name[0] ? r->away_name : "another device");
    }
    if (r->kind == PT_REC_PENDING) {
        s.arriving = true;
        copy_str(s.arriving_from, sizeof s.arriving_from, r->away_name[0] ? r->away_name : "your Mac");
    }
    return s;
}

const app_dock_agents_t *app_dock_agents(app_dock_handle_t d)
{
    return d ? &d->agents : NULL;
}

static const app_dock_agent_t *find_agent(app_dock_handle_t d, const char *session_id)
{
    for (int i = 0; d && session_id && session_id[0] && i < d->agents.count; i++) {
        if (strcmp(d->agents.items[i].id, session_id) == 0) {
            return &d->agents.items[i];
        }
    }
    return NULL;
}

const app_dock_agent_t *app_dock_agent_find(app_dock_handle_t d, const char *session_id)
{
    return find_agent(d, session_id);
}

/* Signed answers need the pairing with the Mac the sessions came from. */
static conn_t *paired_agents_conn(app_dock_handle_t d)
{
    if (!d->paired.paired || !d->agents_from[0] || strcmp(d->paired.mac_id, d->agents_from) != 0) {
        return NULL;
    }
    return conn_for(d, d->agents_from);
}

app_dock_answer_t app_dock_agent_decide(app_dock_handle_t d, const char *session_id, const char *req, bool allow)
{
    const app_dock_agent_t *a = find_agent(d, session_id);
    if (!a || !req || !req[0] || strcmp(a->req, req) != 0) {
        return APP_DOCK_ANSWER_GONE;
    }
    if (!a->answerable) {
        return APP_DOCK_ANSWER_TERMINAL;
    }
    conn_t *c = paired_agents_conn(d);
    if (c) {
        size_t n = pt_pair_sign_decision(&d->paired, &d->node.me, a->req, allow ? "allow" : "deny", a->summary,
                                         a->detail, d->decision, sizeof d->decision);
        /* The number must never repeat, even across a restart: save before sending. */
        if (!n || !dock_platform_save_pair(&d->paired) || !enqueue(c, d->decision, n)) {
            return APP_DOCK_ANSWER_FAILED;
        }
        dock_platform_log("pixlz: %s %s on %.*s (signed)", allow ? "allowed" : "denied", a->req, PT_NAME_MAX - 1,
                          c->peer.name);
        return APP_DOCK_ANSWER_SENT;
    }
    if (allow) {
        return APP_DOCK_ANSWER_FAILED;
    }
    return app_dock_agent_deny(d, a->req) ? APP_DOCK_ANSWER_SENT : APP_DOCK_ANSWER_FAILED;
}

bool app_dock_restyle(app_dock_handle_t d, const char *species, const char *name)
{
    if (!d || !species || !name || d->node.record.kind != PT_REC_OWNED || pt_node_in_trip(&d->node)) {
        return false;
    }
    char now_species[PT_ID_MAX], now_name[PT_NAME_MAX];
    if (app_dock_pet(d, now_species, sizeof now_species, now_name, sizeof now_name) &&
            strcmp(now_species, species) == 0 && strcmp(now_name, name) == 0) {
        return true;   /* already that */
    }
    if (!pt_node_restyle(&d->node, species, name, &d->outs) || !perform(d, &d->outs)) {
        return false;   /* a failed save reloads the record as it was */
    }
    dock_platform_log("pixlz: the Pixl here is now %.*s (%.*s)", PT_NAME_MAX - 1, name, PT_ID_MAX - 1, species);
    return true;
}

bool app_dock_dictation_send(app_dock_handle_t d, const char *session, const uint8_t *clip, size_t len)
{
    if (!d || !session || !clip || len < 1600 || !conn_for(d, d->agents_from)) {
        return false;   /* < 0.2 s: nothing said */
    }
    app_dock_transcript_t *tr = &d->transcript;
    snprintf(tr->id, sizeof tr->id, "d%u", (unsigned)++d->dictation_n);
    snprintf(tr->session, sizeof tr->session, "%s", session);
    tr->text[0] = tr->error[0] = 0;
    tr->pending = true;
    tr->version++;
    d->up.clip = clip;
    d->up.len = len;
    d->up.sent = 0;
    d->up.part = 0;
    d->up.active = true;
    pump_dictation(d);
    return true;
}

const app_dock_transcript_t *app_dock_transcript(app_dock_handle_t d)
{
    return d ? &d->transcript : NULL;
}

bool app_dock_transcript_reply(app_dock_handle_t d)
{
    if (!d || d->transcript.pending || !d->transcript.text[0]) {
        return false;
    }
    conn_t *c = conn_for(d, d->agents_from);
    if (!c || !d->paired.paired || strcmp(d->paired.mac_id, d->agents_from) != 0) {
        return false;
    }
    size_t n = pt_pair_sign_reply(&d->paired, &d->node.me, d->transcript.session, d->transcript.text, d->frame,
                                  sizeof d->frame);
    if (!n || !dock_platform_save_pair(&d->paired) || !enqueue(c, d->frame, n)) {
        return false;
    }
    dock_platform_log("pixlz: dictated reply sent (%d chars)", (int)strlen(d->transcript.text));
    d->transcript.text[0] = 0;
    d->transcript.version++;
    return true;
}

bool app_dock_agent_chat(app_dock_handle_t d, const char *session_id)
{
    const app_dock_agent_t *a = find_agent(d, session_id);
    conn_t *c = a ? conn_for(d, d->agents_from) : NULL;
    if (!c) {
        return false;
    }
    pt_jw_t w;
    pt_jw_init(&w, d->decision, sizeof d->decision);
    pt_jw_lit(&w, "{\"agentChat\":{\"id\":");
    pt_jw_str(&w, a->id);
    pt_jw_lit(&w, "}}");
    if (!w.ok || !enqueue(c, d->decision, w.len)) {
        return false;
    }
    app_dock_chat_t *ch = &d->chat;   /* asked: now it's loading */
    copy_str(ch->id, sizeof ch->id, a->id);
    ch->title[0] = 0;
    ch->count = -1;
    ch->version++;
    return true;
}

const app_dock_chat_t *app_dock_chat(app_dock_handle_t d)
{
    return d ? &d->chat : NULL;
}

bool app_dock_agent_reply(app_dock_handle_t d, const char *session_id, const char *text)
{
    const app_dock_agent_t *a = find_agent(d, session_id);
    if (!a || !text) {   /* working or not: the Mac holds a reply until the session finishes */
        return false;
    }
    conn_t *c = paired_agents_conn(d);
    if (!c) {
        return false;
    }
    size_t n = pt_pair_sign_reply(&d->paired, &d->node.me, a->id, text, d->decision, sizeof d->decision);
    if (!n || !dock_platform_save_pair(&d->paired) || !enqueue(c, d->decision, n)) {
        return false;
    }
    dock_platform_log("pixlz: replied \"%.40s\" to %.*s", text, (int)sizeof a->project - 1, a->project);
    return true;
}

bool app_dock_pair_request(app_dock_handle_t d)
{
    if (!d) {
        return false;
    }
    conn_t *c = conn_for(d, d->agents_from);
    for (int i = 0; !c && i < MAX_CONNS; i++) {   /* else the latest Mac to say hello */
        conn_t *o = &d->conns[i];
        if (o->fd >= 0 && o->hello && (!c || o->hello_ms > c->hello_ms)) {
            c = o;
        }
    }
    static const char req[] = "{\"pair\":{\"step\":\"request\"}}";
    if (!c || !enqueue(c, req, sizeof req - 1)) {
        return false;
    }
    dock_platform_log("pixlz: asked %.*s to pair", PT_NAME_MAX - 1, c->peer.name);
    return true;
}

void app_dock_pair_answer(app_dock_handle_t d, bool accept)
{
    if (!d) {
        return;
    }
    pt_pair_t was = d->pair;
    pt_pair_user(&d->pair, accept, &d->pair_out);
    apply_pair(d, conn_for(d, was.peer.id), was.peer.name);
}

bool app_dock_unpair(app_dock_handle_t d)
{
    if (!d || !d->paired.paired) {
        return false;
    }
    memset(&d->pair_new, 0, sizeof d->pair_new);   /* paired = false: erases the saved pairing */
    if (!dock_platform_save_pair(&d->pair_new)) {
        dock_platform_log("pixlz: couldn't unpair (not saved); still paired");
        return false;
    }
    dock_platform_log("pixlz: unpaired from %.*s", PT_NAME_MAX - 1, d->paired.mac_name);
    memset(&d->paired, 0, sizeof d->paired);
    return true;
}

bool app_dock_agent_deny(app_dock_handle_t d, const char *req)
{
    if (!d || !req || !req[0]) {
        return false;
    }
    char body[96];
    pt_jw_t w;
    pt_jw_init(&w, body, sizeof body);
    pt_jw_lit(&w, "{\"agentDecision\":{\"id\":");
    pt_jw_str(&w, req);
    pt_jw_lit(&w, ",\"behavior\":\"deny\"}}");
    conn_t *c = conn_for(d, d->agents_from);   /* only the Mac that asked; never another */
    if (!w.ok || !c || !enqueue(c, body, w.len)) {
        return false;
    }
    dock_platform_log("pixlz: denied %.20s on %.*s", req, PT_NAME_MAX - 1, c->peer.name);
    return true;
}

const app_dock_feed_t *app_dock_feed(app_dock_handle_t d)
{
    return d ? &d->feed : NULL;
}

bool app_dock_set_locked(app_dock_handle_t d, bool locked)
{
    if (!d) {
        return false;
    }
    d->record_copy = d->node.record;
    if (!pt_node_set_locked(&d->node, locked)) {
        return false;
    }
    if (!dock_platform_save(&d->node.record)) {
        d->node.record = d->record_copy;   /* not saved: as it was */
        dock_platform_log("pixlz: couldn't save the %s; unchanged", locked ? "lock" : "unlock");
        return false;
    }
    dock_platform_log("pixlz: %s (saved)", locked ? "locked to this device" : "unlocked");
    return true;
}

void app_dock_set_known_species(app_dock_handle_t d, const char *const *ids, int count)
{
    if (d && ids && count > 0) {
        d->node.known_species = ids;
        d->node.known_count = count;
    }
}

bool app_dock_pet(app_dock_handle_t d, char *species, int species_cap, char *name, int name_cap)
{
    if (!d || !species || species_cap <= 0) {
        return false;
    }
    species[0] = 0;
    if (name && name_cap > 0) {
        name[0] = 0;
    }
    const pt_record_t *r = &d->node.record;
    pt_span_t v;
    if (r->kind == PT_REC_NONE || r->state_len == 0 || !pt_json_find(r->state, r->state_len, "species", &v) ||
            !pt_json_string(v, species, (size_t)species_cap)) {
        species[0] = 0;
        return false;
    }
    if (name && name_cap > 0 && (!pt_json_find(r->state, r->state_len, "name", &v) ||
                                 !pt_json_string(v, name, (size_t)name_cap))) {
        name[0] = 0;
    }
    return true;
}

void app_dock_load_look(char *out, int cap)
{
    if (out && cap > 0) {
        out[0] = 0;
        dock_platform_load_look(out, (size_t)cap);
    }
}

bool app_dock_save_look(const char *id)
{
    if (!id || !dock_platform_save_look(id)) {
        dock_platform_log("pixlz: couldn't save the look");
        return false;
    }
    return true;
}
