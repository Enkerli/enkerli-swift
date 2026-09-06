//
//  VaneBreathEnvelope.hpp
//  AudioKernel
//
//  Synthetic breath — an envelope that stands in for a wind controller.
//
//  Ported from Vane's `Source/Synth/BreathEnvelope.h`, whose reasoning is the
//  reason this plug-in exists at all and is reproduced rather than summarised.
//
//  WHY IT EXISTS. The amplitude source is
//  `max(breath CC, expression, channel pressure, velocityMix * sqrt(velocity),
//  this)`. A sequencer sends none of the first three. With `velocityMix` at its
//  default of 0 the instrument is **silent** — measured in Vane, not inferred:
//  peak 0.00000 against 0.99997 with breath at 0.7. A DAW piano roll, most
//  keyboards, and this suite's own MelGen and Serpe all land in that hole.
//
//  NOT A GENERIC ADSR, and the differences are the point:
//
//   · **Attack is slow by default (35 ms).** A reed does not snap; the speaking
//     threshold takes real time to cross, and an instant attack is what makes
//     synthetic wind sound synthetic.
//   · **Velocity scales the peak and shortens the attack.** Blowing harder both
//     gets louder and speaks sooner — one control, two consequences, which is
//     what a player actually does.
//   · **Legato does not retrigger.** Several notes inside one breath. A legato
//     note re-aims the target and leaves the current level alone, so the phrase
//     keeps its shape instead of re-articulating on every pitch. Re-attacking
//     there is exactly what makes a slurred line sound typed instead of played.
//
//  `levelFor` stays a pure function of a phase and the segment times, because
//  the shape eventually wants to be a recorded DrawnQurve "qurve" rather than
//  four numbers — and SwiftDrawnQurve, on this same foundation, already records
//  one.
//
//  Block-rate is fine here as it is in Vane, but for a different reason: Vane's
//  waveguide smooths breath internally over ~20 ms and this MVP has no
//  waveguide, so the kernel one-poles the result per sample instead. Without
//  that the block boundaries are audible as a buzz at the block rate.
//

#pragma once

#include <algorithm>
#include <cmath>

class VaneBreathEnvelope {
public:
    struct Params {
        float attackMs = 35.0f;    ///< reed speaking time at full velocity
        float decayMs = 120.0f;    ///< settle from the initial push to sustain
        float sustain = 0.80f;     ///< body of the note, as a fraction of peak
        float releaseMs = 180.0f;  ///< breath dying after the note ends
        /// How much velocity shortens the attack. 1 = a fff note speaks
        /// immediately, 0 = every note takes attackMs regardless.
        float velocityToAttack = 0.6f;
    };

    void prepare(double sampleRate) {
        mSampleRate = sampleRate > 0 ? sampleRate : 48000.0;
        reset();
    }

    void reset() {
        mStage = Stage::Idle;
        mLevel = 0.0f;
        mPeak = 0.0f;
        mPhase = 0.0f;
    }

    bool isActive() const { return mStage != Stage::Idle; }
    float current() const { return mLevel; }

    /// @param legato true when this note continues a phrase already sounding.
    ///
    /// Velocity does **not** set the peak here, which is a divergence from
    /// Vane's file and is explained at the top of `VaneDSPKernel.hpp`: in this
    /// MVP the envelope is the note's *gate* rather than a fifth amplitude
    /// source, so its peak is always 1 and velocity's loudness role lives in the
    /// gesture term. What velocity still does is shorten the attack — blowing
    /// harder speaks sooner — which is the half of "one control, two
    /// consequences" that belongs to the envelope.
    void noteOn(float velocity, bool legato) {
        mVelocity = std::clamp(velocity, 0.0f, 1.0f);
        mPeak = 1.0f;
        if (legato && (mStage != Stage::Idle || mLevel > 0.0f)) {
            // Mid-phrase: no new attack. Straight to sustain at whatever level
            // we are already at, so a louder note swells rather than restarting.
            mStage = Stage::Sustain;
            return;
        }
        mStage = Stage::Attack;
        mPhase = 0.0f;
    }

    void noteOff() {
        if (mStage == Stage::Idle) { return; }
        mReleaseFrom = mLevel;
        mStage = Stage::Release;
        mPhase = 0.0f;
    }

    /// Advance by `samples` and return the new level. Once per block.
    float advance(int samples, const Params &params) {
        if (mStage == Stage::Idle) { return 0.0f; }
        const float dt = float(double(samples) / mSampleRate) * 1000.0f;   // ms

        switch (mStage) {
            case Stage::Attack: {
                const float ms = attackMsFor(params);
                mPhase += dt;
                if (mPhase >= ms) {
                    mStage = Stage::Decay;
                    mPhase = 0.0f;
                    mLevel = mPeak;
                } else {
                    mLevel = mPeak * (ms > 0.0f ? mPhase / ms : 1.0f);
                }
                break;
            }
            case Stage::Decay: {
                const float ms = std::max(1.0f, params.decayMs);
                mPhase += dt;
                const float target = mPeak * std::clamp(params.sustain, 0.0f, 1.0f);
                if (mPhase >= ms) {
                    mStage = Stage::Sustain;
                    mLevel = target;
                } else {
                    mLevel = mPeak + (target - mPeak) * (mPhase / ms);
                }
                break;
            }
            case Stage::Sustain:
                // Tracks the peak, so a legato note that re-aimed louder
                // actually arrives there instead of sitting at the old level.
                mLevel += (mPeak * std::clamp(params.sustain, 0.0f, 1.0f) - mLevel) * 0.05f;
                break;
            case Stage::Release: {
                const float ms = std::max(1.0f, params.releaseMs);
                mPhase += dt;
                if (mPhase >= ms) { reset(); }
                else { mLevel = mReleaseFrom * (1.0f - mPhase / ms); }
                break;
            }
            case Stage::Idle:
                break;
        }
        mLevel = std::clamp(mLevel, 0.0f, 1.0f);
        return mLevel;
    }

private:
    enum class Stage { Idle, Attack, Decay, Sustain, Release };

    float attackMsFor(const Params &params) const {
        const float shorten = std::clamp(params.velocityToAttack, 0.0f, 1.0f) * mVelocity;
        return std::max(1.0f, params.attackMs * (1.0f - shorten));
    }

    double mSampleRate = 48000.0;
    Stage mStage = Stage::Idle;
    float mLevel = 0.0f;
    float mPeak = 0.0f;
    float mVelocity = 0.0f;
    float mPhase = 0.0f;
    float mReleaseFrom = 0.0f;
};
