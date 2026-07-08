# XSynth MCU firmware — Phase 2b (archived source + prebuilt image)

The STM32F030K6 MCU on the NSynth Super PCB reads the touch grid, 6 pots, and 4
encoders and hands them to the Raspberry Pi over a bit-banged i2c bus. This is the
firmware with **Kyle's Phase 2b modifications**: a signal-weighted centroid giving
**continuous grid position + per-key pressure** (vs. the stock coarse 0–10 grid), and
a widened i2c `Inputs` struct. Archived here because it otherwise lived only on the
device's SD card.

## What's here / what's not
- `src/` — the 2b source (`main.cc` + helpers, `Makefile`, linker `030.ld`, `openocd.cfg`).
- `bin/main.elf` — the **prebuilt, known-good 2b image** (~16 KB flash). Flashable as-is; no rebuild needed.
- `utils/` — upstream helper scripts.
- **NOT included: `cube/`** — the STM32Cube HAL (~351 MB of ST vendor code). Restore it from the
  open-nsynth-super upstream (`googlecreativelab/open-nsynth-super`, `firmware/cube/`) or the device
  before rebuilding; the Makefile references it. You do NOT need it just to *flash* `main.elf`.

## Build (needs `arm-none-eabi-gcc` + `cube/`)
```
cd src && make          # -> ../bin/main.elf (text+data ~16.2 KB, fits the 32 K flash)
```

## Flash (on the Pi, over its GPIO SWD — SWCLK=25, SWDIO=24, srst=23 per openocd.cfg)
```
sudo systemctl stop open-xsynth              # free the MCU/i2c first
cd src
# backup the target's current image first (root FS is full -> /dev/shm):
sudo openocd --file openocd.cfg --command "dump_image /dev/shm/stock.bin 0x08000000 0x8000" --command shutdown
# flash + verify + reset:
sudo openocd --file openocd.cfg --command "program ../bin/main.elf verify reset exit"
sudo systemctl start open-xsynth
```
Then **hard power-cycle the unit hands-off** so the AT42QT2120 touch chips calibrate a clean
baseline (flashing churns it). Verified device id `0x10006444`, 32 K flash, SWD DPIDR `0x0bb11477`.

Stock MCU images (rollback) are in `../firmware_backup/` (`fw_backup_orig.bin` = original unit;
`unit2_stock.bin` = the current unit's pre-2b image).

## 2b i2c format (what the Pi's InputThread + `mcu_read.py` expect)
Write `0` (snapshot), read **20 bytes**: `posX, posY, pressure, pad` (bytes) then `rot[4]`,
`pots[6]`, `pad[2]`, then a `u32` checksum. Layout is 4×`u32` little-endian; checksum =
`(0xaa55aa55 + sum(4 u32 words)) & 0xffffffff`. Idle (no touch) = `pos=(255,255) press=0`.
The stock firmware's struct is 12 bytes / 3×`u32` — mixing stock MCU with the 2b InputThread
fails the checksum and the grid goes dead, so keep the MCU and the open-xsynth build in lockstep.
