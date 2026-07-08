// Open XSynth — Phase 1 instrument: expressive mono voice + inertial cutoff knob.
//   GRID (continuous, from 2b firmware):
//     x (/grid/pos)      -> pitch (scale-quantized, glides between degrees)
//     y (/grid/pos)      -> TONE: saw<->pulse blend + brightness tilt (round low / bright high)
//     pressure           -> INTENSITY: swells loudness + opens filter + blooms vibrato
//     velocity (dp/dt)   -> ATTACK: derived in SC from pressure rise-rate at onset; fires a
//                           fast bright+amp transient (jab = pluck, slow press = swell-in)
//   ENCODERS: 0=scale  1=root  2=CUTOFF (inertial flywheel, base tone macro)  3=octave
//     scale/root/octave use a DETENT feel: ~detTicks notches must fill before the
//     param steps once; turning faster fills notches faster (velocity gain), so a
//     quick flick steps ~1:1 while a slow, careful turn resists. Reversing resets fill.
//   POTS:     0=WEIGHT (inertia friction, provisional)  1=res  2=attack  3=release
//             4=sustain  5=vib-rate
//
//   Live tuning (send floats to Pi:8001, relay forwards to SC):
//     inertia: /tune/friction /tune/kick /tune/step /tune/cap
//     detent:  /tune/dticks /tune/dslow /tune/dfast /tune/dmax /tune/ddecay /tune/dgrace
//     mapping: /map/pamp /map/pbri /map/pvib /map/tbri /map/samp /map/sbri /map/strikeref
//
//   Controls arrive on SC default port 57120 via osc_relay.py (8001->57120).
//   Autostarts on boot (xsynth-instrument.service). Reload: sudo systemctl restart xsynth-instrument
(
s = Server.default;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;
s.options.memSize = 32768;

~oled = NetAddr("127.0.0.1", 8000);
~tele = NetAddr("127.0.0.1", 9000);   // live tuning telemetry (clients/tele_monitor.py listens here)
~fft  = NetAddr("127.0.0.1", 9001);   // live audio-output analysis (clients/fft_monitor.py listens here)
~note = nil;
~scaleIdx = 0;
~root = 0;
~oct = 0;
~lastCell = 5;

~noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];

~scales = [
    (name:"major",   cents:[0,200,400,500,700,900,1100],                                period:1200),
    (name:"minor",   cents:[0,200,300,500,700,800,1000],                                period:1200),
    (name:"penta",   cents:[0,200,400,700,900],                                          period:1200),
    (name:"JImaj",   cents:[0,204,386,498,702,884,1088],                                 period:1200),
    (name:"neutral", cents:[0,200,350,500,700,900,1050],                                 period:1200),
    (name:"19edo",   cents:[0,189,379,505,695,884,1074],                                 period:1200),
    (name:"BohlenP", cents:[0,146,293,439,585,732,878,1024,1170,1317,1463,1609,1756],    period:1902)
];

~baseFreq = 261.63;  // C4 when root=0, oct=0

~p = (cutoff:1500, res:0.3, atk:0.01, dcy:0.2, sus:0.75, rel:0.4, vibRate:5, gliss:0.06, amp:0.5);

// ---- expressive grid state ----
~press = 0;        // continuous pressure 0..1
~yTone = 0.5;      // y -> tone 0..1
~lastPress = 0; ~lastPressT = 0; ~strikePeak = 0;
// touch gating: a real touch must cross ~gate pressure to sound. Phantom/ghost
// touches from cap-sensor baseline noise fire at near-zero pressure (~0.01-0.02),
// so the gate silences them. Velocity = pressure rise-rate up to the gate cross.
~gate = 0.08; ~pending = false; ~sounding = false; ~lastStrike = 0;
// mapping amounts (live-tunable via /map/*)
~m = (ampFloor:0.12, pAmp:1.6, pBri:1.5, pVib:0.6, tBri:1.6, sAmp:0.7, sBri:2.0);
~strikeRef = 25;   // pressure-slope (per sec) that maps to strike=1

// ---- inertial cutoff (encoder 2) ----
~cutoffMin = 150; ~cutoffMax = 4500;   // base range kept in the musical/expressive zone
~hzFromCutPos = { |pos| ~cutoffMin * ((~cutoffMax / ~cutoffMin) ** pos.clip(0, 1)) };
~cutPosFromHz = { |hz|  (hz / ~cutoffMin).log / (~cutoffMax / ~cutoffMin).log };
~cutPos = ~cutPosFromHz.(~p.cutoff);
~cutVel = 0.0;
~step = 0.015; ~kick = 0.030; ~friction = 0.88; ~velCap = 0.45; ~fps = 45; ~velEps = 0.0006;

// ---- detent accumulators (encoders 0=scale 1=root 3=octave) ----
// Each physical tick fills a notch accumulator; ~detTicks notches advance one param
// step at slow speed. Turning faster makes each tick fill more notches (velocity gain,
// up to ~detMax), so a quick flick steps ~1:1 while a careful turn resists. Reversing
// direction restarts the fill. Idle fill can relax back (~detDecay, default = hold).
~detAccum = [0, 0, 0, 0];        // fractional notch fill per encoder (0..~detTicks)
~detDir   = [0, 0, 0, 0];        // last turn direction; reversal resets the fill
~detLastT = [0, 0, 0, 0];        // last tick time per encoder (for velocity)
~detRate  = [0, 0, 0, 0];        // EMA of tick rate (ticks/sec)
~detTicks = 4;                   // notches per step at slow speed ("a few")
~detSlow  = 4;                   // <= this ticks/sec -> no gain (full resistance)
~detFast  = 22;                  // >= this ticks/sec -> full velocity gain
~detMax   = 4;                   // per-tick fill at full speed (== ~detTicks -> steps 1:1)
~detDecay = 0.80;                // idle fill decay per frame (1.0 = hold; <1 springs back to 0, ~0.5s at 0.80)
~detGrace = 1.0;                 // seconds idle before the fill springs back

// signed steps advanced by one physical tick (idx, signed delta d) -> usually 0 or +-1
~detStep = { |idx, d|
    var now = Main.elapsedTime;
    var dt  = now - ~detLastT[idx];
    var rate = if(dt > 0) { 1 / dt } { ~detFast };
    var dir = d.sign;
    var mult, steps = 0;
    ~detLastT[idx] = now;
    ~detRate[idx]  = (~detRate[idx] * 0.5) + (rate * 0.5);              // EMA smooth the speed
    mult = ~detRate[idx].linlin(~detSlow, ~detFast, 1, ~detMax).clip(1, ~detMax);
    if((dir != ~detDir[idx]) and: { ~detDir[idx] != 0 }) { ~detAccum[idx] = 0 };  // reversal resets
    ~detDir[idx] = dir;
    ~detAccum[idx] = ~detAccum[idx] + (d.abs * mult);
    steps = (~detAccum[idx] / ~detTicks).floor.asInteger;
    if(steps > 0) { ~detAccum[idx] = ~detAccum[idx] - (steps * ~detTicks) };
    steps * dir;
};

// ---- OLED focus state ----
~focusParam = nil;
~focusLabel = ""; ~focusNorm = 0; ~focusStr = ""; ~focusMomentum = false;
~focusUntil = 0; ~focusHold = 1.5; ~dirty = true;
~focusFill = nil; ~focusFillMax = 4; ~focusDetIdx = nil;   // notch-fill readout for detent encoders

~showFocus = { |label, norm, valStr, momentum = false|
    ~focusParam = label.asSymbol;
    ~focusLabel = label; ~focusNorm = norm.clip(0, 1); ~focusStr = valStr;
    ~focusMomentum = momentum;
    ~focusFill = nil; ~focusDetIdx = nil;                  // default: no notch bar (pots, cutoff)
    ~focusUntil = Main.elapsedTime + ~focusHold;
    ~dirty = true;
};

// focus display for a detent encoder — shows the value plus the filling notch bar
~showDetent = { |label, norm, valStr, idx|
    ~showFocus.(label, norm, valStr);
    ~focusFill = ~detAccum[idx]; ~focusFillMax = ~detTicks; ~focusDetIdx = idx;
    ~dirty = true;
};

~fmtHz = { |hz| if(hz >= 1000) { (hz / 1000).round(0.1).asString ++ "k" } { hz.round(1).asInteger.asString } };

~freqFor = { |cell|
    var sc = ~scales[~scaleIdx];
    var n = sc[\cents].size;
    var idx = cell + (~oct * n);
    var per = idx div: n;
    var deg = idx mod: n;
    var cents = (per * sc[\period]) + sc[\cents][deg] + (~root * 100);
    ~baseFreq * (2 ** (cents / 1200));
};

// push current mapping amounts onto a running voice
~applyMap = { |syn|
    if(syn.notNil) {
        syn.set(\ampFloor, ~m.ampFloor, \pAmp, ~m.pAmp, \pBri, ~m.pBri, \pVib, ~m.pVib, \tBri, ~m.tBri, \sAmp, ~m.sAmp, \sBri, ~m.sBri);
    };
};

~drawPlay = {
    var sc = ~scales[~scaleIdx];
    ~oled.sendMsg("/oled/clear");
    ~oled.sendMsg("/oled/rect", 0, 0, 127, 63, 0);
    ~oled.sendMsg("/oled/text", 4, 11, "scl " ++ sc[\name]);
    ~oled.sendMsg("/oled/text", 4, 23, "root " ++ ~noteNames[~root] ++ " o" ++ ~oct);
    ~oled.sendMsg("/oled/text", 4, 37, "prs");
    ~oled.sendMsg("/oled/bar", 30, 31, 92, 7, ~press.clip(0, 1));
    ~oled.sendMsg("/oled/text", 4, 51, "tone");
    ~oled.sendMsg("/oled/bar", 30, 45, 92, 7, ~yTone.clip(0, 1));
    ~oled.sendMsg("/oled/show");
};

~drawFocus = {
    ~oled.sendMsg("/oled/clear");
    ~oled.sendMsg("/oled/rect", 0, 0, 127, 63, 0);
    ~oled.sendMsg("/oled/text", 6, 14, ~focusLabel);
    ~oled.sendMsg("/oled/text", 78, 14, ~focusStr);
    ~oled.sendMsg("/oled/bar", 6, 22, 116, 16, ~focusNorm);
    case
    { ~focusMomentum } {
        ~oled.sendMsg("/oled/text", 6, 53, "spin");
        ~oled.sendMsg("/oled/bar", 40, 48, 82, 8, (~cutVel.abs / ~velCap).clip(0, 1));
    }
    { ~focusFill.notNil } {                                  // segmented notch fill toward next step
        var n    = ~focusFillMax.floor.asInteger.max(1);
        var x0   = 40, w = 82, gap = 2;
        var cw   = ((w - ((n - 1) * gap)) / n).floor.asInteger.max(1);
        var lit  = ~focusFill.floor.asInteger.clip(0, n);
        ~oled.sendMsg("/oled/text", 6, 53, "notch");
        n.do { |i|
            ~oled.sendMsg("/oled/rect", x0 + (i * (cw + gap)), 48, cw, 8, if(i < lit, 1, 0));
        };
    };
    ~oled.sendMsg("/oled/show");
};

~drawUI = {
    if(~focusParam.notNil and: { Main.elapsedTime < ~focusUntil }) { ~drawFocus.() } { ~drawPlay.() };
};

s.waitForBoot({
    SynthDef(\voice, { |freq=220, gate=1, baseAmp=0.32, cutoff=1500, res=0.3,
                       atk=0.01, dcy=0.2, sus=0.75, rel=0.4, gliss=0.06, vibRate=5,
                       press=0, strike=0, tone=0.5,
                       ampFloor=0.12, pAmp=1.6, pBri=1.5, pVib=0.6, tBri=1.6, sAmp=0.7, sBri=2.0|
        var pitch  = Lag.kr(freq, gliss);
        var pr     = Lag.kr(press, 0.05);                       // smoothed pressure
        var tn     = Lag.kr(tone, 0.05);                        // smoothed y-tone
        var vibAmt = (pVib * pr).clip(0, 1);                    // pressure blooms vibrato
        var vib    = SinOsc.kr(vibRate) * vibAmt * pitch * 0.04;
        var f      = pitch + vib;
        var sub    = SinOsc.ar(f * 0.5) * 0.25;
        var mix    = (Saw.ar(f) * tn) + (Pulse.ar(f, 0.25) * (1 - tn));   // y: round <-> bright
        var osc    = (mix * 0.5) + sub;
        var env    = EnvGen.kr(Env.adsr(atk, dcy, sus, rel), gate, doneAction: 2);
        var hit    = EnvGen.kr(Env.perc(0.004, 0.08), doneAction: 0) * strike;  // one-shot strike transient at note birth
        var amp    = baseAmp * env * (ampFloor + (pr * pAmp) + (hit * sAmp));
        var co     = cutoff * (2 ** ((tBri * (tn - 0.5)) + (pBri * pr) + (sBri * hit)));
        var sig    = RLPF.ar(osc, co.clip(80, 14000), res.linexp(0, 1, 1.0, 0.05));
        Out.ar(0, (sig * amp * 0.6).tanh.dup);
    }).add;

    // output analyzer — taps bus 0 at the tail, streams level + spectrum so we can "see" the sound
    SynthDef(\analyzer, {
        var in    = Mix(In.ar(0, 2));
        var amp   = Amplitude.kr(in, 0.01, 0.1).ampdb.clip(-90, 6);
        var chain = FFT(LocalBuf(1024), in);
        var cent  = SpecCentroid.kr(chain);
        var flat  = SpecFlatness.kr(chain);
        var bands = [125, 250, 500, 1000, 2000, 4000, 8000].collect { |fc|
            Amplitude.kr(BPF.ar(in, fc, 0.7)).ampdb.clip(-90, 6)
        };
        SendReply.kr(Impulse.kr(15), '/anlz', [amp, cent, flat] ++ bands);
    }).add;

    s.sync;

    ~analyzer = Synth.tail(s.defaultGroup, \analyzer);                       // analysis runs after voices
    OSCdef(\anlz, { |msg| ~fft.sendMsg("/fft", *(msg[3..])) }, '/anlz');     // forward to fft_monitor.py

    OSCdef(\touch, { |msg|
        if(msg[1] == 1) {
            // ARM a pending touch — do not sound until pressure crosses ~gate.
            // Kills phantom/ghost touches (they never build real pressure).
            ~pending = true; ~sounding = false;
            ~strikePeak = 0; ~lastPress = 0; ~lastPressT = Main.elapsedTime;
            ~focusParam = nil;
        } {
            if(~sounding and: { ~note.notNil }) { ~note.set(\gate, 0) };
            ~note = nil; ~pending = false; ~sounding = false; ~press = 0; ~dirty = true;
        };
    }, '/grid/touch');

    OSCdef(\pos, { |msg|
        var x = msg[1], y = msg[2];
        var cell = x.round.asInteger.clip(0, 10);
        ~lastCell = cell;                               // always track (used at commit)
        ~yTone = (y / 10).clip(0, 1);
        if(~sounding and: { ~note.notNil }) {           // only react to a real, sounding note
            ~note.set(\freq, ~freqFor.(cell), \tone, ~yTone);
            ~dirty = true;
        };
    }, '/grid/pos');

    OSCdef(\pressure, { |msg|
        var p = msg[1];
        var now = Main.elapsedTime;
        var dt = now - ~lastPressT;
        var slope = if(dt > 0) { (p - ~lastPress) / dt } { 0 };
        ~lastPress = p; ~lastPressT = now;
        case
        { ~pending } {                                  // waiting to confirm a real touch
            if(slope > 0) { ~strikePeak = max(~strikePeak, slope) };
            if(p >= ~gate) {                            // crossed the gate -> commit the note
                var sv = (~strikePeak / ~strikeRef).clip(0, 1);
                ~pending = false; ~sounding = true; ~press = p.clip(0, 1); ~lastStrike = sv;
                ~note = Synth(\voice, [
                    \freq, ~freqFor.(~lastCell), \baseAmp, ~p.amp, \cutoff, ~p.cutoff, \res, ~p.res,
                    \atk, ~p.atk, \dcy, ~p.dcy, \sus, ~p.sus, \rel, ~p.rel, \gliss, ~p.gliss,
                    \vibRate, ~p.vibRate, \press, ~press, \tone, ~yTone, \strike, sv
                ]);
                ~applyMap.(~note);
                ~dirty = true;
            };
        }
        { ~sounding and: { ~note.notNil } } {           // sustaining: pressure modulates the voice
            ~press = p.clip(0, 1);
            ~note.set(\press, ~press);
            ~dirty = true;
        };
    }, '/grid/pressure');

    OSCdef(\rotary, { |msg|
        var idx = msg[1], d = msg[2];
        case
        { idx == 0 } {
            var steps = ~detStep.(0, d);
            if(steps != 0) {
                ~scaleIdx = (~scaleIdx + steps).wrap(0, ~scales.size - 1).asInteger;
                if(~note.notNil) { ~note.set(\freq, ~freqFor.(~lastCell)) };
            };
            ~showDetent.("SCALE", ~scaleIdx / (~scales.size - 1), ~scales[~scaleIdx][\name], 0);
        }
        { idx == 1 } {
            var steps = ~detStep.(1, d);
            if(steps != 0) {
                ~root = (~root + steps) % 12;
                if(~note.notNil) { ~note.set(\freq, ~freqFor.(~lastCell)) };
            };
            ~showDetent.("ROOT", ~root / 11, ~noteNames[~root], 1);
        }
        { idx == 2 } {
            ~cutPos = (~cutPos + (d * ~step)).clip(0, 1);
            ~cutVel = (~cutVel + (d * ~kick)).clip(~velCap.neg, ~velCap);
            ~p.cutoff = ~hzFromCutPos.(~cutPos);
            if(~note.notNil) { ~note.set(\cutoff, ~p.cutoff) };
            ~showFocus.("CUTOFF", ~cutPos, ~fmtHz.(~p.cutoff), true);
        }
        { idx == 3 } {
            var steps = ~detStep.(3, d);
            if(steps != 0) {
                ~oct = (~oct + steps).clip(-3, 3);
                if(~note.notNil) { ~note.set(\freq, ~freqFor.(~lastCell)) };
            };
            ~showDetent.("OCTAVE", (~oct + 3) / 6, "o" ++ ~oct, 3);
        };
    }, '/rotary');

    OSCdef(\pot, { |msg|
        var idx = msg[1], v = msg[2];
        case
        { idx == 0 } { ~friction = v.linlin(0, 1, 0.70, 0.97);
            ~showFocus.("WEIGHT", v, ~friction.round(0.01).asString) }
        { idx == 1 } { ~p.res = v; if(~note.notNil){~note.set(\res, v)};
            ~showFocus.("RES", v, v.round(0.01).asString) }
        { idx == 2 } { ~p.atk = v.linexp(0, 1, 0.002, 1.0); if(~note.notNil){~note.set(\atk, ~p.atk)};
            ~showFocus.("ATTACK", v, (~p.atk * 1000).round(1).asInteger.asString ++ "ms") }
        { idx == 3 } { ~p.rel = v.linexp(0, 1, 0.02, 2.5); if(~note.notNil){~note.set(\rel, ~p.rel)};
            ~showFocus.("RELEASE", v, ~p.rel.round(0.01).asString ++ "s") }
        { idx == 4 } { ~p.sus = v; if(~note.notNil){~note.set(\sus, v)};
            ~showFocus.("SUSTAIN", v, v.round(0.01).asString) }
        { idx == 5 } { ~p.vibRate = v.linexp(0, 1, 0.5, 12); if(~note.notNil){~note.set(\vibRate, ~p.vibRate)};
            ~showFocus.("VIB RATE", v, ~p.vibRate.round(0.1).asString ++ "hz") };
    }, '/pot');

    // ---- live tuning: inertia feel ----
    OSCdef(\tuneFric, { |msg| ~friction = msg[1].clip(0.5, 0.995); ("friction=" ++ ~friction).postln }, '/tune/friction');
    OSCdef(\tuneKick, { |msg| ~kick = msg[1].max(0);             ("kick=" ++ ~kick).postln }, '/tune/kick');
    OSCdef(\tuneStep, { |msg| ~step = msg[1].max(0);             ("step=" ++ ~step).postln }, '/tune/step');
    OSCdef(\tuneCap,  { |msg| ~velCap = msg[1].max(0.05);        ("cap=" ++ ~velCap).postln }, '/tune/cap');

    // ---- live tuning: detent feel (scale/root/octave notches) ----
    OSCdef(\tuneDticks, { |msg| ~detTicks = msg[1].max(1);          ("dticks=" ++ ~detTicks).postln }, '/tune/dticks');
    OSCdef(\tuneDslow,  { |msg| ~detSlow  = msg[1].max(0.1);        ("dslow="  ++ ~detSlow).postln }, '/tune/dslow');
    OSCdef(\tuneDfast,  { |msg| ~detFast  = msg[1].max(1);          ("dfast="  ++ ~detFast).postln }, '/tune/dfast');
    OSCdef(\tuneDmax,   { |msg| ~detMax   = msg[1].max(1);          ("dmax="   ++ ~detMax).postln }, '/tune/dmax');
    OSCdef(\tuneDdecay, { |msg| ~detDecay = msg[1].clip(0.5, 1.0);  ("ddecay=" ++ ~detDecay).postln }, '/tune/ddecay');
    OSCdef(\tuneDgrace, { |msg| ~detGrace = msg[1].max(0);          ("dgrace=" ++ ~detGrace).postln }, '/tune/dgrace');

    // ---- live tuning: expression mapping amounts ----
    OSCdef(\mapPamp, { |msg| ~m.pAmp = msg[1].max(0); ~applyMap.(~note); ("pAmp=" ++ ~m.pAmp).postln }, '/map/pamp');
    OSCdef(\mapPbri, { |msg| ~m.pBri = msg[1].max(0); ~applyMap.(~note); ("pBri=" ++ ~m.pBri).postln }, '/map/pbri');
    OSCdef(\mapPvib, { |msg| ~m.pVib = msg[1].max(0); ~applyMap.(~note); ("pVib=" ++ ~m.pVib).postln }, '/map/pvib');
    OSCdef(\mapTbri, { |msg| ~m.tBri = msg[1].max(0); ~applyMap.(~note); ("tBri=" ++ ~m.tBri).postln }, '/map/tbri');
    OSCdef(\mapSamp, { |msg| ~m.sAmp = msg[1].max(0); ~applyMap.(~note); ("sAmp=" ++ ~m.sAmp).postln }, '/map/samp');
    OSCdef(\mapSbri, { |msg| ~m.sBri = msg[1].max(0); ~applyMap.(~note); ("sBri=" ++ ~m.sBri).postln }, '/map/sbri');
    OSCdef(\mapSref, { |msg| ~strikeRef = msg[1].max(1); ("strikeRef=" ++ ~strikeRef).postln }, '/map/strikeref');
    OSCdef(\mapGate, { |msg| ~gate = msg[1].clip(0, 1); ("gate=" ++ ~gate).postln }, '/map/gate');
    OSCdef(\mapAfloor, { |msg| ~m.ampFloor = msg[1].max(0); ~applyMap.(~note); ("ampFloor=" ++ ~m.ampFloor).postln }, '/map/afloor');
    OSCdef(\mapCut,    { |msg| ~p.cutoff = msg[1].clip(80, 14000); ~cutPos = ~cutPosFromHz.(~p.cutoff); if(~note.notNil){~note.set(\cutoff, ~p.cutoff)}; ("cut=" ++ ~p.cutoff).postln }, '/map/cut');

    // ---- inertial integrator + OLED heartbeat (~45 fps) ----
    ~physics = Routine({
        var dt = 1 / ~fps;
        loop {
            var now = Main.elapsedTime;
            // live telemetry for tuning — press, strike, y-tone, cutoff base/modulated, amp factor
            ~tele.sendMsg("/tele", ~press.asFloat, ~lastStrike.asFloat, ~yTone.asFloat,
                ~cutPos.asFloat, ~p.cutoff.asFloat,
                (~p.cutoff * (2 ** ((~m.tBri * (~yTone - 0.5)) + (~m.pBri * ~press)))).clip(80, 14000).asFloat,
                (~p.amp * (~m.ampFloor + (~press * ~m.pAmp))).asFloat,
                if(~sounding, 1, 0));
            if(~cutVel.abs > ~velEps) {
                ~cutPos = (~cutPos + (~cutVel * dt)).clip(0, 1);
                if((~cutPos <= 0) or: { ~cutPos >= 1 }) { ~cutVel = 0 };
                ~cutVel = ~cutVel * ~friction;
                if(~cutVel.abs <= ~velEps) { ~cutVel = 0 };
                ~p.cutoff = ~hzFromCutPos.(~cutPos);
                if(~note.notNil) { ~note.set(\cutoff, ~p.cutoff) };
                ~showFocus.("CUTOFF", ~cutPos, ~fmtHz.(~p.cutoff), true);
            };
            // detent fills relax back after idle (physics spring-back; ~detDecay=1.0 = hold)
            if(~detDecay < 1.0) {
                [0, 1, 3].do { |i|
                    if((~detAccum[i] > 0) and: { (now - ~detLastT[i]) > ~detGrace }) {
                        ~detAccum[i] = ~detAccum[i] * ~detDecay;
                        if(~detAccum[i] < 0.02) { ~detAccum[i] = 0; ~detDir[i] = 0 };
                        if(i == ~focusDetIdx) { ~focusFill = ~detAccum[i]; ~dirty = true };
                    };
                };
            };
            if(~focusParam.notNil and: { now >= ~focusUntil }) {
                ~focusParam = nil; ~dirty = true;
            };
            if(~dirty) { ~drawUI.(); ~dirty = false };
            dt.wait;
        };
    }).play(SystemClock);

    ~dirty = true; ~drawUI.();
    "=== PHASE1 READY — expressive voice (x,y,press,vel) + inertial cutoff ===".postln;
});
)
