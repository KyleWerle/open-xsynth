#!/usr/bin/env python3
"""
Zero-dependency OSC monitor for open-xsynth's control stream.

The device sends controls to localhost:8001, so run this ON the device:
    python3 osc_dump.py 8001 30      # listen on 8001 for 30 seconds

Prints each decoded message and a per-address tally at the end. Binds
dual-stack so it catches both 127.0.0.1 and ::1.
"""
import socket, struct, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
DUR  = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0

def read_str(data, i):
    end = data.index(b"\x00", i)
    s = data[i:end].decode("ascii", "replace")
    i = end + 1
    while i % 4:
        i += 1
    return s, i

def parse(data):
    addr, i = read_str(data, 0)
    args = []
    if i < len(data) and data[i:i+1] == b",":
        tags, i = read_str(data, i)
        for t in tags[1:]:
            if t == "i":
                args.append(struct.unpack(">i", data[i:i+4])[0]); i += 4
            elif t == "f":
                args.append(round(struct.unpack(">f", data[i:i+4])[0], 3)); i += 4
            elif t == "s":
                s, i = read_str(data, i); args.append(s)
            else:
                args.append("?" + t)
    return addr, args

try:
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("::", PORT))
except Exception:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", PORT))
s.settimeout(0.5)

print("listening on :%d for %.0fs -- touch the grid, twist knobs, turn encoders!" % (PORT, DUR))
sys.stdout.flush()
end = time.time() + DUR
count = 0
seen = {}
while time.time() < end:
    try:
        data, _ = s.recvfrom(4096)
    except socket.timeout:
        continue
    addr, args = parse(data)
    count += 1
    seen[addr] = seen.get(addr, 0) + 1
    print("%-12s %s" % (addr, args))
    sys.stdout.flush()
print("---- done. %d messages ----" % count)
for a in sorted(seen):
    print("  %-12s x%d" % (a, seen[a]))
