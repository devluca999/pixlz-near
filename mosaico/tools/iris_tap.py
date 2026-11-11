"""Tap the Mosaico at (x, y) through a running ESP-Iris gateway (python mosaico.py iris run): pointer/v1 begin, wait, end.

usage: iris_tap.py <gateway-url> <device-id> <x> <y> [hold-seconds] [count]   (count 2 = a double-tap)
The gateway's input gesture sends begin and end ~12 ms apart, inside one frame, so a game sees only
a release; two raw calls ~120 ms apart behave like a finger."""
import base64, json, struct, sys, time, urllib.request, uuid

url, device, x, y = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
hold = float(sys.argv[5]) if len(sys.argv) > 5 else 0.12
count = int(sys.argv[6]) if len(sys.argv) > 6 else 1

def pointer(phase, seq):
    payload = struct.pack("<BBhhHI", phase, 0, x, y, 0, seq)
    body = json.dumps({"service_id": 0x1001, "method_id": 1, "deadline_ms": 1000,
                       "payload_base64": base64.b64encode(payload).decode()}).encode()
    req = urllib.request.Request(f"{url}/v2/devices/{device}/rpc/raw", data=body, method="POST",
                                 headers={"Content-Type": "application/json", "X-Operation-ID": str(uuid.uuid4())})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status

seq = int(time.time()) & 0xFFFFFFF
for i in range(count):
    t0 = time.monotonic()
    pointer(0, seq)
    time.sleep(hold)
    pointer(2, seq + 1)
    seq += 2
    print(f"tap {i + 1} held {time.monotonic() - t0:.3f}s")
    if i + 1 < count:
        time.sleep(0.07)
