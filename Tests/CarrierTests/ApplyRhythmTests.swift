//
//  ApplyRhythmTests.swift
//  CarrierTests
//
//  Rhythm replacement, checked against the properties the mapping promises
//  rather than against a golden output.
//
//  There are no vectors for `applyRhythm` in the monorepo — `packages/
//  accompaniment` has eight vector files and none of them covers this one — so
//  what is checked here is the four rules the TypeScript's own header states,
//  each as a property. If vectors for it ever land, these become conformance
//  cases and this comment goes away.
//

import Foundation
import Testing
@testable import Carrier
import Theory

private func line(_ degrees: [Int], eighthsEach: Int = 2) -> MelodyPattern {
    MelodyPattern(
        name: "line", bars: 1, summary: "",
        notes: degrees.enumerated().map { i, degree in
            PatternNote(startEighth: i * eighthsEach, lengthEighths: eighthsEach,
                        degree: degree, velocity: 90)
        })
}

@Test func theMaskSpansThePatternRatherThanFixingAStepSize() {
    // Eight notes of one eighth each: an eight-eighth span. E(3,8) over it is
    // an eighth grid, so the onsets land on eighths 0, 3, 6.
    let source = line([0, 1, 2, 3, 4, 5, 6, 7], eighthsEach: 1)
    let performed = source.performed(on: .euclidean(3, 8))
    #expect(performed?.notes.map(\.startEighth) == [0, 3, 6])

    // The same mask over a span twice as long is a quarter grid, not a
    // half-length pattern with a hole after it.
    let longer = line([0, 1, 2, 3, 4, 5, 6, 7], eighthsEach: 2)
    let stretched = longer.performed(on: .euclidean(3, 8))
    #expect(stretched?.notes.map(\.startEighth) == [0, 6, 12])
}

@Test func onsetsTakeSourceNotesInOrderAndCycle() {
    // Three notes, five onsets: the material repeats rather than running out.
    let source = line([0, 2, 4])
    let performed = source.performed(on: .euclidean(5, 8))
    #expect(performed?.notes.map(\.degree) == [0, 2, 4, 0, 2])
}

@Test func durationsAreLegatoToTheNextOnset() {
    let source = line([0, 2, 4], eighthsEach: 1)   // a three-eighth span
    let performed = source.performed(on: RhythmSpec.bits("100100")!)
    // Six steps over three eighths: onsets at steps 0 and 3 land on eighths 0
    // and 1.5 → 0 and 2 after rounding, and the last runs to the end.
    let notes = performed!.notes
    #expect(notes.count == 2)
    #expect(notes[0].startEighth + notes[0].lengthEighths == notes[1].startEighth,
            "the first note should end where the second begins")
    #expect(notes.last!.startEighth + notes.last!.lengthEighths == 3,
            "and the last should run to the end of the span")
    #expect(notes.allSatisfy { $0.restAfterEighths == 0 },
            "legato leaves no rest to carry")
}

@Test func aChromaticApproachRepointsAndEverythingElseKeepsItsRole() {
    var source = line([0, 2, 4])
    source.notes[1].alteration = 1
    source.notes[1].role = .offScale
    source.notes[2].role = .chordTone
    let performed = source.performed(on: .euclidean(3, 8))!
    #expect(performed.notes[1].alteration == 1)
    #expect(performed.notes[1].role == .offScale)
    #expect(performed.notes[2].role == .chordTone)
    // isLeadable is derived from those two, and is what stops the seam leading
    // from snapping a deliberate colour note onto the chord. It has to survive.
    #expect(performed.notes[1].isLeadable == false)
    #expect(performed.notes[0].isLeadable == true)
}

@Test func anAccentIsPlayedHarderNotLonger() {
    let source = line([0, 2, 4])
    let plain = source.performed(on: .euclidean(3, 8))!
    let accented = source.performed(on: RhythmSpec(
        steps: EuclideanRhythm.pattern(beats: 3, steps: 8),
        accents: [true, false, false, false, false, false, false, false],
        label: "E(3,8) accented"))!
    #expect(accented.notes[0].velocity == plain.notes[0].velocity + MelodyPattern.accentVelocityBoost)
    #expect(accented.notes[1].velocity == plain.notes[1].velocity)
    #expect(accented.notes.map(\.lengthEighths) == plain.notes.map(\.lengthEighths),
            "an accent changes velocity and nothing else")
}

@Test func aMaskWithNoOnsetsIsRefusedRatherThanReturningSilence() {
    let source = line([0, 2, 4])
    #expect(source.performed(on: RhythmSpec(steps: [false, false, false, false])) == nil)
    #expect(MelodyPattern(name: "", bars: 1, summary: "", notes: [])
        .performed(on: .euclidean(3, 8)) == nil)
}

@Test func theSameOperationOnRealizedNotes() {
    let notes = [
        SequencedNote(note: 60, velocity: 90, startBeat: 0, durationBeats: 1),
        SequencedNote(note: 64, velocity: 90, startBeat: 1, durationBeats: 1),
        SequencedNote(note: 67, velocity: 90, startBeat: 2, durationBeats: 1),
    ]
    let performed = notes.performed(on: .euclidean(3, 8), lengthBeats: 4)
    #expect(performed.map(\.note) == [60, 64, 67])
    #expect(performed.map(\.startBeat) == [0, 1.5, 3])
    #expect(performed.last!.durationBeats == 1, "the last note runs to the end of the loop")
}

@Test func provenanceSurvives() {
    var source = line([0, 2, 4])
    source.name = "Long tones"
    source.summary = "held, mostly"
    let performed = source.performed(on: .euclidean(3, 8))!
    #expect(performed.name.contains("Long tones"))
    #expect(performed.name.contains("E(3,8)"))
    #expect(performed.summary.contains("held, mostly"))
    #expect(performed.summary.contains("E(3,8)"))
}
