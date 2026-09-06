//
//  GestureCurveTests.swift
//  CarrierTests
//
//  What a drawn curve is, away from anything that plays one.
//
//  There are no vectors for this. DrawnQurve's engine has never been ported to
//  another language — `apps/drawnqurve` in music-suite is a React UI talking to
//  the C++ over a bridge, not a second implementation — so there is nothing to
//  hold it against, and saying so is better than implying otherwise. What is
//  checked here is the behaviour `LaneSnapshot.hpp` documents, as properties.
//

import Foundation
import Testing
@testable import Carrier

@Test func aStrokeBecomesAFixedTable() {
    let curve = GestureCurve.fromStroke([(0, 0), (1, 1)])
    #expect(curve?.table.count == GestureCurve.sampleCount)
    #expect(curve?.table.first == 0)
    #expect(curve?.table.last == 1)
    // A straight diagonal: the middle sample is the middle value.
    #expect(abs((curve?.value(atPhase: 0.5) ?? 0) - 0.5) < 0.005)
}

@Test func oneDrawnPointIsAFlatLine() {
    // Legitimate to draw and legitimate to send — a constant is a curve.
    let curve = GestureCurve.fromStroke([(0.4, 0.7)])
    #expect(curve?.isFlat == true)
    #expect(abs((curve?.value(atPhase: 0.9) ?? 0) - 0.7) < 0.0001)
}

@Test func nothingDrawnIsNotACurve() {
    #expect(GestureCurve.fromStroke([]) == nil)
}

@Test func theTableIsEvenInTimeAcrossTheStrokeNotInDistanceAlongIt() {
    // Two points in the first tenth and one at the end: the flat run should own
    // nine tenths of the loop. Resampling by arc length would give it far less,
    // and a drawn automation curve is meant to spend time where the hand did.
    let curve = GestureCurve.fromStroke([(0, 0), (0.1, 1), (1, 1)])!
    #expect(curve.value(atPhase: 0.05) < 0.9, "still climbing early")
    #expect(curve.value(atPhase: 0.5) > 0.99, "flat for the rest")
    #expect(curve.value(atPhase: 0.95) > 0.99)
}

@Test func aLoopHasNoLastSample() {
    // Phase wraps round the table rather than running off its end: the value
    // just before 1 leads back toward the value at 0.
    let curve = GestureCurve.fromStroke([(0, 0), (1, 1)])!
    let justBefore = curve.value(atPhase: 0.999)
    let atZero = curve.value(atPhase: 0)
    #expect(justBefore > 0.9)
    #expect(atZero == 0)
    // And a phase past 1, or below 0, is the same point as its wrap.
    #expect(abs(curve.value(atPhase: 1.25) - curve.value(atPhase: 0.25)) < 1e-9)
    #expect(abs(curve.value(atPhase: -0.75) - curve.value(atPhase: 0.25)) < 1e-9)
}

@Test func aPhaseOffsetMovesTheStartingPoint() {
    var curve = GestureCurve.fromStroke([(0, 0), (1, 1)])!
    curve.phaseOffset = 0.25
    #expect(abs(curve.value(atPhase: 0) - 0.25) < 0.005)
    #expect(abs(curve.value(atPhase: 0.5) - 0.75) < 0.005)
}

@Test func theOutputWindowScalesAndCanInvert() {
    let curve = GestureCurve(table: (0..<GestureCurve.sampleCount).map {
        Double($0) / Double(GestureCurve.sampleCount - 1) })
    var narrowed = curve
    narrowed.minOut = 0.25
    narrowed.maxOut = 0.75
    #expect(abs(narrowed.ranged(atPhase: 0) - 0.25) < 0.001)
    #expect(abs(narrowed.ranged(atPhase: 1) - 0.25) < 0.001, "phase 1 wraps to 0")
    #expect(abs(narrowed.ranged(atPhase: 0.5) - 0.5) < 0.005)

    // Inverted bounds play it upside down, which is a real thing to want.
    var flipped = curve
    flipped.minOut = 1
    flipped.maxOut = 0
    #expect(abs(flipped.ranged(atPhase: 0) - 1) < 0.001)
    #expect(abs(flipped.ranged(atPhase: 0.5) - 0.5) < 0.005)
}

@Test func aTableOfAnotherLengthIsResampledRatherThanRefused() {
    // A curve saved by another build, or handed over by another plug-in, is
    // worth reading.
    let coarse = GestureCurve(table: [0, 1, 0])
    #expect(coarse.table.count == GestureCurve.sampleCount)
    #expect(abs(coarse.value(atPhase: 0.5) - 1) < 0.01, "the peak survives")
    #expect(coarse.value(atPhase: 0) < 0.01)
}

@Test func everythingIsClampedIntoRange() {
    let wild = GestureCurve(table: [-5, 5, 0.5], controller: 999, channel: -3,
                            velocity: 0, phaseOffset: 3.25)
    #expect(wild.table.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(wild.controller == 127)
    #expect(wild.channel == 0)
    #expect(wild.velocity == 1)
    #expect(abs(wild.phaseOffset - 0.25) < 1e-9, "a phase offset is its fraction")
}

@Test func aCurveRoundTripsThroughJSON() {
    var curve = GestureCurve.fromStroke([(0, 0.2), (0.5, 0.9), (1, 0.1)],
                                        durationSeconds: 2.5)!
    curve.message = .pitchBend
    curve.smoothing = 0.3
    curve.isOneShot = true
    let restored = try! JSONDecoder().decode(
        GestureCurve.self, from: try! JSONEncoder().encode(curve))
    #expect(restored == curve)
}
