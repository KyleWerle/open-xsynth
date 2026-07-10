# Ableton Link bridge (`linkbridge`)

SuperCollider 3.7 on the Pi has no `LinkClock`, so Ableton Link comes from this small
external peer. It joins the Link session and streams tempo + beat + bar-phase + peer
count to sclang (`/link/state` on `127.0.0.1:57120`, 50 Hz). The SC side lives in
`sc/phase2.scd` (`OSCdef(\linkState)`): it matches Link's tempo and phase-locks the
groovebox clock (hard-snap on first lock, then a gentle PLL), **only while peers > 0**.
A 1 s watchdog drops the lock and free-runs if the bridge stops. `/tune/linkkp` tunes
the PLL gain.

## Build (on the Pi — Raspbian Stretch, g++ 6.3, no cmake)

Link 4.x needs C++17 (`<optional>`); g++ 6.3 is C++14 only, so use **Link 3.1.5**.
The SDK is header-only — clone it to `/dev/shm` (the root FS is ~99% full) and install
only the ~450 KB binary:

```sh
SDK=/home/pi/linkbridge/sdk
git clone --depth 1 --branch Link-3.1.5 --recurse-submodules \
    https://github.com/Ableton/link.git "$SDK"
g++ -std=c++14 -O1 -pthread -DASIO_STANDALONE -DLINK_PLATFORM_LINUX=1 -w \
    -I "$SDK/include" -I "$SDK/modules/asio-standalone/asio/include" \
    link/bridge.cpp -o /home/pi/linkbridge/linkbridge -latomic
rm -rf "$SDK"
```

Gotchas (each cost time):
- **Do NOT pass `--shallow-submodules`** — it fetches the asio submodule tip (1.36, C++17)
  instead of the pinned C++14 asio, and the compile fails on `<optional>`.
- **`-DLINK_PLATFORM_LINUX=1` is required.** Without cmake it isn't auto-defined, so
  `ableton::link::platform` is empty (`Clock`/`IoContext`/`Random` missing) and `htonll`
  is undeclared.

## Run / autostart

`systemd/xsynth-link.service` runs `/home/pi/linkbridge/linkbridge 127.0.0.1 57120`,
enabled to start after `xsynth-instrument`. Restart: `sudo systemctl restart xsynth-link`.

## Test

Enable Ableton Link on another peer on the same LAN (Ableton Live with Link on), set a
tempo, hit play — the XSynth follows tempo + downbeats. Confirm with
`grep 'link LOCK' /tmp/scosc.log`. Verified locking to Live 2026-07-10.
