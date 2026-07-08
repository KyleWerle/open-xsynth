# open-xsynth OSC protocol

Two independent UDP/OSC streams. All numeric ranges below are what the firmware
actually emits / expects.

| Direction | Port | Bound to | Notes |
|---|---|---|---|
| Controls **out** (device → you) | `8001` | `localhost` | sent to `localhost:8001` — see [Consuming controls remotely](#consuming-controls-remotely) |
| Drawing **in** (you → device) | `8000` | `0.0.0.0` | reachable from any host on the LAN |

Ports/hosts are defined in [`app/open-xsynth/src/ofApp.h`](../app/open-xsynth/src/ofApp.h)
(`HOST`, `INPORT`, `OUTPORT`).

---

## Controls OUT — device → `udp:8001`

Emitted as the player touches the surface. The frame loop samples the hardware at
~30 Hz, so expect events at that rate while a control is moving.

| Address | Args | Range | Meaning |
|---|---|---|---|
| `/grid/xy` | `int x`, `int y` | `0–10`, `0–10` | finger cell on the 11×11 touch grid |
| `/grid/touch` | `int state` | `0` / `1` | `1` = finger down (on grid), `0` = finger up |
| `/pot` | `int idx`, `float value` | `0–5`, `0.0–1.0` | a potentiometer moved (also fires once for all 6 at startup) |
| `/rotary` | `int idx`, `int delta` | `0–3`, signed (~`-4…+4`) | encoder turned this tick; only sent when non-zero |
| `/mouse/button` | `int button`, `string` | — , `"down"`/`"up"` | from a USB mouse, dev convenience only |

Notes:
- `/grid/xy` is only sent when the cell changes; `/grid/touch` brackets a gesture.
- `/rotary` is **relative** (a delta per tick), not an absolute position — accumulate
  it yourself.
- `/pot` is sent only when a value changes (plus the startup burst), so you always
  get current values on launch.

## Drawing IN — you → `udp:8000`

The OLED is **128×64**, monochrome (white on black). Drawing is **double-buffered**:
build a frame between `/oled/clear` and `/oled/show`. Numeric args may be sent as
**int or float** — the firmware accepts either, so don't worry about OSC typing.

| Address | Args | Draws |
|---|---|---|
| `/oled/clear` | — | begin a new (empty) pending frame |
| `/oled/text` | `x y "string"` | bitmap text (~8 px tall; `y` ≈ baseline) |
| `/oled/line` | `x1 y1 x2 y2` | a line |
| `/oled/rect` | `x y w h fill` | rectangle; `fill` `0` = outline, `1` = filled |
| `/oled/circle` | `x y r fill` | circle; `fill` `0` = outline, `1` = filled |
| `/oled/pixel` | `x y` | a single dot |
| `/oled/bar` | `x y w h value` | meter: outline box with filled width = `value` (`0.0–1.0`) |
| `/oled/scrolltext` | `y "string" speed` | marquee text that scrolls right→left at `speed` px/sec (animates on its own) |
| `/oled/bitmap` | `x y w h <blob>` | 1-bit packed image (see below) |
| `/oled/show` | — | commit the pending frame to the screen |

Display control (apply immediately, not part of a frame):

| Address | Args | Effect |
|---|---|---|
| `/oled/brightness` | `value` | contrast; `0.0–1.0` (or `0–255`) |
| `/oled/invert` | `0/1` | invert the whole display (white↔black) |
| `/oled/release` | — | hand the OLED back to the built-in particle screen |

Behavior:
- Whenever a frame is committed (`/oled/show`), the remote screen **takes over**
  the OLED and **holds it** until you send `/oled/release`. (It's sticky — a static
  frame stays put; you don't have to re-send it.) `scrolltext` keeps animating from
  the held frame with no further messages.
- Unknown `/oled/*` addresses (and any other addresses) are ignored.

**Bitmap blob format:** row-major, 1 bit per pixel, MSB-first within each byte,
no row padding (a continuous bitstream of `w*h` bits, `ceil(w*h/8)` bytes). A set
bit = lit pixel. See `pack_bits()` in [`clients/osc_send.py`](../clients/osc_send.py).
- A typical frame:

  ```
  /oled/clear
  /oled/rect   0 0 127 63 0
  /oled/text   8 14 "HELLO"
  /oled/bar    8 52 111 8 0.66
  /oled/show
  ```

## Consuming controls remotely

Controls are sent to **`localhost:8001`**, so out of the box only a program running
**on the device** receives them. To consume them from another machine, pick one:

1. **Run your consumer on the Pi** (simplest; also lowest latency).
2. **Change the destination** — edit `HOST` / `OUTPORT` in `ofApp.h` to your
   machine's IP (or a broadcast address) and rebuild.
3. **Relay on-device** — run a tiny script on the Pi that forwards `udp:8001`
   to a remote host.

Drawing *in* has no such limit — port 8000 is bound to `0.0.0.0` and is reachable
from anywhere on the LAN.

## Latency notes

Control input is polled on a **dedicated thread at ~200 Hz** with its own OSC
sender, so control events fire within ~5 ms of a change — independent of the
30 fps render loop. The OLED blit is **dirty-checked** (the slow i2c transfer is
skipped when the frame is unchanged), keeping the render loop free. Localhost UDP
is microseconds; WiFi adds a few ms of jitter.

OSC transport is not the bottleneck. **Don't send sample-rate audio over OSC** —
keep audio in your app's audio domain and use OSC for control-rate data
(≤ ~100 Hz: levels, envelopes, FFT bins) and the display.

(Implementation: [`InputThread.*`](../app/open-xsynth/src/InputThread.h) for the
poller, [`OledScreenDriver.cpp`](../app/open-xsynth/src/OledScreenDriver.cpp) for
the dirty-check.)
