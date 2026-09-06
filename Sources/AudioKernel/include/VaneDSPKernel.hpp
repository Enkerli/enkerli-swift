//
//  VaneDSPKernel.hpp
//  AudioKernel
//
//  A mono, breath-first wind voice, and the render loop around it.
//
//  This is the first thing in this package that produces a *sample*. The MIDI
//  kernel next door has four jobs and all four are about messages; its render
//  block's entire output is `mMIDIOutBlock`. This one must produce a number
//  every sample whether or not anything has been decided, which inverts
//  PORTING.md §8's invariant rather than breaking it — and is exactly why it is
//  a separate target that `Shell` and `Kernel` do not depend on. A MIDI
//  processor never links a line of this.
//
//  ── What makes it Vane rather than a generic synth ────────────────────────
//
//  **Amplitude comes from breath, not from the keyboard.** The gesture is
//
//      max(CC2, CC11, channel pressure, velocityMix * sqrt(velocity))
//
//  — Vane's formula, and `max` rather than a sum because these are four
//  spellings of one gesture, not four gestures. The first three are what a wind
//  controller, a breath controller and an MPE surface actually send; the fourth
//  is the fallback that keeps a piano roll from being silent, and setting it to
//  zero is what makes this instrument silent under a sequencer — the trap Vane
//  measured (peak 0.00000 against 0.99997) and this file's harness reproduces.
//
//  **One divergence from Vane, and it is deliberate.** Vane has a fifth term in
//  that `max`: a synthetic breath envelope, opt-in and off by default. Here the
//  envelope is not a source at all — it is the note's **gate**:
//
//      amplitude = gesture * gate
//
//  Two reasons. First, a fifth term in a `max` *flattens a wind player*: an
//  envelope sitting at 0.7 means the breath can never go below 0.7, which
//  removes the expression the instrument exists for — which is exactly why
//  Vane's is off by default. Second, with only a `max`, a released note whose
//  velocity term is still standing never stops. Vane has a waveguide that needs
//  a non-zero excitation and a separate gate; this MVP has neither, so the
//  envelope does that job. A wind player's breath is unflattened, a piano-roll
//  note gets a shape and a release, and `velocityMix = 0` still silences it.
//
//  **Legato does not retrigger.** A note arriving while one is held re-aims the
//  pitch and leaves the envelope, the filter state and the oscillator phase
//  alone. Every one of those three would click if it were reset, and the third
//  is the one people forget.
//
//  **Everything that can step, glides.** Pitch through a portamento, breath
//  through a one-pole, gain through a per-sample ramp, cutoff recomputed per
//  sample. A wind line is continuous, so a discontinuity anywhere in the chain
//  is heard as a fault in the instrument rather than as a feature of the note.
//
//  ── Real-time discipline ──────────────────────────────────────────────────
//
//  No allocation, no locks, no logging. The wavetable is 1.4 MB built once by
//  `initialize`, off this thread, and shared by every instance. The only thing
//  crossing to the UI is a `std::atomic<float>` in `SharedFields` — which is a
//  struct for the same reason the MIDI kernel's is: a bare `std::atomic` member
//  makes the whole type un-importable by Swift, and the symptom is not an error
//  about atomics but `cannot find 'VaneDSPKernel' in scope` at every use site.
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <algorithm>
#import <atomic>
#import <cmath>

#import "VaneParameterAddresses.h"
#import "VaneBreathEnvelope.hpp"
#import "VaneSVFilter.hpp"
#import "VaneWavetable.hpp"

class VaneDSPKernel {
public:
    // MARK: - Lifecycle

    void initialize(double sampleRate, int channelCount) {
        mSampleRate = sampleRate > 0 ? sampleRate : 48000.0;
        mChannelCount = channelCount > 0 ? channelCount : 2;
        // Forces the shared table to build here rather than on the first note,
        // which is the one place it would allocate on the audio thread.
        (void)VaneWavetable::shared();
        mFilter.prepare(mSampleRate);
        mEnvelope.prepare(mSampleRate);
        reset();
    }

    void deInitialize() {}

    /// Everything a stopped instrument should forget. Not the parameters.
    void reset() {
        mHeldCount = 0;
        mPhase = 0.0f;
        mCurrentHz = 0.0;
        mTargetHz = 0.0;
        mGain = 0.0f;
        mBreathSmoothed = 0.0f;
        mBreathCC = 0.0f;
        mExpressionCC = 0.0f;
        mPressure = 0.0f;
        mTimbreCC = 0.5f;
        mBend = 0.0f;
        mBendSmoothed = 0.0f;
        mVelocity = 0.0f;
        mEnvelope.reset();
        mFilter.reset();
        mShared.breath.store(0.0f, std::memory_order_relaxed);
        mShared.sounding.store(false, std::memory_order_relaxed);
    }

    // MARK: - Host plumbing

    AUAudioFrameCount maximumFramesToRender() const { return mMaxFrames; }
    void setMaximumFramesToRender(AUAudioFrameCount frames) { mMaxFrames = frames; }
    bool isBypassed() const { return mBypassed; }
    void setBypass(bool bypassed) { mBypassed = bypassed; if (bypassed) { reset(); } }
    MIDIProtocolID AudioUnitMIDIProtocol() const { return kMIDIProtocol_2_0; }

    /// Silences the voice on the next block.
    ///
    /// A synth's stuck note is the same bug as a MIDI processor's and worse in
    /// one way: there is no downstream instrument to send an all-notes-off to,
    /// so nothing outside this kernel can stop it. A held-note stack that got
    /// out of step — a note-on whose note-off was filtered by a host, say —
    /// would otherwise sound until the plug-in was removed.
    ///
    /// A flag rather than a direct reset, for the same reason the MIDI kernel
    /// uses one: whoever calls this is the UI, and the UI does not own the
    /// render thread's state.
    void requestPanic() {
        mShared.panicRequested.store(true, std::memory_order_release);
    }

    // MARK: - What the UI may look at
    //
    // Two readings, both atomic, both written by the render thread and never
    // read by it. Breath is the interesting one: this is an instrument whose
    // whole subject is a continuous gesture, and an interface that could not
    // show it would be describing a different instrument.

    float currentBreath() const { return mShared.breath.load(std::memory_order_relaxed); }
    bool isSounding() const { return mShared.sounding.load(std::memory_order_relaxed); }

    // MARK: - Parameters

    void setParameter(AUParameterAddress address, AUValue value) {
        switch (address) {
            case vaneMorph: mMorph = std::clamp(float(value), 0.0f, 1.0f); break;
            case vaneLevel: mLevel = std::clamp(float(value), 0.0f, 1.0f); break;
            case vaneCutoff: mCutoffHz = std::clamp(float(value), 20.0f, 20000.0f); break;
            case vaneResonance: mResonance = std::clamp(float(value), 0.0f, 1.0f); break;
            case vaneBreathToCutoff: mBreathToCutoff = std::clamp(float(value), 0.0f, 8.0f); break;
            case vaneVelocityMix: mVelocityMix = std::clamp(float(value), 0.0f, 1.0f); break;
            case vaneGlideMs: mGlideMs = std::clamp(float(value), 0.0f, 2000.0f); break;
            case vaneAttackMs: mEnvelopeParams.attackMs = std::max(0.0f, float(value)); break;
            case vaneDecayMs: mEnvelopeParams.decayMs = std::max(1.0f, float(value)); break;
            case vaneSustain: mEnvelopeParams.sustain = std::clamp(float(value), 0.0f, 1.0f); break;
            case vaneReleaseMs: mEnvelopeParams.releaseMs = std::max(1.0f, float(value)); break;
            case vaneTimbreToCutoff: mTimbreToCutoff = std::clamp(float(value), 0.0f, 8.0f); break;
            case vaneBendRange: mBendRange = std::clamp(float(value), 0.0f, 96.0f); break;
            default: break;
        }
    }

    AUValue getParameter(AUParameterAddress address) const {
        switch (address) {
            case vaneMorph: return mMorph;
            case vaneLevel: return mLevel;
            case vaneCutoff: return mCutoffHz;
            case vaneResonance: return mResonance;
            case vaneBreathToCutoff: return mBreathToCutoff;
            case vaneVelocityMix: return mVelocityMix;
            case vaneGlideMs: return mGlideMs;
            case vaneAttackMs: return mEnvelopeParams.attackMs;
            case vaneDecayMs: return mEnvelopeParams.decayMs;
            case vaneSustain: return mEnvelopeParams.sustain;
            case vaneReleaseMs: return mEnvelopeParams.releaseMs;
            case vaneTimbreToCutoff: return mTimbreToCutoff;
            case vaneBendRange: return mBendRange;
            default: return 0;
        }
    }

    // MARK: - Events

    void handleOneEvent(AUEventSampleTime now, AURenderEvent const *event) {
        switch (event->head.eventType) {
            case AURenderEventParameter:
                setParameter(event->parameter.parameterAddress, event->parameter.value);
                break;
            case AURenderEventMIDIEventList:
                handleMIDIEventList(&event->MIDIEventsList);
                break;
            default:
                break;
        }
    }

    void handleMIDIEventList(AUMIDIEventList const *midiEvent) {
        const MIDIEventList *list = &midiEvent->eventList;
        const MIDIEventPacket *packet = &list->packet[0];
        for (uint32_t index = 0; index < list->numPackets; ++index) {
            for (uint32_t word = 0; word < packet->wordCount; ++word) {
                const uint32_t first = packet->words[word];
                const uint8_t messageType = (uint8_t)((first >> 28) & 0xF);
                if (messageType == 0x2) {
                    // MIDI 1.0 in a UMP word.
                    handleChannelMessage((uint8_t)((first >> 20) & 0xF),
                                         (uint8_t)((first >> 8) & 0x7F),
                                         (uint8_t)(first & 0x7F));
                } else if (messageType == 0x4 && word + 1 < packet->wordCount) {
                    // MIDI 2.0: 16-bit velocity in the second word's high half.
                    const uint32_t second = packet->words[word + 1];
                    const uint8_t status = (uint8_t)((first >> 20) & 0xF);
                    const uint8_t data1 = (uint8_t)((first >> 8) & 0x7F);
                    const uint8_t data2 = (uint8_t)((second >> 25) & 0x7F);
                    handleChannelMessage(status, data1, data2);
                    word += 1;
                } else {
                    const uint8_t words = umpWordCount(messageType);
                    if (words > 1) { word += (words - 1); }
                }
            }
            packet = MIDIEventPacketNext(packet);
        }
    }

    /// Channel is deliberately ignored.
    ///
    /// This is a **mono** instrument, and under MPE every note arrives on its own
    /// channel with its own bend, pressure and CC74. Merging them is exactly
    /// right here: one voice, one gesture, whichever finger is expressing it.
    /// It is also what makes the same code work for a wind controller on channel
    /// 1 and a Seaboard on channels 2–16 with no mode switch — and a mode switch
    /// is the thing a player has to remember.
    ///
    /// A polyphonic Vane would have to stop ignoring it. That is in GAPS.md.
    void handleChannelMessage(uint8_t status, uint8_t data1, uint8_t data2) {
        switch (status) {
            case 0x9:
                if (data2 == 0) { noteOff(data1); } else { noteOn(data1, data2); }
                break;
            case 0x8:
                noteOff(data1);
                break;
            case 0xD:   // channel pressure — the wind controller's main axis
                mPressure = float(data1) / 127.0f;
                break;
            case 0xE:   // pitch bend, 14-bit, low septet first
                mBend = (float(data1 | (uint16_t(data2) << 7)) - 8192.0f) / 8192.0f;
                break;
            case 0xB:
                handleControlChange(data1, data2);
                break;
            default:
                break;
        }
    }

    void handleControlChange(uint8_t controller, uint8_t value) {
        const float normalized = float(value) / 127.0f;
        switch (controller) {
            case 2:  mBreathCC = normalized; break;       // breath
            case 11: mExpressionCC = normalized; break;   // expression
            case 74: mTimbreCC = normalized; break;       // MPE timbre
            case 120: case 123:                            // all sound / notes off
                mHeldCount = 0;
                mEnvelope.noteOff();
                break;
            default: break;
        }
    }

    // MARK: - Notes
    //
    // A held-note stack rather than a single note, so releasing the upper note
    // of a trill returns to the lower one instead of stopping the phrase. Mono
    // synths that skip this are the ones that go silent halfway through a run.

    void noteOn(uint8_t note, uint8_t velocity) {
        const bool legato = mHeldCount > 0;
        if (mHeldCount < kMaxHeld) { mHeld[mHeldCount++] = note; }
        mVelocity = float(velocity) / 127.0f;
        mTargetHz = frequencyOf(note);
        if (!legato) {
            // From silence: start where we are going, so the first note does not
            // glide up from wherever the last phrase ended.
            mCurrentHz = mTargetHz;
            mFilter.reset();
        }
        mEnvelope.noteOn(mVelocity, legato);
        mShared.sounding.store(true, std::memory_order_relaxed);
    }

    void noteOff(uint8_t note) {
        int found = -1;
        for (int index = 0; index < mHeldCount; ++index) {
            if (mHeld[index] == note) { found = index; break; }
        }
        if (found < 0) { return; }
        for (int index = found; index + 1 < mHeldCount; ++index) {
            mHeld[index] = mHeld[index + 1];
        }
        mHeldCount -= 1;
        if (mHeldCount > 0) {
            // Back to whatever is still down — the trill case.
            mTargetHz = frequencyOf(mHeld[mHeldCount - 1]);
        } else {
            mEnvelope.noteOff();
        }
    }

    // MARK: - Render

    /// One segment of a block. `buffers` is the host's output list.
    void process(AudioBufferList *buffers, AUAudioFrameCount startFrame,
                 AUAudioFrameCount frameCount) {
        if (buffers == nullptr || frameCount == 0) { return; }

        if (mShared.panicRequested.exchange(false, std::memory_order_acq_rel)) {
            // Everything a note leaves behind: the stack, the envelope, the
            // gain. Not the parameters — panic is "stop", not "forget".
            mHeldCount = 0;
            mEnvelope.reset();
            mGain = 0.0f;
            mBreathSmoothed = 0.0f;
        }

        if (mBypassed) { writeSilence(buffers, startFrame, frameCount); return; }

        // Block-rate: the envelope, the resonance coefficient, and the targets
        // everything else ramps toward. Per-sample: the pitch, the breath, the
        // gain and the cutoff — the four that are audible if they step.
        const float gate = mEnvelope.advance(int(frameCount), mEnvelopeParams);
        const float gesture = std::clamp(std::max({
            mBreathCC,
            mExpressionCC,
            mPressure,
            mVelocityMix * std::sqrt(mVelocity)
        }), 0.0f, 1.0f);
        const float breathTarget = gesture * gate;

        mFilter.setResonance(mResonance);

        // Bend is smoothed over 2 ms rather than applied instantly. MIDI 1.0
        // bend arrives as a stream of 14-bit words and a controller sweeping
        // fast sends coarse steps; without this they are audible as a zipper on
        // the one gesture a wind player uses most. Short enough that it is not
        // a glide — a glide is `mGlideMs`, and conflating the two would make
        // portamento un-turn-off-able.
        const float bendCoefficient = onePoleCoefficient(2.0f);
        const float glideCoefficient = onePoleCoefficient(mGlideMs);
        // 6 ms on breath. Vane's waveguide does this internally; this MVP has no
        // waveguide, and without it the block boundaries are audible as a buzz
        // at the block rate rather than as a smooth swell.
        const float breathCoefficient = onePoleCoefficient(6.0f);
        const float gainCoefficient = onePoleCoefficient(3.0f);

        const VaneWavetable &table = VaneWavetable::shared();

        for (AUAudioFrameCount frame = 0; frame < frameCount; ++frame) {
            mCurrentHz += (mTargetHz - mCurrentHz) * double(glideCoefficient);
            mBreathSmoothed += (breathTarget - mBreathSmoothed) * breathCoefficient;
            mBendSmoothed += (mBend - mBendSmoothed) * bendCoefficient;

            const double bendRatio = std::pow(2.0, double(mBendSmoothed * mBendRange) / 12.0);
            const double soundingHz = std::clamp(mCurrentHz * bendRatio, 8.0, mSampleRate * 0.5);
            // The mip level follows the sounding pitch, so a two-octave bend
            // sheds harmonics on the way up rather than aliasing them back down.
            const int level = VaneWavetable::mipLevelFor(soundingHz, mSampleRate);

            float sample = table.readMorph(mMorph, level, mPhase);

            mPhase += float(soundingHz / mSampleRate);
            if (mPhase >= 1.0f) { mPhase -= std::floor(mPhase); }

            const float openOctaves = mBreathToCutoff * mBreathSmoothed
                                    + mTimbreToCutoff * mTimbreCC;
            mFilter.setCutoff(mCutoffHz * std::pow(2.0f, openOctaves));
            sample = mFilter.processLowPass(sample);

            const float gainTarget = mBreathSmoothed * mLevel;
            mGain += (gainTarget - mGain) * gainCoefficient;
            sample *= mGain;

            writeSample(buffers, startFrame + frame, sample);
        }

        mShared.breath.store(mBreathSmoothed, std::memory_order_relaxed);
        mShared.sounding.store(mHeldCount > 0 || mEnvelope.isActive() || mGain > 1e-4f,
                               std::memory_order_relaxed);
    }

private:
    static constexpr int kMaxHeld = 16;

    static double frequencyOf(uint8_t note) {
        return 440.0 * std::pow(2.0, (double(note) - 69.0) / 12.0);
    }

    /// A one-pole coefficient for a given time constant, clamped so that 0 ms is
    /// "immediately" rather than a division by zero.
    float onePoleCoefficient(float milliseconds) const {
        if (milliseconds <= 0.01f) { return 1.0f; }
        const double samples = mSampleRate * double(milliseconds) / 1000.0;
        return float(1.0 - std::exp(-1.0 / std::max(1.0, samples)));
    }

    void writeSample(AudioBufferList *buffers, AUAudioFrameCount frame, float value) {
        for (UInt32 channel = 0; channel < buffers->mNumberBuffers; ++channel) {
            float *out = (float *)buffers->mBuffers[channel].mData;
            if (out != nullptr) { out[frame] = value; }
        }
    }

    void writeSilence(AudioBufferList *buffers, AUAudioFrameCount startFrame,
                      AUAudioFrameCount frameCount) {
        for (UInt32 channel = 0; channel < buffers->mNumberBuffers; ++channel) {
            float *out = (float *)buffers->mBuffers[channel].mData;
            if (out == nullptr) { continue; }
            for (AUAudioFrameCount frame = 0; frame < frameCount; ++frame) {
                out[startFrame + frame] = 0.0f;
            }
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

    /// Atomics live in a struct with explicit copy semantics, for the reason the
    /// MIDI kernel's header spells out at length: a bare `std::atomic` member
    /// makes the enclosing type un-importable by Swift, and the error you get is
    /// that the type does not exist.
    struct SharedFields {
        std::atomic<float> breath{0.0f};
        std::atomic<bool> sounding{false};
        std::atomic<bool> panicRequested{false};

        SharedFields() {}
        SharedFields(const SharedFields &other)
        : breath{other.breath.load(std::memory_order_relaxed)},
          sounding{other.sounding.load(std::memory_order_relaxed)},
          panicRequested{other.panicRequested.load(std::memory_order_relaxed)} {}
        SharedFields &operator=(const SharedFields &other) {
            breath.store(other.breath.load(std::memory_order_relaxed), std::memory_order_relaxed);
            sounding.store(other.sounding.load(std::memory_order_relaxed), std::memory_order_relaxed);
            panicRequested.store(other.panicRequested.load(std::memory_order_relaxed), std::memory_order_relaxed);
            return *this;
        }
    };
    SharedFields mShared;

    double mSampleRate = 48000.0;
    int mChannelCount = 2;
    AUAudioFrameCount mMaxFrames = 1024;
    bool mBypassed = false;

    // Parameters. Plain members rather than atomics, matching the MIDI kernel:
    // a host's parameter changes arrive as render events on this thread, and the
    // initial set happens before rendering starts. An aligned 4-byte float does
    // not tear on the platforms this ships to.
    float mMorph = 0.35f;
    float mLevel = 0.8f;
    float mCutoffHz = 900.0f;
    float mResonance = 0.15f;
    float mBreathToCutoff = 3.0f;
    float mVelocityMix = 0.35f;
    float mGlideMs = 45.0f;
    float mTimbreToCutoff = 1.5f;
    float mBendRange = 48.0f;

    VaneBreathEnvelope::Params mEnvelopeParams;
    VaneBreathEnvelope mEnvelope;
    VaneSVFilter mFilter;

    // Gesture, as received.
    float mBreathCC = 0.0f;
    float mExpressionCC = 0.0f;
    float mPressure = 0.0f;
    float mTimbreCC = 0.5f;
    float mBend = 0.0f;
    float mBendSmoothed = 0.0f;
    float mVelocity = 0.0f;

    // Voice.
    uint8_t mHeld[kMaxHeld] = {};
    int mHeldCount = 0;
    float mPhase = 0.0f;
    double mCurrentHz = 0.0;
    double mTargetHz = 0.0;
    float mGain = 0.0f;
    float mBreathSmoothed = 0.0f;
};
