"""Swipe on the Mosaico through a running ESP-Iris gateway: pointer/v1 begin, moves ~33 ms apart, end.

usage: iris_swipe.py <gateway-url> <device-id> <x0> <y0> <x1> <y1> [steps]
A fast swipe across Frogg flings him (off a side edge: home to the Mac)."""
import base64, json, struct, sys, time, urllib.request, uuid

url, device = sys.argv[1], sys.argv[2]
x0, y0, x1, y1 = (int(v) for v in sys.argv[3:7])
steps = int(sys.argv[7]) if len(sys.argv) > 7 else 4

def pointer(phase, x, y, seq):
    payload = struct.pack("<BBhhHI", phase, 0, x, y, 0, seq)
    body = json.dumps({"service_id": 0x1001, "method_id": 1, "deadline_ms": 1000,
                       "payload_base64": base64.b64encode(payload).decode()}).encode()
    req = urllib.request.Request(f"{url}/v2/devices/{device}/rpc/raw", data=body, method="POST",
                                 headers={"Content-Type": "application/json", "X-Operation-ID": str(uuid.uuid4())})
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.status

seq = int(time.time()) & 0xFFFFFFF
pointer(0, x0, y0, seq)
for i in range(1, steps + 1):
    time.sleep(0.034)
    pointer(1, x0 + (x1 - x0) * i // steps, y0 + (y1 - y0) * i // steps, seq + i)
pointer(2, x1, y1, seq + steps + 1)
print("swiped", (x0, y0), "->", (x1, y1))
