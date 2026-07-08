#!/bin/bash
# Install + enable the Open XSynth autostart stack on the Pi.
#   scp this whole systemd/ dir to the Pi, then: bash install.sh
#
# Two units: xsynth-instrument (bundled jackd + sclang/scsynth, self-healing via a
# watchdog) and xsynth-relay (8001->57120). jackd is NO LONGER a separate service —
# it's bundled so every restart cycles a fresh jackd (fresh socket).
#
# The stack runs /home/pi/current.scd, a symlink to the active build. The instrument
# .scd files (phase1.scd, phase2.scd) are deployed separately (scp to /home/pi/); this
# script only sets up systemd + points current.scd at phase2.scd (the default) if unset.
# Also required on the Pi for the BreakSlicer engine: /home/pi/breakbeats/beats00..15.wav.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"

echo ">> stop any manual stack"
pkill -f osc_relay.py 2>/dev/null || true
pkill -9 sclang   2>/dev/null || true
pkill -9 scsynth  2>/dev/null || true
pkill jackd       2>/dev/null || true

echo ">> retire the OLD separate jack unit + wrapper (now bundled)"
if systemctl list-unit-files 2>/dev/null | grep -q '^xsynth-jack.service'; then
    sudo systemctl disable --now xsynth-jack.service 2>/dev/null || true
fi
sudo rm -f /etc/systemd/system/xsynth-jack.service
rm -f /home/pi/xsynth-sc.sh
sleep 2

echo ">> install wrapper -> /home/pi/xsynth-stack.sh"
install -m 0755 "$SRC/xsynth-stack.sh" /home/pi/xsynth-stack.sh

echo ">> point current.scd at the active build (default phase2.scd) if unset"
if [ ! -e /home/pi/current.scd ]; then
    ln -sf /home/pi/phase2.scd /home/pi/current.scd
fi

echo ">> install unit files -> /etc/systemd/system/"
sudo install -m 0644 "$SRC/xsynth-instrument.service" /etc/systemd/system/
sudo install -m 0644 "$SRC/xsynth-relay.service"      /etc/systemd/system/
sudo systemctl daemon-reload

echo ">> enable (autostart on boot) + (re)start now"
sudo systemctl enable  xsynth-instrument.service xsynth-relay.service
sudo systemctl restart xsynth-instrument.service
sudo systemctl restart xsynth-relay.service

echo ">> done."
