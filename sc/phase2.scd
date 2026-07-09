// Open XSynth — Phase 2: multi-engine groovebox.
//   Several engines play AT ONCE, mixed to the DAC. Encoder 3 is a global ENGINE-SELECT
//   context menu; every other control (enc 0/1/2, the 6 pots, the grid) addresses the
//   FOCUSED engine. Non-focused engines keep sounding. A shared TempoClock emits 16th-note
//   steps that drive every engine's sequencer in lockstep.
//
//   Current scope: breakbeat slicer + Kaoss XY glitch pad —
//     VOICE  — the phase1 expressive mono-voice (verbatim; octave moved enc3 -> pot0).
//     BREAK  — 16-step slicer: 16 mono breaks (/home/pi/breakbeats) sliced x16, REPITCHED so
//              the whole break fills one bar (pitch tracks BPM). Base groove = straight run of
//              break 0 (lanes). Chain: slices -> \glitchFx -> \djfilter -> bus.
//              enc0=TEMPO  enc1=(spare)  enc2=DJ FILTER (bipolar HP/LP, cutoff-flywheel physics).
//              GRID = live Kaoss glitch pad: X=density, Y=flavor (CRUSH<->GATE<->SPACE),
//              pressure=wet, touch=engage. Encoders assumed row-major 2x2: 0=TL 1=TR 2=BL 3=BR.
//
//   NOTE: engines are Events accessed via explicit [\key] (dot pseudo-methods are unreliable
//   here — setters silently fail / collide with real method names like group/reset/bus).
//
//   Signal graph:
//     voiceGroup(\voice)               -> voiceBus ┐
//     breakGroup(\slice… -> \djfilter) -> breakBus ┼-> \mixer -> bus 0 -> \analyzer (TAIL)
//
//   Controls arrive on SC default port 57120 via osc_relay.py (8001->57120).
//   Live tuning (send floats to Pi:8001): as phase1, plus /tune/bpm /tune/reset /tune/lvvoice /tune/lvbreak.
//   Dev-run (service stopped): QT_QPA_PLATFORM=offscreen sclang phase2.scd < <(exec tail -f /dev/null)
(
s = Server.default;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;
s.options.memSize = 32768;

~oled = NetAddr("127.0.0.1", 8000);
~tele = NetAddr("127.0.0.1", 9000);   // control-side telemetry (clients/tele_monitor.py)
~fft  = NetAddr("127.0.0.1", 9001);   // audio-side analysis (clients/fft_monitor.py)
~anlzOn = false;                      // \analyzer FFT scope OFF by default — telemetry-only, bursty FFT/7-BPF cost; /tune/anlz 1 to enable for tuning

// ================= shared musical config =================
~note = nil;                          // VOICE state stays global (single voice, tuned; low-risk)
~scaleIdx = 0; ~root = 0; ~oct = 0; ~lastCell = 5;
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
~baseFreq = 261.63;
~p = (cutoff:1500, res:0.3, atk:0.01, dcy:0.2, sus:0.75, rel:0.4, vibRate:5, gliss:0.06, amp:0.5);

// ---- expressive grid state (VOICE) ----
~press = 0; ~yTone = 0.5;
~lastPress = 0; ~lastPressT = 0; ~strikePeak = 0;
~gate = 0.08; ~pending = false; ~sounding = false; ~lastStrike = 0;
~m = (ampFloor:0.12, pAmp:1.6, pBri:1.5, pVib:0.6, tBri:1.6, sAmp:0.7, sBri:2.0);
~strikeRef = 25;

// ---- inertial cutoff (VOICE, encoder 2) ----
~cutoffMin = 150; ~cutoffMax = 4500;
~hzFromCutPos = { |pos| ~cutoffMin * ((~cutoffMax / ~cutoffMin) ** pos.clip(0, 1)) };
~cutPosFromHz = { |hz|  (hz / ~cutoffMin).log / (~cutoffMax / ~cutoffMin).log };
~cutPos = ~cutPosFromHz.(~p.cutoff); ~cutVel = 0.0;
~step = 0.015; ~kick = 0.030; ~friction = 0.88; ~velCap = 0.45; ~fps = 45; ~velEps = 0.0006;
~spinNorm = 0;                        // generic momentum-bar fill for the focused flywheel

// ---- DJ filter (BREAK, encoder 2): bipolar HP/LP, reuses the cutoff flywheel feel ----
~djPos = 0.5; ~djVel = 0.0;           // 0.5 = bypass; <0.5 sweeps LP down; >0.5 sweeps HP up
~breakFilt = nil;                     // the persistent \djfilter synth (set at build)
~breakGlitch = nil;                   // the persistent \glitchFx synth (Kaoss XY pad target)

// ---- detent accumulators (shared; slots 0/1 = VOICE scale/root, 3 = engine-select) ----
~detAccum = [0, 0, 0, 0]; ~detDir = [0, 0, 0, 0]; ~detLastT = [0, 0, 0, 0]; ~detRate = [0, 0, 0, 0];
~detTicks = 4; ~detSlow = 4; ~detFast = 22; ~detMax = 4; ~detDecay = 0.80; ~detGrace = 1.0;
~detStep = { |idx, d|
    var now = Main.elapsedTime;
    var dt  = now - ~detLastT[idx];
    var rate = if(dt > 0) { 1 / dt } { ~detFast };
    var dir = d.sign;
    var mult, steps = 0;
    ~detLastT[idx] = now;
    ~detRate[idx]  = (~detRate[idx] * 0.5) + (rate * 0.5);
    mult = ~detRate[idx].linlin(~detSlow, ~detFast, 1, ~detMax).clip(1, ~detMax);
    if((dir != ~detDir[idx]) and: { ~detDir[idx] != 0 }) { ~detAccum[idx] = 0 };
    ~detDir[idx] = dir;
    ~detAccum[idx] = ~detAccum[idx] + (d.abs * mult);
    steps = (~detAccum[idx] / ~detTicks).floor.asInteger;
    if(steps > 0) { ~detAccum[idx] = ~detAccum[idx] - (steps * ~detTicks) };
    steps * dir;
};

// ================= engine registry / focus =================
~engines = nil; ~focus = 0;
~eng = { ~engines[~focus] };          // the focused engine
~menuUntil = 0; ~menuHold = 1.2;      // engine-select overlay timer
~stepIdx = 0;                         // master 16th-note step 0..15
~subDiv = 4; ~subPhase = 0;           // looper sub-ticks per 16th -> 1/64-note automation resolution
~bpm = 110; ~clock = TempoClock(~bpm / 60);

// ================= OLED focus/overlay system =================
~focusParam = nil;
~focusLabel = ""; ~focusNorm = 0; ~focusStr = ""; ~focusMomentum = false;
~focusUntil = 0; ~focusHold = 1.5; ~dirty = true;
~focusFill = nil; ~focusFillMax = 4; ~focusDetIdx = nil;

~showFocus = { |label, norm, valStr, momentum = false|
    ~focusParam = label.asSymbol;
    ~focusLabel = label; ~focusNorm = norm.clip(0, 1); ~focusStr = valStr;
    ~focusMomentum = momentum;
    ~focusFill = nil; ~focusDetIdx = nil;
    ~focusUntil = Main.elapsedTime + ~focusHold;
    ~dirty = true;
};
~showDetent = { |label, norm, valStr, idx|
    ~showFocus.(label, norm, valStr);
    ~focusFill = ~detAccum[idx]; ~focusFillMax = ~detTicks; ~focusDetIdx = idx;
    ~dirty = true;
};
~showEngineMenu = { ~menuUntil = Main.elapsedTime + ~menuHold; ~focusParam = nil; ~dirty = true; };

~fmtHz = { |hz| if(hz >= 1000) { (hz / 1000).round(0.1).asString ++ "k" } { hz.round(1).asInteger.asString } };
~djLabel = { |p|                       // readable state for the DJ filter position
    case
    { p < 0.47 } { "LP" ++ ((0.5 - p) * 200).round.asInteger }
    { p > 0.53 } { "HP" ++ ((p - 0.5) * 200).round.asInteger }
    { true }     { "thru" };
};
// BREAK grid: Y (0..1) -> which break (0..15). A center band = silence (-1 = rest); the two
// outer zones map continuously onto breaks 0..15 so every break stays reachable off-center.
~centerDead = 0.08;
~breakFromY = { |yn|
    var cd = ~centerDead, t;
    if(yn.absdif(0.5) < cd) { -1 } {
        t = if(yn < 0.5)
            { (yn / (0.5 - cd)) * 0.5 }
            { 0.5 + (((yn - 0.5 - cd) / (0.5 - cd)) * 0.5) };
        (t * 15).round.asInteger.clip(0, 15);
    };
};
~freqFor = { |cell|
    var sc = ~scales[~scaleIdx];
    var n = sc[\cents].size;
    var idx = cell + (~oct * n);
    var per = idx div: n;
    var deg = idx mod: n;
    var cents = (per * sc[\period]) + sc[\cents][deg] + (~root * 100);
    ~baseFreq * (2 ** (cents / 1200));
};
~applyMap = { |syn|
    if(syn.notNil) {
        syn.set(\ampFloor, ~m.ampFloor, \pAmp, ~m.pAmp, \pBri, ~m.pBri, \pVib, ~m.pVib, \tBri, ~m.tBri, \sAmp, ~m.sAmp, \sBri, ~m.sBri);
    };
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
        ~oled.sendMsg("/oled/bar", 40, 48, 82, 8, ~spinNorm.clip(0, 1));
    }
    { ~focusFill.notNil } {
        var n    = ~focusFillMax.floor.asInteger.max(1);
        var x0   = 40, w = 82, gap = 2;
        var cw   = ((w - ((n - 1) * gap)) / n).floor.asInteger.max(1);
        var lit  = ~focusFill.floor.asInteger.clip(0, n);
        ~oled.sendMsg("/oled/text", 6, 53, "notch");
        n.do { |i| ~oled.sendMsg("/oled/rect", x0 + (i * (cw + gap)), 48, cw, 8, if(i < lit, 1, 0)) };
    };
    ~oled.sendMsg("/oled/show");
};
~drawMenu = {
    ~oled.sendMsg("/oled/clear");
    ~oled.sendMsg("/oled/rect", 0, 0, 127, 63, 0);
    ~oled.sendMsg("/oled/text", 6, 11, "ENGINE");
    ~engines.do { |e, i|
        var y = 28 + (i * 14);
        ~oled.sendMsg("/oled/text", 8, y, if(i == ~focus, "> ", "  ") ++ e[\name]);
    };
    ~oled.sendMsg("/oled/show");
};
~drawUI = {
    var now = Main.elapsedTime;
    case
    { now < ~menuUntil } { ~drawMenu.() }
    { ~focusParam.notNil and: { now < ~focusUntil } } { ~drawFocus.() }
    { true } { ~eng.()[\drawPlay].() };
};

// ================= ENGINE: Voice (phase1 voice, wrapped) =================
~makeVoiceEngine = {
    var self = ();
    self[\name] = "VOICE";
    self[\obus] = nil; self[\grp] = nil;
    self[\build] = { |g, b| self[\grp] = g; self[\obus] = b; };
    self[\step]  = { |step| };                    // no sequencer yet
    self[\reset] = { };
    self[\panic] = {                              // release any sounding voice — called on focus-out
        if(self[\grp].notNil) { self[\grp].set(\gate, 0) };   // group .set releases every voice in it (rel env, no click)
        ~note = nil; ~pending = false; ~sounding = false; ~press = 0;
    };
    self[\tick]    = { };                         // no looper on VOICE (sub-tick clock hooks, no-op)
    self[\advance] = { };
    self[\rotary] = { |idx, d|
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
            ~spinNorm = (~cutVel.abs / ~velCap).clip(0, 1);
            ~p.cutoff = ~hzFromCutPos.(~cutPos);
            if(~note.notNil) { ~note.set(\cutoff, ~p.cutoff) };
            ~showFocus.("CUTOFF", ~cutPos, ~fmtHz.(~p.cutoff), true);
        };
    };
    self[\pot] = { |idx, v|
        case
        { idx == 0 } { ~oct = ((v * 6) - 3).round.asInteger.clip(-3, 3);
            if(~note.notNil) { ~note.set(\freq, ~freqFor.(~lastCell)) };
            ~showFocus.("OCTAVE", (~oct + 3) / 6, "o" ++ ~oct) }
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
    };
    self[\gridTouch] = { |down|
        if(down) {
            ~pending = true; ~sounding = false;
            ~strikePeak = 0; ~lastPress = 0; ~lastPressT = Main.elapsedTime;
            ~focusParam = nil;
        } {
            if(~sounding and: { ~note.notNil }) { ~note.set(\gate, 0) };
            ~note = nil; ~pending = false; ~sounding = false; ~press = 0; ~dirty = true;
        };
    };
    self[\gridPos] = { |x, y|
        var cell = x.round.asInteger.clip(0, 10);
        ~lastCell = cell;
        ~yTone = (y / 10).clip(0, 1);
        if(~sounding and: { ~note.notNil }) {
            ~note.set(\freq, ~freqFor.(cell), \tone, ~yTone);
            ~dirty = true;
        };
    };
    self[\gridPressure] = { |p|
        var now = Main.elapsedTime;
        var dt = now - ~lastPressT;
        var slope = if(dt > 0) { (p - ~lastPress) / dt } { 0 };
        ~lastPress = p; ~lastPressT = now;
        case
        { ~pending } {
            if(slope > 0) { ~strikePeak = max(~strikePeak, slope) };
            if(p >= ~gate) {
                var sv = (~strikePeak / ~strikeRef).clip(0, 1);
                ~pending = false; ~sounding = true; ~press = p.clip(0, 1); ~lastStrike = sv;
                ~note = Synth(\voice, [
                    \out, self[\obus].index,
                    \freq, ~freqFor.(~lastCell), \baseAmp, ~p.amp, \cutoff, ~p.cutoff, \res, ~p.res,
                    \atk, ~p.atk, \dcy, ~p.dcy, \sus, ~p.sus, \rel, ~p.rel, \gliss, ~p.gliss,
                    \vibRate, ~p.vibRate, \press, ~press, \tone, ~yTone, \strike, sv
                ], self[\grp]);
                ~applyMap.(~note);
                ~dirty = true;
            };
        }
        { ~sounding and: { ~note.notNil } } {
            ~press = p.clip(0, 1);
            ~note.set(\press, ~press);
            ~dirty = true;
        };
    };
    self[\drawPlay] = {
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
    self;
};

// ================= ENGINE: BreakSlicer (M3 — sampler + grid recorder) =================
~makeBreakSlicer = {
    var self = ();
    self[\name] = "BREAK";
    self[\obus] = nil; self[\grp] = nil;
    self[\state] = (
        level:   0.9,
        repitch: 1.0,
        drive:   1.0,
        // 16-step lanes drive the base groove (default = straight run of break 0). The grid no
        // longer records these — it's now a live Kaoss-style glitch pad over the running loop.
        playSeq: Array.fill(16, { |i| i }),
        sampSeq: Array.fill(16, 0),
        preBus:  nil,                            // slices -> preBus -> \glitchFx -> \djfilter -> obus
        gBus:    nil,
        // XY glitch-pad state: Y=mangle (density+flavor), pressure=wet, touch=engage
        padOn: false, wet: 0, density: 0, flavor: 0.5,
        // ---- M-A looper: X automation lane driving the DJ filter; 1 bar @ subDiv=4 = 64 sub-ticks ----
        loopBars: 1, loopSubs: 64, loopSub: 0,
        xLane: FloatArray.newClear(256),         // pre-alloc MAX (4 bars); only 0..loopSubs-1 used
        xWritten: false, recording: false, liveX: 0.5,
        sweepDepth: 1.0, lastSentPos: -1.0
    );
    self[\build] = { |g, b|
        self[\grp] = g; self[\obus] = b;
        self[\state][\preBus] = Bus.audio(s, 2);      // slices sum here
        self[\state][\gBus]   = Bus.audio(s, 2);      // glitch -> filter
        // group-tail order: slices(head) -> \glitchFx -> \djfilter -> engine bus
        ~breakGlitch = Synth.tail(g, \glitchFx, [\in, self[\state][\preBus].index, \out, self[\state][\gBus].index, \bpm, ~bpm]);
        ~breakFilt   = Synth.tail(g, \djfilter, [\in, self[\state][\gBus].index, \out, b.index, \pos, ~djPos]);
    };
    self[\step]  = { |step|
        var st = self[\state];
        if((st[\sampSeq][step] >= 0) and: { ~breakBufs.notNil }) {   // >= 0 : not a rest
            var buf = ~breakBufs[st[\sampSeq][step].clip(0, ~breakBufs.size - 1)];
            Synth(\slice, [
                \buf, buf.bufnum, \sliceIdx, st[\playSeq][step].clip(0, 15), \numSlices, 16,
                \stepDur, 15 / ~bpm, \repitch, st[\repitch], \drive, st[\drive],
                \amp, st[\level], \out, st[\preBus].index
            ], self[\grp]);                                     // head of group -> before the FX tail
        };
        ~dirty = true;                                          // animate the playhead when focused
    };
    self[\reset] = {                                            // back to the default straight groove + loop phase
        16.do { |i| self[\state][\playSeq][i] = i; self[\state][\sampSeq][i] = 0 };
        self[\state][\loopSub] = 0;
    };
    self[\clear] = { self[\state][\xWritten] = false; };        // drop recorded automation (keeps groove)
    self[\panic] = {                                            // focus-out: disarm record + drop the glitch pad
        self[\state][\recording] = false;
        self[\state][\padOn] = false; self[\state][\wet] = 0;
        if(~breakGlitch.notNil) { ~breakGlitch.set(\wet, 0) };
    };
    // ---- looper sub-tick: SOLE writer of the DJ-filter pos (knob base + recorded X offset) ----
    self[\tick] = {
        var st = self[\state];
        var ls = st[\loopSub];
        var xv, pos;
        if(st[\recording]) { st[\xLane][ls] = st[\liveX] };     // commit live X into the lane
        xv  = if(st[\recording] or: { st[\xWritten] }) { st[\xLane][ls] } { 0.5 };
        pos = (~djPos + ((xv - 0.5) * st[\sweepDepth])).clip(0, 1);
        if((pos - st[\lastSentPos]).abs > 0.001) {              // change-check: idle loop sends nothing
            if(~breakFilt.notNil) { ~breakFilt.set(\pos, pos) };
            st[\lastSentPos] = pos;
        };
        if(~subPhase == 0) { ~tele.sendMsg("/loop", ls, pos.asFloat, xv.asFloat, if(st[\recording], 1, 0)) };  // looper eyes, downbeat only
    };
    self[\advance] = { self[\state][\loopSub] = (self[\state][\loopSub] + 1) % self[\state][\loopSubs] };
    self[\rotary] = { |idx, d|
        case
        { idx == 0 } {                                          // TEMPO (top-left)
            ~bpm = (~bpm + d).clip(40, 220); ~clock.tempo = ~bpm / 60;
            if(~breakGlitch.notNil) { ~breakGlitch.set(\bpm, ~bpm) };
            ~showFocus.("TEMPO", (~bpm - 40) / 180, ~bpm.asString ++ "bpm");
        }
        { idx == 1 } { }                                        // spare (top-right) — TODO
        { idx == 2 } {                                          // DJ FILTER (bottom-left) — cutoff flywheel feel
            ~djPos = (~djPos + (d * ~step)).clip(0, 1);
            ~djVel = (~djVel + (d * ~kick)).clip(~velCap.neg, ~velCap);
            ~spinNorm = (~djVel.abs / ~velCap).clip(0, 1);
            // node no longer set here — the looper sub-tick is the sole writer of \pos
            ~showFocus.("DJFILT", ~djPos, ~djLabel.(~djPos), true);
        };
    };
    self[\pot]    = { |idx, v| };                               // M4 (drive/glitch land here)
    // ---- grid = Kaoss glitch pad: X = density, Y = flavor, pressure = wet, touch = engage ----
    self[\gridTouch] = { |down|
        var st = self[\state];
        st[\padOn] = down;
        if(down) {
            if(st[\xWritten].not) { st[\xLane].fill(0.5) };     // first-activation pre-fill: unrecorded = filter thru
            st[\recording] = true;                              // arm: sub-tick commits liveX into the lane
        } {
            st[\recording] = false; st[\xWritten] = true;       // release: recorded lane now plays back + loops
            st[\wet] = 0;
            if(~breakGlitch.notNil) { ~breakGlitch.set(\wet, 0) };
        };
        ~dirty = true;
    };
    self[\gridPressure] = { |p|
        self[\state][\wet] = if(self[\state][\padOn]) { p.clip(0, 1) } { 0 };
        if(~breakGlitch.notNil) { ~breakGlitch.set(\wet, self[\state][\wet]) };
        ~dirty = true;
    };
    self[\gridPos] = { |x, y|
        var st = self[\state];
        st[\liveX]   = (x / 10).clip(0, 1);                    // X -> DJ-filter sweep lane (recorded)
        st[\density] = (y / 10).clip(0, 1);                    // Y -> mangle (density + flavor together)
        st[\flavor]  = (y / 10).clip(0, 1);
        if(~breakGlitch.notNil) { ~breakGlitch.set(\density, st[\density], \flavor, st[\flavor]) };
        ~dirty = true;
    };
    self[\drawPlay] = {
        var st = self[\state];
        var bx = 6, by = 15, bw = 74, bh = 44;                          // XY pad box
        var fname = case { st[\flavor] < 0.34 } { "CRUSH" } { st[\flavor] > 0.66 } { "SPACE" } { true } { "GATE" };
        var dotx = (bx + 1 + (st[\density] * (bw - 5))).asInteger;
        var doty = (by + bh - 5 - (st[\flavor] * (bh - 5))).asInteger;  // flavor grows UP
        ~oled.sendMsg("/oled/clear");
        ~oled.sendMsg("/oled/rect", 0, 0, 127, 63, 0);
        ~oled.sendMsg("/oled/text", 4, 10, "BRK " ++ ~bpm);
        ~oled.sendMsg("/oled/rect", bx, by, bw, bh, 0);                 // pad border
        ~oled.sendMsg("/oled/rect", dotx, doty, 4, 4, 1);               // density(x) / flavor(y) dot
        ~oled.sendMsg("/oled/text", 88, 22, if(st[\padOn]) { fname } { "idle" });
        ~oled.sendMsg("/oled/text", 88, 40, "wet");
        ~oled.sendMsg("/oled/bar", 88, 46, 34, 7, st[\wet]);
        ~oled.sendMsg("/oled/rect", bx + (~stepIdx * (bw / 16)).asInteger, by + bh + 2, 3, 2, 1);  // playhead tick
        ~oled.sendMsg("/oled/show");
    };
    self;
};

~engines = [ ~makeVoiceEngine.(), ~makeBreakSlicer.() ];

// Change focus, releasing the OUTGOING engine's sounding notes first. Without this a held
// VOICE note is orphaned on switch (its gate never drops), the \voice node leaks, and the
// accumulating DSP load starves the OLED/touch loop. Routes both focus paths (enc3 + harness).
~setFocus = { |idx|
    var target = idx.wrap(0, ~engines.size - 1).asInteger;
    if(target != ~focus) { ~eng.()[\panic].(); ~focus = target; };
    ~showEngineMenu.(); ~dirty = true;
};

// ================= boot =================
s.waitForBoot({
    SynthDef(\voice, { |out=0, freq=220, gate=1, baseAmp=0.32, cutoff=1500, res=0.3,
                       atk=0.01, dcy=0.2, sus=0.75, rel=0.4, gliss=0.06, vibRate=5,
                       press=0, strike=0, tone=0.5,
                       ampFloor=0.12, pAmp=1.6, pBri=1.5, pVib=0.6, tBri=1.6, sAmp=0.7, sBri=2.0|
        var pitch  = Lag.kr(freq, gliss);
        var pr     = Lag.kr(press, 0.05);
        var tn     = Lag.kr(tone, 0.05);
        var vibAmt = (pVib * pr).clip(0, 1);
        var vib    = SinOsc.kr(vibRate) * vibAmt * pitch * 0.04;
        var f      = pitch + vib;
        var sub    = SinOsc.ar(f * 0.5) * 0.25;
        var mix    = (Saw.ar(f) * tn) + (Pulse.ar(f, 0.25) * (1 - tn));
        var osc    = (mix * 0.5) + sub;
        var env    = EnvGen.kr(Env.adsr(atk, dcy, sus, rel), gate, doneAction: 2);
        var hit    = EnvGen.kr(Env.perc(0.004, 0.08), doneAction: 0) * strike;
        var amp    = baseAmp * env * (ampFloor + (pr * pAmp) + (hit * sAmp));
        var co     = cutoff * (2 ** ((tBri * (tn - 0.5)) + (pBri * pr) + (sBri * hit)));
        var sig    = RLPF.ar(osc, co.clip(80, 14000), res.linexp(0, 1, 1.0, 0.05));
        Out.ar(out, (sig * amp * 0.6).tanh.dup);        // -> engine bus (was bus 0)
    }).add;

    SynthDef(\blip, { |out=0, freq=220, amp=0.3|
        var env = EnvGen.ar(Env.perc(0.001, 0.12), doneAction: 2);
        Out.ar(out, (SinOsc.ar(freq) * env * amp).dup);
    }).add;

    // one-shot breakbeat slice, REPITCHED so the whole break spans exactly one bar: each slice
    // plays in `stepDur` seconds regardless of the break's native length. Pitch therefore tracks
    // BPM (slower = pitched down, faster = up) and 16 slices fill the bar with no gap/overlap.
    // Slice bounds + fit-rate computed on the SERVER (BufFrames/BufDur), so no client numFrames.
    SynthDef(\slice, { |buf=0, sliceIdx=0, numSlices=16, stepDur=0.13, repitch=1, amp=0.5, drive=1, out=0|
        var slFr    = BufFrames.kr(buf) / numSlices;
        var rateFit = (BufDur.kr(buf) / numSlices) / stepDur;   // stretch one slice to one step
        var rs      = BufRateScale.kr(buf) * rateFit * repitch;
        var env     = EnvGen.ar(Env.linen(0.002, (stepDur - 0.006).max(0.002), 0.004), doneAction: 2);
        var ph      = Phasor.ar(0, rs, sliceIdx * slFr, (sliceIdx + 1) * slFr);
        var s0      = BufRd.ar(1, buf, ph, 2) * drive;
        var sat     = s0 * (27 + (s0 * s0)) / (27 + (9 * s0 * s0));
        Out.ar(out, Pan2.ar(sat * env * amp, 0));
    }).add;

    // DJ hi/lo filter insert: pos 0.5 = bypass, <0.5 sweeps a LPF down, >0.5 sweeps a HPF up.
    SynthDef(\djfilter, { |in=0, out=0, pos=0.5|
        var sig   = In.ar(in, 2);
        var p     = Lag.kr(pos, 0.08);
        var lpAmt = (0.5 - p).max(0) * 2;                       // 0..1 as p goes 0.5 -> 0
        var hpAmt = (p - 0.5).max(0) * 2;                       // 0..1 as p goes 0.5 -> 1
        var lpF   = (20000 * ((70 / 20000) ** lpAmt)).clip(60, 20000);
        var hpF   = (20 * ((9000 / 20) ** hpAmt)).clip(20, 12000);
        var lp    = RLPF.ar(sig, lpF, 0.6);
        var hp    = RHPF.ar(sig, hpF, 0.6);
        Out.ar(out, Select.ar(p >= 0.5, [lp, hp]));             // seamless: both ~dry near 0.5
    }).add;

    // Kaoss-style XY glitch insert. density (grid X) = intensity, flavor (grid Y) crossfades a
    // 3-effect palette CRUSH <-> GATE <-> SPACE, wet (grid pressure) = dry/fx mix; touch engages.
    // bpm syncs the gate + delay. At density/wet 0 it is transparent.
    SynthDef(\glitchFx, { |in=0, out=0, wet=0, density=0, flavor=0.5, bpm=110|
        var dry = In.ar(in, 2);
        var w   = Lag.kr(wet, 0.06);
        var dn  = Lag.kr(density, 0.06);
        var fl  = Lag.kr(flavor, 0.08);
        var wC  = (1 - (fl * 2)).clip(0, 1);                    // CRUSH weight (fl 0 -> .5)
        var wG  = (1 - ((fl - 0.5).abs * 2)).clip(0, 1);        // GATE  weight (peak at .5)
        var wS  = ((fl * 2) - 1).clip(0, 1);                    // SPACE weight (fl .5 -> 1)
        var levels = 2 ** (16 - (dn * 13)).max(1);              // bit-depth quant levels
        var crush, gate, space, fx;
        // CRUSH: samplerate reduction (S&H) + bit reduction + drive — all CORE UGens (no sc3-plugins)
        crush = Latch.ar(dry, Impulse.ar(SampleRate.ir * (1 - (dn * 0.92)).max(0.03)));
        crush = (crush * levels).round / levels;
        crush = (crush * (1 + (dn * 5))).tanh;                  // + drive as density rises
        gate  = dry * LFPulse.kr((bpm / 60) * (2 ** (dn * 4).round), 0, 0.5).range(1 - dn, 1);
        space = dry + (CombC.ar(dry, 0.5, (60 / bpm) * 0.25, 0.1 + (dn * 6)) * dn);  // 1/16-synced comb
        fx    = ((crush * wC) + (gate * wG) + (space * wS)) / (wC + wG + wS + 0.001);
        Out.ar(out, XFade2.ar(dry, fx.tanh, (w * 2) - 1));      // pressure = dry..fx
    }).add;

    // sums the engine buses to the hardware out; per-engine level
    SynthDef(\mixer, { |voiceBus=0, breakBus=0, lvVoice=0.8, lvBreak=0.9|
        Out.ar(0, (In.ar(voiceBus, 2) * lvVoice) + (In.ar(breakBus, 2) * lvBreak));
    }).add;

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

    // load the 16 breakbeats (mono 44.1k) into buffers; s.sync waits for the async reads
    ~breakBufs = Array.fill(16, { |i|
        Buffer.read(s, "/home/pi/breakbeats/beats" ++ (if(i < 10) { "0" ++ i } { i.asString }) ++ ".wav");
    });

    s.sync;

    // per-engine group -> bus, built BEFORE mixer/analyzer so node order is
    // voiceGroup, breakGroup, mixer, analyzer (analyzer stays TAIL / last).
    ~engines.do { |e|
        var bus = Bus.audio(s, 2);
        var grp = Group.tail(s.defaultGroup);
        e[\build].(grp, bus);
    };
    ~mixer = Synth.tail(s.defaultGroup, \mixer, [
        \voiceBus, ~engines[0][\obus].index, \breakBus, ~engines[1][\obus].index
    ]);
    ~analyzer = if(~anlzOn) { Synth.tail(s.defaultGroup, \analyzer) };  // scope off by default (Pi 3 headroom); /tune/anlz toggles
    OSCdef(\anlz, { |msg| ~fft.sendMsg("/fft", *(msg[3..])) }, '/anlz');

    // ---- input dispatch: ONE OSCdef per address -> focused engine (enc3 = global select) ----
    OSCdef(\rotary, { |msg|
        var idx = msg[1], d = msg[2];
        if(idx == 3) {
            var steps = ~detStep.(3, d);
            if(steps != 0) { ~setFocus.(~focus + steps) };
        } {
            ~eng.()[\rotary].(idx, d);
        };
    }, '/rotary');
    OSCdef(\pot,      { |msg| ~eng.()[\pot].(msg[1], msg[2]) }, '/pot');
    OSCdef(\pos,      { |msg| ~eng.()[\gridPos].(msg[1], msg[2]) }, '/grid/pos');
    OSCdef(\pressure, { |msg| ~eng.()[\gridPressure].(msg[1]) }, '/grid/pressure');
    OSCdef(\touch,    { |msg| ~menuUntil = 0; ~eng.()[\gridTouch].(msg[1] == 1) }, '/grid/touch');

    // ---- live tuning (VOICE feel, carried over from phase1) ----
    OSCdef(\tuneFric, { |msg| ~friction = msg[1].clip(0.5, 0.995); ("friction=" ++ ~friction).postln }, '/tune/friction');
    OSCdef(\tuneKick, { |msg| ~kick = msg[1].max(0);             ("kick=" ++ ~kick).postln }, '/tune/kick');
    OSCdef(\tuneStep, { |msg| ~step = msg[1].max(0);             ("step=" ++ ~step).postln }, '/tune/step');
    OSCdef(\tuneCap,  { |msg| ~velCap = msg[1].max(0.05);        ("cap=" ++ ~velCap).postln }, '/tune/cap');
    OSCdef(\tuneDticks, { |msg| ~detTicks = msg[1].max(1);          ("dticks=" ++ ~detTicks).postln }, '/tune/dticks');
    OSCdef(\tuneDslow,  { |msg| ~detSlow  = msg[1].max(0.1);        ("dslow="  ++ ~detSlow).postln }, '/tune/dslow');
    OSCdef(\tuneDfast,  { |msg| ~detFast  = msg[1].max(1);          ("dfast="  ++ ~detFast).postln }, '/tune/dfast');
    OSCdef(\tuneDmax,   { |msg| ~detMax   = msg[1].max(1);          ("dmax="   ++ ~detMax).postln }, '/tune/dmax');
    OSCdef(\tuneDdecay, { |msg| ~detDecay = msg[1].clip(0.5, 1.0);  ("ddecay=" ++ ~detDecay).postln }, '/tune/ddecay');
    OSCdef(\tuneDgrace, { |msg| ~detGrace = msg[1].max(0);          ("dgrace=" ++ ~detGrace).postln }, '/tune/dgrace');
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

    // ---- transport + per-engine mix (global) ----
    OSCdef(\tuneBpm,   { |msg| ~bpm = msg[1].clip(40, 220); ~clock.tempo = ~bpm / 60; ("bpm=" ++ ~bpm).postln }, '/tune/bpm');
    OSCdef(\tuneReset, { |msg| ~stepIdx = 0; ~subPhase = 0; ~engines.do { |e| e[\reset].() }; "reset".postln }, '/tune/reset');
    OSCdef(\breakClear, { |msg| ~engines[1][\clear].(); "break clear".postln }, '/tune/breakclear');
    OSCdef(\tuneAnlz, { |msg|                                  // FFT telemetry scope on/off (off = Pi 3 headroom)
        var on = msg[1] > 0;
        if(on and: { ~analyzer.isNil }) { ~analyzer = Synth.tail(s.defaultGroup, \analyzer) };
        if(on.not and: { ~analyzer.notNil }) { ~analyzer.free; ~analyzer = nil };
        ~anlzOn = on; ("analyzer=" ++ on).postln;
    }, '/tune/anlz');
    OSCdef(\lvVoice,   { |msg| ~mixer.set(\lvVoice, msg[1].clip(0, 2)); ("lvVoice=" ++ msg[1]).postln }, '/tune/lvvoice');
    OSCdef(\lvBreak,   { |msg| ~mixer.set(\lvBreak, msg[1].clip(0, 2)); ("lvBreak=" ++ msg[1]).postln }, '/tune/lvbreak');

    // ================= HARNESS HOOKS (instrument-harness interface) =================
    // Dormant until the harness calls them; remove this block to revert. Only /harness/*
    // addresses; never touches the audio graph. See instrument-harness/shims/xsynth/.
    // Point the telemetry streams at a listener host (workstation) for off-device observe;
    // "" / "0" / "local" reverts to loopback.
    OSCdef(\hTelehost, { |msg|
        var host = msg[1].asString;
        if((host == "") or: { host == "0" } or: { host == "local" }) { host = "127.0.0.1" };
        ~tele = NetAddr(host, 9000); ~fft = NetAddr(host, 9001);
        ("harness telehost -> " ++ host).postln;
    }, '/harness/telehost');
    // Jump focus to an engine by name (reliable absolute select vs. blind enc3 stepping).
    OSCdef(\hFocus, { |msg|
        var target = msg[1].asSymbol;
        var idx = ~engines.detectIndex({ |e| e[\name].asSymbol == target });
        if(idx.notNil) { ~setFocus.(idx); ("harness focus " ++ target ++ " (idx " ++ idx ++ ")").postln }
                       { ("harness focus: no engine '" ++ target ++ "'").postln };
    }, '/harness/focus');
    // Record the master output (bus 0) to /dev/shm (root FS is full); harness pulls it back.
    OSCdef(\hRecStart, { |msg|
        var name = if(msg[1].notNil) { msg[1].asString } { "harness_rec" };
        var path = "/dev/shm/" ++ name ++ ".wav";
        fork {
            s.recHeaderFormat = "wav"; s.recSampleFormat = "int16";
            s.prepareForRecord(path, 65536); s.sync; s.record;
            ("harness rec -> " ++ path).postln;
        };
    }, '/harness/rec/start');
    OSCdef(\hRecStop, { |msg| s.stopRecording; "harness rec stop".postln }, '/harness/rec/stop');

    // ---- master 16th-note clock: drives every engine's step in lockstep ----
    ~stepTask = Routine({
        loop {
            ~engines.do { |e| e[\tick].() };                  // looper sub-tick FIRST (read lane, push filter)
            if(~subPhase == 0) {                               // real 16th on the sub-phase downbeat
                ~engines.do { |e| e[\step].(~stepIdx) };
                ~stepIdx = (~stepIdx + 1) % 16;
            };
            ~engines.do { |e| e[\advance].() };                // advance loop counters LAST
            ~subPhase = (~subPhase + 1) % ~subDiv;
            (0.25 / ~subDiv).wait;                             // 1/64 note (subDiv sub-ticks per 16th)
        };
    }).play(~clock);

    // ---- 45fps wall-clock loop: VOICE physics + detent spring-back + OLED blit ----
    ~physics = Routine({
        var dt = 1 / ~fps;
        loop {
            var now = Main.elapsedTime;
            ~tele.sendMsg("/tele", ~press.asFloat, ~lastStrike.asFloat, ~yTone.asFloat,
                ~cutPos.asFloat, ~p.cutoff.asFloat,
                (~p.cutoff * (2 ** ((~m.tBri * (~yTone - 0.5)) + (~m.pBri * ~press)))).clip(80, 14000).asFloat,
                (~p.amp * (~m.ampFloor + (~press * ~m.pAmp))).asFloat,
                if(~sounding, 1, 0));
            if(~cutVel.abs > ~velEps) {                       // VOICE inertial cutoff coast
                ~cutPos = (~cutPos + (~cutVel * dt)).clip(0, 1);
                if((~cutPos <= 0) or: { ~cutPos >= 1 }) { ~cutVel = 0 };
                ~cutVel = ~cutVel * ~friction;
                if(~cutVel.abs <= ~velEps) { ~cutVel = 0 };
                ~p.cutoff = ~hzFromCutPos.(~cutPos);
                if(~note.notNil) { ~note.set(\cutoff, ~p.cutoff) };
                if(~focus == 0) { ~spinNorm = (~cutVel.abs / ~velCap).clip(0, 1);
                                  ~showFocus.("CUTOFF", ~cutPos, ~fmtHz.(~p.cutoff), true) };
            };
            if(~djVel.abs > ~velEps) {                        // BREAK DJ-filter flywheel coast
                ~djPos = (~djPos + (~djVel * dt)).clip(0, 1);
                if((~djPos <= 0) or: { ~djPos >= 1 }) { ~djVel = 0 };
                ~djVel = ~djVel * ~friction;
                if(~djVel.abs <= ~velEps) { ~djVel = 0 };
                // node no longer set here — the looper sub-tick coasts \pos from ~djPos
                if(~focus == 1) { ~spinNorm = (~djVel.abs / ~velCap).clip(0, 1);
                                  ~showFocus.("DJFILT", ~djPos, ~djLabel.(~djPos), true) };
            };
            if(~detDecay < 1.0) {                             // detent fills spring back after idle
                [0, 1, 3].do { |i|
                    if((~detAccum[i] > 0) and: { (now - ~detLastT[i]) > ~detGrace }) {
                        ~detAccum[i] = ~detAccum[i] * ~detDecay;
                        if(~detAccum[i] < 0.02) { ~detAccum[i] = 0; ~detDir[i] = 0 };
                        if(i == ~focusDetIdx) { ~focusFill = ~detAccum[i]; ~dirty = true };
                    };
                };
            };
            if(~focusParam.notNil and: { now >= ~focusUntil }) { ~focusParam = nil; ~dirty = true };
            if(~dirty) { ~drawUI.(); ~dirty = false };
            dt.wait;
        };
    }).play(SystemClock);

    ~dirty = true; ~drawUI.();
    "=== PHASE2 READY — VOICE + BREAK slicer (16 breaks, DJ filter), enc3=engine-select ===".postln;
});
)
