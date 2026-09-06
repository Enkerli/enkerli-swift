//
//  GestureCurve.swift
//  Carrier
//
//  A drawn line, as something a plug-in can loop.
//
//  Ported from `Source/Engine/LaneSnapshot.hpp` in
//  [DrawnQurve](https://github.com/Enkerli/DrawnQurve), whose header already
//  says the important thing: "No JUCE headers are included here so the engine
//  can be unit-tested stand-alone." That file was written as plain data on
//  purpose, and this is that decision paying off in a second framework.
//
//  A curve is **256 normalised samples and the rules for performing them**. Not
//  the points somebody drew: those are input, they arrive at whatever rate a
//  finger and a screen agree on, and they are resampled here once, off the
//  audio thread, into a table the render thread can index without thinking.
//  Everything downstream — smoothing, ranging, quantizing, mapping to MIDI —
//  reads that table.
//
//  It is carrier rather than app for the same reason `MelodyPattern` is: it is
//  what one plug-in would hand another. A curve is an envelope, and an envelope
//  is not specific to drawing one — MelGen could perform a take's velocity from
//  a curve, and neither plug-in has to know the other exists.
//

import Foundation

/// What a curve's value is sent as.
public enum CurveMessage: String, Codable, Hashable, Sendable, CaseIterable {
    /// Control change. `controller` says which.
    case controlChange
    /// Channel pressure — one data byte, no controller number.
    case channelPressure
    /// Pitch bend, 14-bit, centred at 8192.
    case pitchBend
    /// Note on/off, the value read as a pitch.
    case note

    public var label: String {
        switch self {
        case .controlChange: return "CC"
        case .channelPressure: return "Pressure"
        case .pitchBend: return "Bend"
        case .note: return "Note"
        }
    }

    /// Whether the value is a pitch, which is the only case a scale applies to.
    public var isPitched: Bool { self == .note }
}

/// A drawn line and how to perform it.
public struct GestureCurve: Codable, Hashable, Sendable {

    /// Always this many. A fixed table is what lets the render thread index it
    /// with no bounds decision and no allocation, and 256 is DrawnQurve's own
    /// number — fine enough that interpolation is inaudible at any loop length
    /// a finger can draw.
    public static let sampleCount = 256

    /// Normalised samples, 0 at the bottom of the drawn area and 1 at the top.
    public private(set) var table: [Double]

    /// How long the gesture took. The loop's length at 1× speed.
    public var durationSeconds: Double

    public var message: CurveMessage
    /// Which controller, in `.controlChange`. 74 is filter cutoff by convention
    /// and is DrawnQurve's default.
    public var controller: Int
    /// 0-indexed, so 0 is channel 1.
    public var channel: Int

    /// The window the normalised value is mapped into, as fractions of the
    /// message's full range. Inverting them (min above max) is legal and means
    /// the curve plays upside down — which is a real thing to want and costs
    /// nothing to allow.
    public var minOut: Double
    public var maxOut: Double

    /// One-pole coefficient, 0 = off. Applied per emitted value, so its effect
    /// depends on how often the lane emits — which is DrawnQurve's behaviour
    /// and worth knowing rather than being surprised by.
    public var smoothing: Double

    /// Velocity in `.note`.
    public var velocity: Int

    /// Where in the table the loop starts, 0..<1.
    public var phaseOffset: Double

    /// Play once and stop, rather than looping.
    public var isOneShot: Bool

    public init(table: [Double] = Array(repeating: 0.5, count: GestureCurve.sampleCount),
                durationSeconds: Double = 1,
                message: CurveMessage = .controlChange,
                controller: Int = 74,
                channel: Int = 0,
                minOut: Double = 0,
                maxOut: Double = 1,
                smoothing: Double = 0.08,
                velocity: Int = 100,
                phaseOffset: Double = 0,
                isOneShot: Bool = false) {
        self.table = GestureCurve.resized(table)
        self.durationSeconds = max(0.01, durationSeconds)
        self.message = message
        self.controller = min(127, max(0, controller))
        self.channel = min(15, max(0, channel))
        self.minOut = min(1, max(0, minOut))
        self.maxOut = min(1, max(0, maxOut))
        self.smoothing = min(0.99, max(0, smoothing))
        self.velocity = min(127, max(1, velocity))
        self.phaseOffset = phaseOffset - phaseOffset.rounded(.down)
        self.isOneShot = isOneShot
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(table: try c.decodeIfPresent([Double].self, forKey: .table) ?? [],
                  durationSeconds: try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 1,
                  message: try c.decodeIfPresent(CurveMessage.self, forKey: .message) ?? .controlChange,
                  controller: try c.decodeIfPresent(Int.self, forKey: .controller) ?? 74,
                  channel: try c.decodeIfPresent(Int.self, forKey: .channel) ?? 0,
                  minOut: try c.decodeIfPresent(Double.self, forKey: .minOut) ?? 0,
                  maxOut: try c.decodeIfPresent(Double.self, forKey: .maxOut) ?? 1,
                  smoothing: try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.08,
                  velocity: try c.decodeIfPresent(Int.self, forKey: .velocity) ?? 100,
                  phaseOffset: try c.decodeIfPresent(Double.self, forKey: .phaseOffset) ?? 0,
                  isOneShot: try c.decodeIfPresent(Bool.self, forKey: .isOneShot) ?? false)
    }

    // MARK: - Drawing one

    /// Resamples a drawn stroke into the fixed table.
    ///
    /// Points arrive at whatever rate a finger and a screen agree on — bunched
    /// where the hand slowed, sparse where it moved — and the table is evenly
    /// spaced in *time across the stroke*, not in distance along it. Drawing
    /// slowly through the middle therefore spends more of the loop there, which
    /// is what a drawn automation curve should do and is not what an
    /// arc-length resampling would give you.
    ///
    /// - Parameter points: `(x, y)` with x increasing, both normalised 0…1.
    ///   Out-of-order or duplicate x values are tolerated; y is clamped.
    public static func fromStroke(_ points: [(x: Double, y: Double)],
                                  durationSeconds: Double = 1) -> GestureCurve? {
        let cleaned = points
            .map { (x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
            .sorted { $0.x < $1.x }
        guard cleaned.count >= 2 else {
            // One point is a flat line at that height, which is a legitimate
            // thing to draw and a legitimate thing to send.
            guard let only = cleaned.first else { return nil }
            return GestureCurve(table: Array(repeating: only.y, count: sampleCount),
                                durationSeconds: durationSeconds)
        }

        var table = [Double](repeating: 0, count: sampleCount)
        var cursor = 0
        for index in 0..<sampleCount {
            let x = Double(index) / Double(sampleCount - 1)
            while cursor + 2 < cleaned.count, cleaned[cursor + 1].x < x { cursor += 1 }
            let a = cleaned[cursor]
            let b = cleaned[min(cursor + 1, cleaned.count - 1)]
            let span = b.x - a.x
            table[index] = span <= 0 ? b.y : a.y + (b.y - a.y) * ((x - a.x) / span)
        }
        return GestureCurve(table: table, durationSeconds: durationSeconds)
    }

    static func resized(_ values: [Double]) -> [Double] {
        guard !values.isEmpty else {
            return Array(repeating: 0.5, count: sampleCount)
        }
        guard values.count != sampleCount else {
            return values.map { min(1, max(0, $0)) }
        }
        // A table of another length is resampled rather than refused: a curve
        // saved by another build, or handed over by another plug-in, is worth
        // reading.
        return (0..<sampleCount).map { index in
            let position = Double(index) * Double(values.count - 1) / Double(sampleCount - 1)
            let low = Int(position)
            let high = min(low + 1, values.count - 1)
            let fraction = position - Double(low)
            return min(1, max(0, values[low] + (values[high] - values[low]) * fraction))
        }
    }

    // MARK: - Reading one

    /// The curve at a phase in 0…1, wrapping, with `phaseOffset` applied.
    ///
    /// Linear interpolation between adjacent samples, and the wrap is round the
    /// table rather than off its end — a loop has no last sample, it has a
    /// sample that leads back to the first.
    public func value(atPhase phase: Double) -> Double {
        let wrapped = (phase + phaseOffset).truncatingRemainder(dividingBy: 1)
        let normalised = wrapped < 0 ? wrapped + 1 : wrapped
        let position = normalised * Double(Self.sampleCount - 1)
        let low = Int(position)
        let high = (low + 1) % Self.sampleCount
        let fraction = position - Double(low)
        return table[low] + (table[high] - table[low]) * fraction
    }

    /// The value mapped into the output window, still normalised 0…1.
    public func ranged(atPhase phase: Double) -> Double {
        let raw = value(atPhase: phase)
        return minOut + (maxOut - minOut) * raw
    }

    /// Where the curve is flat, which is what a "nothing drawn yet" check wants.
    public var isFlat: Bool {
        guard let first = table.first else { return true }
        return table.allSatisfy { abs($0 - first) < 0.0005 }
    }
}
