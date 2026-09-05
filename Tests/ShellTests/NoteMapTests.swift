//
//  NoteMapTests.swift
//  ShellTests
//
//  The decision half of the transform — the part that runs off the audio thread
//  and can therefore be tested like ordinary code.
//
//  The other half, the render-thread rewrite, is C++ and is checked by
//  Scripts/check-kernel.sh, which neither this runner nor Xcode's can reach.
//  Between them they cover the whole path; separately, neither does, and it is
//  worth saying so here because "swift test passed" is not "the quantizer
//  works".
//

import Foundation
import Testing
@testable import Shell
import Theory

private let cMajor = [0, 2, 4, 5, 7, 9, 11]

@Test func anUnconfiguredMapChangesNothing() {
    #expect(NoteMap.identity.isIdentity)
    for note in [0, 60, 61, 127] {
        #expect(NoteMap.identity[note] == .note(note))
    }
}

@Test func aNoteAlreadyInTheSetIsLeftAlone() {
    let map = NoteMap.snapping(to: cMajor)
    for note in [60, 62, 64, 65, 67, 69, 71, 72] {
        #expect(map[note] == .note(note), "\(note) is in C major")
    }
}

@Test func snappingIsOctaveFree() {
    // The set is pitch classes, so the same rule has to apply at both ends of
    // the keyboard — that is the property that makes "snap to C major" mean one
    // thing rather than one thing per octave.
    let map = NoteMap.snapping(to: cMajor)
    for octave in 0...9 {
        let cSharp = 1 + octave * 12
        guard cSharp < 128 else { continue }
        #expect(map[cSharp] == .note(cSharp - 1), "C♯ in octave \(octave)")
    }
}

@Test func tiesGoDown() {
    // C♯ is a semitone from C and a semitone from D. Downward, because a line
    // quantized upward climbs: every ambiguous note nudges the contour the same
    // way, and over a phrase that is audible as drift.
    let map = NoteMap.snapping(to: cMajor, how: .nearest)
    #expect(map[61] == .note(60))
    #expect(map[66] == .note(65))   // F♯ between F and G
    // E♭ is a semitone from D and a semitone from E — a tie, like C♯ — so it
    // goes down too. Written the other way round first, on the belief that D
    // was a tone below; it is not, and in a seven-note scale almost every
    // outside note is equidistant, which is exactly why the tie rule has to be
    // decided once rather than per case.
    #expect(map[63] == .note(62))
    // Where the neighbours are NOT equidistant, the nearer one wins whichever
    // way it lies. C major has no such note; a pentatonic does, below.
}

@Test func theThreeDirectionsDoWhatTheySay() {
    let down = NoteMap.snapping(to: cMajor, how: .down)
    let up = NoteMap.snapping(to: cMajor, how: .up)
    #expect(down[61] == .note(60))
    #expect(up[61] == .note(62))
    #expect(down[63] == .note(62), "downward, E♭ goes to D even though E is nearer")
    #expect(up[63] == .note(64))
}

@Test func muteIsADifferentInstrumentFromSnapping() {
    let map = NoteMap.snapping(to: cMajor, how: .mute)
    #expect(map[61] == .muted)
    #expect(map[60] == .note(60), "what is in the set still plays")
}

@Test func aPentatonicLeavesWiderGaps() {
    // Five notes rather than seven, so the snapping has further to reach — and
    // this is the case where a nearest-with-ties-down rule is doing visible
    // work rather than agreeing with everything.
    let pentatonic = PitchClassSet.family(5, root: 0)   // C D E G A
    let map = NoteMap.snapping(to: pentatonic)
    #expect(map[65] == .note(64), "F is a semitone over E and a tone under G")
    #expect(map[66] == .note(67), "F♯ is nearer G")
    #expect(map[70] == .note(69), "B♭ is a semitone over A")
    #expect(map[71] == .note(72), "B is nearer the C above")
}

@Test func everyScaleFamilyProducesATotalMap() {
    // Whatever the set, every one of the 128 notes has an answer — a map with a
    // hole in it is a note that silently vanishes, which is indistinguishable
    // from a bug in whatever is upstream.
    for k in 3...8 {
        for root in 0..<12 {
            let map = NoteMap.snapping(to: PitchClassSet.family(k, root: root))
            #expect(map.destinations.count == 128, "k=\(k) root=\(root)")
            #expect(!map.destinations.contains(.muted),
                    "k=\(k) root=\(root): nearest-snapping should never need to mute")
        }
    }
}

@Test func anEmptySetIsRefusedRatherThanMutingEverything() {
    // "No scale selected" is a state a UI can be in, and answering it with
    // silence would look exactly like a broken plug-in.
    #expect(NoteMap.snapping(to: []).isIdentity)
}

@Test func aSingleNoteSetIsLegalAndSnapsEverythingToIt() {
    // One pitch class means the nearest member can be up to six semitones away,
    // which is the widest the snapping ever reaches and the case where "nearest"
    // stops being a rounding and becomes an opinion.
    let map = NoteMap.snapping(to: [0])
    #expect(map[60] == .note(60))
    #expect(map[61] == .note(60))
    #expect(map[65] == .note(60), "F is five semitones above C and seven below the next")
    // F♯ is six semitones either way — the widest tie there is — and the rule
    // says down, so 60. Written as 72 first, which is what "ties go down" reads
    // like when you are thinking about the interval rather than the pitch.
    #expect(map[66] == .note(60))
}
