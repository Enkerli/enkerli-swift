//
//  vane-main.mm
//  AudioKernel
//
//  The synth's render path, driven directly, outside any host.
//
//  This is the first harness in the package that looks at *samples*, and the
//  failures it is hunting are a different species from the MIDI ones. A stuck
//  note is loud and obvious. The bugs here are:
//
//   · **Aliasing** — inharmonic tones that move down as you play up. Present in
//     every naive wavetable synth, inaudible in a unit test that only checks
//     "something came out", and impossible to filter away afterwards.
//   · **Clicks** — a discontinuity at a note boundary, a parameter step, or a
//     mip-level change. Each is a single sample wrong out of forty-eight
//     thousand, which no peak or RMS check will ever notice.
//   · **Silence** — the failure Vane measured and documented: with no breath
//     source and `velocityMix` at 0, the instrument produces nothing at all,
//     and every sequencer in this suite lands in that hole.
//
//  So the checks here are mostly about *continuity* and *bandwidth*, not about
//  amplitude. `maxStep` is the workhorse: the largest jump between consecutive
//  samples. A click is exactly that and nothing else.
//
//  Compiled and run by Scripts/check-kernel.sh alongside the MIDI harnesses.
//

#import <Foundation/Foundation.h>
#import "../../Sources/AudioKernel/include/VaneDSPKernel.hpp"
#import "../../Sources/AudioKernel/include/VaneAUProcessHelper.hpp"

#import <string>
#import <vector>

// ── A buffer to render into ────────────────────────────────────────────────

static constexpr int kChannels = 2;
static constexpr double kSampleRate = 48000.0;

struct Output {
    std::vector<float> left, right;
    AudioBufferList *list() {
        mBuffers.mNumberBuffers = kChannels;
        mBuffers.mBuffers[0].mNumberChannels = 1;
        mBuffers.mBuffers[0].mDataByteSize = UInt32(left.size() * sizeof(float));
        mBuffers.mBuffers[0].mData = left.data();
        mBuffers.mBuffers[1].mNumberChannels = 1;
        mBuffers.mBuffers[1].mDataByteSize = UInt32(right.size() * sizeof(float));
        mBuffers.mBuffers[1].mData = right.data();
        return (AudioBufferList *)&mBuffers;
    }
    struct { UInt32 mNumberBuffers; AudioBuffer mBuffers[kChannels]; } mBuffers;
};

static Output makeOutput(int frames) {
    Output out;
    out.left.assign(size_t(frames), 0.0f);
    out.right.assign(size_t(frames), 0.0f);
    return out;
}

// ── Measuring ──────────────────────────────────────────────────────────────

static float peakOf(const std::vector<float> &samples) {
    float peak = 0.0f;
    for (float sample : samples) { peak = std::max(peak, std::fabs(sample)); }
    return peak;
}

/// The largest jump between consecutive samples. A click is this and nothing
/// else — an amplitude check cannot see one and an RMS check averages it away.
///
/// **Only meaningful on a smooth waveform.** A band-limited sawtooth steps by
/// nearly its whole amplitude between two samples near the edge of the ramp, by
/// construction: its top harmonic is close to Nyquist, so it moves half a cycle
/// per sample. Measuring this on a saw measures the saw. Every continuity check
/// below therefore sets `vaneMorph` to 0, where the table is a single sine and a
/// click has nothing to hide behind. Four of these checks failed on the first
/// run for exactly that reason and none of them was a real fault.
static float maxStep(const std::vector<float> &samples) {
    float worst = 0.0f;
    for (size_t index = 1; index < samples.size(); ++index) {
        worst = std::max(worst, std::fabs(samples[index] - samples[index - 1]));
    }
    return worst;
}

/// How many times the signal crosses zero — a cheap, library-free stand-in for
/// "how high is the top harmonic". A band-limited waveform at a given pitch has
/// a bounded crossing rate; an aliasing one does not.
///
/// Good for aliasing, useless for brightness: a signal with a strong
/// fundamental crosses zero twice per cycle whatever its harmonics are doing,
/// which is why the filter check below uses `brightness` instead. Reaching for
/// this one there gave 56 crossings against 56 and looked like a filter that
/// did nothing.
static int zeroCrossings(const std::vector<float> &samples) {
    int count = 0;
    for (size_t index = 1; index < samples.size(); ++index) {
        if ((samples[index - 1] <= 0.0f) != (samples[index] <= 0.0f)) { count += 1; }
    }
    return count;
}

/// How much rougher the signal is than a clean sine of the same pitch and level.
///
/// A sine at `hz` moves at most `2*pi*hz/sr * peak` between samples, and that is
/// a *physical* floor, not a tolerance — a C4 sine at 0.61 steps by 0.021 with
/// nothing wrong at all. An absolute threshold below that number fails every
/// correct signal, which is what the first version of these checks did.
///
/// So the measure is a ratio: 1.0 is a clean sine, and a click is many times
/// that. The checks allow 3, which is loose enough for the peak of a smoothed
/// ramp and an order of magnitude tighter than any real discontinuity.
static float roughness(const std::vector<float> &samples, double hz) {
    const float peak = peakOf(samples);
    if (peak <= 0.0f || hz <= 0.0) { return 0.0f; }
    const float expected = float(2.0 * M_PI * hz / kSampleRate) * peak;
    return maxStep(samples) / expected;
}

/// Plain RMS of a range.
static float rmsOf(const std::vector<float> &samples, size_t from, size_t count) {
    if (from + count > samples.size()) { return 0.0f; }
    double energy = 0.0;
    for (size_t index = from; index < from + count; ++index) {
        energy += double(samples[index]) * double(samples[index]);
    }
    return float(std::sqrt(energy / double(count)));
}

/// The quietest short window in a signal, as a fraction of the loudest.
///
/// A retriggered envelope is a *dip*, not a change in peak: the level falls to
/// zero and climbs back over the attack. Comparing peaks before and after a
/// slur cannot see that — it was the first version of the legato check, and it
/// passed happily against an envelope deliberately made to retrigger. Only
/// looking inside the transition finds it.
static float quietestWindow(const std::vector<float> &samples, size_t window = 128) {
    if (samples.size() < window * 2) { return 0.0f; }
    float loudest = 0.0f, quietest = 1e9f;
    for (size_t start = 0; start + window <= samples.size(); start += window / 2) {
        double energy = 0.0;
        for (size_t index = start; index < start + window; ++index) {
            energy += double(samples[index]) * double(samples[index]);
        }
        const float rms = float(std::sqrt(energy / double(window)));
        loudest = std::max(loudest, rms);
        quietest = std::min(quietest, rms);
    }
    return loudest > 0.0f ? quietest / loudest : 0.0f;
}

/// RMS of the first difference over RMS of the signal — a spectral centroid in
/// two lines and no library.
///
/// For a signal whose harmonics have amplitudes a_h, this is
/// `omega * sqrt(sum(h^2 a_h^2) / sum(a_h^2))`, so it weights high harmonics by
/// the square of their number. A sine gives `omega`; the sixteen-harmonic frame
/// of this table gives 3.2x that, which is what the arithmetic predicts and what
/// it measures.
///
/// The first version of this was mean-|difference| over peak, and it was nearly
/// useless: it separated a sine from a full saw by 1.14x, because a saw's slope
/// energy is concentrated at its edge and the peak it is divided by grows with
/// it. That reading made a working filter look like a control that did nothing —
/// the metric was wrong, not the kernel, and it took a direct measurement of the
/// filter's response to tell those apart.
static float brightness(const std::vector<float> &samples) {
    if (samples.size() < 2) { return 0.0f; }
    double slope = 0.0, energy = 0.0;
    for (size_t index = 1; index < samples.size(); ++index) {
        const double difference = double(samples[index]) - double(samples[index - 1]);
        slope += difference * difference;
        energy += double(samples[index]) * double(samples[index]);
    }
    return energy > 0.0 ? float(std::sqrt(slope / energy)) : 0.0f;
}

// ── Feeding it ─────────────────────────────────────────────────────────────

static uint32_t noteWord(uint8_t status, uint8_t channel, uint8_t data1, uint8_t data2) {
    return ((uint32_t)0x2 << 28) | ((uint32_t)(status & 0xF) << 20)
         | ((uint32_t)(channel & 0xF) << 16)
         | ((uint32_t)(data1 & 0x7F) << 8) | (uint32_t)(data2 & 0x7F);
}

static void feed(VaneDSPKernel &kernel, uint32_t word) {
    MIDIEventList list = {};
    MIDIEventPacket *packet = MIDIEventListInit(&list, kMIDIProtocol_2_0);
    packet = MIDIEventListAdd(&list, sizeof(MIDIEventList), packet, 0, 1, &word);
    // AURenderEvent is a union — the event type goes inside the payload. The
    // MIDI harnesses learned that the hard way; this one inherited the fix.
    AUMIDIEventList wrapper = {};
    wrapper.eventType = AURenderEventMIDIEventList;
    wrapper.eventList = list;
    AURenderEvent event = {};
    event.MIDIEventsList = wrapper;
    kernel.handleOneEvent(0, &event);
}

static void render(VaneDSPKernel &kernel, Output &out, int frames) {
    kernel.process(out.list(), 0, AUAudioFrameCount(frames));
}

/// Renders `blocks` blocks and returns the whole thing as one signal, so a
/// discontinuity *at a block boundary* is visible. Most render bugs live
/// exactly there and a single-block test cannot see them.
static std::vector<float> renderContinuous(VaneDSPKernel &kernel, int blocks, int blockSize) {
    std::vector<float> all;
    for (int block = 0; block < blocks; ++block) {
        Output out = makeOutput(blockSize);
        render(kernel, out, blockSize);
        all.insert(all.end(), out.left.begin(), out.left.end());
    }
    return all;
}

// ── Saying what happened ───────────────────────────────────────────────────

static int gFailures = 0;

static void check(const std::string &what, bool passed, const std::string &detail = "") {
    printf("  %s  %s%s\n", passed ? "PASS" : "FAIL", what.c_str(),
           detail.empty() ? "" : (" — " + detail).c_str());
    if (!passed) { gFailures += 1; }
}

static std::string number(double value, int places = 4) {
    char buffer[32];
    snprintf(buffer, sizeof(buffer), "%.*f", places, value);
    return buffer;
}

static VaneDSPKernel makeKernel() {
    VaneDSPKernel kernel;
    kernel.initialize(kSampleRate, kChannels);
    return kernel;
}

int main() {
    printf("── vane: a breath-first voice ─────────────────────\n");

    // ── silence, and the silence bug ───────────────────────────────────────
    {
        VaneDSPKernel kernel = makeKernel();
        Output out = makeOutput(512);
        render(kernel, out, 512);
        check("an untouched instrument is silent", peakOf(out.left) == 0.0f,
              number(peakOf(out.left)));
        check("in both channels", peakOf(out.right) == 0.0f);
    }
    {
        // Vane measured this: with velocityMix at 0 and no breath, no
        // expression and no pressure, the instrument is SILENT. Every sequencer
        // in this suite sends exactly that. The default here is 0.35 for that
        // reason, and this is the check that keeps it non-zero.
        VaneDSPKernel kernel = makeKernel();
        feed(kernel, noteWord(0x9, 0, 60, 100));
        std::vector<float> sound = renderContinuous(kernel, 20, 256);
        check("a plain note-on with no breath still sounds", peakOf(sound) > 0.01f,
              "peak " + number(peakOf(sound)));

        VaneDSPKernel mute = makeKernel();
        mute.setParameter(vaneVelocityMix, 0.0f);
        feed(mute, noteWord(0x9, 0, 60, 100));
        std::vector<float> nothing = renderContinuous(mute, 20, 256);
        check("and turning velocityMix to zero is what silences it — the bug Vane measured",
              peakOf(nothing) < 1e-6f, "peak " + number(peakOf(nothing), 8));
        // The first version of this kernel put the envelope in the max as a
        // fifth source, the way Vane's formula reads. It made this check
        // impossible to fail — and, worse, it meant an envelope sitting at 0.7
        // stopped a wind player's breath from ever going below 0.7. Vane's
        // synthetic breath is opt-in and off by default for that reason; here
        // the envelope is the gate instead.
    }

    // ── breath is the amplitude ────────────────────────────────────────────
    {
        VaneDSPKernel kernel = makeKernel();
        kernel.setParameter(vaneVelocityMix, 0.0f);   // breath only
        feed(kernel, noteWord(0x9, 0, 60, 1));        // minimum velocity
        feed(kernel, noteWord(0xB, 0, 2, 127));       // CC2 breath, full
        std::vector<float> loud = renderContinuous(kernel, 30, 256);

        VaneDSPKernel quiet = makeKernel();
        quiet.setParameter(vaneVelocityMix, 0.0f);
        feed(quiet, noteWord(0x9, 0, 60, 127));       // maximum velocity
        feed(quiet, noteWord(0xB, 0, 2, 20));         // barely blowing
        std::vector<float> soft = renderContinuous(quiet, 30, 256);

        check("blowing harder is louder than playing harder",
              peakOf(loud) > peakOf(soft) * 2.0f,
              "breath " + number(peakOf(loud)) + " vs velocity " + number(peakOf(soft)));
    }
    {
        // All four gesture sources are one gesture spelled four ways, so the
        // amplitude is their max. Any of them alone must be enough.
        const uint8_t sources[3] = { 2, 11, 74 };
        (void)sources;
        for (int which = 0; which < 3; ++which) {
            VaneDSPKernel kernel = makeKernel();
            kernel.setParameter(vaneVelocityMix, 0.0f);
            feed(kernel, noteWord(0x9, 0, 60, 1));
            const char *name = "";
            if (which == 0) { feed(kernel, noteWord(0xB, 0, 2, 110)); name = "breath CC2"; }
            if (which == 1) { feed(kernel, noteWord(0xB, 0, 11, 110)); name = "expression CC11"; }
            if (which == 2) { feed(kernel, noteWord(0xD, 0, 110, 0)); name = "channel pressure"; }
            std::vector<float> sound = renderContinuous(kernel, 30, 256);
            check(std::string("a voice speaks from ") + name, peakOf(sound) > 0.05f,
                  "peak " + number(peakOf(sound)));
        }
    }

    // ── continuity: the clicks ─────────────────────────────────────────────
    //
    // A wind line is continuous, so any discontinuity in the chain is heard as
    // a fault in the instrument rather than as an articulation. The threshold
    // is generous — a real click is an order of magnitude past it.
    {
        VaneDSPKernel kernel = makeKernel();
        kernel.setParameter(vaneMorph, 0.0f);     // a sine — see maxStep's note
        feed(kernel, noteWord(0x9, 0, 60, 100));
        feed(kernel, noteWord(0xB, 0, 2, 100));
        std::vector<float> sound = renderContinuous(kernel, 40, 256);
        check("a sustained note is as smooth as the sine it is",
              roughness(sound, 261.6) < 3.0f,
              number(roughness(sound, 261.6), 2) + "x a clean sine, over 10240 "
              "samples and 40 blocks");
    }
    {
        // The legato case, which is the whole instrument. A second note while
        // the first is held must re-aim the pitch and leave the envelope, the
        // filter state and the oscillator phase alone.
        VaneDSPKernel kernel = makeKernel();
        kernel.setParameter(vaneMorph, 0.0f);
        // A long attack, so that a retrigger — if one ever creeps back in — is
        // unmistakable rather than marginal. At the 35 ms default the deliberate
        // divergence dips to 0.64 against a 0.70 bar, which is a 9% margin and
        // not a result worth trusting. At 200 ms it dips to a tenth.
        kernel.setParameter(vaneAttackMs, 200.0f);
        feed(kernel, noteWord(0x9, 0, 60, 100));
        feed(kernel, noteWord(0xB, 0, 2, 100));
        std::vector<float> before = renderContinuous(kernel, 40, 256);
        feed(kernel, noteWord(0x9, 0, 67, 100));        // slur up a fifth
        std::vector<float> after = renderContinuous(kernel, 20, 256);

        std::vector<float> across;
        across.insert(across.end(), before.end() - 512, before.end());
        across.insert(across.end(), after.begin(), after.begin() + 512);
        check("a legato note does not click", roughness(across, 392.0) < 3.0f,
              number(roughness(across, 392.0), 2) + "x a clean sine");
        // The level on either side of the slur, measured directly.
        //
        // Two weaker versions of this check passed against an envelope
        // deliberately broken to retrigger. Comparing peaks before and after
        // could not see the dip at all; the quietest-window measure saw it, but
        // at 0.58 against a 0.5 threshold — smeared by the gain smoother and by
        // its own averaging window, and far too close to call. Comparing the
        // 256 samples on each side of the transition is the same question asked
        // where the answer is: a retrigger drops the gate from sustain to zero
        // and climbs back over the attack, so it lands near 0.3.
        const float levelBefore = rmsOf(before, before.size() - 256, 256);
        // The TROUGH over the first four blocks, not the level at the boundary.
        // A retrigger's dip is deepest a block or two in — the breath and gain
        // smoothers lag it by design, so sampling only the first block after the
        // slur reads 0.86 where the trough is 0.45. That version of this check
        // passed against a deliberately retriggering envelope, which is the
        // third time this one control has been checked badly.
        float trough = 1e9f;
        for (size_t start = 0; start + 256 <= 1024; start += 128) {
            trough = std::min(trough, rmsOf(after, start, 256));
        }
        check("and does not restart the envelope — the phrase keeps its shape",
              trough > levelBefore * 0.7f,
              number(trough / std::max(levelBefore, 1e-9f), 2)
              + "x the level it was at, at the deepest point after the slur");
        VaneDSPKernel fresh = makeKernel();
        fresh.setParameter(vaneMorph, 0.0f);
        feed(fresh, noteWord(0xB, 0, 2, 100));
        std::vector<float> silence = renderContinuous(fresh, 10, 256);
        feed(fresh, noteWord(0x9, 0, 60, 100));
        std::vector<float> attack = renderContinuous(fresh, 10, 256);
        std::vector<float> onset;
        onset.insert(onset.end(), silence.end() - 512, silence.end());
        onset.insert(onset.end(), attack.begin(), attack.begin() + 512);
        check("while a note after silence does attack from nothing, so the "
              "measure is not simply always true",
              quietestWindow(onset) < 0.1f,
              "quietest window " + number(quietestWindow(onset), 3));
    }
    {
        // Releasing the upper note of a trill must return to the lower one, not
        // stop the phrase. Mono synths that skip the held-note stack go silent
        // halfway through a run.
        VaneDSPKernel kernel = makeKernel();
        feed(kernel, noteWord(0xB, 0, 2, 100));
        feed(kernel, noteWord(0x9, 0, 60, 100));
        feed(kernel, noteWord(0x9, 0, 62, 100));
        feed(kernel, noteWord(0x8, 0, 62, 0));          // release the upper
        std::vector<float> still = renderContinuous(kernel, 20, 256);
        check("releasing the upper note of a trill keeps sounding",
              peakOf(still) > 0.05f, "peak " + number(peakOf(still)));

        feed(kernel, noteWord(0x8, 0, 60, 0));
        feed(kernel, noteWord(0xB, 0, 2, 0));
        std::vector<float> tail = renderContinuous(kernel, 120, 256);
        check("and releasing the last one lets it go",
              peakOf({ tail.end() - 512, tail.end() }) < 0.01f,
              "tail peak " + number(peakOf({ tail.end() - 512, tail.end() })));
    }

    // ── bandwidth: the aliasing ────────────────────────────────────────────
    //
    // The mip level is chosen so the top harmonic still fits under Nyquist.
    // Checked twice: as arithmetic on the selector, and as a measurable property
    // of the signal it produces.
    {
        // The full table is 1024 harmonics, so it only fits below 24000/1024 —
        // about 23 Hz. A bass note at 55 Hz gets 256, which is the right answer
        // and not the one this check first asserted.
        check("only a note below the bottom of hearing gets the whole table",
              VaneWavetable::mipLevelFor(20.0, kSampleRate) == VaneWavetable::kNumMipLevels - 1,
              "level " + std::to_string(VaneWavetable::mipLevelFor(20.0, kSampleRate)));
        check("a low bass note gets 256 harmonics",
              VaneWavetable::mipLevelFor(55.0, kSampleRate) == 8,
              "level " + std::to_string(VaneWavetable::mipLevelFor(55.0, kSampleRate)));
        check("and a very high one is driven down to a sine",
              VaneWavetable::mipLevelFor(20000.0, kSampleRate) == 0,
              "level " + std::to_string(VaneWavetable::mipLevelFor(20000.0, kSampleRate)));

        bool monotonic = true;
        int previous = VaneWavetable::kNumMipLevels;
        for (double hz = 20.0; hz < 20000.0; hz *= 1.05) {
            const int level = VaneWavetable::mipLevelFor(hz, kSampleRate);
            if (level > previous) { monotonic = false; break; }
            previous = level;
        }
        check("levels only ever fall as pitch rises", monotonic);

        bool underNyquist = true;
        double worstHz = 0;
        for (double hz = 20.0; hz < 20000.0; hz *= 1.02) {
            const int level = VaneWavetable::mipLevelFor(hz, kSampleRate);
            const double top = hz * double(1 << level);
            if (top > kSampleRate * 0.5) { underNyquist = false; worstHz = hz; break; }
        }
        check("so no frame's top harmonic is ever above Nyquist", underNyquist,
              underNyquist ? "checked 20 Hz to 20 kHz"
                           : "fails at " + number(worstHz, 1) + " Hz");
    }
    {
        // The measurable consequence. A saw two octaves up must not have more
        // zero crossings than its own fundamental can account for — which is
        // exactly what aliasing adds.
        VaneDSPKernel kernel = makeKernel();
        kernel.setParameter(vaneMorph, 1.0f);            // the fullest frame
        kernel.setParameter(vaneCutoff, 20000.0f);       // filter out of the way
        kernel.setParameter(vaneBreathToCutoff, 0.0f);
        kernel.setParameter(vaneTimbreToCutoff, 0.0f);
        feed(kernel, noteWord(0xB, 0, 2, 127));
        feed(kernel, noteWord(0x9, 0, 108, 100));        // C8, ~4186 Hz
        std::vector<float> high = renderContinuous(kernel, 20, 256);

        // At 4186 Hz on a 48 kHz rate only five harmonics fit, so the level
        // selector allows four. A band-limited signal crosses zero at most
        // 2 * topHarmonic times per second.
        const double seconds = double(high.size()) / kSampleRate;
        const double crossingsPerSecond = zeroCrossings(high) / seconds;
        const double ceiling = 2.0 * 4186.0 * 4.0 * 1.1;   // 4 harmonics + slack
        check("a very high note does not alias into extra crossings",
              crossingsPerSecond < ceiling,
              number(crossingsPerSecond, 0) + " per second, ceiling "
              + number(ceiling, 0));
    }

    // ── the controls do what they say ──────────────────────────────────────
    {
        // The cutoff has to start BELOW the note's harmonics or there is
        // nothing for breath to open. At the 900 Hz default a C3's six audible
        // harmonics all sit under it already, and the first version of this
        // check compared a filter doing nothing with a filter doing nothing —
        // 0.0094 against 0.0095, which reads as a broken control.
        //
        // C2 with a 100 Hz cutoff and no resonance is the arrangement that
        // discriminates: sixteen harmonics reaching 1 kHz, all of them above the
        // closed cutoff, none of them above the open one. Resonance is off
        // because a bump sitting on the fundamental flatters the closed case.
        VaneDSPKernel bright = makeKernel();
        bright.setParameter(vaneMorph, 1.0f);
        bright.setParameter(vaneCutoff, 100.0f);
        bright.setParameter(vaneResonance, 0.0f);
        bright.setParameter(vaneTimbreToCutoff, 0.0f);
        bright.setParameter(vaneBreathToCutoff, 6.0f);
        feed(bright, noteWord(0xB, 0, 2, 127));
        feed(bright, noteWord(0x9, 0, 36, 100));
        std::vector<float> open = renderContinuous(bright, 40, 256);

        VaneDSPKernel dull = makeKernel();
        dull.setParameter(vaneMorph, 1.0f);
        dull.setParameter(vaneCutoff, 100.0f);
        dull.setParameter(vaneResonance, 0.0f);
        dull.setParameter(vaneTimbreToCutoff, 0.0f);
        dull.setParameter(vaneBreathToCutoff, 0.0f);
        feed(dull, noteWord(0xB, 0, 2, 127));
        feed(dull, noteWord(0x9, 0, 36, 100));
        std::vector<float> closed = renderContinuous(dull, 40, 256);

        check("breath opens the filter, which is what makes blowing harder sound "
              "brighter rather than only louder",
              brightness(open) > brightness(closed) * 2.0f,
              "brightness " + number(brightness(open)) + " vs " + number(brightness(closed)));
    }
    {
        // Morph is the other headline control and the one that says what kind of
        // instrument this is. Frame 0 is a sine, frame 15 is sixteen harmonics,
        // and the sweep between them has to be monotonic or the control is a
        // surprise rather than a dimension.
        float previous = 0.0f;
        bool rising = true;
        std::string trace;
        for (float morph : { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f }) {
            VaneDSPKernel kernel = makeKernel();
            kernel.setParameter(vaneMorph, morph);
            kernel.setParameter(vaneCutoff, 20000.0f);
            kernel.setParameter(vaneBreathToCutoff, 0.0f);
            kernel.setParameter(vaneTimbreToCutoff, 0.0f);
            feed(kernel, noteWord(0xB, 0, 2, 127));
            feed(kernel, noteWord(0x9, 0, 36, 100));
            const float value = brightness(renderContinuous(kernel, 40, 256));
            if (value < previous) { rising = false; }
            trace += (trace.empty() ? "" : " → ") + number(value, 4);
            previous = value;
        }
        check("morph sweeps simplest to fullest, monotonically", rising, trace);
    }

    {
        VaneDSPKernel kernel = makeKernel();
        kernel.setParameter(vaneMorph, 0.0f);
        kernel.setParameter(vaneBendRange, 2.0f);        // a keyboard's range
        feed(kernel, noteWord(0xB, 0, 2, 127));
        feed(kernel, noteWord(0x9, 0, 60, 100));
        std::vector<float> flat = renderContinuous(kernel, 20, 256);
        feed(kernel, noteWord(0xE, 0, 0, 127));          // bend to the top
        std::vector<float> bent = renderContinuous(kernel, 20, 256);
        check("pitch bend raises the pitch", zeroCrossings(bent) > zeroCrossings(flat),
              std::to_string(zeroCrossings(flat)) + " → " + std::to_string(zeroCrossings(bent)));
        check("and does not click on the way", roughness(bent, 293.7) < 3.0f,
              number(roughness(bent, 293.7), 2) + "x a clean sine");
    }
    {
        VaneDSPKernel kernel = makeKernel();
        kernel.setParameter(vaneMorph, 0.0f);
        feed(kernel, noteWord(0xB, 0, 2, 127));
        feed(kernel, noteWord(0x9, 0, 60, 100));
        std::vector<float> before = renderContinuous(kernel, 20, 256);
        kernel.setParameter(vaneLevel, 0.1f);
        std::vector<float> after = renderContinuous(kernel, 40, 256);
        check("level does what it says", peakOf(after) < peakOf(before),
              number(peakOf(before)) + " → " + number(peakOf(after)));
        check("and ramps rather than steps", roughness(after, 261.6) < 3.0f,
              number(roughness(after, 261.6), 2) + "x a clean sine");
    }

    // ── MPE: one gesture, whichever channel it arrives on ──────────────────
    {
        VaneDSPKernel kernel = makeKernel();
        kernel.setParameter(vaneVelocityMix, 0.0f);
        feed(kernel, noteWord(0x9, 5, 60, 100));         // note on channel 6
        feed(kernel, noteWord(0xD, 9, 120, 0));          // pressure on channel 10
        std::vector<float> sound = renderContinuous(kernel, 30, 256);
        check("a mono voice merges the MPE channels rather than needing a mode",
              peakOf(sound) > 0.05f, "peak " + number(peakOf(sound)));
    }

    // ── panic, and bypass ──────────────────────────────────────────────────
    {
        VaneDSPKernel kernel = makeKernel();
        feed(kernel, noteWord(0xB, 0, 2, 127));
        feed(kernel, noteWord(0x9, 0, 60, 100));
        renderContinuous(kernel, 10, 256);
        feed(kernel, noteWord(0xB, 0, 123, 0));          // all notes off
        std::vector<float> after = renderContinuous(kernel, 120, 256);
        check("all-notes-off releases the voice",
              peakOf({ after.end() - 512, after.end() }) < 0.01f,
              "tail peak " + number(peakOf({ after.end() - 512, after.end() })));
    }
    {
        VaneDSPKernel kernel = makeKernel();
        feed(kernel, noteWord(0xB, 0, 2, 127));
        feed(kernel, noteWord(0x9, 0, 60, 100));
        renderContinuous(kernel, 10, 256);
        kernel.setBypass(true);
        Output out = makeOutput(512);
        render(kernel, out, 512);
        check("bypass writes silence rather than leaving the buffer alone",
              peakOf(out.left) == 0.0f, number(peakOf(out.left)));
    }

    // ── what the interface reads ───────────────────────────────────────────
    {
        VaneDSPKernel kernel = makeKernel();
        check("nothing is sounding before a note", !kernel.isSounding());
        feed(kernel, noteWord(0xB, 0, 2, 100));
        feed(kernel, noteWord(0x9, 0, 60, 100));
        renderContinuous(kernel, 20, 256);
        check("breath is readable, and is what was blown",
              kernel.currentBreath() > 0.6f && kernel.currentBreath() <= 1.0f,
              number(kernel.currentBreath()));
        check("and the instrument says it is sounding", kernel.isSounding());
    }

    // ── an event in the middle of a block ──────────────────────────────────
    //
    // The bug `VaneAUProcessHelper.hpp` warns about: each segment must write to
    // its own offset in the output buffer. Forget it and every segment writes
    // over the first, which sounds like a stutter at the block rate and looks,
    // in a waveform view, almost right. Nothing above can see it — every check
    // there renders one segment per block, which is the case where the offset is
    // zero and the bug is invisible.
    {
        VaneDSPKernel kernel = makeKernel();
        VaneAUProcessHelper helper(kernel);
        feed(kernel, noteWord(0xB, 0, 2, 127));

        const uint32_t word = noteWord(0x9, 0, 60, 100);
        MIDIEventList list = {};
        MIDIEventPacket *packet = MIDIEventListInit(&list, kMIDIProtocol_2_0);
        packet = MIDIEventListAdd(&list, sizeof(MIDIEventList), packet, 0, 1, &word);

        AUMIDIEventList wrapper = {};
        wrapper.eventType = AURenderEventMIDIEventList;
        wrapper.eventSampleTime = 256;       // halfway through a 512-frame block
        wrapper.eventList = list;
        AURenderEvent event = {};
        event.MIDIEventsList = wrapper;

        Output out = makeOutput(512);
        AudioTimeStamp timestamp = {};
        timestamp.mSampleTime = 0;
        helper.processWithEvents(out.list(), &timestamp, 512, &event);

        const std::vector<float> firstHalf(out.left.begin(), out.left.begin() + 256);
        const std::vector<float> secondHalf(out.left.begin() + 256, out.left.end());
        check("a note that starts mid-block leaves the first half silent",
              peakOf(firstHalf) == 0.0f, "peak " + number(peakOf(firstHalf), 8));
        check("and is written to the second half rather than over the first",
              peakOf(secondHalf) > 0.0f, "peak " + number(peakOf(secondHalf)));
    }

    printf("\n%s\n", gFailures == 0 ? "vane: OK" : "vane: FAILURES");
    return gFailures == 0 ? 0 : 1;
}
