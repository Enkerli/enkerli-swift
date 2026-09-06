//
//  CurveLaneTests.swift
//  ShellTests
//
//  The mask a lane hands the kernel — which is the one number in this path
//  that has a documented history of being written down backwards.
//

import Foundation
import Testing
@testable import Shell
import Carrier
import Theory

@Test func noScaleIsChromatic() {
    #expect(CurveLane().scaleMask == 0x0FFF)
    #expect(CurveLane(pitchClasses: []).scaleMask == 0x0FFF)
}

@Test func cMajorIs0xAB5() {
    // The value this suite has written down wrong five times, in five files,
    // always with correct code beside it. 0xAD5 is Lydian.
    let lane = CurveLane(pitchClasses: [0, 2, 4, 5, 7, 9, 11], root: 0)
    #expect(lane.scaleMask == 0xAB5)
    #expect(CurveLane(pitchClasses: [0, 2, 4, 6, 7, 9, 11], root: 0).scaleMask == 0xAD5,
            "Lydian — the one it keeps being confused with")
}

@Test func theMaskIsRootRelative() {
    // G major has the same shape as C major, so the same mask: the root is
    // carried separately and the mask says intervals, not pitch classes.
    let c = CurveLane(pitchClasses: PitchClassSet.family(7, root: 0), root: 0)
    let g = CurveLane(pitchClasses: PitchClassSet.family(7, root: 7), root: 7)
    #expect(c.scaleMask == g.scaleMask)
    #expect(c.scaleMask == 0xAB5)
}

@Test func bitZeroIsTheRoot() {
    // Stated as its own case because it is the convention, and because a port
    // that reversed it would still pass a test that only checked whole scales
    // whose masks happen to be near-palindromic.
    #expect(CurveLane(pitchClasses: [0], root: 0).scaleMask == 0b0000_0000_0001)
    #expect(CurveLane(pitchClasses: [11], root: 0).scaleMask == 0b1000_0000_0000)
    #expect(CurveLane(pitchClasses: [1], root: 0).scaleMask == 0b0000_0000_0010)
}

@Test func aScaleFamilyRoundTripsThroughTheMask() {
    for k in 3...8 {
        for root in 0..<12 {
            let lane = CurveLane(pitchClasses: PitchClassSet.family(k, root: root), root: root)
            let intervals = (0..<12).filter { lane.scaleMask >> UInt16($0) & 1 == 1 }
            let expected = Set(PitchClassSet.family(k, root: root)
                .map { ChordScales.pitchClass($0 - root) }).sorted()
            #expect(intervals == expected, "k=\(k) root=\(root)")
        }
    }
}

@Test func aLaneRoundTripsThroughJSON() {
    var lane = CurveLane(curve: GestureCurve.fromPoints([(0, 0), (0.5, 1), (1, 0)])!,
                         isEnabled: true,
                         pitchClasses: [0, 3, 7],
                         root: 2)
    lane.curve.message = .note
    let restored = try! JSONDecoder().decode(
        CurveLane.self, from: try! JSONEncoder().encode(lane))
    #expect(restored == lane)
    #expect(restored.scaleMask == lane.scaleMask)
}
