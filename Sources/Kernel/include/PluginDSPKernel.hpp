//
//  PluginDSPKernel.hpp
//  Kernel
//
//  Created by Alexandre Enkerli on 2026-08-21.
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/MIDIMessages.h>
#import <CoreMIDI/MIDIServices.h>

#import <algorithm>
#import <atomic>
#import <cmath>
#import <vector>

#import "PluginParameterAddresses.h"

/*
 PluginDSPKernel
 As a non-ObjC class, this is safe to use from render thread.
 */
class PluginDSPKernel {
public:
    void initialize(double inSampleRate) {
        mSampleRate = inSampleRate;
        // Identity maps and no held notes. Done here rather than in a member
        // initialiser because a 2 x 128 loop in a header that Swift imports is
        // clearer than two brace-initialiser expressions nobody can read.
        for (uint32_t buffer = 0; buffer < 2; ++buffer) {
            for (uint32_t note = 0; note < kNoteMapSize; ++note) {
                mNoteMaps[buffer][note] = (uint8_t)note;
            }
        }
        for (uint32_t channel = 0; channel < 16; ++channel) {
            for (uint32_t note = 0; note < kNoteMapSize; ++note) {
                mHeldNotes[channel][note] = kNoHeldNote;
            }
        }
    }
    
    void deInitialize() {
        // Drop the host-supplied blocks so a stale one can never be called
        // after the host has torn down its render resources.
        mMIDIOutBlock = nullptr;
        mLegacyMIDIOutBlock = nullptr;
        mMusicalContextBlock = nullptr;
    }
    
    // MARK: - Bypass
    bool isBypassed() {
        return mBypassed;
    }
    
    void setBypass(bool shouldBypass) {
        mBypassed = shouldBypass;
    }
    
    // MARK: - Parameter Getter / Setter
    // Add a case for each parameter in PluginParameterAddresses.h
    void setParameter(AUParameterAddress address, AUValue value) {
        switch (address) {
            case PluginParameterAddress::playMelody:
                mPlayMelody = (bool)value;
                break;
            case PluginParameterAddress::playbackDirection:
                mDirection = (PluginPlaybackDirection)(int)std::round(value);
                break;
            case PluginParameterAddress::hostSync:
                mHostSync = (bool)value;
                break;
        }
    }

    AUValue getParameter(AUParameterAddress address) {
        // Return the goal. It is not thread safe to return the ramping value.

        switch (address) {
            case PluginParameterAddress::playMelody:
                return (AUValue)mPlayMelody;

            case PluginParameterAddress::playbackDirection:
                return (AUValue)mDirection;

            case PluginParameterAddress::hostSync:
                return (AUValue)mHostSync;

            default: return 0.f;
        }
    }
    
    // MARK: - Maximum Frames To Render
    AUAudioFrameCount maximumFramesToRender() const {
        return mMaxFramesToRender;
    }
    
    void setMaximumFramesToRender(const AUAudioFrameCount &maxFrames) {
        mMaxFramesToRender = maxFrames;
    }
    
    // MARK: - Musical Context
    void setMusicalContextBlock(AUHostMusicalContextBlock contextBlock) {
        mMusicalContextBlock = contextBlock;
    }
    
    // MARK: - MIDI Output
    //
    // A host supplies whichever of these two blocks it supports: the UMP-based
    // event list block (MIDI 2.0 capable hosts) or the byte-based legacy block.
    // Both may be nil until the host has connected our MIDI output, in which
    // case the kernel emits nothing.
    void setMIDIOutputEventBlock(AUMIDIEventListBlock midiOutBlock) {
        mMIDIOutBlock = midiOutBlock;
    }

    void setLegacyMIDIOutputEventBlock(AUMIDIOutputEventBlock midiOutBlock) {
        mLegacyMIDIOutBlock = midiOutBlock;
    }

    bool hasMIDIOutput() const {
        return mMIDIOutBlock != nullptr || mLegacyMIDIOutBlock != nullptr;
    }

    // MARK: - MIDI Protocol
    MIDIProtocolID AudioUnitMIDIProtocol() const {
        return kMIDIProtocol_2_0;
    }
    
    // MARK: - Melody Sequence (UI-thread setters, render-thread reader)
    //
    // The sequence is double-buffered: the UI thread writes into the inactive
    // buffer, then commitSequence() atomically flips which buffer the render
    // thread reads. Buffers are fixed-size, so there is never an allocation
    // or dangling pointer visible to the render thread.
    
    static constexpr uint32_t kMaxSequenceNotes = 512;
    static constexpr uint32_t kMaxActiveNotes = 64;
    /// One entry per MIDI note, so the transform's lookup is an array index.
    static constexpr uint32_t kNoteMapSize = 128;
    /// "Nothing is sounding for this (channel, note)".
    ///
    /// 0xFE rather than 0xFF, and the difference is a bug the kernel harness
    /// caught: `kMuted` is 0xFF, and a muted note stores its mapping in the
    /// held table like any other, so with one shared sentinel the note-off
    /// read "nothing was held here" and passed the original note through. A
    /// muted note-on produced silence and its note-off produced a note-off —
    /// for a note nothing had started. Both values are outside MIDI's 0…127,
    /// which is why the collision was invisible to every type in the file.
    static constexpr uint8_t kNoHeldNote = 0xFE;
    
    struct SequenceNote {
        double startBeat = 0;
        double endBeat = 0;
        uint8_t note = 0;
        uint8_t velocity = 0; // 0-127
    };
    
    void beginSequenceUpdate() {
        mStagingIndex = 1 - mShared.activeIndex.load(std::memory_order_acquire);
        mSequenceCounts[mStagingIndex] = 0;
    }
    
    void appendSequenceNote(double startBeat, double durationBeats, uint8_t note, uint8_t velocity) {
        uint32_t &count = mSequenceCounts[mStagingIndex];
        if (count >= kMaxSequenceNotes) { return; }
        mSequences[mStagingIndex][count] = { startBeat, startBeat + durationBeats, note, velocity };
        count += 1;
    }
    
    /// - Parameter restartFromTop: play the new sequence from its first beat
    ///   rather than from wherever the loop happens to be.
    ///
    ///   Without this, a take committed at beat 17 of a 32-beat loop began
    ///   sounding at beat 17: everything before that was skipped until the loop
    ///   came round, which is heard as the take's first notes never arriving.
    ///   Auditioning several takes in a row made it every take.
    ///
    ///   Asked for when the *take* changes, not when the render does — otherwise
    ///   moving an expression slider, which re-pushes the same take, would jump
    ///   the loop back to the start on every touch.
    void commitSequence(double lengthBeats, bool restartFromTop = false) {
        mSequenceLengths[mStagingIndex] = std::max(lengthBeats, 0.25);
        mShared.activeIndex.store(mStagingIndex, std::memory_order_release);
        if (restartFromTop) {
            mShared.restartRequested.store(true, std::memory_order_release);
        }
    }
    
    /**
     MARK: - Internal Process
     
     This function does the core MIDI processing:
     it plays back the committed melody sequence, looped, following the host tempo.
     */
    void process(AUEventSampleTime bufferStartTime, AUAudioFrameCount frameCount) {

        if (mBypassed) { return; }

        // Ask the host for tempo and playhead position; fall back to the last
        // known tempo, and note whether the beat position is usable at all.
        mHostBeatValid = false;
        if (mMusicalContextBlock) {
            double tempo = 0;
            double beatPosition = 0;
            if (mMusicalContextBlock(&tempo,
                                     nullptr /* timeSignatureNumerator */,
                                     nullptr /* timeSignatureDenominator */,
                                     &beatPosition,
                                     nullptr /* sampleOffsetToNextBeat */,
                                     nullptr /* currentMeasureDownbeatPosition */)) {
                if (tempo > 0) { mTempo = tempo; }
                mHostBeat = beatPosition;
                mHostBeatValid = true;
            }
        }

        processMelody(bufferStartTime, frameCount);
    }

    void processMelody(AUEventSampleTime bufferStartTime, AUAudioFrameCount frameCount) {
        if (!hasMIDIOutput()) { return; }

        // Handle transport transitions of the playMelody parameter.
        if (mPlayMelody && !mMelodyPlaying) {
            mTimelineBeats = 0;
            mLoopOrigin = 0;
            mPassCarry = 0;
            mShared.passIndex.store(0, std::memory_order_relaxed);
            mHostBeatInitialized = false;
            mMelodyPlaying = true;
            // Pressing play is itself a restart, so an outstanding request from a
            // take committed while stopped doesn't fire a second one later.
            mShared.restartRequested.store(false, std::memory_order_relaxed);
        } else if (!mPlayMelody && mMelodyPlaying) {
            releaseAllNotes(bufferStartTime);
            mMelodyPlaying = false;
            // Publish the stop here: the early return below means
            // publishPassIndex never runs again, so a playhead left to the last
            // value would sit frozen mid-loop instead of disappearing.
            mShared.phaseBeats.store(-1.0, std::memory_order_relaxed);
        }

        if (!mMelodyPlaying) { return; }

        const double beatsPerFrame = mTempo / 60.0 / mSampleRate;
        if (beatsPerFrame <= 0) { return; }
        const double bufferBeats = double(frameCount) * beatsPerFrame;

        // Work out the window of timeline beats this buffer covers. When synced,
        // the window comes from the host's playhead so we follow its transport,
        // tempo map and locates; otherwise we advance our own playhead.
        double windowStart = mTimelineBeats;
        double windowEnd = mTimelineBeats + bufferBeats;

        if (mHostSync && mHostBeatValid) {
            if (!mHostBeatInitialized) {
                // First synced buffer: latch the host position, emit nothing.
                // The loop starts here, so we come in on the pattern's downbeat
                // rather than at whatever beat the host happens to sit on.
                mHostBeatInitialized = true;
                mTimelineBeats = mHostBeat;
                mLoopOrigin = mHostBeat;
                mPassCarry = mShared.passIndex.load(std::memory_order_relaxed);
                return;
            }
            windowStart = mTimelineBeats;
            windowEnd = mHostBeat;

            // A stopped host repeats the same position, and a locate jumps it.
            // Either way, release what is sounding and resync without emitting.
            const bool stalled = windowEnd <= windowStart;
            const bool jumped = (windowEnd - windowStart) > bufferBeats * 4.0 + 1e-9;
            if (stalled || jumped) {
                releaseAllNotes(bufferStartTime);
                mTimelineBeats = windowEnd;
                // A locate is a fresh start: re-anchor the loop, both so the
                // pattern is heard from its top and so loop time can't go
                // negative when the host jumps backwards.
                mPassCarry = mShared.passIndex.load(std::memory_order_relaxed);
                mLoopOrigin = windowEnd;
                return;
            }
        } else {
            mHostBeatInitialized = false;
        }

        // A newly committed take asked to be heard from its beginning: move the
        // loop's origin to here. Whatever is sounding belongs to the take being
        // replaced, so it is released rather than left to expire against beat
        // numbers that no longer mean the same thing.
        if (mShared.restartRequested.exchange(false, std::memory_order_acq_rel)) {
            releaseAllNotes(bufferStartTime);
            // Carry the passes already played before moving the origin, so the
            // counter the interface reads doesn't fall back to zero underneath it.
            mPassCarry = mShared.passIndex.load(std::memory_order_relaxed);
            mLoopOrigin = windowStart;
        }

        // Everything below works in loop time — beats from the loop's own start —
        // rather than in timeline time, so a restart is just a change of origin.
        const double loopStart = windowStart - mLoopOrigin;
        const double loopEnd = windowEnd - mLoopOrigin;

        // Note-offs first, so a note re-triggered at the loop point is released
        // before its next note-on.
        for (uint32_t i = 0; i < mActiveCount;) {
            if (mActiveNotes[i].offBeat < loopEnd) {
                const double offset = std::max(0.0, mActiveNotes[i].offBeat - loopStart) / beatsPerFrame;
                sendNoteOff(bufferStartTime + AUEventSampleTime(offset), mActiveNotes[i].note, 0);
                mActiveNotes[i] = mActiveNotes[mActiveCount - 1];
                mActiveCount -= 1;
            } else {
                i += 1;
            }
        }

        scheduleNotes(bufferStartTime, loopStart, loopEnd, beatsPerFrame);
        mTimelineBeats = windowEnd;
        publishPassIndex(loopEnd);
    }

    /// How many complete loop passes have played. The UI polls this to know when
    /// a take has finished, so it can queue up the next one.
    int64_t currentPass() const {
        return mShared.passIndex.load(std::memory_order_relaxed);
    }

    /// - Parameter loopBeats: position in loop time — beats since the loop's
    ///   origin, which moves whenever a take restarts.
    void publishPassIndex(double loopBeats) {
        mShared.tempo.store(mTempo, std::memory_order_relaxed);
        const uint32_t seq = mShared.activeIndex.load(std::memory_order_acquire);
        const double loopLength = mSequenceLengths[seq];
        if (loopLength <= 0) { return; }
        mShared.loopBeats.store(loopLength, std::memory_order_relaxed);
        // Passes *played*, carried across restarts, rather than passes since the
        // origin. The origin moves on every take handover, so a counter derived
        // from it alone resets to zero each time — and the interface, which asks
        // "has a pass gone by since I last acted", saw its own anchor stranded
        // above the counter. The interval then stretched instead of holding: two
        // loops became four, then six, compounding for as long as the session
        // ran. This counter only ever climbs.
        mShared.passIndex.store(mPassCarry + (int64_t)std::floor(loopBeats / loopLength),
                                std::memory_order_relaxed);
        // Where in the loop the last buffer ended. The pass counter says which
        // time round we are; this says where, which is what a playhead needs.
        double phase = std::fmod(loopBeats, loopLength);
        if (phase < 0) { phase += loopLength; }
        mShared.phaseBeats.store(mMelodyPlaying ? phase : -1.0, std::memory_order_relaxed);
    }

    /// Position within the loop in beats, or a negative value when nothing is
    /// playing — so the interface can tell "at beat zero" from "stopped".
    double currentPhaseBeats() const {
        return mShared.phaseBeats.load(std::memory_order_relaxed);
    }

    // MARK: - Transform
    //
    // Rewriting notes on their way through, which is the other half of what an
    // AU MIDI processor can be and the first thing this kernel has been asked
    // for that is not scheduling.
    //
    // MelGen, ProgGenie and Serpe are all *generators*: they decide a whole
    // pattern off-thread and hand it over, and PORTING.md §8 calls that the
    // invariant — "nothing generates on the audio thread". A quantizer inverts
    // the dataflow but not that rule, and the distinction is worth stating
    // rather than re-deriving: **the decision is still off-thread; only the
    // lookup is on it.** Which pitch classes to snap to, and to what, is
    // computed by the app and committed as a 128-entry table. The render thread
    // reads one byte per note-on. It cannot allocate, cannot block and cannot
    // think.
    //
    // The map is double-buffered exactly like the sequence, for the same
    // reason: a fixed-size buffer flipped by one atomic store means the render
    // thread never sees a half-written table and never touches a pointer that
    // could go stale.

    static constexpr uint8_t kMuted = 0xFF;

    /// The same value, reachable from Swift.
    ///
    /// A `static constexpr` member does not cross C++ interop — Swift simply
    /// does not see it — and hard-coding 0xFF on the Swift side would be two
    /// copies of a sentinel whose whole job is to be unmistakable. One function
    /// is cheaper than that going wrong.
    static uint8_t mutedNote() { return kMuted; }

    /// Fills the inactive map. Every entry starts as itself — an untouched
    /// table is a pass-through, so a half-configured plug-in is silent about it
    /// rather than silent.
    void beginNoteMapUpdate() {
        mMapStagingIndex = 1 - mShared.mapIndex.load(std::memory_order_acquire);
        for (uint32_t note = 0; note < kNoteMapSize; ++note) {
            mNoteMaps[mMapStagingIndex][note] = (uint8_t)note;
        }
    }

    /// `outgoing` may be `kMuted`, which swallows the note.
    ///
    /// Swallowing rather than snapping is a real mode — "play only what is in
    /// the set" is a different instrument from "bend everything into it" — and
    /// it costs one sentinel value here instead of a second table.
    void setMappedNote(uint8_t incoming, uint8_t outgoing) {
        if (incoming >= kNoteMapSize) { return; }
        mNoteMaps[mMapStagingIndex][incoming] = outgoing;
    }

    void commitNoteMap() {
        mShared.mapIndex.store(mMapStagingIndex, std::memory_order_release);
    }

    /// Off by default. A MIDI processor that rewrote notes before anybody asked
    /// it to would be a bug that sounds like a feature.
    void setTransformEnabled(bool enabled) {
        mShared.transformEnabled.store(enabled, std::memory_order_release);
    }

    bool isTransformEnabled() const {
        return mShared.transformEnabled.load(std::memory_order_relaxed);
    }

    // MARK: - Capture

    /// Whether incoming MIDI is collected for learning. Off by default: capture
    /// is a thing you turn on, not something that happens to you.
    void setCaptureEnabled(bool enabled) {
        mCaptureEnabled = enabled;
    }

    bool isCaptureEnabled() const { return mCaptureEnabled; }

    /// How many events have ever been captured. The UI keeps its own cursor and
    /// reads forward from it, which is what makes the ring single-writer,
    /// single-reader and lock-free.
    uint64_t capturedEventCount() const {
        return mShared.captureWrite.load(std::memory_order_acquire);
    }

    /// The oldest event still in the ring. Anything before this was overwritten.
    uint64_t oldestCapturedEvent() const {
        const uint64_t written = capturedEventCount();
        return written > kCaptureCapacity ? written - kCaptureCapacity : 0;
    }

    double capturedBeat(uint64_t index) const { return mCapture[index % kCaptureCapacity].beat; }
    uint8_t capturedNote(uint64_t index) const { return mCapture[index % kCaptureCapacity].note; }
    uint8_t capturedVelocity(uint64_t index) const { return mCapture[index % kCaptureCapacity].velocity; }
    bool capturedIsOn(uint64_t index) const { return mCapture[index % kCaptureCapacity].isOn != 0; }

    /// Tempo and loop length as the render thread sees them, so the UI can say
    /// how long a loop lasts in seconds.
    double currentTempo() const {
        return mShared.tempo.load(std::memory_order_relaxed);
    }

    double currentLoopBeats() const {
        return mShared.loopBeats.load(std::memory_order_relaxed);
    }

    /**
     Emits note-ons for every occurrence of a sequence note in the timeline
     window [windowStart, windowEnd).

     The sequence loops, and each pass through the loop plays either forwards or
     reversed depending on the direction parameter. A reversed pass is a true
     time-reversal: a note occupying [s, e) of a loop of length L plays at
     [L - e, L - s). The window can straddle a loop boundary, so it is walked one
     pass at a time.
     */
    void scheduleNotes(AUEventSampleTime bufferStartTime, double windowStart, double windowEnd, double beatsPerFrame) {
        const uint32_t seq = mShared.activeIndex.load(std::memory_order_acquire);
        const double loopLength = mSequenceLengths[seq];
        const uint32_t noteCount = mSequenceCounts[seq];
        if (noteCount == 0 || loopLength <= 0) { return; }

        double cursor = windowStart;
        while (cursor < windowEnd) {
            const double passIndex = std::floor(cursor / loopLength);
            const double passStart = passIndex * loopLength;
            const double segmentEnd = std::min(windowEnd, passStart + loopLength);
            const bool reversed = isReversedPass((int64_t)passIndex);
            const double phaseStart = cursor - passStart;
            const double phaseEnd = segmentEnd - passStart;

            for (uint32_t i = 0; i < noteCount; ++i) {
                const SequenceNote &event = mSequences[seq][i];
                const double duration = event.endBeat - event.startBeat;
                const double phase = reversed ? (loopLength - event.endBeat) : event.startBeat;
                if (duration <= 0 || phase < 0 || phase >= loopLength) { continue; }
                if (phase < phaseStart || phase >= phaseEnd) { continue; }

                const double occurrence = passStart + phase;
                const AUEventSampleTime time =
                    bufferStartTime + AUEventSampleTime((occurrence - windowStart) / beatsPerFrame);
                startActiveNote(time, event.note, event.velocity, occurrence + duration);
            }

            cursor = segmentEnd;
        }
    }

    bool isReversedPass(int64_t passIndex) const {
        switch (mDirection) {
            case PluginPlaybackDirectionBackward:
                return true;
            case PluginPlaybackDirectionPingPong:
                // Alternate passes, so the loop turns around at both ends.
                return (passIndex % 2) != 0;
            default:
                return false;
        }
    }

    void releaseAllNotes(AUEventSampleTime time) {
        for (uint32_t i = 0; i < mActiveCount; ++i) {
            sendNoteOff(time, mActiveNotes[i].note, 0);
        }
        mActiveCount = 0;
    }

    void startActiveNote(AUEventSampleTime time, uint8_t note, uint8_t velocity, double offBeat) {
        // If this pitch is already sounding, release it to avoid a stuck note.
        for (uint32_t i = 0; i < mActiveCount; ++i) {
            if (mActiveNotes[i].note == note) {
                sendNoteOff(time, note, 0);
                sendNoteOn(time, note, uint16_t(velocity) * 516);
                mActiveNotes[i].offBeat = offBeat;
                return;
            }
        }
        if (mActiveCount >= kMaxActiveNotes) { return; }
        sendNoteOn(time, note, uint16_t(velocity) * 516);
        mActiveNotes[mActiveCount] = { offBeat, note };
        mActiveCount += 1;
    }
    
    void sendNoteOn(AUEventSampleTime sampleTime, uint8_t noteNum, uint16_t velocity) {
        if (mMIDIOutBlock) {
            auto message = MIDI2NoteOn(0, 0, noteNum, 0, 0, velocity);
            MIDIEventList eventList = {};
            MIDIEventPacket *packet = MIDIEventListInit(&eventList, kMIDIProtocol_2_0);
            packet = MIDIEventListAdd(&eventList, sizeof(MIDIEventList), packet, 0, 2, (UInt32 *)&message);
            mMIDIOutBlock(sampleTime, 0, &eventList);
        } else if (mLegacyMIDIOutBlock) {
            const uint8_t bytes[3] = { 0x90, noteNum, midi1Velocity(velocity) };
            mLegacyMIDIOutBlock(sampleTime, 0, sizeof(bytes), bytes);
        }
    }

    void sendNoteOff(AUEventSampleTime sampleTime, uint8_t noteNum, uint16_t velocity) {
        if (mMIDIOutBlock) {
            auto message = MIDI2NoteOff(0, 0, noteNum, 0, 0, velocity);
            MIDIEventList eventList = {};
            MIDIEventPacket *packet = MIDIEventListInit(&eventList, kMIDIProtocol_2_0);
            packet = MIDIEventListAdd(&eventList, sizeof(MIDIEventList), packet, 0, 2, (UInt32 *)&message);
            mMIDIOutBlock(sampleTime, 0, &eventList);
        } else if (mLegacyMIDIOutBlock) {
            const uint8_t bytes[3] = { 0x80, noteNum, midi1Velocity(velocity) };
            mLegacyMIDIOutBlock(sampleTime, 0, sizeof(bytes), bytes);
        }
    }

    // MIDI 2.0 velocities are 16-bit; MIDI 1.0 wants the top 7 bits.
    static uint8_t midi1Velocity(uint16_t velocity) {
        return uint8_t(velocity >> 9);
    }
    
    void handleOneEvent(AUEventSampleTime now, AURenderEvent const *event) {
        switch (event->head.eventType) {
            case AURenderEventParameter: {
                handleParameterEvent(now, event->parameter);
                break;
            }
                
            case AURenderEventMIDIEventList: {
                handleMIDIEventList(now, &event->MIDIEventsList);
                break;
            }
                
            default:
                break;
        }
    }

    void handleMIDIEventList(AUEventSampleTime now, AUMIDIEventList const* midiEvent) {
        // Capture before forwarding. The capture is a fixed ring written by this
        // thread and read by the UI, so nothing here allocates, locks or blocks —
        // the whole point of learning from playing is that it costs the render
        // thread nothing.
        if (mCaptureEnabled) {
            captureEventList(&midiEvent->eventList);
        }

        if (!mMIDIOutBlock) { return; }

        // Pass incoming MIDI through unchanged unless a map says otherwise.
        // The common case is one branch and one atomic load.
        if (!mShared.transformEnabled.load(std::memory_order_relaxed)) {
            mMIDIOutBlock(now, 0, &midiEvent->eventList);
            return;
        }
        transformEventList(now, &midiEvent->eventList);
    }

    /// Rewrites note numbers on their way out, and keeps note-offs matched.
    ///
    /// The matching is the whole difficulty and it is not optional. A note-on
    /// for 61 mapped to 60 must be followed by a note-off for **60**, not for
    /// 61 — the map may have changed in between, or the same incoming note may
    /// have been mapped differently when it started. So what was actually sent
    /// is remembered per (channel, note) and the note-off reads it back. Get
    /// this wrong and the symptom is a stuck note, which is the worst bug a
    /// MIDI processor has because it outlives the plug-in that caused it.
    ///
    /// Anything that is not a note-on or note-off — control change, pitch bend,
    /// clock, sysex — is forwarded untouched, one packet at a time.
    void transformEventList(AUEventSampleTime now, const MIDIEventList *list) {
        if (list == nullptr) { return; }
        const uint8_t map = (uint8_t)mShared.mapIndex.load(std::memory_order_acquire);

        const MIDIEventPacket *packet = &list->packet[0];
        for (uint32_t index = 0; index < list->numPackets; ++index) {
            // A copy on the stack, edited in place. Fixed size, no allocation.
            MIDIEventPacket edited = *packet;
            bool swallow = false;

            for (uint32_t word = 0; word < edited.wordCount; ++word) {
                const uint32_t first = edited.words[word];
                const uint8_t messageType = (uint8_t)((first >> 28) & 0xF);
                const bool isMIDI1 = messageType == 0x2;
                const bool isMIDI2 = messageType == 0x4 && word + 1 < edited.wordCount;
                if (!isMIDI1 && !isMIDI2) {
                    const uint8_t words = umpWordCount(messageType);
                    if (words > 1) { word += (words - 1); }
                    continue;
                }

                const uint8_t status = (uint8_t)((first >> 20) & 0xF);
                const uint8_t channel = (uint8_t)((first >> 16) & 0xF);
                const uint8_t note = (uint8_t)((first >> 8) & 0x7F);
                const bool velocityZero = isMIDI1
                    ? ((uint8_t)(first & 0x7F) == 0)
                    : (((uint16_t)((edited.words[word + 1] >> 16) & 0xFFFF)) == 0);
                const bool isOn = status == 0x9 && !velocityZero;
                const bool isOff = status == 0x8 || (status == 0x9 && velocityZero);

                uint8_t outgoing = note;
                if (isOn) {
                    outgoing = mNoteMaps[map][note];
                    // Remember what was sent, so the note-off can follow it.
                    mHeldNotes[channel][note] = outgoing;
                } else if (isOff) {
                    const uint8_t held = mHeldNotes[channel][note];
                    // No record means the note-on arrived before the transform
                    // was switched on, or before this plug-in was in the chain.
                    // Passing it through unchanged is the safe answer: at worst
                    // it is a note-off nothing is holding.
                    outgoing = held == kNoHeldNote ? note : held;
                    mHeldNotes[channel][note] = kNoHeldNote;
                }

                if ((isOn || isOff) && outgoing == kMuted) {
                    swallow = true;
                    break;
                }
                if ((isOn || isOff) && outgoing != note) {
                    edited.words[word] = (first & ~(uint32_t)(0x7F << 8))
                                       | ((uint32_t)(outgoing & 0x7F) << 8);
                }
                if (isMIDI2) { ++word; }
            }

            if (!swallow) {
                MIDIEventList out = {};
                MIDIEventPacket *slot = MIDIEventListInit(&out, kMIDIProtocol_2_0);
                slot = MIDIEventListAdd(&out, sizeof(MIDIEventList), slot,
                                        edited.timeStamp, edited.wordCount, edited.words);
                mMIDIOutBlock(now, 0, &out);
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    /// Pulls note-ons and note-offs out of a UMP event list into the capture ring.
    ///
    /// Both encodings are handled because both turn up: a host that negotiated
    /// MIDI 1.0 sends message type 2, one that negotiated MIDI 2.0 sends type 4
    /// with 16-bit velocity. Everything else — control change, pitch bend, clock —
    /// is passed through untouched and not captured; this is learning *melody*
    /// from playing, and a mod wheel isn't one.
    void captureEventList(const MIDIEventList *list) {
        if (list == nullptr) { return; }
        const MIDIEventPacket *packet = &list->packet[0];
        for (uint32_t index = 0; index < list->numPackets; ++index) {
            for (uint32_t word = 0; word < packet->wordCount; ++word) {
                const uint32_t first = packet->words[word];
                const uint8_t messageType = (uint8_t)((first >> 28) & 0xF);

                if (messageType == 0x2) {
                    // MIDI 1.0 in a UMP: status, note, velocity in one word.
                    const uint8_t status = (uint8_t)((first >> 20) & 0xF);
                    const uint8_t note = (uint8_t)((first >> 8) & 0x7F);
                    const uint8_t velocity = (uint8_t)(first & 0x7F);
                    if (status == 0x9 && velocity > 0) {
                        pushCapture(note, velocity, true);
                    } else if (status == 0x8 || (status == 0x9 && velocity == 0)) {
                        pushCapture(note, 0, false);
                    }
                } else if (messageType == 0x4 && word + 1 < packet->wordCount) {
                    // MIDI 2.0: velocity is 16-bit in the second word.
                    const uint8_t status = (uint8_t)((first >> 20) & 0xF);
                    const uint8_t note = (uint8_t)((first >> 8) & 0x7F);
                    const uint16_t wide = (uint16_t)((packet->words[word + 1] >> 16) & 0xFFFF);
                    const uint8_t velocity = (uint8_t)(wide >> 9);
                    if (status == 0x9 && wide > 0) {
                        pushCapture(note, velocity > 0 ? velocity : 1, true);
                    } else if (status == 0x8 || (status == 0x9 && wide == 0)) {
                        pushCapture(note, 0, false);
                    }
                    ++word;
                }

                // A UMP's word count tells us how far to step; unknown message
                // types are skipped by the loop rather than mis-parsed.
                const uint8_t words = umpWordCount(messageType);
                if (words > 1) { word += (words - 1); }
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    static uint8_t umpWordCount(uint8_t messageType) {
        switch (messageType) {
            case 0x0: case 0x1: case 0x2: return 1;
            case 0x3: case 0x4: return 2;
            case 0x5: return 4;
            default: return 1;
        }
    }

    /// One entry into the ring. Never blocks: if the UI hasn't drained it in
    /// time the oldest entries are simply lost, which is the right trade for a
    /// render thread — a dropped phrase is a nuisance, a glitch is a bug.
    void pushCapture(uint8_t note, uint8_t velocity, bool isOn) {
        const uint64_t sequence = mShared.captureWrite.load(std::memory_order_relaxed);
        CapturedEvent &slot = mCapture[sequence % kCaptureCapacity];
        slot.beat = mTimelineBeats;
        slot.note = note;
        slot.velocity = velocity;
        slot.isOn = isOn ? 1 : 0;
        mShared.captureWrite.store(sequence + 1, std::memory_order_release);
    }
    
    void handleParameterEvent(AUEventSampleTime now, AUParameterEvent const& parameterEvent) {
        setParameter(parameterEvent.parameterAddress, parameterEvent.value);
    }
    
    // MARK: Member Variables
    AUHostMusicalContextBlock mMusicalContextBlock;
    
    double mSampleRate = 44100.0;
    double mTempo = 120.0;
    bool mBypassed = false;
    AUAudioFrameCount mMaxFramesToRender = 1024;
    
    AUMIDIEventListBlock mMIDIOutBlock;
    AUMIDIOutputEventBlock mLegacyMIDIOutBlock;

    /// One captured note-on or note-off, in timeline beats.
    struct CapturedEvent {
        double beat = 0;
        uint8_t note = 0;
        uint8_t velocity = 0;
        uint8_t isOn = 0;
    };
    static constexpr uint32_t kCaptureCapacity = 1024;

    bool mCaptureEnabled = false;
    CapturedEvent mCapture[kCaptureCapacity];

    // Melody playback state
    struct ActiveNote {
        double offBeat = 0; // timeline beat at which to release
        uint8_t note = 0;
    };

    // Transport parameters
    bool mPlayMelody = false;
    bool mHostSync = false;
    PluginPlaybackDirection mDirection = PluginPlaybackDirectionForward;

    bool mMelodyPlaying = false;   // render-thread playback state
    double mTimelineBeats = 0;     // position the last buffer ended at
    /// The timeline value that counts as beat zero of the loop.
    ///
    /// Zero until something restarts the loop. Keeping it separate from
    /// `mTimelineBeats` is what lets a restart work identically whether the
    /// timeline is ours or the host's: the host's playhead keeps its own meaning,
    /// and the loop just decides where its own start is on that ruler.
    double mLoopOrigin = 0;
    /// Passes played before the current origin. What makes the published pass
    /// counter monotonic across take handovers and host locates.
    int64_t mPassCarry = 0;
    double mHostBeat = 0;          // host playhead, this buffer
    bool mHostBeatValid = false;   // did the host give us a position?
    bool mHostBeatInitialized = false;
    ActiveNote mActiveNotes[kMaxActiveNotes];
    uint32_t mActiveCount = 0;

    SequenceNote mSequences[2][kMaxSequenceNotes];
    uint32_t mSequenceCounts[2] = {0, 0};
    double mSequenceLengths[2] = {0, 0};
    uint32_t mStagingIndex = 1;

    // The note map, double-buffered the same way and for the same reason. Both
    // buffers start as the identity, so a kernel whose map was never written is
    // a pass-through even with the transform switched on.
    uint8_t mNoteMaps[2][kNoteMapSize];
    uint32_t mMapStagingIndex = 1;
    /// What was actually sent for each (channel, incoming note) that is
    /// sounding, so the note-off can follow the note-on. Render thread only —
    /// no atomics, because nothing else touches it.
    uint8_t mHeldNotes[16][kNoteMapSize];

    // Fields shared across threads, gathered in one place because std::atomic is
    // neither copyable nor movable: a bare atomic member makes the whole kernel
    // un-importable by Swift's C++ interop (the type simply disappears from
    // Swift's view). This copyable holder keeps the kernel usable as a stored
    // property in the audio unit that owns this kernel.
    struct SharedFields {
        /// Which sequence buffer the render thread reads (UI thread writes).
        std::atomic<uint32_t> activeIndex{0};
        /// How many complete loop passes have played (render thread writes, the
        /// UI reads it to drive auto-regeneration).
        std::atomic<int64_t> passIndex{0};
        /// The tempo the render thread is working from, so the UI can work out
        /// how long a loop actually lasts and whether generation fits inside one.
        std::atomic<double> tempo{120.0};
        /// Loop length in beats, for the same reason.
        std::atomic<double> loopBeats{0};
        /// Position within the current pass, or negative when stopped.
        std::atomic<double> phaseBeats{-1.0};
        /// Set by the UI thread when a newly committed take should be heard from
        /// its beginning; cleared by the render thread once it has been.
        std::atomic<bool> restartRequested{false};
        /// How many MIDI events have been captured, ever. The render thread
        /// writes; the UI reads forward from its own cursor.
        std::atomic<uint64_t> captureWrite{0};
        /// Which note map the render thread reads (UI thread writes).
        std::atomic<uint32_t> mapIndex{0};
        /// Whether to rewrite notes at all. Off by default.
        std::atomic<bool> transformEnabled{false};

        SharedFields() = default;
        SharedFields(const SharedFields &other)
        : activeIndex{other.activeIndex.load(std::memory_order_acquire)},
          passIndex{other.passIndex.load(std::memory_order_acquire)},
          tempo{other.tempo.load(std::memory_order_relaxed)},
          loopBeats{other.loopBeats.load(std::memory_order_relaxed)},
          phaseBeats{other.phaseBeats.load(std::memory_order_relaxed)},
          restartRequested{other.restartRequested.load(std::memory_order_relaxed)},
          captureWrite{other.captureWrite.load(std::memory_order_acquire)},
          mapIndex{other.mapIndex.load(std::memory_order_acquire)},
          transformEnabled{other.transformEnabled.load(std::memory_order_relaxed)} {}
        SharedFields &operator=(const SharedFields &other) {
            activeIndex.store(other.activeIndex.load(std::memory_order_acquire), std::memory_order_release);
            passIndex.store(other.passIndex.load(std::memory_order_acquire), std::memory_order_release);
            tempo.store(other.tempo.load(std::memory_order_relaxed), std::memory_order_relaxed);
            loopBeats.store(other.loopBeats.load(std::memory_order_relaxed), std::memory_order_relaxed);
            phaseBeats.store(other.phaseBeats.load(std::memory_order_relaxed), std::memory_order_relaxed);
            restartRequested.store(other.restartRequested.load(std::memory_order_relaxed), std::memory_order_relaxed);
            captureWrite.store(other.captureWrite.load(std::memory_order_acquire), std::memory_order_release);
            mapIndex.store(other.mapIndex.load(std::memory_order_acquire), std::memory_order_release);
            transformEnabled.store(other.transformEnabled.load(std::memory_order_relaxed), std::memory_order_relaxed);
            return *this;
        }
    };

    SharedFields mShared;
};
