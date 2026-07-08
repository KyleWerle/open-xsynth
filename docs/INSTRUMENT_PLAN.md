# Open XSynth — SuperCollider instrument plan

A standalone, self-contained instrument running **entirely on the device**:
the touch grid triggers and shapes notes, SuperCollider synthesizes audio out
the onboard DAC, and the OLED shows live feedback. Centerpiece interaction:
**tap to play, distance-from-center to shape the sound.**

## Architecture (all on the Pi)

```
  ┌──────────────────────── Raspberry Pi ────────────────────────┐
  │  open-xsynth (openFrameworks)      SuperCollider              │
  │   • reads grid/pots/encoders        • sclang: OSC + mapping   │
  │   • controls ── OSC :8001 ─────────▶  (SynthDef, voices)      │
  │   • OLED   ◀── OSC :8000 ──────────   • scsynth ─▶ JACK ─▶ DAC│
  └───────────────────────────────────────────────────────────────┘
```

- **open-xsynth stays the I/O bridge** (it owns i2c: grid + OLED). It does not
  touch audio.
- **SuperCollider owns audio** via JACK → IQaudIO DAC. No network hop → lowest
  latency. Controls arrive on `localhost:8001`; SC draws feedback to the OLED on
  `localhost:8000`. No conflict, no forwarding.

### Confirmed environment
- SuperCollider **3.7** in apt; audio card 0 = **IQaudIODAC** (pcm512x); 4 cores,
  ~838 MB free.
- Linux scsynth needs **JACK** — `jackd2` drives `hw:IQaudIODAC`.
- Control latency today: tap → OSC ~10–15 ms (200 Hz poller; MCU already at DI=1).

## Phase 0 — stand up the SC stack on the Pi

1. `sudo apt-get install -y supercollider jackd2` (headless; no IDE needed).
2. JACK on the DAC, e.g. `jackd -dalsa -dhw:IQaudIODAC -r44100 -p512 -n3`
   (~512-frame buffer ≈ ~12 ms; tune `-p`/`-n` down later if stable).
3. Boot a server from `sclang` and make a test tone → confirm audio out the jack.
4. In `sclang`: `thisProcess.openUDPPort(8001)` and an `OSCdef` on `/grid/xy` →
   confirm controls arrive. Send a `/oled/text` to `NetAddr("127.0.0.1", 8000)` →
   confirm SC can drive the OLED.

Deliverable: a `.scd` that receives a tap and plays a note, with SC drawing the
note to the OLED. (Proves the whole loop on-device.)

## Phase 1 — the instrument (on the 11×11 grid + smoothing)

**Interaction model (locked)**
- **Mono-legato.** Touch down → note-on (trigger env). Slide to a new cell while
  held → pitch change *without* re-triggering. Lift (`/grid/touch 0`) → release.
- **x → pitch**, scale-quantized (11 cells ≈ 1.5 octaves), selectable scale/root.
- **Distance from center → vibrato DEPTH** (`.lag`-smoothed). Center = no vibrato;
  toward the edges = deeper. The headline expressive gesture.
- **y → dynamics**: maps amplitude from quiet-but-audible (bottom) → loud (top),
  for expressive level control as you play.

**Controls (locked)**
- 4 **encoders** (relative) → **filter cutoff**, **filter resonance**, octave
  shift, scale/root select.
- 6 **pots** → amp **A / D / S / R**, **vibrato rate**, **glide/portamento time**.

**SynthDef (starting point)**: mono 2-osc subtractive voice (saw/pulse + sub),
resonant LPF (cutoff/res from encoders), amp ADSR (pots). Vibrato = sine LFO on
pitch, rate from a pot, **depth from distance-from-center**. Amplitude scaled by
**y**. Portamento (pot) for legato glides between cells.

**OLED feedback** (SC → `/oled/*`): note name, a `/oled/bar` for distance, a marker
dot at the grid cell, current scale/waveform. The display is "free" now that the
protocol exists.

**Autostart**: a second systemd unit (after `open-xsynth`) that launches jack +
scsynth + the `.scd`, so the instrument is live on power-up.

## Phase 2 — centroid firmware (continuous position + pressure)

> **STATUS (validated on hardware — see [FIRMWARE.md](FIRMWARE.md) for the how):**
> - **2a (centroid)** ✅ works — AKS off + centroid of detected keys → smooth
>   half-cell position (0–250), no between-pad stick. Source in repo; not yet
>   wired into open-xsynth (needs the 0–250 read + `/grid/pos`).
> - **2b (analog signal)** ✅ proven viable — the Key Signal register gives a
>   smooth **~130-level pressure** ramp (718→876) + velocity (its slope) +
>   continuous position. This is the path to the "strumming a guitar string"
>   feel Kyle wants. Build = signal-weighted centroid + pressure + velocity,
>   which needs widening the i2c message (firmware checksum + RPi struct in
>   lockstep — details in FIRMWARE.md).
> - North star: **most expressive + lowest latency**, incrementally.
> - Safe flash/restore loop (Pi GPIO SWD + verified backup) is dialed.

Goal: replace the discrete 11-per-axis readout with a **continuous, sub-cell
position** (+ pressure/velocity) for smooth, expressive control.

- Chip is **AT42QT2120** (×2). It exposes **per-key Signal and Reference
  registers** over i2c — the current firmware reads only the detection bitmask
  (register 3) and discards the analog signal.
- **Plan**: in `ReadTouch()`, read the 11 key signal & reference values per axis,
  compute `delta_k = max(0, signal_k − reference_k)`, then a weighted centroid
  `pos = Σ(k · delta_k) / Σ(delta_k)` → continuous 0–10.x.
- **Free bonus — pressure/velocity**: the *sum* of per-key deltas (`Σ delta_k`) is
  a proxy for finger contact area / press density → use it for **velocity** (on
  tap) and/or continuous **pressure**. Position = centroid, pressure = sum, from
  the same read.
- **Report it finer**: widen the touch field in the i2c `Inputs` struct (e.g.
  `uint16_t touch[2]` fixed-point + a pressure byte). This changes the struct size,
  so the **checksum layout and the RPi `InputThread` struct must change in
  lockstep**.
- **Keep it portable / translatable (your ask)**: the RPi side should emit BOTH —
  the existing quantized **`/grid/xy` (0–10)** so all current mappings/clients keep
  working unchanged, AND new **`/grid/pos x y` (normalized 0.0–1.0 floats)** +
  **`/grid/pressure p`**. Continuous users opt into `/grid/pos`; everyone else
  ignores it. Normalized 0–1 maps trivially back to X/Y (`*10`), so it's a clean
  superset, not a breaking change.
- **Bandwidth/rate**: reading ~22 bytes/axis over bit-banged i2c is heavier; may
  reduce the MCU touch scan rate — measure, keep it ≥ ~100 Hz.
- **Flash**: rebuild firmware (`firmware/src`, arm-none-eabi) and reflash via
  **OpenOCD** (already installed). Risk: a bad flash needs an SWD re-flash to
  recover — keep the working `.bin` as a known-good fallback.

Build Phase 1 first; adopt Phase 2 once the coarse grid proves limiting.

## Decisions
- **Locked:** mono-legato; x→pitch; distance→vibrato depth; y→dynamics; filter
  (cutoff/res) on encoders; ADSR + vibrato-rate + glide on pots.
- **Tune by feel:** default scale/root + octave range; oscillator waveform(s);
  glide time; vibrato rate range; how aggressively distance scales vibrato depth.
- **Pi 3 budget:** single mono voice is trivial for scsynth — plenty of headroom.
