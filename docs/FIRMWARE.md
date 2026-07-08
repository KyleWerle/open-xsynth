# Open XSynth — MCU firmware (touch/pots/encoders)

The mainboard MCU (**STM32F030K6**, 32 K flash / 4 K RAM) reads the hardware and
serves it to the Pi over i2c. Source: `open-nsynth-super/firmware/src/` (stock repo;
our changes live there). This doc covers building/flashing it and the touch work.

## Build & flash (all on the Pi)

Everything's already installed on the device (`arm-none-eabi-gcc`, `openocd`, and the
STM32Cube F0 library at `firmware/cube/`).

```bash
cd /home/pi/open-nsynth-super/firmware/src
make                  # -> ../bin/main.elf
sudo openocd --file openocd.cfg --command 'program ../bin/main.elf verify reset exit'
```

**OpenOCD programs the MCU over the Pi's own GPIO as an SWD adapter** (no external
programmer): SWCLK=GPIO25, SWDIO=GPIO24, reset=GPIO23 (see `openocd.cfg`). Stop
`open-xsynth` first (it shares the i2c bus and the flash halts the MCU).

### Backup & restore — ALWAYS back up before flashing
```bash
# backup (32 K dump):
sudo openocd --file openocd.cfg --command 'dump_image /home/pi/fw_backup_orig.bin 0x08000000 0x8000'
# restore:
sudo openocd --file openocd.cfg --command 'program /home/pi/fw_backup_orig.bin verify reset exit 0x08000000'
```
A verified backup of the original firmware is kept at
`firmware_backup/fw_backup_orig.bin` (repo) and `/home/pi/fw_backup_orig.bin` (device).

### Gotchas
- **`030.ld` shipped capping FLASH at 16 K, but the chip has 32 K** — we bumped it to
  32 K. The stock firmware was near the 16 K ceiling.
- **Cortex-M0 has no hardware divide** — integer `/` pulls in the soft-division lib
  (~1 K+). Fine now with 32 K, but keep hot paths division-free where easy.
- **Installing SuperCollider/JACK can remove `librtaudio-dev` + alsa dev headers**,
  which silently changes openFrameworks' compiler flags and forces a full OF
  recompile that then fails on `RtAudio.h`. Fix:
  `sudo apt-get install --reinstall librtaudio-dev libasound2-dev`, then `make -j1`.
- After flashing, the touch chips (**AT42QT2120 ×2**) recalibrate their baseline. A
  bad power-on (finger resting on the grid, or rapid resets mid-flash) leaves a bad
  baseline → phantom triggers / no-touch (255). A clean **power-cycle with the grid
  clear** fixes it. **Always test touch with a real, deliberate finger and a clean
  baseline — never infer from an unattended capture.**

## Touch resolution work

The grid is two 11-key capacitive strips (one per axis). Stock firmware reports a
discrete `0..10` (first detected key) → felt steppy/sticky between pads.

### Phase 2a — centroid (VALIDATED, source in repo)
- `InitTouch`: **AKS disabled** (Key Control reg `28+key` = `0` instead of `4`) so
  adjacent keys co-detect.
- `ReadTouch`: **centroid of all detected keys** → sub-cell position, reported as
  **0..250** in the `touch[axis]` byte (255 = no touch). RPi divides by 25.0.
- Result on hardware: idle `(255,255)` clean, center `(125,125)`, corner `(0,0)`,
  slow slide = smooth ~12.5 steps (**half-cell**, no stick). ~2× resolution.
- NOTE: needs open-xsynth's `InputThread` updated to read 0–250 (emit `/grid/pos`
  continuous + `/grid/xy` rounded) before it's usable in the instrument.

### Phase 2b — analog signal (BUILT + VALIDATED)
On the MCU: posX **173** / posY **150** / pressure **175** distinct levels —
fully continuous. RPi `InputThread` updated in lockstep (20-byte struct, 4-word
checksum) and emits `/grid/pos`, `/grid/pressure`, `/grid/xy` (rounded), `/grid/touch`.
~2% of reads checksum-mismatch (heavier i2c races the poll; harmless, skipped;
optimize later by caching the reference reads). Remaining: SC patch to use the
continuous streams (the strum).

The richer source for *expression* (pressure + velocity + truly continuous position):
- **Key Signal** registers at `0x34 + 2*key` (2 bytes, **LITTLE-ENDIAN**:
  `signal = buf[1]*256 + buf[0]` — reading it big-endian looks like 0–65535 garbage).
  Reference data at `0x4C + 2*key` (subtract for a baseline-independent delta).
- Measured: a finger pressure ramp moved the raw signal **~718→876, ~130 smooth
  levels** = rich continuous **pressure**; **velocity** = its slope.
- Real build: signal-weighted centroid (continuous position) + pressure + velocity,
  which means **widening the i2c message**. Current `Inputs` = `touch[2] + rotaries[4]
  + pots[6]` = 12 B, checksum over 3×u32 (`CopyInputs` is hardcoded). Plan: e.g.
  `posX, posY, pressure, velocity` (4 B) + `rotaries[4]` + `pots[6]`+2 pad = 16 B
  (4×u32); update `CopyInputs` checksum (3→4 u32) **and** the RPi `InputThread`
  struct/read-size in lockstep.

## Current device state
**Phase 2b firmware is flashed** (continuous position + pressure, 20-byte message).
The open-xsynth `InputThread` is updated to match and was rebuilding at last check
(full OF recompile after the rtaudio-dev restore). To finish: let the OF build
complete → start `open-xsynth` → update `sc/phase1.scd` to consume `/grid/pos` +
`/grid/pressure` → play. Firmware + open-xsynth are now both 2b — they must stay in
lockstep (don't flash the old 0–10 firmware against the 2b app, or vice-versa).
