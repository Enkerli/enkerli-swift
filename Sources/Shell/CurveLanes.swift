//
//  CurveLanes.swift
//  Shell
//
//  Handing the render thread a set of drawn curves.
//
//  The third capability with the same shape as the other two, and the shape is
//  the point: a plug-in decides something off the audio thread, commits it as a
//  fixed-size snapshot, and the render thread reads it without thinking.
//  `setMelody` commits notes, `setNoteMap` commits 128 bytes, and this commits
//  up to four curves. None of them lets the render thread allocate, block, or
//  ask a question whose answer is still being typed.
//
//  A lane is a `GestureCurve` from `Carrier` plus the two things that are about
//  *this plug-in's* arrangement rather than about the curve: whether it is
//  running, and which scale it quantizes to in Note mode.
//

import Foundation
import Carrier
import Kernel
import Theory

/// One drawn curve, as a plug-in holds it.
public struct CurveLane: Codable, Hashable, Sendable {
    public var curve: GestureCurve
    /// Silence this lane without erasing its curve — the difference between
    /// "not now" and "undo", which is worth a separate control.
    public var isEnabled: Bool
    /// Which pitch classes a `.note` lane folds to. Empty means chromatic.
    ///
    /// Held as a set rather than a mask because that is what `Theory` speaks and
    /// what a UI picks; the mask is derived on the way to the kernel.
    public var pitchClasses: [Int]
    /// The root the scale is relative to.
    public var root: Int

    public init(curve: GestureCurve = GestureCurve(),
                isEnabled: Bool = false,
                pitchClasses: [Int] = [],
                root: Int = 0) {
        self.curve = curve
        self.isEnabled = isEnabled
        self.pitchClasses = pitchClasses
        self.root = root
    }

    /// The 12-bit root-relative mask the kernel wants.
    ///
    /// Bit 0 is the root — leftmost = LSB, like every mask in this suite, and
    /// like DrawnQurve's own `ScaleData.h`. 0xFFF is chromatic and means no
    /// quantization at all, which is what an empty set becomes.
    ///
    /// The value worth remembering: C major is 0xAB5. 0xAD5 is Lydian, and the
    /// two have been swapped in prose five times across this suite with correct
    /// code beside them every time.
    public var scaleMask: UInt16 {
        guard !pitchClasses.isEmpty else { return 0x0FFF }
        var mask: UInt16 = 0
        for pitchClass in pitchClasses {
            let interval = ChordScales.pitchClass(pitchClass - root)
            mask |= (1 << UInt16(interval))
        }
        return mask == 0 ? 0x0FFF : mask
    }
}

extension PluginAudioUnit {

    /// How many lanes the kernel has room for.
    public static var curveLaneCount: Int { 4 }

    /// Commits a set of lanes. Lanes beyond what the kernel holds are dropped,
    /// and missing ones are silent rather than stale — `beginCurveUpdate`
    /// clears the staging set first, so a lane removed from the array stops.
    public func setCurveLanes(_ lanes: [CurveLane]) {
        kernel.beginCurveUpdate()
        for (index, lane) in lanes.prefix(Self.curveLaneCount).enumerated() {
            for (sample, value) in lane.curve.table.enumerated() {
                kernel.setCurveSample(UInt32(index), UInt32(sample), Float(value))
            }
            kernel.setCurveLane(UInt32(index),
                                lane.curve.durationSeconds,
                                Float(lane.curve.minOut),
                                Float(lane.curve.maxOut),
                                Float(lane.curve.smoothing),
                                Float(lane.curve.phaseOffset),
                                lane.scaleMask,
                                UInt8(clamping: lane.root),
                                UInt8(clamping: lane.curve.controller),
                                UInt8(clamping: lane.curve.channel),
                                UInt8(clamping: lane.curve.velocity),
                                UInt8(lane.curve.message.kernelValue),
                                lane.curve.isOneShot,
                                lane.isEnabled)
        }
        kernel.commitCurves()
    }

    /// Whether the lanes run at all. Switching it off ends any note they hold.
    public var areCurvesRunning: Bool {
        get { kernel.areCurvesEnabled() }
        set { kernel.setCurvesEnabled(newValue) }
    }

    /// Where a lane's playhead is, 0…1, or nil when it is not running.
    public func curvePhase(ofLane lane: Int) -> Double? {
        guard lane >= 0, lane < Self.curveLaneCount else { return nil }
        let phase = kernel.curvePhase(UInt32(lane))
        return phase < 0 ? nil : phase
    }
}

extension CurveMessage {
    /// The kernel's enum, which is a plain `uint8_t` across the interop
    /// boundary. Mapped explicitly rather than by `allCases` order, so
    /// reordering the Swift enum cannot silently change what a plug-in sends.
    var kernelValue: Int {
        switch self {
        case .controlChange: return 0
        case .channelPressure: return 1
        case .pitchBend: return 2
        case .note: return 3
        }
    }
}
