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

        // Before anything else, and outside the transport entirely. A burst is
        // a request the user made — "send these bytes now" — and holding it
        // until the host happens to be playing would make a diagnostic that
        // works in one host and mysteriously does not in another, which is the
        // opposite of what a diagnostic is for.
        sendPendingSysEx(bufferStartTime);

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

        // Curve lanes run alongside the note sequence rather than instead of
        // it. A plug-in that uses one uses only one, but the kernel does not
        // need to know that, and keeping them independent is what let the note
        // path stay untouched when this was added.
        if (mSampleRate > 0 && frameCount > 0) {
            advanceCurves(bufferStartTime, (double)frameCount / mSampleRate);
        }
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

    // MARK: - Curve lanes
    //
    // Playing a drawn line, which is the kernel's third job after scheduling
    // notes and rewriting them.
    //
    // Adapted from GestureEngine in DrawnQurve, and this one is a *move* rather
    // than a port: that engine is C++ and this is C++, so there is no language
    // boundary to get wrong and nothing for a vector file to hold. What holds it
    // is Tests/Kernel/curves-main.mm, the same way the transform path is held.
    //
    // Same division as everywhere else in this kernel. Off-thread: the 256
    // samples, the message type, the range, the scale mask — all committed as a
    // fixed-size snapshot. On-thread: advance a phase, index the table,
    // interpolate, smooth, map, and emit only when the value changed. No
    // allocation, no branching on anything the UI is still deciding.
    //
    // A lane emits at most one message per render block, deliberately. The
    // alternative — a message per frame — floods a MIDI stream with values no
    // synth can act on and no host can display, and at 48 kHz it is 48,000
    // control changes a second for a curve nobody can hear moving that fast.

    /// Eight, because a drawn lane can carry two curves.
    ///
    /// It was four, matching DrawnQurve's `kMaxLanes`. Apple Pencil reports
    /// pressure alongside position, and a stroke that carries it produces two
    /// curves from one gesture — the line you drew and how hard you pressed
    /// while drawing it. A plug-in pairs them, so four drawn lanes want eight
    /// here. The array is 8 x (256 floats + a few fields), about 8 KB per
    /// buffer and 16 KB double-buffered, which is not a number worth
    /// economising on.
    static constexpr uint32_t kMaxCurveLanes = 8;
    static constexpr uint32_t kCurveTableSize = 256;

    enum class CurveMessage : uint8_t {
        ControlChange = 0,
        ChannelPressure = 1,
        PitchBend = 2,
        Note = 3,
    };

    struct CurveLane {
        float table[kCurveTableSize] = {};
        double durationSeconds = 1.0;
        float minOut = 0.0f;
        float maxOut = 1.0f;
        float smoothing = 0.08f;
        float phaseOffset = 0.0f;
        /// 12-bit root-relative mask; bit 0 is the root. 0xFFF is chromatic and
        /// means no quantization. Leftmost = LSB, like every mask in this suite.
        uint16_t scaleMask = 0x0FFF;
        uint8_t scaleRoot = 0;
        uint8_t controller = 74;
        uint8_t channel = 0;
        uint8_t velocity = 100;
        CurveMessage message = CurveMessage::ControlChange;
        bool oneShot = false;
        bool enabled = false;
    };

    /// Per-lane render-thread state. No atomics: nothing else touches it.
    struct CurveRuntime {
        double elapsedSeconds = 0;
        float smoothed = 0;
        int lastValue = -1;      ///< last emitted, for dedup. -1 = nothing yet
        int lastRawNote = -1;    ///< before quantization, to tell which way it moved
        int heldNote = -1;       ///< sounding note in Note mode, -1 = none
        uint8_t heldChannel = 0; ///< the channel it started on
        bool started = false;    ///< whether the smoother has a value yet
        bool finished = false;   ///< a one-shot that has run out
    };

    void beginCurveUpdate() {
        mCurveStagingIndex = 1 - mShared.curveIndex.load(std::memory_order_acquire);
        for (uint32_t lane = 0; lane < kMaxCurveLanes; ++lane) {
            mCurveLanes[mCurveStagingIndex][lane] = CurveLane{};
        }
    }

    void setCurveSample(uint32_t lane, uint32_t index, float value) {
        if (lane >= kMaxCurveLanes || index >= kCurveTableSize) { return; }
        mCurveLanes[mCurveStagingIndex][lane].table[index] = value;
    }

    void setCurveLane(uint32_t lane, double durationSeconds,
                      float minOut, float maxOut, float smoothing, float phaseOffset,
                      uint16_t scaleMask, uint8_t scaleRoot,
                      uint8_t controller, uint8_t channel, uint8_t velocity,
                      uint8_t message, bool oneShot, bool enabled) {
        if (lane >= kMaxCurveLanes) { return; }
        CurveLane &target = mCurveLanes[mCurveStagingIndex][lane];
        target.durationSeconds = durationSeconds > 0.01 ? durationSeconds : 0.01;
        target.minOut = minOut;
        target.maxOut = maxOut;
        target.smoothing = smoothing;
        target.phaseOffset = phaseOffset;
        target.scaleMask = scaleMask;
        target.scaleRoot = scaleRoot;
        target.controller = controller;
        target.channel = channel;
        target.velocity = velocity;
        target.message = (CurveMessage)message;
        target.oneShot = oneShot;
        target.enabled = enabled;
    }

    void commitCurves() {
        mShared.curveIndex.store(mCurveStagingIndex, std::memory_order_release);
    }

    /// Whether curve lanes run at all. Off until asked, like the transform.
    void setCurvesEnabled(bool enabled) {
        mShared.curvesEnabled.store(enabled, std::memory_order_release);
        if (!enabled) { mShared.curvesStopRequested.store(true, std::memory_order_release); }
    }

    bool areCurvesEnabled() const {
        return mShared.curvesEnabled.load(std::memory_order_relaxed);
    }

    /// Where a lane's playhead is, 0..1, for drawing it. -1 when it is not
    /// running.
    double curvePhase(uint32_t lane) const {
        if (lane >= kMaxCurveLanes) { return -1; }
        return mShared.curvePhases[lane].load(std::memory_order_relaxed);
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
    // MARK: - SysEx: the fourth job
    //
    // The kernel had three jobs — schedule notes, rewrite notes, play curves —
    // and all three deal in things it can *construct*: a note number, a
    // controller value. SysEx is different in kind. It is opaque bytes decided
    // somewhere else, and the render thread's entire contribution is carrying
    // them without touching them.
    //
    // That makes it the easiest of the four to get right and the easiest to get
    // subtly wrong, because "bytes arrive intact" is the whole contract and
    // there is no musical symptom when it breaks. A wrong note is audible; a
    // truncated frame is a device that does not answer.
    //
    // Out is a *burst*, not a stream: the UI fills a buffer and commits it, and
    // the render thread sends that buffer once. A second identical burst needs a
    // second commit. That is deliberate — a probe asking "did these exact bytes
    // get out?" must be able to tell this burst's echo from the last one's, and
    // a queue that re-sent on every block could not.

    static constexpr uint32_t kSysExMaxBytes = 64;
    static constexpr uint32_t kSysExBurstFrames = 16;
    static constexpr uint32_t kSysExInCapacity = 64;

    /// One SysEx frame, F0 and F7 included, in a fixed slot.
    ///
    /// Up here with the constants rather than down with the other storage,
    /// because `sendSysExFrame` names it and C++ reads a class body in order for
    /// member *signatures* even though it defers member bodies. Putting it below
    /// gave `unknown type name 'SysExFrame'` on the declaration alone.
    struct SysExFrame {
        uint8_t bytes[kSysExMaxBytes] = {};
        uint32_t length = 0;
    };
    struct SysExBurst {
        SysExFrame frames[kSysExBurstFrames];
        uint32_t count = 0;
    };

    /// Starts filling the burst that is not being read.
    void beginSysExBurst() {
        const uint32_t back = 1 - (mShared.sysExIndex.load(std::memory_order_acquire) & 1);
        mSysExOut[back].count = 0;
    }

    /// Adds one frame, F0 and F7 included, to the burst being filled.
    ///
    /// Returns false rather than truncating. A SysEx frame that is silently cut
    /// short is the exact failure this whole capability exists to detect, and
    /// producing one here to avoid an awkward return value would be absurd.
    bool addSysExFrame(const uint8_t *bytes, uint32_t length) {
        if (bytes == nullptr || length < 2 || length > kSysExMaxBytes) { return false; }
        const uint32_t back = 1 - (mShared.sysExIndex.load(std::memory_order_acquire) & 1);
        SysExBurst &burst = mSysExOut[back];
        if (burst.count >= kSysExBurstFrames) { return false; }
        SysExFrame &frame = burst.frames[burst.count];
        for (uint32_t index = 0; index < length; ++index) { frame.bytes[index] = bytes[index]; }
        frame.length = length;
        burst.count += 1;
        return true;
    }

    /// Publishes the burst. The render thread sends it once, on its next block.
    void commitSysExBurst() {
        const uint32_t current = mShared.sysExIndex.load(std::memory_order_acquire);
        mShared.sysExIndex.store(current + 1, std::memory_order_release);
    }

    /// How many frames have ever arrived. The UI reads forward from its own
    /// cursor, exactly as it does for captured notes.
    uint64_t sysExInCount() const {
        return mShared.sysExInWrite.load(std::memory_order_acquire);
    }

    uint64_t oldestSysExIn() const {
        const uint64_t written = sysExInCount();
        return written > kSysExInCapacity ? written - kSysExInCapacity : 0;
    }

    uint32_t sysExInLength(uint64_t index) const {
        return mSysExIn[index % kSysExInCapacity].length;
    }

    uint8_t sysExInByte(uint64_t index, uint32_t offset) const {
        const SysExFrame &frame = mSysExIn[index % kSysExInCapacity];
        return offset < frame.length ? frame.bytes[offset] : 0;
    }

    /// Whether an arriving frame was longer than a slot. Reported rather than
    /// hidden: a truncated frame in the ring must never be mistaken for what
    /// the wire carried.
    uint64_t sysExInTruncated() const {
        return mShared.sysExInTruncated.load(std::memory_order_acquire);
    }

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
    
    /// Advances every enabled curve lane by one block and emits what changed.
    ///
    /// One message per lane per block, deliberately — see the note above the
    /// commit API. `secondsPerBlock` is how much time this block covers, which
    /// is the only thing a curve needs from the transport: unlike the note
    /// sequence, a curve loops on its own recorded duration rather than on
    /// beats, so it does not follow tempo unless somebody asks it to.
    void advanceCurves(AUEventSampleTime sampleTime, double secondsPerBlock) {
        if (!mShared.curvesEnabled.load(std::memory_order_relaxed)) {
            if (mShared.curvesStopRequested.exchange(false, std::memory_order_acq_rel)) {
                releaseCurveNotes(sampleTime);
            }
            return;
        }
        const uint32_t set = mShared.curveIndex.load(std::memory_order_acquire);

        for (uint32_t lane = 0; lane < kMaxCurveLanes; ++lane) {
            const CurveLane &curve = mCurveLanes[set][lane];
            CurveRuntime &runtime = mCurveRuntimes[lane];

            if (!curve.enabled) {
                releaseCurveNote(sampleTime, lane);
                mShared.curvePhases[lane].store(-1.0, std::memory_order_relaxed);
                runtime.finished = false;
                continue;
            }

            runtime.elapsedSeconds += secondsPerBlock;
            double phase = runtime.elapsedSeconds / curve.durationSeconds;
            if (phase >= 1.0) {
                if (curve.oneShot) {
                    // A one-shot ends where it ends and stays there: releasing
                    // its note and holding the last value is what "played once"
                    // has to mean for a controller, which has no note-off.
                    if (!runtime.finished) {
                        runtime.finished = true;
                        releaseCurveNote(sampleTime, lane);
                    }
                    phase = 1.0;
                } else {
                    runtime.elapsedSeconds = fmod(runtime.elapsedSeconds, curve.durationSeconds);
                    phase = runtime.elapsedSeconds / curve.durationSeconds;
                }
            }
            mShared.curvePhases[lane].store(phase, std::memory_order_relaxed);
            if (runtime.finished) { continue; }

            const float raw = sampleCurve(curve, (float)phase);
            const float ranged = curve.minOut + (curve.maxOut - curve.minOut) * raw;

            // One-pole smoothing, and the first value is taken as-is rather
            // than eased up from zero — otherwise every lane opens with a swoop
            // nobody drew.
            if (!runtime.started) {
                runtime.smoothed = ranged;
                runtime.started = true;
            } else {
                const float coefficient = curve.smoothing;
                runtime.smoothed += (ranged - runtime.smoothed) * (1.0f - coefficient);
            }
            emitCurveValue(sampleTime, lane, curve, runtime, runtime.smoothed);
        }
    }

    /// Table lookup with linear interpolation, wrapping round rather than off
    /// the end — a loop has no last sample.
    static float sampleCurve(const CurveLane &curve, float phase) {
        float shifted = phase + curve.phaseOffset;
        shifted -= floorf(shifted);
        const float position = shifted * (float)(kCurveTableSize - 1);
        const uint32_t low = (uint32_t)position;
        const uint32_t high = (low + 1) % kCurveTableSize;
        const float fraction = position - (float)low;
        return curve.table[low] + fraction * (curve.table[high] - curve.table[low]);
    }

    /// The nearest member of a root-relative 12-bit mask.
    ///
    /// Ties resolve by direction of travel — a curve climbing takes the note
    /// above, a curve falling takes the one below — which is DrawnQurve's rule
    /// and is the right one here for the reason the opposite rule is right in a
    /// quantizer: this is following a line somebody drew, so the fold should go
    /// the way the line is already going.
    static uint8_t quantizeCurveNote(int note, uint16_t mask, uint8_t root, bool movingUp) {
        if (mask == 0x0FFF) { return (uint8_t)(note < 0 ? 0 : (note > 127 ? 127 : note)); }
        note = note < 0 ? 0 : (note > 127 ? 127 : note);
        const int interval = ((note % 12) - (int)root + 12) % 12;
        if ((mask >> interval) & 1) { return (uint8_t)note; }

        int below = -1, above = -1;
        for (int distance = 1; distance <= 6; ++distance) {
            if (below < 0 && note - distance >= 0
                && ((mask >> (((interval - distance) % 12 + 12) % 12)) & 1)) {
                below = note - distance;
            }
            if (above < 0 && note + distance <= 127
                && ((mask >> ((interval + distance) % 12)) & 1)) {
                above = note + distance;
            }
            if (below >= 0 && above >= 0) { break; }
        }
        if (below < 0 && above < 0) { return (uint8_t)note; }
        if (below < 0) { return (uint8_t)above; }
        if (above < 0) { return (uint8_t)below; }
        const int down = note - below, up = above - note;
        if (down == up) { return (uint8_t)(movingUp ? above : below); }
        return (uint8_t)(down < up ? below : above);
    }

    void emitCurveValue(AUEventSampleTime sampleTime, uint32_t lane,
                        const CurveLane &curve, CurveRuntime &runtime, float value) {
        const float clamped = value < 0 ? 0 : (value > 1 ? 1 : value);
        switch (curve.message) {
            case CurveMessage::ControlChange: {
                const int coarse = (int)(clamped * 127.0f + 0.5f);
                if (coarse == runtime.lastValue) { return; }
                runtime.lastValue = coarse;
                sendControlChange(sampleTime, curve.channel, curve.controller, (uint8_t)coarse);
                return;
            }
            case CurveMessage::ChannelPressure: {
                const int coarse = (int)(clamped * 127.0f + 0.5f);
                if (coarse == runtime.lastValue) { return; }
                runtime.lastValue = coarse;
                sendChannelPressure(sampleTime, curve.channel, (uint8_t)coarse);
                return;
            }
            case CurveMessage::PitchBend: {
                const int wide = (int)(clamped * 16383.0f + 0.5f);
                if (wide == runtime.lastValue) { return; }
                runtime.lastValue = wide;
                sendPitchBend(sampleTime, curve.channel, (uint16_t)wide);
                return;
            }
            case CurveMessage::Note: {
                const int raw = (int)(clamped * 127.0f + 0.5f);
                const bool movingUp = runtime.lastValue < 0 || raw >= runtime.lastRawNote;
                runtime.lastRawNote = raw;
                const uint8_t note = quantizeCurveNote(raw, curve.scaleMask,
                                                       curve.scaleRoot, movingUp);
                if ((int)note == runtime.lastValue) { return; }
                // Off before on: a curve walking up a scale would otherwise
                // stack every note it passed through, and a synth with limited
                // voices would run out inside one loop.
                releaseCurveNote(sampleTime, lane);
                runtime.lastValue = note;
                runtime.heldNote = note;
                runtime.heldChannel = curve.channel;
                sendNoteOnChannel(sampleTime, curve.channel, note,
                                  (uint16_t)curve.velocity * 516);
                return;
            }
        }
    }

    /// Ends a lane's held note, if it has one. Uses the channel recorded when
    /// the note started, so changing a lane's channel mid-note does not orphan
    /// it — the same rule the transform path follows for the same reason.
    void releaseCurveNote(AUEventSampleTime sampleTime, uint32_t lane) {
        CurveRuntime &runtime = mCurveRuntimes[lane];
        if (runtime.heldNote < 0) { return; }
        sendNoteOffChannel(sampleTime, runtime.heldChannel, (uint8_t)runtime.heldNote);
        runtime.heldNote = -1;
        runtime.lastValue = -1;
    }

    void releaseCurveNotes(AUEventSampleTime sampleTime) {
        for (uint32_t lane = 0; lane < kMaxCurveLanes; ++lane) {
            releaseCurveNote(sampleTime, lane);
            mCurveRuntimes[lane] = CurveRuntime{};
            mShared.curvePhases[lane].store(-1.0, std::memory_order_relaxed);
        }
    }

    void sendControlChange(AUEventSampleTime sampleTime, uint8_t channel,
                           uint8_t controller, uint8_t value) {
        sendMIDI1(sampleTime, 0xB, channel, controller, value);
    }

    void sendChannelPressure(AUEventSampleTime sampleTime, uint8_t channel, uint8_t value) {
        sendMIDI1(sampleTime, 0xD, channel, value, 0);
    }

    void sendPitchBend(AUEventSampleTime sampleTime, uint8_t channel, uint16_t value) {
        // 14-bit, low seven bits first — the one place in MIDI 1.0 where the
        // least significant byte leads, which is not the suite's leftmost-LSB
        // convention showing up but does rhyme with it.
        sendMIDI1(sampleTime, 0xE, channel, (uint8_t)(value & 0x7F), (uint8_t)((value >> 7) & 0x7F));
    }

    void sendNoteOnChannel(AUEventSampleTime sampleTime, uint8_t channel,
                           uint8_t note, uint16_t velocity) {
        sendMIDI1(sampleTime, 0x9, channel, note, midi1Velocity(velocity));
    }

    void sendNoteOffChannel(AUEventSampleTime sampleTime, uint8_t channel, uint8_t note) {
        sendMIDI1(sampleTime, 0x8, channel, note, 0);
    }

    /// One MIDI 1.0 message in a UMP word.
    ///
    /// MIDI 1.0 rather than 2.0 for the curve lanes: a control change is seven
    /// bits wherever it lands, every host understands this encoding, and the
    /// note path above already uses MIDI2NoteOn where the extra resolution is
    /// worth having. Mixing the two in one stream is legal.
    void sendMIDI1(AUEventSampleTime sampleTime, uint8_t status, uint8_t channel,
                   uint8_t data1, uint8_t data2) {
        if (mMIDIOutBlock) {
            const uint32_t word = ((uint32_t)0x2 << 28)
                                | ((uint32_t)(status & 0xF) << 20)
                                | ((uint32_t)(channel & 0xF) << 16)
                                | ((uint32_t)(data1 & 0x7F) << 8)
                                | (uint32_t)(data2 & 0x7F);
            MIDIEventList eventList = {};
            MIDIEventPacket *packet = MIDIEventListInit(&eventList, kMIDIProtocol_2_0);
            packet = MIDIEventListAdd(&eventList, sizeof(MIDIEventList), packet, 0, 1, &word);
            mMIDIOutBlock(sampleTime, 0, &eventList);
        } else if (mLegacyMIDIOutBlock) {
            const uint8_t bytes[3] = { (uint8_t)((status << 4) | (channel & 0xF)), data1, data2 };
            mLegacyMIDIOutBlock(sampleTime, 0, status == 0xD ? 2 : 3, bytes);
        }
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

    /// Pulls SysEx7 frames out of a UMP list into the inbound ring.
    ///
    /// Message type 0x3 is SysEx7: two words per packet, six data bytes maximum,
    /// and a status nibble saying whether this packet is the whole frame (0), its
    /// start (1), a middle (2) or its end (3). So a frame is reassembled across
    /// packets and, in principle, across render blocks — which is why the
    /// partial buffer is a member and not a local.
    ///
    /// The F0 and F7 are *not* on the wire in UMP; they are framing that MIDI
    /// 1.0 needed and SysEx7 replaced with the status nibble. They are put back
    /// here so that everything above this line sees one representation of a
    /// frame, the one the protocol documents are written in.
    void captureSysEx(const MIDIEventList *list) {
        if (list == nullptr) { return; }
        const MIDIEventPacket *packet = &list->packet[0];
        for (uint32_t index = 0; index < list->numPackets; ++index) {
            for (uint32_t word = 0; word < packet->wordCount; ++word) {
                const uint32_t first = packet->words[word];
                const uint8_t messageType = (uint8_t)((first >> 28) & 0xF);
                if (messageType != 0x3) {
                    const uint8_t words = umpWordCount(messageType);
                    if (words > 1) { word += (words - 1); }
                    continue;
                }
                if (word + 1 >= packet->wordCount) { break; }
                const uint32_t second = packet->words[word + 1];
                const uint8_t status = (uint8_t)((first >> 20) & 0xF);
                const uint8_t count = (uint8_t)((first >> 16) & 0xF);

                if (status == 0x0 || status == 0x1) {
                    mSysExPartial.length = 0;
                    mSysExOverflowed = false;
                    mSysExInProgress = true;
                    appendSysExByte(0xF0);
                }
                if (!mSysExInProgress) { word += 1; continue; }

                const uint8_t data[6] = {
                    (uint8_t)((first >> 8) & 0x7F), (uint8_t)(first & 0x7F),
                    (uint8_t)((second >> 24) & 0x7F), (uint8_t)((second >> 16) & 0x7F),
                    (uint8_t)((second >> 8) & 0x7F), (uint8_t)(second & 0x7F)
                };
                for (uint8_t byte = 0; byte < count && byte < 6; ++byte) {
                    appendSysExByte(data[byte]);
                }

                if (status == 0x0 || status == 0x3) {
                    appendSysExByte(0xF7);
                    pushSysExIn();
                    mSysExInProgress = false;
                }
                word += 1;
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    void appendSysExByte(uint8_t byte) {
        if (mSysExPartial.length >= kSysExMaxBytes) { mSysExOverflowed = true; return; }
        mSysExPartial.bytes[mSysExPartial.length++] = byte;
    }

    /// One frame into the ring. Never blocks; the oldest is lost if the UI has
    /// not drained it, which is the same trade the note capture makes.
    void pushSysExIn() {
        if (mSysExOverflowed) {
            mShared.sysExInTruncated.fetch_add(1, std::memory_order_relaxed);
        }
        const uint64_t sequence = mShared.sysExInWrite.load(std::memory_order_relaxed);
        mSysExIn[sequence % kSysExInCapacity] = mSysExPartial;
        mShared.sysExInWrite.store(sequence + 1, std::memory_order_release);
        mSysExPartial.length = 0;
        mSysExOverflowed = false;
    }

    /// Sends a committed burst, once.
    ///
    /// Compared against the render thread's own counter rather than a flag the
    /// UI clears, so a commit that lands while this block is running is sent on
    /// the next one instead of being lost or sent twice.
    void sendPendingSysEx(AUEventSampleTime sampleTime) {
        const uint32_t committed = mShared.sysExIndex.load(std::memory_order_acquire);
        if (committed == mSysExSent) { return; }
        mSysExSent = committed;
        const SysExBurst &burst = mSysExOut[committed & 1];
        for (uint32_t index = 0; index < burst.count; ++index) {
            sendBurstMessage(sampleTime, burst.frames[index]);
        }
    }

    /// One message out of a burst.
    ///
    /// A burst carries whatever a device needs to be told, and for a device that
    /// is rarely only SysEx: the RND takes its seed over SysEx, its scale over
    /// CC9, and its tonic as a *note*. Three mechanisms for three message types
    /// would have been three things to get right; one buffer that dispatches on
    /// the status byte is one.
    ///
    /// So: leading 0xF0 means SysEx7, anything else is a short MIDI 1.0 message
    /// sent verbatim. Nothing here interprets a channel message beyond its
    /// length — the whole contract of a burst is that the bytes decided
    /// off-thread are the bytes that go out.
    void sendBurstMessage(AUEventSampleTime sampleTime, const SysExFrame &frame) {
        if (frame.length == 0) { return; }
        if (frame.bytes[0] != 0xF0) { sendShortMessage(sampleTime, frame); return; }
        sendSysExFrame(sampleTime, frame);
    }

    /// A two- or three-byte channel message, as one UMP word.
    void sendShortMessage(AUEventSampleTime sampleTime, const SysExFrame &frame) {
        if (frame.length < 2) { return; }
        const uint8_t status = (uint8_t)((frame.bytes[0] >> 4) & 0xF);
        const uint8_t channel = (uint8_t)(frame.bytes[0] & 0xF);
        const uint8_t data1 = frame.bytes[1];
        const uint8_t data2 = frame.length > 2 ? frame.bytes[2] : 0;
        sendMIDI1(sampleTime, status, channel, data1, data2);
    }

    /// One SysEx frame out, as SysEx7 packets of at most six data bytes.
    ///
    /// The F0 and F7 the caller supplied are stripped again here, for the reason
    /// given above `captureSysEx`: they are MIDI 1.0 framing, and UMP carries
    /// the same information in the status nibble. Sending them as data bytes
    /// would produce a frame no device accepts — and, worse, one that looks
    /// right in a byte dump.
    void sendSysExFrame(AUEventSampleTime sampleTime, const SysExFrame &frame) {
        if (frame.length < 2) { return; }
        const uint8_t *data = frame.bytes + 1;
        const uint32_t total = frame.length - 2;

        if (mLegacyMIDIOutBlock && !mMIDIOutBlock) {
            mLegacyMIDIOutBlock(sampleTime, 0, frame.length, frame.bytes);
            return;
        }
        if (!mMIDIOutBlock) { return; }

        MIDIEventList eventList = {};
        MIDIEventPacket *packet = MIDIEventListInit(&eventList, kMIDIProtocol_2_0);
        uint32_t sent = 0;
        do {
            const uint32_t chunk = (total - sent) > 6 ? 6 : (total - sent);
            const bool isFirst = sent == 0;
            const bool isLast = sent + chunk >= total;
            const uint8_t status = isFirst ? (isLast ? 0x0 : 0x1) : (isLast ? 0x3 : 0x2);

            uint8_t bytes[6] = {};
            for (uint32_t index = 0; index < chunk; ++index) { bytes[index] = data[sent + index]; }

            const uint32_t words[2] = {
                ((uint32_t)0x3 << 28) | ((uint32_t)status << 20) | ((uint32_t)chunk << 16)
                    | ((uint32_t)bytes[0] << 8) | (uint32_t)bytes[1],
                ((uint32_t)bytes[2] << 24) | ((uint32_t)bytes[3] << 16)
                    | ((uint32_t)bytes[4] << 8) | (uint32_t)bytes[5]
            };
            packet = MIDIEventListAdd(&eventList, sizeof(MIDIEventList), packet, 0, 2, words);
            sent += chunk;
        } while (sent < total);

        mMIDIOutBlock(sampleTime, 0, &eventList);
    }

    void handleMIDIEventList(AUEventSampleTime now, AUMIDIEventList const* midiEvent) {
        captureSysEx(&midiEvent->eventList);

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

    /// Double-buffered, like the sequence and the curves and for the same
    /// reason: the UI fills one while the render thread reads the other.
    SysExBurst mSysExOut[2];
    /// The generation the render thread has already sent. Its own; not shared.
    uint32_t mSysExSent = 0;

    SysExFrame mSysExIn[kSysExInCapacity];
    /// Partial reassembly across UMP packets. A SysEx7 frame arrives as up to
    /// six data bytes per packet with a start/continue/end status, so a frame
    /// spans packets and — in principle — render blocks.
    SysExFrame mSysExPartial;
    bool mSysExInProgress = false;
    bool mSysExOverflowed = false;

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

    CurveLane mCurveLanes[2][kMaxCurveLanes];
    uint32_t mCurveStagingIndex = 1;
    CurveRuntime mCurveRuntimes[kMaxCurveLanes];
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
        /// Which curve set the render thread reads (UI thread writes).
        std::atomic<uint32_t> curveIndex{0};
        /// Whether curve lanes run. Off by default.
        std::atomic<bool> curvesEnabled{false};
        /// Set when curves are switched off, so the render thread knows to end
        /// any note they left sounding. Cleared by the render thread.
        std::atomic<bool> curvesStopRequested{false};
        /// Which SysEx burst buffer is current. Incremented by the UI thread on
        /// commit; the render thread sends a buffer once per new value.
        std::atomic<uint32_t> sysExIndex{0};
        /// How many SysEx frames have arrived, ever.
        std::atomic<uint64_t> sysExInWrite{0};
        /// How many arriving frames did not fit a slot.
        std::atomic<uint64_t> sysExInTruncated{0};
        /// Where each lane's playhead is, 0..1, or -1 when it is not running.
        ///
        /// In here rather than beside the runtimes because of the note at the
        /// top of this struct, which predicted this exact mistake: an array of
        /// bare atomics as a member of the kernel makes the whole type
        /// un-importable by Swift, and the symptom is not an error about
        /// atomics — it is `cannot find 'PluginDSPKernel' in scope` at every
        /// use site, because the type simply stops existing in Swift's view.
        std::atomic<double> curvePhases[kMaxCurveLanes];

        SharedFields() {
            for (uint32_t lane = 0; lane < kMaxCurveLanes; ++lane) {
                curvePhases[lane].store(-1.0, std::memory_order_relaxed);
            }
        }
        SharedFields(const SharedFields &other)
        : activeIndex{other.activeIndex.load(std::memory_order_acquire)},
          passIndex{other.passIndex.load(std::memory_order_acquire)},
          tempo{other.tempo.load(std::memory_order_relaxed)},
          loopBeats{other.loopBeats.load(std::memory_order_relaxed)},
          phaseBeats{other.phaseBeats.load(std::memory_order_relaxed)},
          restartRequested{other.restartRequested.load(std::memory_order_relaxed)},
          captureWrite{other.captureWrite.load(std::memory_order_acquire)},
          mapIndex{other.mapIndex.load(std::memory_order_acquire)},
          transformEnabled{other.transformEnabled.load(std::memory_order_relaxed)},
          curveIndex{other.curveIndex.load(std::memory_order_acquire)},
          curvesEnabled{other.curvesEnabled.load(std::memory_order_relaxed)},
          curvesStopRequested{other.curvesStopRequested.load(std::memory_order_relaxed)},
          sysExIndex{other.sysExIndex.load(std::memory_order_acquire)},
          sysExInWrite{other.sysExInWrite.load(std::memory_order_acquire)},
          sysExInTruncated{other.sysExInTruncated.load(std::memory_order_acquire)} {
            for (uint32_t lane = 0; lane < kMaxCurveLanes; ++lane) {
                curvePhases[lane].store(other.curvePhases[lane].load(std::memory_order_relaxed),
                                        std::memory_order_relaxed);
            }
        }
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
            curveIndex.store(other.curveIndex.load(std::memory_order_acquire), std::memory_order_release);
            curvesEnabled.store(other.curvesEnabled.load(std::memory_order_relaxed), std::memory_order_relaxed);
            curvesStopRequested.store(other.curvesStopRequested.load(std::memory_order_relaxed), std::memory_order_relaxed);
            sysExIndex.store(other.sysExIndex.load(std::memory_order_acquire), std::memory_order_release);
            sysExInWrite.store(other.sysExInWrite.load(std::memory_order_acquire), std::memory_order_release);
            sysExInTruncated.store(other.sysExInTruncated.load(std::memory_order_acquire), std::memory_order_release);
            for (uint32_t lane = 0; lane < kMaxCurveLanes; ++lane) {
                curvePhases[lane].store(other.curvePhases[lane].load(std::memory_order_relaxed),
                                        std::memory_order_relaxed);
            }
            return *this;
        }
    };

    SharedFields mShared;
};
