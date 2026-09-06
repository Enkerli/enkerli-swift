//
//  curves-main.mm
//  Kernel
//
//  Curve lanes, driven directly, outside any host.
//
//  The kernel's third job after scheduling notes and rewriting them, and the
//  first that emits anything other than a note. Adapted from DrawnQurve's
//  GestureEngine — C++ to C++, so there is no language boundary and nothing for
//  a vector file to hold; what holds it is this.
//
//  Two of these cases are about the same class of bug as the transform's: a
//  note started by a curve has to be ended by the same lane, on the channel it
//  started on, whatever the lane is set to by then. A curve walking up a scale
//  that never releases is a plug-in that fills a synth's voices in one loop and
//  leaves them there.
//
//  Made to fail before the green was believed. Four divergences planted in the
//  engine:
//
//    · a note lane that never releases before starting the next  → 3 failures
//    · control changes emitted every block instead of on change  → 1
//    · the scale mask read MSB-first                             → 2
//    · note-offs always sent on channel 0                        → 0, at first
//
//  That last one is the useful one. It passed, because the test that exists to
//  catch it started its note on channel 0 — so the planted wrong answer and the
//  right answer were the same value. A test whose expected result is also the
//  bug cannot fail. It starts on channel 5 now, and the same plant produces a
//  named failure.
//

#import <Foundation/Foundation.h>
#import "../../Sources/Kernel/include/PluginDSPKernel.hpp"

#import <cmath>
#import <set>
#import <string>
#import <vector>

struct Sent { uint8_t status, channel, data1, data2; };
static std::vector<Sent> gSent;
static void resetSent() { gSent.clear(); }

static AUMIDIEventListBlock recordingBlock() {
    return ^(AUEventSampleTime, uint8_t, const MIDIEventList *list) {
        if (list == nullptr) { return (OSStatus)noErr; }
        const MIDIEventPacket *packet = &list->packet[0];
        for (uint32_t p = 0; p < list->numPackets; ++p) {
            for (uint32_t w = 0; w < packet->wordCount; ++w) {
                const uint32_t first = packet->words[w];
                if ((uint8_t)((first >> 28) & 0xF) != 0x2) { continue; }
                gSent.push_back({ (uint8_t)((first >> 20) & 0xF),
                                  (uint8_t)((first >> 16) & 0xF),
                                  (uint8_t)((first >> 8) & 0x7F),
                                  (uint8_t)(first & 0x7F) });
            }
            packet = MIDIEventPacketNext(packet);
        }
        return (OSStatus)noErr;
    };
}

static int gFailures = 0;
static void check(const std::string &what, bool passed, const std::string &detail = "") {
    printf("  %s  %s%s\n", passed ? "PASS" : "FAIL", what.c_str(),
           detail.empty() ? "" : (" — " + detail).c_str());
    if (!passed) { gFailures += 1; }
}

/// A rising ramp, 0 at phase 0 and 1 at the end.
static void installRamp(PluginDSPKernel &kernel, uint8_t message,
                        double seconds = 1.0, uint16_t mask = 0x0FFF, uint8_t channel = 0) {
    kernel.beginCurveUpdate();
    for (uint32_t i = 0; i < 256; ++i) {
        kernel.setCurveSample(0, i, (float)i / 255.0f);
    }
    kernel.setCurveLane(0, seconds, 0.0f, 1.0f, /*smoothing*/ 0.0f, /*phaseOffset*/ 0.0f,
                        mask, /*root*/ 0, /*cc*/ 74, channel, /*velocity*/ 100,
                        message, /*oneShot*/ false, /*enabled*/ true);
    kernel.commitCurves();
    kernel.setCurvesEnabled(true);
}

/// A rising ramp with a quantization grid on it.
static void installGriddedRamp(PluginDSPKernel &kernel, uint16_t columns, uint16_t levels,
                               uint8_t message = 0, double seconds = 1.0) {
    kernel.beginCurveUpdate();
    for (uint32_t i = 0; i < 256; ++i) {
        kernel.setCurveSample(0, i, (float)i / 255.0f);
    }
    kernel.setCurveLane(0, seconds, 0.0f, 1.0f, /*smoothing*/ 0.0f, /*phaseOffset*/ 0.0f,
                        0x0FFF, 0, /*cc*/ 74, /*channel*/ 0, /*velocity*/ 100,
                        message, /*oneShot*/ false, /*enabled*/ true);
    kernel.setCurveLaneGrid(0, columns, levels);
    kernel.commitCurves();
    kernel.setCurvesEnabled(true);
}

/// One block of `seconds`, at the sample rate the kernel was initialised with.
static void run(PluginDSPKernel &kernel, double seconds, double sampleRate = 48000) {
    kernel.advanceCurves(0, seconds);
}

int main() {
    printf("── curves: playing a drawn line ───────────────────\n");

    // ── off by default ─────────────────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();
        run(kernel, 0.1);
        check("nothing runs until asked", gSent.empty(),
              gSent.empty() ? "" : "something came out");
    }

    // ── control change ─────────────────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installRamp(kernel, 0);            // CC
        resetSent();
        run(kernel, 0.0);                  // phase 0
        check("a ramp starts at the bottom",
              gSent.size() == 1 && gSent[0].status == 0xB && gSent[0].data1 == 74
              && gSent[0].data2 == 0,
              gSent.empty() ? "nothing" : "cc" + std::to_string(gSent[0].data1)
                              + " = " + std::to_string(gSent[0].data2));
        resetSent();
        run(kernel, 0.5);
        check("and reaches the middle halfway through",
              gSent.size() == 1 && gSent[0].data2 > 60 && gSent[0].data2 < 68,
              gSent.empty() ? "nothing" : std::to_string(gSent[0].data2));
    }

    // ── the same value is not sent twice ───────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        kernel.beginCurveUpdate();
        for (uint32_t i = 0; i < 256; ++i) { kernel.setCurveSample(0, i, 0.5f); }
        kernel.setCurveLane(0, 1.0, 0, 1, 0, 0, 0x0FFF, 0, 74, 0, 100, 0, false, true);
        kernel.commitCurves();
        kernel.setCurvesEnabled(true);
        resetSent();
        for (int block = 0; block < 20; ++block) { run(kernel, 0.01); }
        check("a flat curve sends one message, not twenty", gSent.size() == 1,
              std::to_string(gSent.size()) + " messages");
    }

    // ── pitch bend is 14-bit, low seven bits first ─────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installRamp(kernel, 2);            // PitchBend
        resetSent();
        run(kernel, 0.0);
        check("a bend starts at the bottom of its range",
              gSent.size() == 1 && gSent[0].status == 0xE
              && gSent[0].data1 == 0 && gSent[0].data2 == 0);
        resetSent();
        run(kernel, 0.5);
        const int wide = gSent.empty() ? -1 : (gSent[0].data1 | (gSent[0].data2 << 7));
        check("and halfway is near the 14-bit centre",
              wide > 8000 && wide < 8400, std::to_string(wide) + " of 16383");
    }

    // ── channel pressure ───────────────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installRamp(kernel, 1);            // ChannelPressure
        resetSent();
        run(kernel, 0.5);
        check("pressure is one data byte on status 0xD",
              gSent.size() == 1 && gSent[0].status == 0xD
              && gSent[0].data1 > 60 && gSent[0].data1 < 68,
              gSent.empty() ? "nothing" : std::to_string(gSent[0].data1));
    }

    // ── notes: off before on, and matched ──────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installRamp(kernel, 3);            // Note
        resetSent();
        run(kernel, 0.0);
        check("a note lane starts one note", gSent.size() == 1 && gSent[0].status == 0x9,
              gSent.empty() ? "nothing" : std::to_string(gSent.size()) + " messages");
        const uint8_t first = gSent.empty() ? 0 : gSent[0].data1;

        resetSent();
        run(kernel, 0.5);
        // Climbing the ramp: the old note ends before the new one starts.
        bool offThenOn = gSent.size() == 2
                      && gSent[0].status == 0x8 && gSent[0].data1 == first
                      && gSent[1].status == 0x9;
        check("moving up ends the old note before starting the new one", offThenOn,
              gSent.size() == 2
                ? ("off " + std::to_string(gSent[0].data1)
                   + ", on " + std::to_string(gSent[1].data1))
                : (std::to_string(gSent.size()) + " messages — a curve that never "
                   "releases fills a synth's voices in one loop"));
    }

    // ── a channel change mid-note does not orphan it ───────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        // Starts on channel 5, NOT channel 0. Written the other way round first,
        // and a planted bug that always sent note-offs on channel 0 passed —
        // because the note had started there. A test whose expected value is
        // also the wrong answer cannot fail.
        installRamp(kernel, 3, 1.0, 0x0FFF, /*channel*/ 5);
        run(kernel, 0.0);
        const uint8_t sounding = gSent.empty() ? 0 : gSent[0].data1;

        // Same curve, different channel, while the note is held.
        kernel.beginCurveUpdate();
        for (uint32_t i = 0; i < 256; ++i) { kernel.setCurveSample(0, i, (float)i / 255.0f); }
        kernel.setCurveLane(0, 1.0, 0, 1, 0, 0, 0x0FFF, 0, 74, /*channel*/ 0, 100, 3, false, true);
        kernel.commitCurves();

        resetSent();
        run(kernel, 0.5);
        bool ok = gSent.size() == 2 && gSent[0].status == 0x8
               && gSent[0].channel == 5 && gSent[0].data1 == sounding
               && gSent[1].status == 0x9 && gSent[1].channel == 0;
        check("a channel change mid-note still ends it on the channel it started on", ok,
              gSent.size() >= 2
                ? ("off went to channel " + std::to_string(gSent[0].channel)
                   + ", on to " + std::to_string(gSent[1].channel))
                : "nothing came out — STUCK NOTE");
    }

    // ── switching the lanes off releases what they were holding ────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installRamp(kernel, 3);
        run(kernel, 0.0);
        const uint8_t sounding = gSent.empty() ? 0 : gSent[0].data1;
        resetSent();
        kernel.setCurvesEnabled(false);
        run(kernel, 0.01);
        check("switching curves off ends the note they were holding",
              gSent.size() == 1 && gSent[0].status == 0x8 && gSent[0].data1 == sounding,
              gSent.empty() ? "nothing came out — STUCK NOTE" : "off sent");
    }

    // ── scale quantization ─────────────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        // C major: bit 0 is the root. Leftmost = LSB, suite-wide.
        installRamp(kernel, 3, 1.0, 0xAB5);
        std::vector<int> notes;
        for (int step = 0; step < 60; ++step) {
            resetSent();
            run(kernel, 1.0 / 60.0);
            for (auto &s : gSent) { if (s.status == 0x9) { notes.push_back(s.data1); } }
        }
        bool allInScale = true;
        static const bool inC[12] = {1,0,1,0,1,1,0,1,0,1,0,1};
        for (int note : notes) { if (!inC[note % 12]) { allInScale = false; } }
        check("every note a quantized lane plays is in the scale",
              allInScale && notes.size() > 5,
              std::to_string(notes.size()) + " notes, all in C major");
        check("and it is 0xAB5 that means C major, not 0xAD5",
              PluginDSPKernel::quantizeCurveNote(61, 0xAB5, 0, true) == 62
              && PluginDSPKernel::quantizeCurveNote(66, 0xAD5, 0, true) == 66,
              "61 → 62 in Ionian; 66 (F♯) is already in Lydian");
    }

    // ── a one-shot stops ───────────────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        kernel.beginCurveUpdate();
        for (uint32_t i = 0; i < 256; ++i) { kernel.setCurveSample(0, i, (float)i / 255.0f); }
        kernel.setCurveLane(0, 0.1, 0, 1, 0, 0, 0x0FFF, 0, 74, 0, 100, 0, /*oneShot*/ true, true);
        kernel.commitCurves();
        kernel.setCurvesEnabled(true);
        for (int block = 0; block < 5; ++block) { run(kernel, 0.05); }
        resetSent();
        for (int block = 0; block < 10; ++block) { run(kernel, 0.05); }
        check("a one-shot goes quiet after one pass", gSent.empty(),
              gSent.empty() ? "" : std::to_string(gSent.size()) + " messages after it ended");
    }

    // ── the playhead is readable ───────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        check("an idle lane reports no playhead", kernel.curvePhase(0) < 0);
        installRamp(kernel, 0, 1.0);
        run(kernel, 0.25);
        const double phase = kernel.curvePhase(0);
        check("and a running one reports where it is",
              phase > 0.2 && phase < 0.3, std::to_string(phase));
    }

    // ── qurve quantization ─────────────────────────────────────────────────
    //
    // The JUCE build's most distinctive control, and two genuinely different
    // instruments rather than one setting with two axes. X turns a gesture into
    // a pattern; Y turns a sweep into positions.
    {
        // Y: four levels over 0..1 means 0, 1/3, 2/3, 1 and nothing else.
        // Four LEVELS, not four intervals — with two, a lane must reach both
        // ends of its own range, and dividing by N instead would leave it
        // quietly unable to hit its own maximum.
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installGriddedRamp(kernel, 0, 4);
        resetSent();
        for (int block = 0; block < 40; ++block) { run(kernel, 1.0 / 40.0); }

        std::set<int> values;
        for (const Sent &sent : gSent) { values.insert(sent.data2); }
        bool onlyFour = values.size() <= 4;
        std::string seen;
        for (int value : values) { seen += std::to_string(value) + " "; }
        check("a value grid emits only its levels", onlyFour, seen);
        check("including both ends of the range",
              values.count(0) > 0 && values.count(127) > 0, seen);
    }
    {
        // X: the playhead steps. A ramp under a column grid emits each value
        // once and holds it, so the count of DISTINCT values is the column
        // count — a continuous ramp over the same span emits far more.
        PluginDSPKernel gridded;
        gridded.initialize(48000);
        gridded.setMIDIOutputEventBlock(recordingBlock());
        installGriddedRamp(gridded, 8, 0);
        resetSent();
        for (int block = 0; block < 64; ++block) { run(gridded, 1.0 / 64.0); }
        std::set<int> steps;
        for (const Sent &sent : gSent) { steps.insert(sent.data2); }

        PluginDSPKernel smooth;
        smooth.initialize(48000);
        smooth.setMIDIOutputEventBlock(recordingBlock());
        installRamp(smooth, 0);
        resetSent();
        std::set<int> continuous;
        for (int block = 0; block < 64; ++block) {
            run(smooth, 1.0 / 64.0);
        }
        for (const Sent &sent : gSent) { continuous.insert(sent.data2); }

        check("a column grid turns a ramp into a staircase",
              steps.size() <= 8 && steps.size() >= 6,
              std::to_string(steps.size()) + " distinct values over 8 columns");
        check("where the same ramp without one is continuous",
              continuous.size() > steps.size(),
              std::to_string(continuous.size()) + " without the grid");
    }
    {
        // Floor, not round. A step must begin when the playhead crosses into
        // its column, not half a column early — rounding is what makes a
        // quantizer feel like it drags.
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installGriddedRamp(kernel, 4, 0);
        resetSent();
        // 0.24 of a four-column grid is 0.96 of the way through column 0 —
        // *just before* the boundary, which is the only place floor and round
        // differ and therefore the only place this can be checked. A tenth of
        // the way in was the first version and it discriminated nothing:
        // floor(0.4) and round(0.4) are both 0, so the planted "round" bug
        // passed it.
        run(kernel, 0.24);
        check("a phase just short of a column boundary is still the lower column",
              !gSent.empty() && gSent.back().data2 == 0,
              gSent.empty() ? "nothing came out"
                            : std::to_string(gSent.back().data2)
                              + " — rounding here is what makes a quantizer drag");
    }
    {
        // Both grids together, on a note lane: the case the JUCE build is known
        // for. A drawn line becomes a sequence of notes on a scale.
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        kernel.beginCurveUpdate();
        for (uint32_t i = 0; i < 256; ++i) { kernel.setCurveSample(0, i, (float)i / 255.0f); }
        // A lane's min/max are a **fraction of the message's own range**, not
        // note numbers: `emitCurveValue` clamps to 0..1 and then scales by 127
        // (or 16383 for bend). The first version of this passed 48 and 72 and
        // got note 127 every time, because both clamped to 1.0 — and it still
        // "passed", because 127 happens to be in C major. Worth stating: the
        // range is in the curve's units, and the message decides what those
        // mean.
        kernel.setCurveLane(0, 1.0, 48.0f / 127.0f, 72.0f / 127.0f, 0.0f, 0.0f,
                            0x0AB5, 0, 74, 0, 100, /*Note*/ 3, false, true);
        kernel.setCurveLaneGrid(0, 8, 8);
        kernel.commitCurves();
        kernel.setCurvesEnabled(true);
        resetSent();
        for (int block = 0; block < 64; ++block) { run(kernel, 1.0 / 64.0); }

        std::set<int> notes;
        for (const Sent &sent : gSent) {
            if (sent.status == 0x9) { notes.insert(sent.data1); }
        }
        std::string seen;
        for (int note : notes) { seen += std::to_string(note) + " "; }
        check("a gridded note lane plays a countable number of notes",
              notes.size() <= 8 && notes.size() >= 3, seen);
        check("inside the range it was given rather than at the top of MIDI",
              !notes.empty() && *notes.begin() >= 48 && *notes.rbegin() <= 72, seen);
        bool inScale = true;
        for (int note : notes) {
            const int degree = ((note - 48) % 12 + 12) % 12;
            if (((0x0AB5 >> degree) & 1) == 0) { inScale = false; }
        }
        check("and every one of them is still in the scale", inScale,
              "0xAB5 is C major, leftmost = LSB");
    }
    {
        // Off is off, not a grid of one. A grid of one would pin the lane to a
        // single value, which turns a control into a mute.
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        installGriddedRamp(kernel, 1, 1);
        resetSent();
        for (int block = 0; block < 40; ++block) { run(kernel, 1.0 / 40.0); }
        std::set<int> values;
        for (const Sent &sent : gSent) { values.insert(sent.data2); }
        check("a grid of one is off rather than a mute", values.size() > 4,
              std::to_string(values.size()) + " distinct values");
    }

    printf("\n");
    if (gFailures > 0) { printf("curves: %d FAILURES\n", gFailures); return 1; }
    printf("curves: OK\n");
    return 0;
}
