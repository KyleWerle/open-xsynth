#!/usr/bin/env python3
"""
Audio-output analyzer reader for Open XSynth. phase1.scd runs a \analyzer synth
that taps the output bus and streams /fft (~15 Hz) with:
  amp(dB)  centroid(Hz)  flatness(0-1)  then 7 octave-band levels(dB): 125 250 500 1k 2k 4k 8k

Lets us "see" the device's sound: level (dynamics / stuck / silent), centroid + bands
(brightness / filter), flatness (tonal vs noisy = artifacts).

  python3 fft_monitor.py [port=9001] [seconds=20]
"""
import socket, struct, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9001
DUR  = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
BANDS = ["125", "250", "500", "1k", "2k", "4k", "8k"]

def parse(data):
    i = data.index(b"\x00"); addr = data[:i].decode("ascii", "replace")
    j = i + 1
    while j % 4: j += 1
    if data[j:j+1] != b",": return addr, []
    te = data.index(b"\x00", j); tags = data[j+1:te]; k = te + 1
    while k % 4: k += 1
    a = []
    for t in tags:
        if t == ord("f"): a.append(struct.unpack(">f", data[k:k+4])[0]); k += 4
        elif t == ord("i"): a.append(struct.unpack(">i", data[k:k+4])[0]); k += 4
    return addr, a

def bar(db):  # -60..0 dB -> 10-char bar
    lvl = int((db + 60) / 60 * 10); lvl = max(0, min(10, lvl))
    return "#" * lvl + "." * (10 - lvl)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", PORT)); s.settimeout(0.5)
print("FFT monitor on :%d for %.0fs" % (PORT, DUR)); sys.stdout.flush()

end = time.time() + DUR; n = 0; last = 0
amp_mx = -99.0; cent_mn = 1e9; cent_mx = -1e9; audible = 0
while time.time() < end:
    try: data, _ = s.recvfrom(2048)
    except socket.timeout: continue
    addr, a = parse(data)
    if addr != "/fft" or len(a) < 10: continue
    n += 1
    amp, cent, flat = a[0], a[1], a[2]; bands = a[3:10]
    amp_mx = max(amp_mx, amp)
    if amp > -50: audible += 1; cent_mn = min(cent_mn, cent); cent_mx = max(cent_mx, cent)
    now = time.time()
    if now - last >= 0.4:
        spec = " ".join("%s %s" % (BANDS[i], bar(bands[i])) for i in range(7))
        print("amp%6.1f cent%6.0f flat%4.2f | %s" % (amp, cent, flat, spec)); sys.stdout.flush()
        last = now
print("---- %d frames ----" % n)
if n:
    cmn = cent_mn if cent_mn < 1e8 else 0
    print("amp max %.1f dB | centroid(audible) %.0f..%.0f Hz | audible %.0f%% of frames"
          % (amp_mx, cmn, cent_mx, 100.0 * audible / n))
