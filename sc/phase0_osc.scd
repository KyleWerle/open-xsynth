// Phase 0 loop: SC receives controls on :8001, plays a mono note on tap
// (x -> pitch), draws to the OLED on :8000. Runs until killed.
//   QT_QPA_PLATFORM=offscreen sclang phase0_osc.scd
(
s = Server.default;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;
s.options.memSize = 32768;

// controls arrive on SC's default port (57120) via osc_relay.py (8001->57120)
~oled = NetAddr("127.0.0.1", 8000);
~note = nil;

~drawFreq = { |label|
    ~oled.sendMsg("/oled/clear");
    ~oled.sendMsg("/oled/rect", 0, 0, 127, 63, 0);
    ~oled.sendMsg("/oled/text", 8, 14, "OPEN XSYNTH");
    ~oled.sendMsg("/oled/text", 8, 34, label);
    ~oled.sendMsg("/oled/show");
};

s.waitForBoot({
    SynthDef(\blip, { |freq=220, amp=0.25, gate=1|
        var env = EnvGen.kr(Env.adsr(0.005, 0.12, 0.75, 0.25), gate, doneAction:2);
        var sig = Saw.ar(freq)*0.5 + Pulse.ar(freq*0.5, 0.3)*0.3;
        sig = RLPF.ar(sig, 1500, 0.35);
        Out.ar(0, (sig * env * amp).dup);
    }).add;

    s.sync;

    OSCdef(\touch, { |msg|
        if(msg[1] == 1) {
            ~note = Synth(\blip, [\freq, 220]);
        } {
            if(~note.notNil) { ~note.set(\gate, 0); ~note = nil };
        };
    }, '/grid/touch');

    OSCdef(\xy, { |msg|
        var midi = 48 + (msg[1] * 2);
        if(~note.notNil) { ~note.set(\freq, midi.midicps) };
        ~drawFreq.("note " ++ midi.asInteger);
    }, '/grid/xy');

    ~drawFreq.("SC READY - tap!");
    "=== OSC LOOP READY (running until stopped) ===".postln;
});
)
