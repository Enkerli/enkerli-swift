//
//  NoteMap.swift
//  Shell
//
//  Where every incoming note goes, decided off the audio thread.
//
//  This is the Swift face of the kernel's transform path, and the reason it
//  exists as a type rather than as three calls is the invariant it protects.
//  PORTING.md §8: *nothing generates on the audio thread.* Three plug-ins have
//  honoured that by deciding a whole pattern off-thread and handing the kernel
//  already-decided notes. A quantizer inverts the dataflow — notes arrive from
//  outside and leave changed — and it would be easy to read that as the
//  invariant breaking.
//
//  It does not, and the distinction is worth stating once so nobody has to
//  re-derive it: **the decision is off-thread; only the lookup is on it.** A
//  `NoteMap` is 128 bytes computed here, in Swift, at whatever leisure the app
//  likes — a pitch-class set, a mode, a whole chord progression's worth of
//  reasoning if it wants. The render thread reads one byte per note-on. It
//  cannot allocate, cannot block, and cannot think.
//
//  What that buys is worth naming too: the same "one loop, not one buffer"
//  budget §8 describes for inference applies here. A map can be as expensive to
//  compute as you like, because computing it is not what the audio thread does.
//

import Foundation
import Kernel
import Theory

/// Where each of the 128 MIDI notes goes.
public struct NoteMap: Hashable, Sendable {

    /// What a note maps to, or that it is swallowed.
    public enum Destination: Hashable, Sendable {
        case note(Int)
        /// Not played at all — "only what is in the set" rather than "everything
        /// bent into it", which is a different instrument.
        case muted
    }

    /// Index is the incoming note.
    public private(set) var destinations: [Destination]

    /// The identity: every note plays itself. What an unconfigured plug-in is.
    public static let identity = NoteMap()

    public init() {
        destinations = (0..<128).map { .note($0) }
    }

    public init(destinations: [Destination]) {
        var padded = destinations.prefix(128).map { $0 }
        while padded.count < 128 { padded.append(.note(padded.count)) }
        self.destinations = padded
    }

    public subscript(note: Int) -> Destination {
        get { note >= 0 && note < 128 ? destinations[note] : .note(note) }
        set { if note >= 0 && note < 128 { destinations[note] = newValue } }
    }

    /// Whether this map would change anything. An identity map with the
    /// transform switched on is a plug-in that appears broken and is not, so a
    /// caller that wants to say so needs to be able to ask.
    public var isIdentity: Bool {
        destinations.enumerated().allSatisfy { $0.element == .note($0.offset) }
    }

    // MARK: - Building one from a pitch-class set

    /// How a note outside the set is handled.
    public enum Snap: String, CaseIterable, Sendable {
        /// To the nearest member, ties going down.
        case nearest
        /// To the nearest member at or below it.
        case down
        /// To the nearest member at or above it.
        case up
        /// Not at all — the note is swallowed.
        case mute

        public var label: String {
            switch self {
            case .nearest: return "Nearest"
            case .down: return "Down"
            case .up: return "Up"
            case .mute: return "Mute"
            }
        }
    }

    /// Snap every note to the nearest member of a pitch-class set.
    ///
    /// The set is pitch classes, so this is octave-free by construction: a note
    /// is measured against the set repeated in every octave, which is what makes
    /// "snap to C major" mean the same thing at both ends of the keyboard.
    ///
    /// Ties in `.nearest` go **down**. That is a choice and not an obvious one —
    /// a semitone either way is equally close — and it is made once here rather
    /// than differently in two places. Downward, because a line quantized upward
    /// tends to climb: every ambiguous note nudges the contour one way, and over
    /// a phrase that is audible as drift.
    public static func snapping(to pitchClasses: [Int], how: Snap = .nearest) -> NoteMap {
        let members = Set(pitchClasses.map(ChordScales.pitchClass))
        guard !members.isEmpty else { return .identity }

        var map = NoteMap()
        for note in 0..<128 {
            if members.contains(ChordScales.pitchClass(note)) {
                map[note] = .note(note)
                continue
            }
            switch how {
            case .mute:
                map[note] = .muted
            case .down:
                map[note] = nearest(from: note, in: members, downOnly: true).map(Destination.note) ?? .muted
            case .up:
                map[note] = nearest(from: note, in: members, upOnly: true).map(Destination.note) ?? .muted
            case .nearest:
                let below = nearest(from: note, in: members, downOnly: true)
                let above = nearest(from: note, in: members, upOnly: true)
                switch (below, above) {
                case (nil, nil): map[note] = .muted
                case (let b?, nil): map[note] = .note(b)
                case (nil, let a?): map[note] = .note(a)
                case (let b?, let a?):
                    // Ties down, per the note above.
                    map[note] = .note(note - b <= a - note ? b : a)
                }
            }
        }
        return map
    }

    private static func nearest(from note: Int, in members: Set<Int>,
                                downOnly: Bool = false, upOnly: Bool = false) -> Int? {
        if downOnly {
            for candidate in stride(from: note, through: 0, by: -1)
            where members.contains(ChordScales.pitchClass(candidate)) { return candidate }
            return nil
        }
        if upOnly {
            for candidate in note..<128
            where members.contains(ChordScales.pitchClass(candidate)) { return candidate }
            return nil
        }
        return nil
    }
}

extension PluginAudioUnit {

    /// Hands the kernel a map and switches the transform on.
    ///
    /// Called from the main thread whenever the decision changes — a new scale,
    /// a new snap direction, a new root. The kernel double-buffers it, so a note
    /// sounding across the change keeps the mapping it started with. That is not
    /// a nicety: without it, turning the scale dial while holding a chord leaves
    /// notes stuck in whatever synth is downstream.
    public func setNoteMap(_ map: NoteMap) {
        kernel.beginNoteMapUpdate()
        for note in 0..<128 {
            switch map[note] {
            case .note(let outgoing):
                kernel.setMappedNote(UInt8(note), UInt8(clamping: outgoing))
            case .muted:
                kernel.setMappedNote(UInt8(note), PluginDSPKernel.mutedNote())
            }
        }
        kernel.commitNoteMap()
    }

    /// Whether incoming notes are rewritten at all. Off until asked.
    public var isTransformEnabled: Bool {
        get { kernel.isTransformEnabled() }
        set { kernel.setTransformEnabled(newValue) }
    }
}
