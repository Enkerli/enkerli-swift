//
//  ApplyRhythm.swift
//  Carrier
//
//  A line you kept, performed on a different grid.
//
//  Ported from `packages/accompaniment/src/rhythm.ts::applyRhythm` in
//  music-suite, where it is described as "the interop dividend": keep a
//  phrase's PITCH material — contour, degrees, harmonic function, dynamics —
//  and replace its rhythm wholesale with any onset mask the suite can express.
//
//  It is here rather than in `Theory` because it is about the interchange
//  format, and here rather than in a plug-in because it is the thing that lets
//  a melody plug-in gain rhythm replacement *without becoming a rhythm
//  plug-in*. MelGen's PORTING.md §5 puts it plainly: "a line you kept,
//  performed on a tresillo, is a MelGen feature that costs one function." This
//  is the function.
//
//  The rules are the TypeScript's, and all four are deterministic:
//
//   · **the mask spans the pattern.** A rhythm is a shape, not a tempo, so its
//     n steps are stretched across the pattern's whole length rather than being
//     given a fixed step size. E(3,8) over two bars is a quarter-note grid; the
//     same E(3,8) over one bar is an eighth-note grid. This is what makes
//     `P(3,1)+P(5,0)` — fifteen steps — land as a fifteen-grid over the same
//     span rather than overflowing it.
//   · **onset k takes source note k, cycling.** More onsets than notes and the
//     material repeats; fewer and the tail is not heard. Contour and harmonic
//     function ride along; only the rhythm is replaced.
//   · **durations are legato to the next onset.** The tied feel. A gate policy
//     would be a different decision and belongs to whoever is performing this,
//     not to the mapping.
//   · **a chromatic approach re-points at the next onset.** "Resolves to
//     whatever comes next" is what the approach *means*, and it means that
//     independently of which grid it is living on. Every other kind of note
//     keeps the role it had.
//
//  What this does NOT do is parse notation. A mask arrives as data — `steps`
//  and optional `accents`, leftmost = LSB like every mask in the suite — so
//  this file stays free of UPI, which is Serpe's, and of `Theory`, which is
//  where a mask gets generated. `EuclideanRhythm.pattern(beats:steps:)` in
//  Theory produces one; so does a parser in a plug-in; so does a person typing
//  sixteen ones and zeroes.
//

import Foundation
import Theory

/// An onset mask, plus what to call it afterwards.
public struct RhythmSpec: Hashable, Sendable {
    /// Leftmost = LSB: index i is step i. At least one onset, or the mapping
    /// has nothing to place.
    public var steps: [Bool]
    /// Optional accent layer, aligned to `steps`. An accented onset is played
    /// harder, not longer.
    public var accents: [Bool]
    /// For provenance, e.g. "E(3,8)". Empty means "describe it by its shape".
    public var label: String

    public init(steps: [Bool], accents: [Bool] = [], label: String = "") {
        self.steps = steps
        self.accents = accents
        self.label = label
    }

    /// The Euclidean rhythm of `beats` onsets over `steps` slots.
    public static func euclidean(_ beats: Int, _ steps: Int, offset: Int = 0) -> RhythmSpec {
        RhythmSpec(steps: EuclideanRhythm.pattern(beats: beats, steps: steps, offset: offset),
                   label: offset == 0 ? "E(\(beats),\(steps))" : "E(\(beats),\(steps),\(offset))")
    }

    /// A bit-string, first character step 0. Nil when it is not one.
    public static func bits(_ string: String) -> RhythmSpec? {
        guard let steps = RhythmCodec.pattern(binary: string), !steps.isEmpty else { return nil }
        return RhythmSpec(steps: steps, label: string)
    }

    public var onsetIndices: [Int] { RhythmCodec.onsets(steps) }
    public var isEmpty: Bool { onsetIndices.isEmpty }

    var describedLabel: String {
        label.isEmpty ? "\(onsetIndices.count)of\(steps.count)" : label
    }
}

extension MelodyPattern {

    /// How much velocity an accent adds. The TypeScript's +18, kept rather than
    /// re-chosen, because two implementations disagreeing about how loud an
    /// accent is would be a silent divergence of exactly the kind vectors exist
    /// to prevent — and nobody has measured a better number.
    public static let accentVelocityBoost = 18

    /// This pattern's pitch material, performed on `rhythm`.
    ///
    /// Returns nil when there is nothing to map — a mask with no onsets, or a
    /// pattern with no notes. Nil rather than an empty pattern because "the
    /// rhythm you asked for cannot be applied" and "the result is silence" are
    /// different answers and a caller should not have to tell them apart by
    /// counting.
    public func performed(on rhythm: RhythmSpec) -> MelodyPattern? {
        let onsetSteps = rhythm.onsetIndices
        guard !onsetSteps.isEmpty, !notes.isEmpty else { return nil }

        // The pattern's span in eighths: where the last note ends, plus whatever
        // rest it was written to carry, because a line that ends with a bar of
        // silence is two bars long and re-gridding it over one would change the
        // tempo of the thing rather than its rhythm.
        let span = notes.reduce(0) { end, note in
            max(end, note.startEighth + note.lengthEighths + note.restAfterEighths)
        }
        guard span > 0 else { return nil }

        let eighthsPerStep = Double(span) / Double(rhythm.steps.count)
        let onsets = onsetSteps.map { Int((Double($0) * eighthsPerStep).rounded()) }

        var placed: [PatternNote] = []
        for (k, onset) in onsets.enumerated() {
            let source = notes[k % notes.count]
            let next = k + 1 < onsets.count ? onsets[k + 1] : span
            let accented = k < onsetSteps.count && onsetSteps[k] < rhythm.accents.count
                && rhythm.accents[onsetSteps[k]]
            placed.append(PatternNote(
                startEighth: onset,
                lengthEighths: max(1, next - onset),
                degree: source.degree,
                octave: source.octave,
                alteration: source.alteration,
                velocity: min(127, max(1, source.velocity + (accented ? Self.accentVelocityBoost : 0))),
                // Legato: the next onset is where this note stops, so there is
                // no rest to carry. The last note runs to the end of the span.
                restAfterEighths: 0,
                role: source.role))
        }

        var result = self
        result.name = "\(name) · \(rhythm.describedLabel)"
        result.notes = placed
        result.summary = summary.isEmpty
            ? "on \(rhythm.describedLabel)"
            : "\(summary), on \(rhythm.describedLabel)"
        return result
    }
}

extension Array where Element == SequencedNote {

    /// The same operation on notes that already have pitches and beats.
    ///
    /// The degree-relative version above is the one that survives being
    /// replayed over other changes and is the one to reach for. This exists
    /// because a take that has already been realized is often what is in front
    /// of you, and re-extracting it to degrees only to re-realize it would lose
    /// whatever the realization decided.
    public func performed(on rhythm: RhythmSpec, lengthBeats: Double) -> [SequencedNote] {
        let onsetSteps = rhythm.onsetIndices
        guard !onsetSteps.isEmpty, !isEmpty, lengthBeats > 0 else { return [] }

        let beatsPerStep = lengthBeats / Double(rhythm.steps.count)
        let onsets = onsetSteps.map { Double($0) * beatsPerStep }
        let material = sorted { $0.startBeat < $1.startBeat }

        return onsets.enumerated().map { k, onset in
            let source = material[k % material.count]
            let next = k + 1 < onsets.count ? onsets[k + 1] : lengthBeats
            let accented = onsetSteps[k] < rhythm.accents.count && rhythm.accents[onsetSteps[k]]
            return SequencedNote(
                note: source.note,
                velocity: UInt8(clamping: Int(source.velocity)
                                + (accented ? MelodyPattern.accentVelocityBoost : 0)),
                startBeat: onset,
                durationBeats: Swift.max(0.01, next - onset))
        }
    }
}
