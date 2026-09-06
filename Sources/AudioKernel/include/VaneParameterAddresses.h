//
//  VaneParameterAddresses.h
//  AudioKernel
//
//  The synth's parameters.
//
//  A **separate address space** from `PluginParameterAddresses.h`, which belongs
//  to the MIDI kernel. The two headers must never be mixed in one plug-in: they
//  number from zero for different things, and an audio unit that included both
//  would have two parameters at address 2 meaning "play the melody" and "morph".
//  Nothing in the build stops that, because they are separate targets and a
//  plug-in could import both — so this comment is the guard.
//
//  Unlike the MIDI processors, a synth's knobs genuinely *are* AU parameters:
//  cutoff, morph and level are values a host should be able to automate, record
//  and recall, and a wind instrument with no automatable timbre would be a
//  strange thing to put in a DAW. That is why this file is not empty, and it is
//  not a contradiction of GAPS.md's line about inert controls — every one of
//  these does something on the next sample.
//
//  Created for SwiftVane, 2026-09-06.
//

#pragma once

#include <AudioToolbox/AUParameters.h>

typedef NS_ENUM(AUParameterAddress, VaneParameterAddress) {
    /// Position across the wavetable's frames: sine at 0, fullest saw at 1.
    vaneMorph = 0,
    /// Output gain.
    vaneLevel = 1,
    /// Filter cutoff with no breath, in Hz.
    vaneCutoff = 2,
    /// 0 = none, 1 = the edge of self-oscillation.
    vaneResonance = 3,
    /// How many octaves full breath opens the filter by. The instrument's
    /// single most important control: it is what makes blowing harder sound
    /// brighter rather than merely louder.
    vaneBreathToCutoff = 4,
    /// How much velocity stands in for breath when nothing is blowing.
    ///
    /// **Defaults to 0.35, not to 0.** Vane's default is 0 and Vane measured
    /// what that costs: a sequencer, a piano roll or a plain keyboard sends no
    /// breath, no expression and no pressure, so the instrument is *silent*.
    /// Silence on first note is the worst possible first impression and the
    /// hardest bug for a player to attribute. A wind controller sends breath
    /// that exceeds this within a few milliseconds, so the two do not fight.
    vaneVelocityMix = 5,
    /// Portamento time between legato notes, in milliseconds.
    vaneGlideMs = 6,
    vaneAttackMs = 7,
    vaneDecayMs = 8,
    vaneSustain = 9,
    vaneReleaseMs = 10,
    /// How much CC74 — the MPE timbre axis — opens the filter, in octaves.
    vaneTimbreToCutoff = 11,
    /// Pitch-bend range in semitones. 48 is the MPE default for per-note bend
    /// and is what a Seaboard or an Exquis expects; 2 is what a keyboard does.
    vaneBendRange = 12
};
