# open-xsynth — development guide

How to build, deploy, and run `open-xsynth` on the NSynth Super hardware.

## The device

- **Raspberry Pi 3**, Raspbian **Stretch (9)**, hostname `raspberrypi`.
- openFrameworks **v0.9.8** (`linuxarmv6l`) at `/home/pi/opt/of`.
- App lives at `/home/pi/opt/of/apps/open-nsynth/open-xsynth/` (OF resolves at
  `../../..`). Only addon is **ofxOsc** (ships with OF).
- Hardware: MCU on i2c `0x47`, OLED on i2c `0x3d`, both on `/dev/i2c-1`.

## Access

- Default login `pi` / `raspberry`. SSH is enabled.
- **Reach it by name:** `avahi-daemon` is installed, so use **`raspberrypi.local`**
  (no need to chase the DHCP IP):
  ```bash
  ssh pi@raspberrypi.local
  ```
- Fallback if mDNS fails — find the IP by ARP (a Pi 3's MAC starts `b8:27:eb`):
  ```bash
  arp -a | grep -i b8-27-eb        # after pinging the subnet if needed
  ```
- Passwordless SSH is set up from the primary dev machine with a dedicated key
  (`id_ed25519_nsynth`).

## Build

openFrameworks' core library is already compiled, so a normal change rebuilds only
the app (~2 min). From the project dir on the device:

```bash
cd /home/pi/opt/of/apps/open-nsynth/open-xsynth
make -j1            # see the warning below — ALWAYS -j1
```

> ⚠️ **Never `make -j4` (or -j2) for a full/OF build.** Four parallel `g++` on
> openFrameworks' headers exhausts the Pi 3's 1 GB RAM, thrashes swap, and wedges
> the box so hard SSH can't connect. Use **`-j1`**. (An app-only rebuild is light,
> but stay on `-j1` to be safe.)

First-time / full OF builds take ~40 min at `-j1`. App-only rebuilds (after editing
`src/`) are ~2 min, dominated by the final link against the 8 MB OF archive.

## Deploy from the local repo

The repo on the dev machine is the source of truth. To push changes:

```bash
# from repo root, copy changed sources to the device:
scp app/open-xsynth/src/*.cpp app/open-xsynth/src/*.h \
    pi@raspberrypi.local:/home/pi/opt/of/apps/open-nsynth/open-xsynth/src/
# then rebuild + restart:
ssh pi@raspberrypi.local '~/rebuild.sh'
```

## One-command rebuild

[`scripts/rebuild.sh`](../scripts/rebuild.sh) (kept on the device) does the right
dance — stop the service (frees the screen and avoids a "text file busy" relink
error), build `-j1`, restart the service, show status:

```bash
~/rebuild.sh
```

## Running / the service

`open-xsynth` runs as a systemd service and **starts on boot**.

```bash
sudo systemctl status open-xsynth      # state
sudo systemctl restart open-xsynth     # bounce it
sudo systemctl stop open-xsynth        # stop (frees OLED/audio/i2c)
journalctl -u open-xsynth -f           # live logs
```

Service file: `/etc/systemd/system/open-xsynth.service`.

**Revert to the stock neural synth** at any time:

```bash
sudo systemctl disable --now open-xsynth
sudo systemctl enable  --now open-nsynth
```

(The stock `open-nsynth` binary and service are untouched.)

## The SuperCollider instrument

The audio + musical logic is a SuperCollider patch, separate from the `open-xsynth` OF
bridge. It runs as its own self-healing systemd stack — `xsynth-instrument` (bundles
jackd + sclang + scsynth via `xsynth-stack.sh`) plus `xsynth-relay` (control forwarder,
8001 → 57120). The stack loads **`/home/pi/current.scd`**, a symlink to the active build.

- **Current build:** `sc/phase2.scd` — the multi-engine groovebox (VOICE + BreakSlicer).
  `phase1.scd` (single voice) is kept as a fallback.
- **BreakSlicer samples:** `/home/pi/breakbeats/beats00..15.wav` (16-bit mono, 44.1 kHz).

Deploy a new instrument build (repo → device):

```bash
scp sc/phase2.scd pi@raspberrypi.local:/home/pi/phase2.scd
ssh pi@raspberrypi.local 'sudo systemctl restart xsynth-instrument'   # cycles a fresh jackd too
```

Roll between builds without editing anything, then restart the unit:

```bash
ssh pi@raspberrypi.local 'ln -sf /home/pi/phase1.scd /home/pi/current.scd && sudo systemctl restart xsynth-instrument'
```

Install / enable the whole stack from the repo `systemd/` dir: `bash install.sh`. Logs:
`journalctl -u xsynth-instrument -f` (also `/tmp/scosc.log`, `/tmp/jack.log`). All
instrument params tune live over OSC to port 8001 (see the top-level `Open-XSynth.md`).

## Filesystem

The root filesystem is mounted **read-write permanently** (the original build's
`fstab` `ro`-lock on `/` was removed for development; `/boot` is still `ro`).
Backup of the original at `/etc/fstab.bak`.

> If you re-lock `/` to `ro` (safer against SD corruption on hard power-off),
> remember you must `sudo mount -o remount,rw /` before any build, and it reverts
> to `ro` on every reboot.

## Gotchas we hit (so you don't again)

- **`make -j4` OOM** — see the build warning above. `-j1` only.
- **Read-only filesystem** — historically `/` mounted `ro` on boot; builds failed
  with *"Read-only file system"*. Now rw permanently. If you ever see that error,
  `sudo mount -o remount,rw /`.
- **Undefined references to `ofTexture` / `ofVbo` / `ofGLRenderer` at link time** —
  the OF archive (`libopenFrameworks.a`) is incomplete/stale (a partial rebuild can
  re-archive it from a subset of objects). Fix: wipe and do a clean full OF rebuild:
  ```bash
  rm -rf /home/pi/opt/of/libs/openFrameworksCompiled/lib/linuxarmv6l/obj/Release \
         /home/pi/opt/of/libs/openFrameworksCompiled/lib/linuxarmv6l/libopenFrameworks.a
  make -j1        # ~40 min
  ```
- **Stale prebuilt binary** — `app/open-xsynth/bin/open-xsynth` in the repo was built
  against libssl 1.0.0 / boost 1.55, which Stretch no longer has. It won't run; build
  from source on-device instead.
- **"Text file busy" on relink** — you can't overwrite the binary while it's running.
  `sudo systemctl stop open-xsynth` (or `pkill -f open-xsynth`) before building.

## Quick smoke test

```bash
# on the device — watch the control stream:
python3 ~/osc_dump.py 8001 20      # then wiggle the grid/pots/encoders

# from any LAN machine — draw to the OLED:
python clients/osc_send.py static
```
