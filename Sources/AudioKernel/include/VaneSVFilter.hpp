//
//  VaneSVFilter.hpp
//  AudioKernel
//
//  Cytomic TPT state-variable filter, ported from Vane's `Source/Synth/SVFilter.h`
//  with JUCE removed. Two things in it are load-bearing and both are the kind of
//  detail that is invisible until it is wrong.
//
//  **Coefficient ordering.** `setResonance` computes `k`, then `a1` from the OLD
//  `g`; `setCutoff` computes `g`, then `a1`/`a2`/`a3` from the fresh `k`. So
//  resonance goes first, cutoff second. Reverse them — or call only
//  `setCutoff` — and `a1` is stale, which sounds like a filter that is nearly
//  right and gets wronger as resonance rises.
//
//  **Why TPT rather than the Zavalishin form.** It stays stable as resonance
//  approaches self-oscillation, and `g` and `k` are independent, so `setCutoff`
//  can run every sample without recomputing `k`. That is what makes a
//  breath-driven sweep tight instead of zippered, and a breath-driven sweep is
//  the whole point of this instrument.
//
//  Reference: Andy Simper, "Solving the continuous SVF equations using
//  trapezoidal integration and equivalent currents" (Cytomic, 2013).
//
//  Not ported: notch and allpass outputs (available as `x - k*v1` and
//  `x - 2*k*v1`, simply not exposed), and soft saturation on the feedback path —
//  so resonance at 1.0 is a clean sine rather than the harmonically rich
//  self-oscillation a real analogue filter gives. Both are in Vane's file as
//  future work and both are still future work.
//

#pragma once

#include <algorithm>
#include <cmath>

class VaneSVFilter {
public:
    void prepare(double sampleRate) {
        mSampleRate = float(sampleRate > 0 ? sampleRate : 48000.0);
        reset();
    }

    void reset() { mS1 = mS2 = 0.0f; }

    /// Update only resonance. Once per block.
    void setResonance(float resonance) {
        const float q = 0.5f + std::clamp(resonance, 0.0f, 1.0f) * 7.5f;
        mK = 1.0f / q;
        mA1 = 1.0f / (1.0f + mG * (mG + mK));
        mA2 = mG * mA1;
        mA3 = mG * mA2;
    }

    /// Update only cutoff. Safe to call per sample — that is the point.
    ///
    /// Clamped at `sr * 0.499` rather than exactly Nyquist: `tan(pi/2)` is
    /// infinite, and a small guard makes coefficient blow-up impossible even
    /// under floating-point rounding.
    void setCutoff(float cutoffHz) {
        cutoffHz = std::clamp(cutoffHz, 20.0f, mSampleRate * 0.499f);
        mG = std::tan(float(M_PI) * cutoffHz / mSampleRate);
        mA1 = 1.0f / (1.0f + mG * (mG + mK));
        mA2 = mG * mA1;
        mA3 = mG * mA2;
    }

    /// Low-pass. The only mode this MVP uses; band- and high-pass are two lines
    /// away and are not offered because nothing here would drive the choice.
    float processLowPass(float x) {
        const float v3 = x - mS2;
        const float v1 = mA1 * mS1 + mA2 * v3;
        const float v2 = mS2 + mA2 * mS1 + mA3 * v3;
        mS1 = 2.0f * v1 - mS1;
        mS2 = 2.0f * v2 - mS2;
        return v2;
    }

private:
    float mSampleRate = 44100.0f;
    float mG = 1.0f;    // tan(pi * cutoff / sr)
    float mK = 1.0f;    // 1/Q
    float mA1 = 1.0f;
    float mA2 = 0.0f;
    float mA3 = 0.0f;
    float mS1 = 0.0f;
    float mS2 = 0.0f;
};
