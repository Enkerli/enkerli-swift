//
//  VaneWavetable.hpp
//  AudioKernel
//
//  A band-limited multi-frame wavetable, and the reason a synth needs one.
//
//  Ported from Vane's `Source/Synth/Wavetable.h`, minus JUCE and minus the file
//  importer. What survives is the part that makes it a musical instrument rather
//  than a buzz: **every frame is stored at eleven mip levels, where level k
//  contains at most 2^k harmonics.** The oscillator picks the level whose top
//  harmonic still fits under Nyquist at the pitch being played.
//
//  Without that, a sawtooth played two octaves up folds every harmonic above
//  Nyquist back down into the audible band as inharmonic noise that follows the
//  pitch *downward* as you play *upward*. It is the single most audible
//  difference between a naive wavetable and a usable one, and it is not
//  something a filter can fix afterwards — the aliases are already inside the
//  band the filter is trying to keep.
//
//  This MVP builds one table: the harmonic stack. Frame k is the first (k+1)
//  harmonics of a sawtooth at 1/h, so the morph sweeps sine → fuller saw, which
//  is a genuinely simplest-to-most-complex axis and the right default before any
//  file is imported. Vane builds the same table with `makeHarmonicStack`.
//
//  Because the spectrum is known analytically, the frames are built additively
//  rather than by the O(N²) DFT Vane's importer needs. That is exact rather than
//  approximate, and it is why this file is 120 lines instead of 260.
//
//  Cost: 16 frames × 11 levels × 2049 floats ≈ 1.4 MB, built once and shared by
//  every instance. It is a function-local static, so C++ guarantees the build
//  happens once and is thread-safe — but it is still *called* from `initialize`,
//  off the render thread, because the first call is the one that allocates.
//

#pragma once

#include <array>
#include <cmath>
#include <vector>

class VaneWavetable {
public:
    static constexpr int kTableSize = 2048;
    /// Level k holds at most 2^k harmonics, so level 0 is a sine and level 10 is
    /// 1024 — the Nyquist cap for a 2048-point table.
    static constexpr int kNumMipLevels = 11;
    static constexpr int kNumFrames = 16;

    /// The shared harmonic stack. Built on first call; never on the audio thread.
    static const VaneWavetable &shared() {
        static const VaneWavetable table = makeHarmonicStack();
        return table;
    }

    /// The highest mip level whose top harmonic still fits under Nyquist.
    ///
    /// At high pitches this converges to 0 — one harmonic, a pure sine — which
    /// is correct and is what a real band-limited oscillator does: there is
    /// simply no room for a second harmonic below Nyquist up there.
    static int mipLevelFor(double hz, double sampleRate) {
        if (hz <= 0.0 || sampleRate <= 0.0) { return kNumMipLevels - 1; }
        const double allowed = (sampleRate * 0.5) / hz;   // harmonics that fit
        if (allowed <= 1.0) { return 0; }
        int level = 0;
        while (level + 1 < kNumMipLevels && (1 << (level + 1)) <= allowed) { ++level; }
        return level;
    }

    /// Linear-interpolated read. `phase` is 0..1; the guard point makes the
    /// wrap-around interpolation safe without a branch.
    float read(int frame, int level, float phase) const {
        const float *table = mFrames[frame][level].data();
        float index = phase * float(kTableSize);
        int whole = int(index);
        if (whole >= kTableSize) { whole = kTableSize - 1; }
        const float fraction = index - float(whole);
        return table[whole] + fraction * (table[whole + 1] - table[whole]);
    }

    /// The morph read: two adjacent frames at one level, crossfaded.
    ///
    /// Both frames are read at the *same* mip level rather than each at its own,
    /// so a morph sweep cannot change its own bandwidth halfway across. A sweep
    /// that got brighter because the level changed under it would be a control
    /// doing two things.
    float readMorph(float morph, int level, float phase) const {
        const float position = morph * float(kNumFrames - 1);
        int low = int(position);
        if (low < 0) { low = 0; }
        if (low > kNumFrames - 2) { low = kNumFrames - 2; }
        const float mix = position - float(low);
        const float a = read(low, level, phase);
        const float b = read(low + 1, level, phase);
        return a + mix * (b - a);
    }

private:
    using Level = std::array<float, kTableSize + 1>;   // +1 guard point
    using Frame = std::array<Level, kNumMipLevels>;
    std::array<Frame, kNumFrames> mFrames{};

    static VaneWavetable makeHarmonicStack() {
        VaneWavetable table;
        for (int frame = 0; frame < kNumFrames; ++frame) {
            const int available = frame + 1;            // harmonics in this frame
            for (int level = 0; level < kNumMipLevels; ++level) {
                const int capped = std::min(available, 1 << level);
                Level &samples = table.mFrames[frame][level];
                float peak = 0.0f;
                for (int n = 0; n < kTableSize; ++n) {
                    const double phase = 2.0 * M_PI * double(n) / double(kTableSize);
                    double sum = 0.0;
                    for (int harmonic = 1; harmonic <= capped; ++harmonic) {
                        sum += std::sin(phase * harmonic) / double(harmonic);
                    }
                    samples[n] = float(sum);
                    peak = std::max(peak, std::fabs(samples[n]));
                }
                // Normalised per (frame, level) so the morph does not also
                // change loudness, and so a level switch mid-note does not step
                // the amplitude. Both would be heard as the control misbehaving.
                const float scale = peak > 0.0f ? 1.0f / peak : 1.0f;
                for (int n = 0; n < kTableSize; ++n) { samples[n] *= scale; }
                samples[kTableSize] = samples[0];
            }
        }
        return table;
    }
};
