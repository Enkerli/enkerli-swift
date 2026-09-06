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

    printf("\n");
    if (gFailures > 0) { printf("curves: %d FAILURES\n", gFailures); return 1; }
    printf("curves: OK\n");
    return 0;
}
