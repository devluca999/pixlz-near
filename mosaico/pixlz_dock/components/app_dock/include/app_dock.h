// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** The Mosaico's travel dock: a TCP server for Macs, the trip node and the saved record.
 * One owner loop; poll it every tick. Contracts: ../README.md. Spike: no pairing or TLS. */
typedef struct app_dock *app_dock_handle_t;

typedef enum {
    APP_DOCK_EVENT_ARRIVED = 1,  /**< The Pixl is owned here now: play the entrance. */
    APP_DOCK_EVENT_LEFT,         /**< Committed: play the exit. */
    APP_DOCK_EVENT_SHRUG,        /**< The trip didn't happen; `reason` says why ("gaveWay": a newer
                                      copy is elsewhere and this one stepped aside; "saveFailed"). */
    APP_DOCK_EVENT_PAIR_CODE,    /**< A Mac wants to pair: show `reason` (6 digits) and ask. */
    APP_DOCK_EVENT_PAIRED,       /**< Paired and saved; `reason` is the Mac's name (cut to fit). */
    APP_DOCK_EVENT_PAIR_ENDED,   /**< The pairing stopped without pairing ("saveFailed": it couldn't be saved). */
} app_dock_event_kind_t;

typedef struct {
    app_dock_event_kind_t kind;
    char reason[32];
} app_dock_event_t;

typedef struct {
    bool network_ready;  /**< Wi-Fi has an address (always true in the simulator). */
    bool online;         /**< Wi-Fi up, or the Bluetooth link connected. */
    bool clock_ok;       /**< Wall clock set (SNTP); trips need it. */
    int macs;            /**< Connected Macs that said hello. */
    bool in_trip;
    bool owns_pet;
    int battery_percent; /**< 0..100, or -1 when unknown. */
    bool on_battery;     /**< Unplugged (discharging). */
    bool locked;         /**< The Pixl here is locked to this device (SPEC §10.6). */
    bool can_call;       /**< Away, and the device that holds it is connected to ask. */
    bool can_reclaim;    /**< Away with a safety copy here (Bring, once online). */
    bool can_bring;      /**< can_reclaim, online, and its holder isn't connected (app_dock_bring). */
    char away_on[96];    /**< Where the Pixl is when it's away ("" otherwise). */
    bool arriving;       /**< Received and saved, waiting for the sender's commit. */
    char arriving_from[96];
    bool store_bad;      /**< A saved Pixl couldn't be read: kept aside; offers are declined. */
    bool paired;         /**< Paired with a Mac (D20): Allow works here for that Mac's agents. */
    bool agents_paired;  /**< The agents list came from the paired Mac. */
    char paired_with[96];
} app_dock_status_t;

/** What the Mac shows on the Mosaico (SPEC §12.1: results only, no AI here): its latest Ask
 * answers and saved highlights, plain ASCII, sent by the Mac when it connects. */
enum { APP_DOCK_FEED_ITEMS = 6, APP_DOCK_FEED_TITLE = 80, APP_DOCK_FEED_BODY = 480 };
typedef struct {
    char title[APP_DOCK_FEED_TITLE];   /**< The question, or the highlight's page title. */
    char body[APP_DOCK_FEED_BODY];     /**< The answer, or the highlighted text. */
} app_dock_feed_item_t;
typedef struct {
    uint32_t version;                  /**< Goes up with every feed received. */
    int answers_count, memory_count;
    app_dock_feed_item_t answers[APP_DOCK_FEED_ITEMS];
    app_dock_feed_item_t memory[APP_DOCK_FEED_ITEMS];
} app_dock_feed_t;

/** Agent mode (SPEC §16.3): the Claude Code sessions on the Mac, as it last sent them (waiting
 * ones first). Cleared when the Mac that sent them goes. Read-only here; Deny goes back to the Mac. */
enum { APP_DOCK_AGENTS = 6 };
typedef struct {
    char id[44];
    char project[28];
    char doing[64];
    char req[16];          /**< A waiting request's id; "" when it isn't waiting. */
    char summary[64];      /**< "Run rm -rf build" */
    char detail[144];      /**< The exact command or file. */
    bool answerable;       /**< The Mac holds it: Deny here answers it. Else: the terminal asks. */
    bool reply_open;       /**< Finished and held open for a reply (Reply from Pixlz on the Mac). */
} app_dock_agent_t;

/** One session's chat, as the Mac sent it on request (newest last). count < 0: still loading. */
enum { APP_DOCK_CHAT_LINES = 12, APP_DOCK_CHAT_TEXT = 292 };
typedef struct {
    char role;             /**< 'y' you, 'c' Claude, 't' a tool it ran */
    char text[APP_DOCK_CHAT_TEXT];
} app_dock_chat_line_t;
typedef struct {
    uint32_t version;
    char id[44];
    char title[64];
    int count;
    app_dock_chat_line_t lines[APP_DOCK_CHAT_LINES];
} app_dock_chat_t;
typedef struct {
    uint32_t version;      /**< Goes up with every change. */
    bool alerts;           /**< Agent alerts are on (the Mac's toggle): call while one waits. */
    int count, waiting;
    app_dock_agent_t items[APP_DOCK_AGENTS];
} app_dock_agents_t;

/** Loads the saved record and starts networking. Returns NULL on allocation failure. */
app_dock_handle_t app_dock_create(void);
/** Closes sockets and frees the dock; clears the handle. NULL is a no-op. */
void app_dock_destroy(app_dock_handle_t *handle);
/** Nonblocking network and timer work; writes up to `max` events, returns how many. */
int app_dock_poll(app_dock_handle_t dock, app_dock_event_t *events, int max);
/** Send the Pixl home: to the paired Mac if connected, else the Mac whose agents are shown,
 * else the one that connected last. The result arrives as LEFT or SHRUG events. */
void app_dock_send_home(app_dock_handle_t dock);
/** Ask the device that holds the Pixl to send it here ("Call"); never another Mac. False when
 * that device isn't connected. Arrives as ARRIVED, or nothing. */
bool app_dock_call(app_dock_handle_t dock);
/** Its Mac is off: bring the Pixl back from the copy kept here. Arrives as ARRIVED. When that
 * Mac comes back it gives way, and the Pixl's time there is lost (SPEC §10.5). */
bool app_dock_bring(app_dock_handle_t dock);
/** Leave for Vibe Mode: ends any trip (abort), switches, then closes connections. False when it
 * can't switch (nothing is closed then). After true, poll does nothing. */
bool app_dock_exit(app_dock_handle_t dock);
app_dock_status_t app_dock_status(app_dock_handle_t dock);
/** The latest feed from a Mac; empty until one arrives, cleared when that Mac goes. */
const app_dock_feed_t *app_dock_feed(app_dock_handle_t dock);
/** The sessions from one Mac; cleared when that Mac goes. Reading never changes them. */
const app_dock_agents_t *app_dock_agents(app_dock_handle_t dock);
/** The session with this id, or NULL. */
const app_dock_agent_t *app_dock_agent_find(app_dock_handle_t dock, const char *session_id);
/** Deny a waiting request, unsigned, on the Mac the sessions came from (never another). */
bool app_dock_agent_deny(app_dock_handle_t dock, const char *req);
typedef enum {
    APP_DOCK_ANSWER_SENT = 0,
    APP_DOCK_ANSWER_GONE,       /**< That session or request isn't there any more. */
    APP_DOCK_ANSWER_TERMINAL,   /**< The Mac doesn't hold it: answer in the terminal. */
    APP_DOCK_ANSWER_FAILED,     /**< Not paired (Allow), or it couldn't be sent. */
} app_dock_answer_t;
/** Answer request `req` of session `session_id`: signed when paired with the Mac that sent the
 * list (Allow needs that); otherwise only Deny, unsigned. */
app_dock_answer_t app_dock_agent_decide(app_dock_handle_t dock, const char *session_id, const char *req, bool allow);
/** Ask the Mac for that session's chat; it arrives in app_dock_chat(). False: not asked. */
bool app_dock_agent_chat(app_dock_handle_t dock, const char *session_id);
const app_dock_chat_t *app_dock_chat(app_dock_handle_t dock);
/** A quick reply to a session held open for one: signed, so only when paired with that Mac. */
bool app_dock_agent_reply(app_dock_handle_t dock, const char *session_id, const char *text);
/** The user's answer to the pairing code on screen. */
void app_dock_pair_answer(app_dock_handle_t dock, bool accept);
/** Forget the paired Mac (Allow turns off here). False if it couldn't be saved (still paired). */
bool app_dock_unpair(app_dock_handle_t dock);
/** Lock or unlock the Pixl here; saved at once. False if nothing changed or it couldn't be saved. */
bool app_dock_set_locked(app_dock_handle_t dock, bool locked);
/** The species ids this device can draw (the strings must outlive the dock). */
void app_dock_set_known_species(app_dock_handle_t dock, const char *const *ids, int count);
/** The Pixl's species and name from its record: here, arriving, or the copy kept when it left.
 * False when none is known (`name` may be "" when the state has none). */
bool app_dock_pet(app_dock_handle_t dock, char *species, int species_cap, char *name, int name_cap);
/** A swap while the Pixl is here (owned, no trip): it travels as that species and name from now
 * on. True once saved, or when it already is that; false otherwise (nothing changes). */
bool app_dock_restyle(app_dock_handle_t dock, const char *species, const char *name);
/** The look chosen on this device (Pixl swap), saved across restarts; "" when none. */
void app_dock_load_look(char *out, int cap);
bool app_dock_save_look(const char *id);

#ifdef __cplusplus
}
#endif
