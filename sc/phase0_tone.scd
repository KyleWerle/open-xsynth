// Phase 0 smoke test: boot the server (on a running JACK), play a 2s tone,
// then exit. Run headless on the Pi:  sclang phase0_tone.scd
(
s = Server.default;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;
s.options.memSize = 32768;  // sample rate inherited from JACK (48 kHz)

s.waitForBoot({
    Routine({
        "=== SERVER BOOTED ===".postln;
        x = { |freq=440| (SinOsc.ar(freq) * 0.2).dup }.play;
        1.5.wait;
        x.set(\freq, 660);
        1.5.wait;
        x.free;
        0.5.wait;
        "=== TONE DONE ===".postln;
        0.exit;
    }).play;
});
)
