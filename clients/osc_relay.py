#!/usr/bin/env python3
"""Tiny OSC relay: receive on one UDP port, forward to SuperCollider (dst).

Feeds open-xsynth's controls (sent to localhost:8001) into SuperCollider's default
OSC port (57120) without SC opening a custom port.

  python3 osc_relay.py [src_port=8001] [dst_port=57120] [dst_host=127.0.0.1]

HARNESS MIRROR: a copy of every forwarded datagram can be fanned to a second dest,
set at runtime by a control message the relay consumes (never forwards to SC):

  /harness/mirror <host:str> <port:int>          -> start mirroring to host:port
  /harness/mirror "0" 0  (host ""/"0"/"local" or port 0) -> stop mirroring

This lets a listener (on the Pi or off-device) observe the raw hardware control
stream. 3.5-safe, stdlib only.

Forward off-device by passing your workstation's IP as dst_host.
"""
import socket, struct, sys

SRC = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
DST = int(sys.argv[2]) if len(sys.argv) > 2 else 57120
DST_HOST = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"


def _read_str(data, i):
    end = data.index(b"\x00", i)
    s = data[i:end].decode("ascii", "replace")
    i = end + 1
    while i % 4:
        i += 1
    return s, i


def _address(data):
    try:
        return data[:data.index(b"\x00")].decode("ascii", "replace")
    except ValueError:
        return ""


def _parse_mirror(data):
    """Return (host, port) from a /harness/mirror message, or None if malformed."""
    try:
        _, i = _read_str(data, 0)
        if data[i:i + 1] != b",":
            return None
        tags, i = _read_str(data, i)
        host, port = "", 0
        for t in tags[1:]:
            if t == "s":
                host, i = _read_str(data, i)
            elif t == "i":
                port = struct.unpack(">i", data[i:i + 4])[0]; i += 4
            elif t == "f":
                port = int(struct.unpack(">f", data[i:i + 4])[0]); i += 4
        return host, port
    except Exception:
        return None


rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
rx.bind(("0.0.0.0", SRC))
tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

mirror = None  # (host, port) while mirroring, else None

print("relay :%d -> %s:%d (mirror off)" % (SRC, DST_HOST, DST), flush=True)
while True:
    data, _ = rx.recvfrom(65536)
    if _address(data) == "/harness/mirror":
        parsed = _parse_mirror(data)
        if parsed is not None:
            host, port = parsed
            if host in ("", "0", "local") or port == 0:
                mirror = None
                print("mirror off", flush=True)
            else:
                mirror = (host, port)
                print("mirror -> %s:%d" % (host, port), flush=True)
        continue  # consume the control message; never forward it to SC
    tx.sendto(data, (DST_HOST, DST))
    if mirror is not None:
        try:
            tx.sendto(data, mirror)
        except Exception:
            pass
