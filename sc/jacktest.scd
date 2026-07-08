// JACK buffer stress test: boot, sustain one representative voice (saw+pulse+
// moving filter) for 12s, then exit. x-runs during this = buffer too small.
(
s = Server.default;
s.options.numOutputBusChannels = 2;
s.options.memSize = 32768;
s.waitForBoot({
    Routine({
        var x = { |freq=220|
            var sig = Saw.ar(freq)*0.5 + Pulse.ar(freq*0.5, 0.3)*0.3;
            sig = RLPF.ar(sig, SinOsc.kr(5).range(800, 2500), 0.3);
            (sig * 0.15).dup;
        }.play;
        12.wait;
        x.free; 0.3.wait;
        "TESTDONE".postln;
        0.exit;
    }).play;
});
)
