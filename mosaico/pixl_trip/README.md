# pixl_trip

The trip protocol (SPEC §10.3–§10.5) in plain C for the ESP-Mosaico: a port of PixlzCore's
`TravelNode`, plus the framing, a small JSON scanner/splicer and SHA-256 it needs. No ESP-IDF
dependencies, so the same code runs in host tests, the simulator and on the device.

**Spike status:** plain TCP, no pairing or TLS (D17). Not mergeable to `main` until pairing lands (D9).

## Responsibilities

| File | Does |
|---|---|
| `pt_frame` | 4-byte big-endian length + JSON body, like PixlzCore's `Framing`. Caller-owned buffer. |
| `pt_json` | Finds a value's span by a dotted path, reads strings/ints, writes escaped JSON, replaces spans. |
| `pt_sha256` | SHA-256 for the ack checksum. |
| `pt_trip` | The node: `pt_node_send/call/connected/received/tick` → ordered outputs. Hello frames. |

## Contracts

- **State stays raw.** The node never decodes PetState into fields. It keeps the canonical bytes it
  received, hashes those raw bytes for the ack (SPEC §10.1), and when the Pixl leaves it splices
  `epoch`, `owner`, `savedAt` and `stats.trips` into them. Keys stay sorted, so the bytes stay
  canonical and match what PixlzCore would write (checked byte for byte in the tests).
- **Outputs in order.** Perform each call's outputs in order. Persist `node->record` on
  `PT_OUT_SAVED` before sending anything after it; that's what keeps at least one complete copy.
- **Single owner.** One task drives a node; nothing is thread-safe. `PT_OUT_SEND` bodies point into
  the node and are valid until the next call.
- **Sizes.** State up to `PT_STATE_MAX` (4 KB), messages up to `PT_MSG_MAX`. `pt_node_t` is about
  33 KB: allocate it once (heap/PSRAM), never on a task stack.
- **Time.** Every call takes `now` as Unix milliseconds. Don't run trips before the clock is set.
- **Who holds it.** An away record keeps the holder's id and name (`away_id`, `away_name`) and a
  `statusReply` with `held: "away"` names them (`holderId`, `holderName`). A pending record keeps
  its sender there instead, and only that sender's replies, commit or abort settle it.
- **Trust.** A `statusReply` counts only from a peer sent `status` in the last 60 s; trip messages
  only from the trip's peer; `call` only from `call_from` when set (the paired Mac).
- **Giving way.** An owned copy that meets a newer one (owned or away) becomes away with an empty
  tombstone, so it can never be brought back; a trip it was offering ends with `gaveWay`.
- **Protocol 2.** Offers carry `proto: 2`; an offer from a newer protocol is declined `needsUpdate`.
  `policy.locked` declines calls with `locked` and blocks sending.

## Known gaps (spike)

- On arrival the Mac also records the travel/receive needs bumps and a `happy` emotion. The C node
  only updates `savedAt`.

## Usage

```c
pt_node_t *node = heap_caps_malloc(sizeof *node, MALLOC_CAP_SPIRAM);
pt_node_init(node, &me, fill_random, NULL);
// load node->record from NVS
pt_outs_t out;
pt_node_received(node, &peer, body, len, now_ms, &out);
for (int i = 0; i < out.count; i++) { /* save / frame + send / animate */ }
```

## Tests

```sh
(cd ../tools/PixlzSend && swift run PixlzSend fixtures ../../pixl_trip/test/fixtures)  # PixlzCore's bytes
make test
```
