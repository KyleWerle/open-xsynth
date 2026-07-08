#!/bin/bash
# Open XSynth — bundled audio stack as ONE systemd unit.
#
# WHY bundled: a new scsynth can only connect to a *freshly started* jackd. A
# long-running jackd's UNIX socket file gets unlinked, so a new client fails with
# "Cannot connect to server socket". Separate jack/instrument services meant an
# instrument-only restart (manual OR crash auto-restart) reconnected to a stale
# jackd and crash-looped. Bundling cycles a fresh jackd every restart.
#
# The unit provides env + limits: XDG_RUNTIME_DIR (jackd makes no socket without a
# runtime dir), JACK_NO_AUDIO_RESERVATION, QT_QPA_PLATFORM (headless Qt),
# LimitRTPRIO/LimitMEMLOCK (RT for jackd AND scsynth).

# Tear the whole stack down on exit/stop so nothing lingers between restarts.
trap 'kill "$JACK_PID" "$SC_PID" 2>/dev/null' EXIT INT TERM

# Clear stale JACK shm/socket left by a previous (possibly hard-killed) cycle. At
# boot /dev/shm is clean and jackd starts fine; on restart, leftovers block the new
# jackd from creating a connectable socket -> scsynth "server failed to start" ->
# crash loop. Wiping them makes every start as clean as a boot.
rm -f /dev/shm/jack_default_* /dev/shm/jack-[0-9]* /dev/shm/jack-shm-registry /dev/shm/sem.jack_sem.* 2>/dev/null

# 1) JACK on the IQaudIO DAC (48k / 128 / 3 = ~8 ms).
jackd -R -dalsa -P hw:0 -r48000 -p128 -n3 > /tmp/jack.log 2>&1 &
JACK_PID=$!

# 2) Wait until JACK actually serves clients (not just forked).
if ! jack_wait -t 30 -w; then
    echo "xsynth-stack: jackd did not come up within 30s" >&2
    exit 1
fi

# 3) sclang boots scsynth + connects to the fresh jackd. sclang needs a live stdin
#    PIPE (boost::asio aborts on /dev/null); QT_QPA_PLATFORM=offscreen is on the unit.
#    Loads /home/pi/current.scd — a symlink to the active build (currently phase2.scd,
#    the multi-engine groovebox: VOICE + BreakSlicer). Roll between builds without
#    editing this script:  ln -sf /home/pi/phaseN.scd /home/pi/current.scd && restart.
sclang /home/pi/current.scd < <(exec tail -f /dev/null) > /tmp/scosc.log 2>&1 &
SC_PID=$!

# 4) Wait for scsynth to actually appear before watching it (startup race guard).
for i in $(seq 1 40); do pgrep -x scsynth > /dev/null && break; sleep 1; done

# 5) Watchdog: if jackd, sclang, OR scsynth goes missing (2 consecutive checks, to
#    ignore transient races), exit so systemd restarts the WHOLE stack fresh.
misses=0
while true; do
    if kill -0 "$JACK_PID" 2>/dev/null \
       && kill -0 "$SC_PID" 2>/dev/null \
       && pgrep -x scsynth > /dev/null; then
        misses=0
    else
        misses=$((misses + 1))
        [ "$misses" -ge 2 ] && break
    fi
    sleep 2
done
echo "xsynth-stack: a component exited -> tearing down for a fresh restart" >&2
exit 1
