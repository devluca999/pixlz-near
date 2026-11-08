"""Intel TDX quote fields and dstack event-log replay.

These are the measurements we compare against. The quote's signature and
collateral are checked separately by dcap-qvl (see verify.py); this module only
reads fields out of the same bytes, so every value we trust comes from the
signed quote rather than from the JSON around it.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

HEADER_LEN = 48
TD10_BODY_LEN = 584
TEE_TYPE_TDX = 0x81

# Offsets inside the TD report body (TDX DCAP quote v4, "TD Quote Body").
_TD_ATTRIBUTES = slice(120, 128)
_MR_TD = slice(136, 184)
_MR_CONFIG_ID = slice(184, 232)
_RTMR = [slice(328 + 48 * i, 376 + 48 * i) for i in range(4)]
_REPORT_DATA = slice(520, 584)


@dataclass(frozen=True)
class TdQuoteFields:
    version: int
    td_attributes: bytes
    mr_td: bytes
    mr_config_id: bytes
    rtmr: tuple[bytes, bytes, bytes, bytes]
    report_data: bytes

    @property
    def debug(self) -> bool:
        """TD_ATTRIBUTES bit 0 set means a debug TD whose memory the host can read."""
        return bool(self.td_attributes[0] & 0x01)


def parse_td_quote(raw: bytes) -> TdQuoteFields:
    if len(raw) < HEADER_LEN + TD10_BODY_LEN:
        raise ValueError(f"quote too short ({len(raw)} bytes)")
    version = int.from_bytes(raw[0:2], "little")
    tee_type = int.from_bytes(raw[4:8], "little")
    if tee_type != TEE_TYPE_TDX:
        raise ValueError(f"not a TDX quote (tee_type {tee_type:#x})")
    if version == 4:
        start = HEADER_LEN
    elif version == 5:
        # v5 inserts body type (u16) and body size (u32) before the body.
        start = HEADER_LEN + 6
    else:
        raise ValueError(f"unsupported quote version {version}")
    body = raw[start : start + TD10_BODY_LEN]
    if len(body) < TD10_BODY_LEN:
        raise ValueError("truncated quote body")
    return TdQuoteFields(
        version=version,
        td_attributes=body[_TD_ATTRIBUTES],
        mr_td=body[_MR_TD],
        mr_config_id=body[_MR_CONFIG_ID],
        rtmr=tuple(body[s] for s in _RTMR),  # type: ignore[arg-type]
        report_data=body[_REPORT_DATA],
    )


def parse_event_log(value: Any) -> list[dict[str, Any]]:
    """The gateway sends the event log as a JSON string; model reports send a list."""
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, list):
        raise ValueError("event_log is not a list")
    return value


def event_digest(event: dict[str, Any]) -> bytes:
    """dstack runtime event digest: SHA-384(type as u32 LE ‖ ":" ‖ event ‖ ":" ‖ payload)."""
    return hashlib.sha384(
        int(event["event_type"]).to_bytes(4, "little")
        + b":"
        + str(event["event"]).encode()
        + b":"
        + bytes.fromhex(event.get("event_payload") or "")
    ).digest()


def replay_rtmr3(events: list[dict[str, Any]]) -> bytes:
    """Extend RTMR3 from zero with every imr==3 event, in log order.

    The digests are recomputed from each event's content (NEAR ships them
    empty), so a tampered payload changes the result.
    """
    mr = bytes(48)
    for ev in events:
        if ev.get("imr") == 3:
            mr = hashlib.sha384(mr + event_digest(ev)).digest()
    return mr


def runtime_events(events: list[dict[str, Any]]) -> dict[str, str]:
    """imr==3 events by name, e.g. {"compose-hash": "<hex>", "app-id": "<hex>"}."""
    return {str(e["event"]): e.get("event_payload", "") for e in events if e.get("imr") == 3}


def expected_mr_config_id(app_compose: str) -> bytes:
    """dstack sets MRCONFIGID = 0x01 ‖ SHA-256(app_compose) ‖ zero padding to 48 bytes."""
    return b"\x01" + hashlib.sha256(app_compose.encode()).digest() + bytes(15)


def compose_images(app_compose: str) -> list[str]:
    """Container images named in the measured docker-compose, for display."""
    try:
        compose = json.loads(app_compose).get("docker_compose_file", "")
    except (json.JSONDecodeError, AttributeError):
        return []
    images: list[str] = []
    for line in str(compose).splitlines():
        line = line.strip()
        if line.startswith("image:"):
            img = line.removeprefix("image:").strip().strip("'\"")
            if img.startswith("${") and ":-" in img:  # ${VAR:-default}
                img = img[img.index(":-") + 2 : -1]
            if img not in images:
                images.append(img)
    return images


def actions_hash(actions: list[dict[str, Any]]) -> str:
    """NEAR compose-manager log hash: SHA-256 of the actions as sorted, compact JSON."""
    return hashlib.sha256(json.dumps(actions, separators=(",", ":"), sort_keys=True).encode()).hexdigest()
