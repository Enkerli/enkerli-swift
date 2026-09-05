//
//  PitchClassSetTests.swift
//  TheoryTests
//
//  The Swift PCS port against the suite's own answers.
//
//  Reads `packages/theory/vectors/pcs-families.json`, which was widened for
//  this port — before it, `consonance` and `classifyDegreeChord` had no vector
//  at all. See RhythmVectorTests for how a missing music-suite checkout is
//  reported, and why it says NOT RUN rather than skipping quietly.
//

import Foundation
import Testing
@testable import Theory

private func pcsVectors() throws -> [String: Any] {
    try Vectors.load("packages/theory/vectors/pcs-families.json")
}

@Test func scaleFamiliesMatchTheSuite() throws {
    guard Vectors.available("families") else { return }
    let cases = try pcsVectors()["families"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty)
    for c in cases {
        let k = c["k"] as! Int
        let root = c["root"] as! Int
        let expected = c["pcs"] as! [Int]
        let family = PitchClassSet.family(k, root: root)
        #expect(family == expected, "k=\(k) root=\(root): \(family) != \(expected)")
        #expect(PitchClassSet.bitmask(family) == c["bitmask"] as! Int,
                "bitmask of k=\(k) root=\(root)")
    }
}

@Test func theCircleOfFifthsMatchesTheSuite() throws {
    guard Vectors.available("fifths") else { return }
    let cases = try pcsVectors()["fifths"] as? [[String: Any]] ?? []
    #expect(cases.count == 12)
    for c in cases {
        let index = c["index"] as! Int
        #expect(CircleOfFifths.chromatic(atIndex: index) == c["chromatic"] as! Int,
                "index \(index)")
        #expect(CircleOfFifths.index(ofChromatic: c["chromatic"] as! Int)
                    == c["backToIndex"] as! Int)
    }
}

@Test func consonanceMatchesTheSuite() throws {
    guard Vectors.available("consonance") else { return }
    let cases = try pcsVectors()["consonance"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty)
    for c in cases {
        let pcs = c["pcs"] as! [Int]
        let expected = (c["value"] as! NSNumber).doubleValue
        let got = (PitchClassSet.consonance(pcs) * 1_000_000).rounded() / 1_000_000
        #expect(abs(got - expected) < 1e-9,
                "\(c["note"] ?? ""): \(got) != \(expected)")
    }
}

@Test func theClassifierMatchesTheSuite() throws {
    guard Vectors.available("classify") else { return }
    let cases = try pcsVectors()["classify"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty)
    for c in cases {
        let info = PitchClassSet.classify(c["pcs"] as! [Int])
        let quality = c["quality"] as? String
        #expect(info.quality?.rawValue == quality, "\(c["note"] ?? "") quality")
        #expect(info.root == c["root"] as? Int, "\(c["note"] ?? "") root")
        #expect(info.name == c["name"] as! String,
                "\(c["note"] ?? "") name: \(info.name) != \(c["name"] as! String)")
    }
}

@Test func romanNumeralsMatchTheSuite() throws {
    guard Vectors.available("numerals") else { return }
    let cases = try pcsVectors()["numerals"] as? [[String: Any]] ?? []
    #expect(cases.count > 100)
    for c in cases {
        let quality = (c["quality"] as? String).flatMap(PitchClassSet.DegreeQuality.init(rawValue:))
        let got = PitchClassSet.romanNumeral(degree: c["degree"] as! Int, quality: quality)
        let want = c["numeral"] as! String
        let where_ = "degree \(c["degree"] ?? "") \(c["quality"] ?? "null"): \(got) != \(want)"
        #expect(got == want, "\(where_)")
    }
}

@Test func degreeChordsMatchTheSuite() throws {
    guard Vectors.available("degreeChords") else { return }
    let cases = try pcsVectors()["degreeChords"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty)
    for c in cases {
        let scale = PitchClassSet.family(c["k"] as! Int, root: c["root"] as! Int)
        let type = PitchClassSet.StackType(rawValue: c["type"] as! String)!
        let chords = PitchClassSet.degreeChords(of: scale, type: type)
        let label = "\(c["scale"] ?? "") \(type.rawValue)"

        #expect(chords.map(\.numeral) == c["numerals"] as! [String], "\(label) numerals")

        let expected = c["degrees"] as! [[String: Any]]
        #expect(chords.count == expected.count, "\(label) count")
        for (chord, want) in zip(chords, expected) {
            #expect(chord.degree == want["degree"] as! Int, "\(label)")
            #expect(chord.rootPitchClass == want["rootPc"] as! Int, "\(label)")
            #expect(chord.pitchClasses == want["pcs"] as! [Int],
                    "\(label) degree \(chord.degree) pcs")
            #expect(chord.bitmask == want["bitmask"] as! Int,
                    "\(label) degree \(chord.degree) bitmask")
            #expect(chord.info.quality?.rawValue == want["quality"] as? String,
                    "\(label) degree \(chord.degree) quality")
            #expect(chord.info.root == want["chordRoot"] as? Int,
                    "\(label) degree \(chord.degree) root")
            #expect(chord.info.name == want["name"] as! String,
                    "\(label) degree \(chord.degree) name")
        }
    }
}

// MARK: - The things that are ours

@Test func aSetIsOctaveAndOrderFree() {
    // No vector needed: this is what "pitch class set" means, stated as a test
    // so it fails even in a checkout with no music-suite beside it.
    #expect(PitchClassSet.bitmask([0, 4, 7]) == 145)
    #expect(PitchClassSet.bitmask([7, 4, 0]) == 145)
    #expect(PitchClassSet.bitmask([12, 16, 19]) == 145)
    #expect(PitchClassSet.consonance([0, 4, 7]) == PitchClassSet.consonance([7, 16, 24]))
    // 2741, and worth a sentence because the number 2773 is written in more
    // than one place as "the C major scale" and is not. 2773 is C major read
    // MSB-first — the convention the suite unified on for twelve days in June
    // 2026 and then reverted — and, read the right way round, it is the bitmask
    // of C Lydian, which is also `M13♯11`'s pitch-class set in the chord
    // dictionary. A wrong number that is a real set is the kind that survives
    // review. This assertion is what caught the stale comment in
    // music-suite's pcs.ts; it stays as the thing that would catch it again.
    #expect(PitchClassSet.bitmask(PitchClassSet.family(7, root: 0)) == 2741)
    #expect(PitchClassSet.bitmask([0, 2, 4, 6, 7, 9, 11]) == 2773, "C Lydian, not C major")
}
