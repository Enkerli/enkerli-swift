//
//  PitchClassSet.swift
//  Theory
//
//  Pitch-class sets: scale families, degree chords, and how consonant a set is.
//
//  Ported from `packages/theory/src/pcs.ts` in music-suite, itself ported from
//  [PickPCS](https://github.com/Enkerli/PickPCS), the suite's concentric PCS
//  picker. Held to `packages/theory/vectors/pcs-families.json`, which was
//  widened for this port: before it, `consonance` and `classifyDegreeChord` had
//  no vector at all and `degreeChords` was checked only by the strings it
//  prints.
//
//  A pitch-class set is octave-free and order-free — {0,4,7} is a major triad
//  whatever register it lands in and whichever way it is written. That is what
//  makes it the right object for a quantizer: "which twelve-tone subset are we
//  snapping to" is a question about pitch classes, and the answer has no
//  octave in it.
//
//  Bitmask convention, as everywhere here: leftmost = LSB, pitch class i
//  contributes 2^i. So {0,4,7} = 1 + 16 + 128 = 145, and the C major scale is
//  **2741**. `ChordDetection.fingerprint` is the same function under another
//  name, and this reuses it rather than writing a third copy.
//
//  2741 rather than 2773, which the TypeScript's own header said until this port
//  disagreed with it. 2773 is C major read MSB-first — the convention the suite
//  unified on for twelve days in June 2026 and then reverted — and, read the
//  right way round, it is the pitch-class set of C Lydian, which is also
//  `M13♯11` in the chord dictionary. A wrong number that is a real set is the
//  kind that survives review, which is the argument for asserting a value you
//  believe rather than one you copied.
//
//  Made to fail before the green was believed: sorting the classifier's
//  candidate roots descending (67 issues), spelling the ring's note names flat
//  (68), moving one interval-class weight (72), and sorting a scale family
//  instead of leaving it in scale order (197). All reverted.
//

import Foundation

/// Where a pitch class sits on the circle of fifths, and back.
public enum CircleOfFifths {
    static let toChromatic = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]

    /// Chromatic pitch class for a position on the circle. 0 = C, 1 = G, …
    public static func chromatic(atIndex index: Int) -> Int {
        toChromatic[ChordScales.pitchClass(index)]
    }

    /// The inverse. Multiplying by 7 mod 12 is the same walk backwards, because
    /// 7 is its own inverse mod 12 — the table above and this line agree, and
    /// the vectors check that they do rather than trusting the arithmetic.
    public static func index(ofChromatic pitchClass: Int) -> Int {
        ChordScales.pitchClass(pitchClass * 7)
    }
}

public enum PitchClassSet {

    // MARK: - Bitmask

    /// Leftmost = LSB: pitch class i contributes 2^i.
    public static func bitmask(_ pitchClasses: [Int]) -> Int {
        ChordDetection.fingerprint(pitchClasses)
    }

    // MARK: - Consonance

    /// Sensory-consonance weight per interval class, 0…6.
    ///
    /// The classic dyad ordering: fifths (ic5) most consonant, thirds and sixths
    /// (ic3, ic4) nearly so, tritone (ic6) and whole tone (ic2) tenser, and the
    /// semitone (ic1) the most dissonant. Index 0 is a unison, which cannot
    /// occur between two *distinct* pitch classes and is 1 for completeness.
    static let intervalClassConsonance: [Double] = [1, 0.0, 0.25, 0.8, 0.9, 1.0, 0.35]

    /// How consonant a set is, in 0…1: the mean weight over every distinct
    /// pair's interval class.
    ///
    /// Order-independent and octave-equivalent, so it scores the harmonic
    /// colour of a chord rather than a voicing of one — a major triad and its
    /// inversions all come back the same, and so do a major triad and a minor
    /// one, because they have the same interval classes. That last is not a
    /// bug and is the reason this is called consonance rather than brightness.
    ///
    /// Fewer than two distinct pitch classes is trivially consonant.
    public static func consonance(_ pitchClasses: [Int]) -> Double {
        let unique = Array(Set(pitchClasses.map(ChordScales.pitchClass)))
        guard unique.count >= 2 else { return 1 }
        var sum = 0.0
        var pairs = 0
        for i in 0..<unique.count {
            for j in (i + 1)..<unique.count {
                let distance = ChordScales.pitchClass(unique[i] - unique[j])
                let intervalClass = distance > 6 ? 12 - distance : distance
                sum += intervalClassConsonance[intervalClass]
                pairs += 1
            }
        }
        return pairs > 0 ? sum / Double(pairs) : 1
    }

    // MARK: - Scale families

    /// The maximally even k-in-12 sets, in PickPCS's chosen rotations.
    ///
    /// k=3 augmented · k=4 diminished seventh · k=5 major pentatonic ·
    /// k=6 whole tone · k=7 major scale · k=8 octatonic (half-whole).
    ///
    /// These are the *Euclidean* families — the same maximal evenness
    /// `EuclideanRhythm` distributes onsets by, applied to twelve pitch classes
    /// instead of n slots. That the scale picker and the rhythm generator are
    /// the same idea in two domains is worth noticing and is not a coincidence
    /// anybody planned.
    public static let familyIntervals: [Int: [Int]] = [
        3: [0, 4, 8],
        4: [0, 3, 6, 9],
        5: [0, 2, 4, 7, 9],
        6: [0, 2, 4, 6, 8, 10],
        7: [0, 2, 4, 5, 7, 9, 11],
        8: [0, 2, 3, 5, 6, 8, 9, 11],
    ]

    /// The k-note family rooted at `rootPitchClass`, **in scale order** rather
    /// than sorted: degree i is scale step i, so a root that wraps the set past
    /// B leaves the order alone. Empty outside k = 3…8.
    public static func family(_ k: Int, root rootPitchClass: Int) -> [Int] {
        guard let intervals = familyIntervals[k] else { return [] }
        return intervals.map { ChordScales.pitchClass(rootPitchClass + $0) }
    }

    // MARK: - Degree chords

    /// PickPCS's display qualities for stacked degree chords.
    ///
    /// A much smaller vocabulary than `ChordDictionary`'s 172, and deliberately
    /// so: this labels diatonic stacks for a ring display, and a picker that
    /// offered to call something a `13♯11` would be answering a question nobody
    /// asked of it. Use the dictionary when the question is "what chord is
    /// this"; use this when it is "what does this degree stack look like".
    public enum DegreeQuality: String, Codable, Hashable, Sendable, CaseIterable {
        case maj, min, dim, aug, sus4
        case maj7, dominant7 = "7", min7, halfDim7, dim7, minMaj7
        case set
    }

    /// Order matters: sevenths are tried before triads, so a four-note stack is
    /// named as a seventh rather than as a triad with something extra.
    static let seventhPatterns: [(DegreeQuality, [Int])] = [
        (.maj7, [0, 4, 7, 11]),
        (.dominant7, [0, 4, 7, 10]),
        (.min7, [0, 3, 7, 10]),
        (.halfDim7, [0, 3, 6, 10]),
        (.dim7, [0, 3, 6, 9]),
        (.minMaj7, [0, 3, 7, 11]),
    ]

    static let triadPatterns: [(DegreeQuality, [Int])] = [
        (.maj, [0, 4, 7]),
        (.min, [0, 3, 7]),
        (.dim, [0, 3, 6]),
        (.aug, [0, 4, 8]),
        (.sus4, [0, 5, 7]),
    ]

    /// PickPCS's own note names, which are neither the sharp nor the flat set.
    ///
    /// **Not `ChordProgression.flatNoteNames`, and the difference is load-bearing
    /// for the vectors.** PickPCS's ring is context-free — it has no key to spell
    /// against — so it picks a readable name per pitch class and mixes: C♯ but
    /// E♭, F♯ but A♭. The TypeScript's own comment says this is "correct for
    /// PickPCS's context-free ring, but NOT proper spelling", and anything doing
    /// scale-degree or functional work must spell from a named root instead.
    ///
    /// It is here because `classifyDegreeChord`'s `name` is in the vectors and a
    /// port that spelled it flat would DIFF on half of them. Two note-name tables
    /// in one module is a smell; the alternative was a silent disagreement with
    /// the contract, which is worse.
    static let ringNoteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    public static func ringName(_ pitchClass: Int) -> String {
        ringNoteNames[ChordScales.pitchClass(pitchClass)]
    }

    public struct DegreeChordInfo: Hashable, Sendable {
        public let quality: DegreeQuality?
        public let root: Int?
        public let name: String

        public init(quality: DegreeQuality?, root: Int?, name: String) {
            self.quality = quality
            self.root = root
            self.name = name
        }
    }

    /// PickPCS's lightweight classifier: which stack is this, and rooted where.
    ///
    /// Every member is tried as a candidate root, in ascending order, and the
    /// first that matches wins — which for a symmetrical set (dim7, augmented)
    /// means the lowest pitch class is chosen, and that is a choice rather than
    /// a fact. Sorting ascending is therefore part of the contract, not
    /// housekeeping: sorting the other way changes the answer on every
    /// symmetrical set, and the vectors catch it.
    public static func classify(_ pitchClasses: [Int]) -> DegreeChordInfo {
        let pcs = pitchClasses.sorted()
        guard pcs.count >= 3 else { return DegreeChordInfo(quality: nil, root: nil, name: "") }

        for root in pcs {
            let normalised = pcs.map { ChordScales.pitchClass($0 - root) }.sorted()
            for (quality, pattern) in seventhPatterns where normalised == pattern {
                return DegreeChordInfo(quality: quality, root: root,
                                       name: ringName(root) + quality.rawValue)
            }
            for (quality, pattern) in triadPatterns where normalised == pattern {
                return DegreeChordInfo(quality: quality, root: root,
                                       name: ringName(root) + quality.rawValue)
            }
        }
        return DegreeChordInfo(quality: .set, root: nil,
                               name: pcs.map(ringName).joined(separator: "-"))
    }

    /// Roman numeral for a degree with a given quality — PickPCS's display rules.
    public static func romanNumeral(degree: Int, quality: DegreeQuality?) -> String {
        let romans = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII"]
        var base = degree >= 0 && degree < romans.count ? romans[degree] : String(degree + 1)
        if quality == .halfDim7 { return base.lowercased() + "ø7" }
        if let quality, [.min, .min7, .minMaj7].contains(quality) { base = base.lowercased() }
        if let quality, [.dim, .dim7].contains(quality) { base += "°" }
        switch quality {
        case .maj7: base += "∆"
        case .dominant7: base += "7"
        case .min7: base += "-7"
        case .dim7: base += "7"
        case .sus4: base += "sus"
        default: break
        }
        return base
    }

    public enum StackType: String, Codable, Hashable, Sendable, CaseIterable {
        /// Thirds: scale steps 0, 2, 4.
        case triads
        /// Steps 0, 3, 4 — a sus-flavoured stack, not a transposition of a triad.
        case sus
        /// Steps 0, 2, 4, 6.
        case sevenths

        var offsets: [Int] {
            switch self {
            case .triads: return [0, 2, 4]
            case .sus: return [0, 3, 4]
            case .sevenths: return [0, 2, 4, 6]
            }
        }
    }

    public struct DegreeChord: Hashable, Sendable {
        public let degree: Int
        public let rootPitchClass: Int
        public let pitchClasses: [Int]
        public let info: DegreeChordInfo
        public let bitmask: Int
        public let numeral: String

        public init(degree: Int, rootPitchClass: Int, pitchClasses: [Int],
                    info: DegreeChordInfo, bitmask: Int, numeral: String) {
            self.degree = degree
            self.rootPitchClass = rootPitchClass
            self.pitchClasses = pitchClasses
            self.info = info
            self.bitmask = bitmask
            self.numeral = numeral
        }
    }

    /// A chord stacked on every degree of a scale.
    ///
    /// The stack wraps: degree 6 of a seven-note scale reaches back around to
    /// degrees 1 and 3, which is what makes the leading-tone chord diminished
    /// rather than short. The pitch classes come back sorted, which is why a
    /// wrapped stack looks out of order and is not.
    public static func degreeChords(of scale: [Int],
                                    type: StackType = .triads) -> [DegreeChord] {
        guard !scale.isEmpty else { return [] }
        return scale.enumerated().map { index, rootPitchClass in
            let pcs = type.offsets
                .map { scale[(index + $0) % scale.count] }
                .sorted()
            let info = classify(pcs)
            return DegreeChord(
                degree: index,
                rootPitchClass: rootPitchClass,
                pitchClasses: pcs,
                info: info,
                bitmask: bitmask(pcs),
                numeral: romanNumeral(degree: index,
                                      quality: type == .sus ? .sus4 : info.quality))
        }
    }
}
