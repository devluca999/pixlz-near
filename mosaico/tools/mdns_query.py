"""Ask one host's mDNS responder directly (unicast to 5353) for PTR _pixlz._tcp.local.

usage: mdns_query.py <ip>. Tells a silent responder apart from a network that drops multicast."""
import socket, struct, sys
host = sys.argv[1]
name = b"".join(bytes([len(p)]) + p for p in b"_pixlz._tcp.local".split(b".")) + b"\0"
q = struct.pack(">HHHHHH", 0x1234, 0, 1, 0, 0, 0) + name + struct.pack(">HH", 12, 0x8001)  # PTR, unicast-response bit
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(q, (host, 5353))
try:
    data, addr = s.recvfrom(4096)
    print("answer from", addr, len(data), "bytes; answers:", struct.unpack(">H", data[6:8])[0])
    print(data)
except socket.timeout:
    print("no answer")
