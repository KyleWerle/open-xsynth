#!/bin/bash
# One-command dev rebuild for open-xsynth, run ON the device.
# Stops the service (frees the screen + avoids a "text file busy" relink),
# builds single-threaded (NEVER -j4 on this 1GB Pi), restarts, shows status.
set -e

PROJ=/home/pi/opt/of/apps/open-nsynth/open-xsynth

# ensure writable (no-op if already rw)
sudo mount -o remount,rw / 2>/dev/null || true

echo ">> stopping service"
sudo systemctl stop open-xsynth || true

echo ">> building (-j1)"
cd "$PROJ"
make -j1

echo ">> starting service"
sudo systemctl start open-xsynth
sleep 2
systemctl --no-pager --lines=0 status open-xsynth | head -4
echo ">> done"
