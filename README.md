# open-xsynth

Run any software using the controls — and the OLED screen — of Google's
[Open NSynth Super](https://github.com/googlecreativelab/open-nsynth-super).

`open-xsynth` replaces the NSynth Super's on-device neural-audio app with a thin
**OSC bridge**. openFrameworks stays on the device doing what it's good at —
reading the hardware and rendering the OLED — and everything else happens in
*your* program, in *any* language that can speak OSC (Python, Node, SuperCollider,
Max/MSP, Pure Data, TidalCycles, a game engine, whatever).

```
  ┌──────────────── NSynth Super (Raspberry Pi) ────────────────┐
  │  open-xsynth (openFrameworks)                               │
  │     hardware (touch grid, 6 pots, 4 encoders)              │
  │        │  controls OUT  ── OSC ──▶  udp :8001              │
  │     OLED 128×64                                            │
  │        ▲  drawing IN    ◀─ OSC ──   udp :8000             │
  └─────────┼───────────────────────────────┼─────────────────┘
            │                                │
       your program (any language) ──────────┘
       receives controls, sends what to draw
```

Two independent OSC streams:

- **Controls OUT** — finger position on the touch grid, the 6 potentiometers, and
  the 4 rotary encoders are emitted as OSC on **port 8001**.
- **Display IN** — your program sends `/oled/*` drawing commands to **port 8000**
  and openFrameworks renders them on the OLED.

See **[docs/PROTOCOL.md](docs/PROTOCOL.md)** for the complete message reference.

## Status

Working and deployed on hardware:

- ✅ Controls stream out (`/grid/xy`, `/grid/touch`, `/pot`, `/rotary`)
- ✅ OLED renders inbound OSC drawing commands (`/oled/text|line|rect|circle|pixel|bar`)
- ✅ Auto-starts on boot via a systemd service

## Quickstart

On the device (already set up — see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)),
`open-xsynth` runs on boot. From any machine on the same network:

**Draw to the OLED** (Python, no dependencies):

```bash
# set the device IP (see clients/osc_send.py), then:
python clients/osc_send.py static      # a title card + meter
python clients/osc_send.py animate 15  # bouncing ball + sweeping bar, 15s
```

**Watch the controls** (run on the device — controls are sent to localhost:8001):

```bash
python3 clients/osc_dump.py 8001 30    # prints every control event for 30s
```

## Repo layout

| Path | What |
|---|---|
| `app/open-xsynth/` | the openFrameworks application (C++) — control OSC out + OLED in |
| `app/open-xsynth/src/RemoteScreen.*` | renders inbound `/oled/*` drawing commands |
| `app/open-xsynth/src/InputThread.*` | 200 Hz threaded MCU poll → control OSC |
| `sc/` | SuperCollider instruments — `phase2.scd` = multi-engine groovebox (VOICE + BreakSlicer, current build); `phase1.scd` = single-voice fallback |
| `systemd/` | autostart stack — `xsynth-stack.sh` (bundled jackd+SC), `install.sh`, unit files |
| `clients/osc_send.py` | zero-dep OSC client + OLED demo |
| `clients/osc_dump.py` | zero-dep OSC monitor for the control stream |
| `clients/osc_relay.py` | forwards controls 8001 → SC's port (57120) |
| `scripts/rebuild.sh` | one-command rebuild + service restart (on device) |
| `firmware_backup/` | verified backup of the stock MCU firmware (recovery image) |
| `docs/PROTOCOL.md` | full OSC message reference |
| `docs/DEVELOPMENT.md` | device access, build, deploy, gotchas |
| `docs/INSTRUMENT_PLAN.md` | SuperCollider instrument plan + Phase 2 status |
| `docs/FIRMWARE.md` | MCU build/flash/backup + touch-resolution (2a/2b) work |

## Credits

Built on the [Open NSynth Super](https://github.com/googlecreativelab/open-nsynth-super)
hardware and openFrameworks app by Google Creative Lab. Licensed under Apache 2.0
(see [LICENSE](LICENSE)).
