//
//  transform-main.mm
//  Kernel
//
//  The note-rewriting path, driven directly, outside any host.
//
//  This is the first thing the kernel does that is not scheduling, and it is the
//  one place a bug outlives the plug-in that caused it: a note-on that is
//  rewritten and a note-off that is not leaves a note sounding forever, in
//  somebody else's synth, after this plug-in has been removed from the chain.
//  So the matching is what most of these cases are about.
//
//  Compiled and run by Scripts/check-kernel.sh, outside Xcode and outside
//  SwiftPM, for the same reason MelGen's kernel suite is: the render thread is
//  C++ and neither test runner reaches it.
//
//  It found two bugs before it was believed, and one of them was in itself.
//
//  `AURenderEvent` is a union, so setting `event.head.eventType` and then
//  assigning the payload overwrites the header with the payload's zeroed one —
//  the kernel saw event type 0, ignored everything, and every case here
//  reported nothing coming out. Two of them "passed" on that, because "nothing
//  came out" is what a muted note looks like. A harness that cannot deliver an
//  event is indistinguishable from a kernel that swallows one, which is worth
//  knowing before trusting a green.
//
//  Then a real one: `kMuted` and `kNoHeldNote` were both 0xFF. A muted note
//  stores its mapping in the held table like any other, so the note-off read
//  "nothing was held here" and passed the original note through — silence on
//  the way in, a note-off on the way out, for a note nothing had started.
//  Both values are outside MIDI's 0…127, so no type in the file could see it.
//
//  Then it was made to fail on purpose, with the three shapes of stuck note:
//
//    · note-on rewritten, note-off left alone (the classic)       → 4 failures
//    · note-off mapped through the CURRENT map rather than the
//      mapping its note-on actually used                          → 3
//    · note-on swallowed by a mute, note-off not                  → 1
//
//  All reverted.
//

#import <Foundation/Foundation.h>
#import "../../Sources/Kernel/include/PluginDSPKernel.hpp"

#import <string>
#import <vector>

// ── A recording output block ───────────────────────────────────────────────

struct Sent {
    uint8_t status;     // 0x9 note-on, 0x8 note-off
    uint8_t channel;
    uint8_t note;
    uint8_t velocity;
};

static std::vector<Sent> gSent;
static std::vector<uint32_t> gRawFirstWords;

static void resetSent() { gSent.clear(); gRawFirstWords.clear(); }

static AUMIDIEventListBlock recordingBlock() {
    return ^(AUEventSampleTime, uint8_t, const MIDIEventList *list) {
        if (list == nullptr) { return (OSStatus)noErr; }
        const MIDIEventPacket *packet = &list->packet[0];
        for (uint32_t p = 0; p < list->numPackets; ++p) {
            for (uint32_t w = 0; w < packet->wordCount; ++w) {
                const uint32_t first = packet->words[w];
                gRawFirstWords.push_back(first);
                const uint8_t type = (uint8_t)((first >> 28) & 0xF);
                if (type == 0x2) {
                    // MIDI 1.0 in one word: the transform path and the curve
                    // lanes.
                    gSent.push_back({ (uint8_t)((first >> 20) & 0xF),
                                      (uint8_t)((first >> 16) & 0xF),
                                      (uint8_t)((first >> 8) & 0x7F),
                                      (uint8_t)(first & 0x7F) });
                    continue;
                }
                if (type == 0x4 && w + 1 < packet->wordCount) {
                    // MIDI 2.0 in two words: the *sequence* path, which uses
                    // 16-bit velocity. This harness recorded only type 0x2 until
                    // 2026-09, so every note the scheduler sent was invisible to
                    // it — and a check that expected one failed while the kernel
                    // was correct. Worth stating plainly: for a while this file
                    // could only see half of what the kernel does.
                    const uint32_t second = packet->words[w + 1];
                    gSent.push_back({ (uint8_t)((first >> 20) & 0xF),
                                      (uint8_t)((first >> 16) & 0xF),
                                      (uint8_t)((first >> 8) & 0x7F),
                                      (uint8_t)((second >> 25) & 0x7F) });
                    w += 1;
                    continue;
                }
            }
            packet = MIDIEventPacketNext(packet);
        }
        return (OSStatus)noErr;
    };
}

// ── Feeding it ─────────────────────────────────────────────────────────────

/// One MIDI 1.0 note message in a UMP word.
static uint32_t noteWord(uint8_t status, uint8_t channel, uint8_t note, uint8_t velocity) {
    return ((uint32_t)0x2 << 28) | ((uint32_t)0x0 << 24)
         | ((uint32_t)(status & 0xF) << 20) | ((uint32_t)(channel & 0xF) << 16)
         | ((uint32_t)(note & 0x7F) << 8) | (uint32_t)(velocity & 0x7F);
}

static void feed(PluginDSPKernel &kernel, uint32_t word) {
    MIDIEventList list = {};
    MIDIEventPacket *packet = MIDIEventListInit(&list, kMIDIProtocol_2_0);
    packet = MIDIEventListAdd(&list, sizeof(MIDIEventList), packet, 0, 1, &word);

    // AURenderEvent is a UNION, so the event type has to be set inside the
    // payload rather than through `event.head` before assigning it — writing
    // the head first and the payload second overwrites the head with the
    // payload's zeroed one, and the kernel then sees event type 0 and ignores
    // it. Which it did, silently, and every case in this file "passed" or
    // "failed" for that reason instead of for its own. That is worth a comment:
    // a harness that cannot deliver an event reports the same thing as a kernel
    // that swallows one.
    AUMIDIEventList wrapper = {};
    wrapper.next = nullptr;
    wrapper.eventSampleTime = 0;
    wrapper.eventType = AURenderEventMIDIEventList;
    wrapper.cable = 0;
    wrapper.eventList = list;

    AURenderEvent event = {};
    event.MIDIEventsList = wrapper;
    kernel.handleOneEvent(0, &event);
}

// ── Saying what happened ───────────────────────────────────────────────────

static int gFailures = 0;

static void check(const std::string &what, bool passed, const std::string &detail = "") {
    printf("  %s  %s%s\n", passed ? "PASS" : "FAIL", what.c_str(),
           detail.empty() ? "" : (" — " + detail).c_str());
    if (!passed) { gFailures += 1; }
}

int main() {
    printf("── transform: rewriting notes on the way through ──\n");

    // ── pass-through when nothing has asked for anything ───────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();
        feed(kernel, noteWord(0x9, 0, 61, 100));
        check("transform off passes a note through untouched",
              gSent.size() == 1 && gSent[0].note == 61,
              gSent.empty() ? "nothing came out" : "note " + std::to_string(gSent[0].note));
    }

    // A map that snaps every black note down to the white one below it — the
    // shape a C-major quantizer has, and enough to tell a rewrite from a
    // pass-through.
    auto snapToCMajor = [](PluginDSPKernel &kernel) {
        static const int inCMajor[12] = {1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1};
        kernel.beginNoteMapUpdate();
        for (int note = 0; note < 128; ++note) {
            int mapped = note;
            while (mapped > 0 && !inCMajor[mapped % 12]) { mapped -= 1; }
            kernel.setMappedNote((uint8_t)note, (uint8_t)mapped);
        }
        kernel.commitNoteMap();
        kernel.setTransformEnabled(true);
    };

    // ── the rewrite, and the matching that is the whole difficulty ─────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        snapToCMajor(kernel);

        resetSent();
        feed(kernel, noteWord(0x9, 0, 61, 100));
        check("a note-on is rewritten", gSent.size() == 1 && gSent[0].note == 60,
              gSent.empty() ? "nothing" : "61 → " + std::to_string(gSent[0].note));
        check("and keeps its velocity and channel",
              gSent.size() == 1 && gSent[0].velocity == 100 && gSent[0].channel == 0);

        resetSent();
        feed(kernel, noteWord(0x8, 0, 61, 0));
        check("the matching note-off follows it rather than the original",
              gSent.size() == 1 && gSent[0].note == 60 && gSent[0].status == 0x8,
              gSent.empty() ? "nothing" : "off for " + std::to_string(gSent[0].note));
    }

    // ── the case that causes stuck notes ───────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        snapToCMajor(kernel);

        resetSent();
        feed(kernel, noteWord(0x9, 0, 61, 100));   // sounds 60

        // The map changes while the note is held — the player turns the scale
        // dial mid-chord, which is the whole point of a quantizer with a dial.
        kernel.beginNoteMapUpdate();
        for (int note = 0; note < 128; ++note) { kernel.setMappedNote((uint8_t)note, (uint8_t)note); }
        kernel.commitNoteMap();

        resetSent();
        feed(kernel, noteWord(0x8, 0, 61, 0));
        check("a map change mid-note does not strand the sounding note",
              gSent.size() == 1 && gSent[0].note == 60,
              gSent.empty() ? "nothing came out — STUCK NOTE"
                            : "off for " + std::to_string(gSent[0].note)
                              + (gSent[0].note == 60 ? "" : " — STUCK NOTE"));
    }

    // ── note-on with velocity 0 is a note-off, and has to match too ────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        snapToCMajor(kernel);
        feed(kernel, noteWord(0x9, 0, 61, 100));
        resetSent();
        feed(kernel, noteWord(0x9, 0, 61, 0));     // running-status note-off
        check("a velocity-0 note-on is treated as the note-off it is",
              gSent.size() == 1 && gSent[0].note == 60,
              gSent.empty() ? "nothing" : "note " + std::to_string(gSent[0].note));
    }

    // ── channels do not leak into each other ───────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        snapToCMajor(kernel);
        feed(kernel, noteWord(0x9, 0, 61, 100));
        resetSent();
        feed(kernel, noteWord(0x8, 5, 61, 0));     // same note, another channel
        check("a note-off on another channel is not the held note's",
              gSent.size() == 1 && gSent[0].channel == 5 && gSent[0].note == 61,
              gSent.empty() ? "nothing"
                            : "ch " + std::to_string(gSent[0].channel)
                              + " note " + std::to_string(gSent[0].note));
    }

    // ── an unmatched note-off is passed through, not swallowed ─────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        snapToCMajor(kernel);
        resetSent();
        feed(kernel, noteWord(0x8, 0, 61, 0));     // no note-on ever arrived
        check("an unmatched note-off goes through unchanged rather than vanishing",
              gSent.size() == 1 && gSent[0].note == 61,
              gSent.empty() ? "swallowed" : "note " + std::to_string(gSent[0].note));
    }

    // ── muting ─────────────────────────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        kernel.beginNoteMapUpdate();
        kernel.setMappedNote(61, PluginDSPKernel::kMuted);
        kernel.commitNoteMap();
        kernel.setTransformEnabled(true);

        resetSent();
        feed(kernel, noteWord(0x9, 0, 61, 100));
        check("a muted note produces nothing", gSent.empty(),
              gSent.empty() ? "" : "something came out");
        resetSent();
        feed(kernel, noteWord(0x8, 0, 61, 0));
        check("and neither does its note-off", gSent.empty(),
              gSent.empty() ? "" : "something came out");
        resetSent();
        feed(kernel, noteWord(0x9, 0, 62, 100));
        check("while an unmapped note beside it is untouched",
              gSent.size() == 1 && gSent[0].note == 62);
    }

    // ── everything that is not a note ──────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        snapToCMajor(kernel);
        resetSent();
        // Control change 74, value 61 — the value is in the note position, so a
        // transform that did not check the message type would rewrite it.
        const uint32_t cc = ((uint32_t)0x2 << 28) | ((uint32_t)0xB << 20)
                          | ((uint32_t)74 << 8) | (uint32_t)61;
        feed(kernel, cc);
        const bool intact = gRawFirstWords.size() == 1 && gRawFirstWords[0] == cc;
        check("a control change is forwarded byte for byte", intact,
              intact ? "" : (gRawFirstWords.empty() ? "nothing came out" : "the word changed"));
    }

    // ── panic ──────────────────────────────────────────────────────────────
    //
    // The worst bug a MIDI processor has is a note-on whose note-off never came,
    // sounding in somebody else's synth, outliving this plug-in being removed
    // from the chain. The kernel already tracked what it holds; what was missing
    // until now was a way for a person to say stop.
    //
    // The transform half is the one that could be wrong quietly: a note-on for
    // 61 mapped to 60 must be released as **60**, and a panic that guessed would
    // leave exactly the note it was called to stop.
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());

        kernel.beginNoteMapUpdate();
        kernel.setMappedNote(61, 60);
        kernel.commitNoteMap();
        kernel.setTransformEnabled(true);

        feed(kernel, noteWord(0x9, 3, 61, 100));
        resetSent();
        kernel.requestPanic();
        kernel.process(0, 512);

        bool releasedTheMappedNote = false;
        bool releasedTheOriginal = false;
        for (const Sent &sent : gSent) {
            if (sent.status != 0x8) { continue; }
            if (sent.note == 60 && sent.channel == 3) { releasedTheMappedNote = true; }
            if (sent.note == 61) { releasedTheOriginal = true; }
        }
        check("panic releases a transformed note as what was actually sent",
              releasedTheMappedNote, "note-off for 60 on channel 3");
        check("and not as what was played, which would leave the real one stuck",
              !releasedTheOriginal);

        // A second panic must not release it twice: a note-off for a note that
        // is no longer sounding is harmless in most synths and not in all, and
        // it would mean the held table was never cleared.
        resetSent();
        kernel.requestPanic();
        kernel.process(512, 512);
        bool releasedAgain = false;
        for (const Sent &sent : gSent) {
            if (sent.status == 0x8 && sent.note == 60) { releasedAgain = true; }
        }
        check("and the held table is cleared, so a second panic sends nothing",
              !releasedAgain);
    }
    {
        // A panic while nothing is sounding must be silent rather than sending
        // 2048 speculative note-offs.
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();
        kernel.requestPanic();
        kernel.process(0, 512);
        check("a panic with nothing sounding sends nothing", gSent.empty(),
              std::to_string(gSent.size()) + " messages");
    }
    {
        // A sequence note released **while still playing**.
        //
        // The first version of this checked a note left over after the transport
        // stopped, and it failed — because stopping already calls
        // `releaseAllNotes`, so there was nothing left to release and the check
        // was describing a situation the kernel does not allow. The kernel was
        // right; the check was checking a hypothetical.
        //
        // What is real is a long note sounding right now and somebody reaching
        // for panic, which is what this does.
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        kernel.beginSequenceUpdate();
        kernel.appendSequenceNote(0.0, 16.0, 64, 100);
        kernel.commitSequence(16.0, true);
        kernel.setParameter(playMelody, 1);
        kernel.process(0, 512);

        resetSent();
        kernel.requestPanic();
        kernel.process(512, 512);
        bool released = false;
        for (const Sent &sent : gSent) {
            if (sent.status == 0x8 && sent.note == 64) { released = true; }
        }
        check("and a sounding sequence note is released mid-flight",
              released, "which is the case panic exists for");
    }

    printf("\n");
    if (gFailures > 0) {
        printf("transform: %d FAILURES\n", gFailures);
        return 1;
    }
    printf("transform: OK\n");
    return 0;
}
