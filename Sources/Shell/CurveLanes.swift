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

    /// What the pen was pressing while the line was drawn, when the input
    /// reported it.
    ///
    /// A companion rather than a second lane, because it is not a second
    /// gesture: it shares this lane's time base exactly, and separating them
    /// into unrelated lanes would let a later edit break the alignment that is
    /// the whole reason to record it.
    public var pressure: GestureCurve?
    /// Whether the companion plays. Separate from `isEnabled`, so pressure can
    /// be muted without muting the line it came from.
    public var isPressureEnabled: Bool

    public init(curve: GestureCurve = GestureCurve(),
                isEnabled: Bool = false,
                pitchClasses: [Int] = [],
                root: Int = 0,
                pressure: GestureCurve? = nil,
                isPressureEnabled: Bool = false) {
        self.curve = curve
        self.isEnabled = isEnabled
        self.pitchClasses = pitchClasses
        self.root = root
        self.pressure = pressure
        self.isPressureEnabled = isPressureEnabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(curve: try c.decodeIfPresent(GestureCurve.self, forKey: .curve) ?? GestureCurve(),
                  isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
                  pitchClasses: try c.decodeIfPresent([Int].self, forKey: .pitchClasses) ?? [],
                  root: try c.decodeIfPresent(Int.self, forKey: .root) ?? 0,
                  pressure: try c.decodeIfPresent(GestureCurve.self, forKey: .pressure),
                  isPressureEnabled: try c.decodeIfPresent(Bool.self, forKey: .isPressureEnabled) ?? false)
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

    /// How many curve slots the kernel has. A drawn lane uses two — the line
    /// and its pressure companion — so this is twice the number of lanes a
    /// plug-in can show.
    public static var curveLaneCount: Int { 8 }
    public static var drawnLaneCount: Int { curveLaneCount / 2 }

    /// Commits a set of lanes. Lanes beyond what the kernel holds are dropped,
    /// and missing ones are silent rather than stale — `beginCurveUpdate`
    /// clears the staging set first, so a lane removed from the array stops.
    public func setCurveLanes(_ lanes: [CurveLane]) {
        kernel.beginCurveUpdate()
        // Each lane takes two kernel slots: the line at 2n, its pressure
        // companion at 2n+1. Paired rather than packed, so a lane's slot is a
        // function of its index alone — a packed layout would move every lane
        // after the one whose pressure was just removed, and the render thread
        // would be told about it one atomic store later.
        let usable = lanes.prefix(Self.curveLaneCount / 2)
        for (index, lane) in usable.enumerated() {
            commit(lane.curve, at: UInt32(index * 2), lane: lane, enabled: lane.isEnabled)
            if let pressure = lane.pressure {
                commit(pressure, at: UInt32(index * 2 + 1), lane: lane,
                       enabled: lane.isEnabled && lane.isPressureEnabled)
            }
        }
        kernel.commitCurves()
    }

    private func commit(_ curve: GestureCurve, at slot: UInt32,
                        lane: CurveLane, enabled: Bool) {
        for (sample, value) in curve.table.enumerated() {
            kernel.setCurveSample(slot, UInt32(sample), Float(value))
        }
        kernel.setCurveLane(slot,
                            curve.durationSeconds,
                            Float(curve.minOut),
                            Float(curve.maxOut),
                            Float(curve.smoothing),
                            Float(curve.phaseOffset),
                            lane.scaleMask,
                            UInt8(clamping: lane.root),
                            UInt8(clamping: curve.controller),
                            UInt8(clamping: curve.channel),
                            UInt8(clamping: curve.velocity),
                            UInt8(curve.message.kernelValue),
                            curve.isOneShot,
                            enabled)
    }

    /// Whether the lanes run at all. Switching it off ends any note they hold.
    public var areCurvesRunning: Bool {
        get { kernel.areCurvesEnabled() }
        set { kernel.setCurvesEnabled(newValue) }
    }

    /// Where a drawn lane's playhead is, 0…1, or nil when it is not running.
    ///
    /// The line's, not its companion's — they share a phase by construction, so
    /// there is only one answer and asking for the other would invite them to
    /// drift in somebody's mental model.
    public func curvePhase(ofLane lane: Int) -> Double? {
        guard lane >= 0, lane < Self.drawnLaneCount else { return nil }
        let phase = kernel.curvePhase(UInt32(lane * 2))
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
