#!/usr/bin/env python3
"""
Zero-dependency OSC client for open-xsynth's OLED (port 8000).
Doubles as a tiny drawing library and a demo.

Set the device address via the OPEN_XSYNTH_HOST env var (or edit HOST below):
    OPEN_XSYNTH_HOST=raspberrypi.local python osc_send.py rich

Drawing protocol (build a frame between clear() and show()), 128x64, mono:
    clear()                      start a new frame
    text(x, y, "str")            bitmap text (~8px tall, y ~ baseline)
    line(x1, y1, x2, y2)
    rect(x, y, w, h, fill=0)     fill 0=outline, 1=filled
    circle(x, y, r, fill=0)
    pixel(x, y)
    bar(x, y, w, h, value)       meter, value 0..1
    scrolltext(y, "str", speed)  marquee, speed px/sec (animates, persists)
    bitmap(x, y, w, h, packed)   1-bit image blob (see pack_bits)
    show()                       commit the frame; remote screen owns OLED
    release()                    hand the OLED back to the particle screen
    brightness(v)                contrast 0..1 (or 0..255)
    invert(on)                   white<->black
"""
import socket, struct, sys, os, math, time

HOST = os.environ.get("OPEN_XSYNTH_HOST", "raspberrypi.local")
PORT = 8000

_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

def _ostr(s):
    b = s.encode("ascii", "replace") + b"\x00"
    while len(b) % 4:
        b += b"\x00"
    return b

def _msg(addr, *args):
    out = _ostr(addr)
    tags = ","
    data = b""
    for a in args:
        if isinstance(a, bool):
            tags += "i"; data += struct.pack(">i", 1 if a else 0)
        elif isinstance(a, int):
            tags += "i"; data += struct.pack(">i", a)
        elif isinstance(a, float):
            tags += "f"; data += struct.pack(">f", a)
        elif isinstance(a, (bytes, bytearray)):
            tags += "b"; bb = bytes(a)
            data += struct.pack(">i", len(bb)) + bb
            while len(data) % 4:
                data += b"\x00"
        else:
            tags += "s"; data += _ostr(str(a))
    return out + _ostr(tags) + data

def send(addr, *args):
    _sock.sendto(_msg(addr, *args), (HOST, PORT))

# convenience wrappers
def clear():                    send("/oled/clear")
def show():                     send("/oled/show")
def release():                  send("/oled/release")
def text(x, y, s):              send("/oled/text", int(x), int(y), str(s))
def line(x1, y1, x2, y2):       send("/oled/line", int(x1), int(y1), int(x2), int(y2))
def rect(x, y, w, h, fill=0):   send("/oled/rect", int(x), int(y), int(w), int(h), int(fill))
def circle(x, y, r, fill=0):    send("/oled/circle", int(x), int(y), int(r), int(fill))
def pixel(x, y):                send("/oled/pixel", int(x), int(y))
def bar(x, y, w, h, value):     send("/oled/bar", int(x), int(y), int(w), int(h), float(value))
def scrolltext(y, s, speed):    send("/oled/scrolltext", int(y), str(s), float(speed))
def brightness(v):              send("/oled/brightness", float(v))
def invert(on):                 send("/oled/invert", 1 if on else 0)
def bitmap(x, y, w, h, packed): send("/oled/bitmap", int(x), int(y), int(w), int(h), bytes(packed))

def pack_bits(rows):
    """Pack rows of a 1-bit image (chars '1'/'#'/'X'/'*' = on) MSB-first."""
    flat = [1 if ch in "1#Xx*" else 0 for r in rows for ch in r]
    out = bytearray()
    for i in range(0, len(flat), 8):
        byte = 0
        for b in range(8):
            if i + b < len(flat) and flat[i + b]:
                byte |= 1 << (7 - b)
        out.append(byte)
    return bytes(out)

# a 16x16 smiley for the bitmap demo
SMILEY = [
    "0000111111110000",
    "0011111111111100",
    "0111111111111110",
    "0111111111111110",
    "1110011111100111",
    "1110011111100111",
    "1111111111111111",
    "1111111111111111",
    "1111111111111111",
    "1100111111110011",
    "1110000000001110",
    "0111000000011100",
    "0111110000111110",
    "0011111111111100",
    "0000111111110000",
    "0000000000000000",
]


def demo_static():
    clear()
    rect(0, 0, 127, 63, 0)
    text(8, 14, "OPEN XSYNTH")
    text(8, 28, "OSC -> OLED")
    text(8, 42, "hi kyle :)")
    bar(8, 52, 111, 8, 0.66)
    show()
    print("sent static frame to %s:%d" % (HOST, PORT))

def demo_animate(seconds=12):
    print("animating for %ds..." % seconds)
    t0 = time.time()
    while time.time() - t0 < seconds:
        t = time.time() - t0
        clear()
        rect(0, 0, 127, 63, 0)
        text(8, 12, "OPEN XSYNTH")
        circle(int(63 + 55 * math.sin(t * 2.0)),
               int(40 + 16 * math.sin(t * 3.1)), 4, 1)
        bar(8, 56, 111, 6, 0.5 + 0.5 * math.sin(t * 1.3))
        show()
        time.sleep(1 / 30.0)
    print("done")

def demo_rich(seconds=10):
    clear()
    rect(0, 0, 127, 63, 0)
    text(6, 11, "OPEN XSYNTH")
    bitmap(104, 2, 16, 16, pack_bits(SMILEY))
    scrolltext(40, "live OSC display * scrolling text * bitmaps * brightness ...   ", 30)
    show()
    print("rich frame sent (scrolltext persists). Pulsing brightness for %ds..." % seconds)
    t0 = time.time()
    while time.time() - t0 < seconds:
        brightness(0.5 + 0.5 * math.sin((time.time() - t0) * 1.6))
        time.sleep(0.05)
    brightness(1.0)
    print("done (display still scrolling; run 'release' to hand back to particles)")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "static"
    if mode == "animate":
        demo_animate(int(sys.argv[2]) if len(sys.argv) > 2 else 12)
    elif mode == "rich":
        demo_rich(int(sys.argv[2]) if len(sys.argv) > 2 else 10)
    elif mode == "release":
        release(); print("released to particle screen")
    elif mode == "invert":
        invert(len(sys.argv) > 2 and sys.argv[2] == "1")
    else:
        demo_static()
