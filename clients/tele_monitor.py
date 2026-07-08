#!/usr/bin/env python3
"""
Telemetry monitor for the Open XSynth instrument. phase1.scd streams a /tele
message (~45 Hz) with its live derived values; this listens and prints a range
summary over a window so we can fine-tune the mapping from real playing.

  python3 tele_monitor.py [port=9000] [seconds=30]

/tele args: press strike yTone cutPos baseCut modCut ampFac sounding
"""
import socket, struct, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
DUR  = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
NAMES = ["press", "strike", "yTone", "cutPos", "baseCut", "modCut", "ampFac", "sounding"]

def parse(data):
    i = data.index(b"\x00"); addr = data[:i].decode("ascii", "replace")
    j = i + 1
    while j % 4: j += 1
    if data[j:j+1] != b",": return addr, []
    te = data.index(b"\x00", j); tags = data[j+1:te]; k = te + 1
    while k % 4: k += 1
    args = []
    for t in tags:
        if t == ord("i"): args.append(struct.unpack(">i", data[k:k+4])[0]); k += 4
        elif t == ord("f"): args.append(struct.unpack(">f", data[k:k+4])[0]); k += 4
    return addr, args

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", PORT)); s.settimeout(0.5)

print("monitoring /tele on :%d for %.0fs -- PLAY NOW (vary pressure, y, cutoff)" % (PORT, DUR))
sys.stdout.flush()
mn = [1e9]*8; mx = [-1e9]*8; sm = [0.0]*8; n = 0
notes = 0; last_snd = 0; ceil_hits = 0
# pressure/strike stats only while a note is sounding (that's when they matter)
psum = pn = 0; pmin = 1e9; pmax = -1e9
end = time.time() + DUR
while time.time() < end:
    try: data, _ = s.recvfrom(2048)
    except socket.timeout: continue
    addr, a = parse(data)
    if addr != "/tele" or len(a) < 8: continue
    n += 1
    for idx in range(8):
        v = float(a[idx]); mn[idx] = min(mn[idx], v); mx[idx] = max(mx[idx], v); sm[idx] += v
    snd = float(a[7])
    if snd > 0.5 and last_snd < 0.5: notes += 1
    last_snd = snd
    if float(a[5]) >= 13000: ceil_hits += 1
    if snd > 0.5:
        p = float(a[0]); psum += p; pn += 1; pmin = min(pmin, p); pmax = max(pmax, p)

print("---- %d samples, %d note-onsets ----" % (n, notes))
if n == 0:
    print("NO TELEMETRY RECEIVED -- is /tele streaming? is the instrument up?")
else:
    print("%-9s %9s %9s %9s" % ("field", "min", "max", "mean"))
    for idx in range(8):
        print("%-9s %9.3f %9.3f %9.3f" % (NAMES[idx], mn[idx], mx[idx], sm[idx]/n))
    print("modCut at/over 13k ceiling: %.0f%% of all samples" % (100.0*ceil_hits/n))
    if pn:
        print("pressure WHILE SOUNDING: min %.3f  max %.3f  mean %.3f  (range used: %.3f)"
              % (pmin, pmax, psum/pn, pmax-pmin))
