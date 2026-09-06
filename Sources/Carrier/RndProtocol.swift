//
//  RndProtocol.swift
//  Carrier
//
//  The Cymaforma RND Synth's wire protocol, ported from `rnd-companion`'s
//  `Source/Protocol/RndProtocol.{h,cpp}`.
//
//  In `Carrier` rather than in a plug-in because two plug-ins need it — the
//  probe and the companion — and because it is exactly what this layer is for:
//  it deals in material and its representation, it has no I/O, and it knows
//  nothing about an audio unit.
//
//  Every device frame is  F0 6F 62 78 <cmd> [payload…] F7. The three bytes
//  6F 62 78 are ASCII "obx", used as a manufacturer tag. 0x6F is inside the
//  MMA-allocated single-byte manufacturer range rather than the 0x7D
//  non-commercial slot, so the tag alone does not prove the sender is an RND —
//  match the port name too before trusting a frame.
//
//  **The vocabulary here is observed, not published.** It comes from the Seed
//  Lab web app's client code and from a capture taken off real hardware. A
//  firmware update can invalidate any of it. `rnd-companion/docs/PROTOCOL.md`
//  records what is confirmed and what is inferred, and that distinction is the
//  most important thing in this file: nothing here should be presented to a user
//  as certain.
//
//  The seed's five-septet packing is **leftmost = LSB**, which is the suite's
//  convention throughout — the same rule that makes the first step of a rhythm
//  bit 0 and C the low bit of a pitch-class set. See music-suite/CONVENTIONS.md.
//  That the device already agreed is a coincidence and a convenient one.
//

import Foundation

public enum RND {

    // MARK: - Framing

    public static let sysExBegin: UInt8 = 0xF0
    public static let sysExEnd: UInt8 = 0xF7
    public static let manufacturerTag: [UInt8] = [0x6F, 0x62, 0x78]

    public enum Command: UInt8, Sendable {
        /// Both directions: the 32-bit patch seed.
        case seed = 0x10
        /// Host→device: play-lock = payload[0], then dump status.
        case unlock = 0x11
        /// Device→host: empty payload, precedes globals and engines.
        case dumpBegin = 0x20
        /// Device→host: patch mode, tempo, tonic, scale.
        case globals = 0x21
        /// Device→host: one per track, carries the engine name.
        case trackEngine = 0x22
    }

    // MARK: - Seeds

    /// A 32-bit seed travels as five 7-bit bytes, least-significant septet
    /// first. The fifth carries only the top nibble.
    public static func packSeed(_ seed: UInt32) -> [UInt8] {
        [UInt8(seed & 0x7F),
         UInt8((seed >> 7) & 0x7F),
         UInt8((seed >> 14) & 0x7F),
         UInt8((seed >> 21) & 0x7F),
         UInt8((seed >> 28) & 0x0F)]
    }

    public static func unpackSeed(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 5 else { return 0 }
        return UInt32(bytes[0] & 0x7F)
            | (UInt32(bytes[1] & 0x7F) << 7)
            | (UInt32(bytes[2] & 0x7F) << 14)
            | (UInt32(bytes[3] & 0x7F) << 21)
            | (UInt32(bytes[4] & 0x0F) << 28)
    }

    /// "0x0123abcd" — the form the device's seeds are usually written in.
    public static func formatSeed(_ seed: UInt32) -> String {
        String(format: "0x%08x", seed)
    }

    /// Accepts "0x1234abcd", bare hex, or a decimal integer.
    ///
    /// Bare hex is only assumed when the string cannot be a plausible decimal,
    /// so typing "125" means 125 rather than 0x125. Returns nil rather than
    /// throwing, so a text field can validate as you type.
    public static func parseSeed(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        if let decimal = UInt32(trimmed, radix: 10) { return decimal }
        return UInt32(trimmed, radix: 16)
    }

    // MARK: - Decoded messages

    public struct Globals: Hashable, Sendable {
        public var patchMode: UInt8
        /// 14-bit, low septet first. See the caveat at the bottom of this file.
        public var tempoBPM: UInt16
        /// Pitch class, 0–11.
        public var tonic: UInt8
        /// 0–19, indexes `scaleName`.
        public var scaleIndex: UInt8

        public init(patchMode: UInt8, tempoBPM: UInt16, tonic: UInt8, scaleIndex: UInt8) {
            self.patchMode = patchMode
            self.tempoBPM = tempoBPM
            self.tonic = tonic
            self.scaleIndex = scaleIndex
        }
    }

    public struct TrackEngine: Hashable, Sendable {
        public var index: UInt8
        public var name: String
        /// Observed 0x00 and 0x01. Purpose unknown; Seed Lab skips both, and so
        /// does this — kept in the decode so a future capture can look at them.
        public var unknownA: UInt8
        public var unknownB: UInt8

        public init(index: UInt8, name: String, unknownA: UInt8 = 0, unknownB: UInt8 = 0) {
            self.index = index
            self.name = name
            self.unknownA = unknownA
            self.unknownB = unknownB
        }
    }

    public enum Message: Hashable, Sendable {
        case seed(UInt32)
        case dumpBegin
        case globals(Globals)
        case trackEngine(TrackEngine)
    }

    // MARK: - Decoding

    /// Skips an optional leading F0 and an optional trailing F7.
    ///
    /// Both are optional because hosts and drivers disagree about whether they
    /// belong to the frame. The kernel puts them back; MIDI 1.0 has them; UMP
    /// does not. Accepting all four combinations costs four lines and removes a
    /// class of bug that only appears on one host.
    private static func body(of bytes: [UInt8]) -> ArraySlice<UInt8> {
        var slice = bytes[...]
        if slice.first == sysExBegin { slice = slice.dropFirst() }
        if slice.last == sysExEnd { slice = slice.dropLast() }
        return slice
    }

    /// True when a frame carries the RND manufacturer tag, whatever follows it.
    ///
    /// The difference between "somebody else's SysEx" and "ours, damaged", and
    /// that distinction is the whole point of the probe: a host that delivers
    /// another vendor's frame intact has proved it passes SysEx, while one that
    /// delivers ours broken has proved the opposite.
    public static func hasManufacturerTag(_ bytes: [UInt8]) -> Bool {
        let slice = body(of: bytes)
        guard slice.count >= manufacturerTag.count else { return false }
        return Array(slice.prefix(manufacturerTag.count)) == manufacturerTag
    }

    /// Decodes one complete frame, or nil.
    ///
    /// Nil means: wrong tag, unknown command, truncated payload. Never partially
    /// applies and never throws.
    public static func parse(_ bytes: [UInt8]) -> Message? {
        let slice = body(of: bytes)
        guard slice.count >= manufacturerTag.count + 1 else { return nil }
        let content = Array(slice)
        guard Array(content.prefix(manufacturerTag.count)) == manufacturerTag else { return nil }
        guard let command = Command(rawValue: content[manufacturerTag.count]) else { return nil }
        let payload = Array(content.dropFirst(manufacturerTag.count + 1))

        switch command {
        case .seed:
            guard payload.count >= 5 else { return nil }
            return .seed(unpackSeed(payload))

        case .dumpBegin:
            guard payload.isEmpty else { return nil }
            return .dumpBegin

        case .globals:
            guard payload.count >= 5 else { return nil }
            return .globals(Globals(patchMode: payload[0],
                                    tempoBPM: UInt16(payload[1] & 0x7F)
                                            | (UInt16(payload[2] & 0x7F) << 7),
                                    tonic: payload[3],
                                    scaleIndex: payload[4]))

        case .trackEngine:
            guard payload.count >= 3 else { return nil }
            let nameBytes = payload.dropFirst(3).prefix { $0 != 0 }
            return .trackEngine(TrackEngine(index: payload[0],
                                            name: String(decoding: nameBytes, as: UTF8.self),
                                            unknownA: payload[1],
                                            unknownB: payload[2]))

        case .unlock:
            // Host→device only. Seeing it means watching our own output echoed
            // back, which is not an error but carries no device state.
            return nil
        }
    }

    /// A label for a frame that is not ours. Empty when it is.
    public static func describeForeign(_ bytes: [UInt8]) -> String {
        if hasManufacturerTag(bytes) { return "" }
        let slice = body(of: bytes)
        guard let first = slice.first else { return "empty SysEx" }
        switch first {
        case 0x7E: return "universal non-real-time SysEx"
        case 0x7F: return "universal real-time SysEx"
        case 0x7D: return "non-commercial SysEx"
        default: return String(format: "manufacturer 0x%02X SysEx", first)
        }
    }

    // MARK: - Encoding

    private static func frame(_ command: Command, _ payload: [UInt8]) -> [UInt8] {
        [sysExBegin] + manufacturerTag + [command.rawValue] + payload + [sysExEnd]
    }

    /// Loads a seed on the device.
    public static func seedMessage(_ seed: UInt32) -> [UInt8] {
        frame(.seed, packSeed(seed))
    }

    /// Clears the play-lock and asks for a status dump.
    ///
    /// The only known way to poll the device, and it costs a brief audible mute
    /// — so drive it from an explicit user action, never from a timer. It is not
    /// needed to follow the seed: the RND broadcasts an unsolicited seed frame
    /// whenever its seed changes, which is silent and free.
    public static func unlockAndDump() -> [UInt8] {
        frame(.unlock, [0x00])
    }

    // MARK: - The control-change layer

    public enum CC {
        public static let scale: UInt8 = 9
        public static let volume: UInt8 = 7
        public static let reverb: UInt8 = 91
    }

    public static let masterChannel = 1
    public static let maxTracks = 4
    public static let numScales = 20
    public static let numTonics = 12

    /// The channel carrying one track's own volume. Track indices are 0-based to
    /// match the device's 0x22 frames; the channels are 2–5.
    public static func trackChannel(_ trackIndex: Int) -> Int { 2 + trackIndex }

    /// The device splits CC9's 0–127 range into 20 scale bands. This is the
    /// midpoint of a band, which is what you send to select one reliably.
    ///
    /// Equivalent to floor(3.2 + 6.4 * index), and the table is authoritative
    /// rather than the formula — mirrored from Seed Lab.
    private static let scaleCCMidpoints: [UInt8] = [
        3, 9, 16, 22, 28, 35, 41, 48, 54, 60, 67, 73, 80, 86, 92, 99, 105, 112, 118, 124
    ]

    public static func scaleCCValue(_ scaleIndex: Int) -> UInt8 {
        guard scaleIndex >= 0 && scaleIndex < numScales else { return scaleCCMidpoints[0] }
        return scaleCCMidpoints[scaleIndex]
    }

    public static func scaleIndex(forCC value: UInt8) -> Int {
        min(Int(value & 0x7F) * numScales / 128, numScales - 1)
    }

    /// Tonic is set by pulsing a note on channel 1, not by a CC.
    public static let tonicNoteBase = 60

    public static func tonicNote(_ pitchClass: Int) -> Int {
        tonicNoteBase + ((pitchClass % numTonics) + numTonics) % numTonics
    }

    /// Scale and tonic *lock* on the hardware once set: the same seed then
    /// produces different engines, and only a power cycle is known to clear it.
    /// Nothing in the observed vocabulary clears the lock — `unlock` (0x11 0x00)
    /// addresses the play-lock, which appears to be a different thing.
    public static let scaleAndTonicLockOnDevice = true

    // MARK: - Names

    /// Chromatic names, deliberately. A tonic byte arrives as a bare pitch class
    /// with no chord or scale to spell it from, and the suite convention says
    /// bare pitch-class data stays chromatic. Do not "fix" this toward
    /// structural spelling — see music-suite/CONVENTIONS.md.
    private static let tonicNames = ["C", "C#", "D", "D#", "E", "F",
                                     "F#", "G", "G#", "A", "A#", "B"]

    /// Index order is the device's, mirrored from Seed Lab's table.
    private static let scaleNames = [
        "major", "minor", "harmonic minor", "blues", "major pentatonic",
        "minor pentatonic", "dorian", "phrygian", "lydian", "mixolydian",
        "locrian", "whole tone", "double harmonic", "hungarian minor",
        "phrygian dominant", "hirajoshi", "insen", "prometheus",
        "octatonic (WT/HT)", "persian"
    ]

    public static func tonicName(_ pitchClass: Int) -> String {
        guard pitchClass >= 0 && pitchClass < numTonics else { return "?" }
        return tonicNames[pitchClass]
    }

    public static func scaleName(_ scaleIndex: Int) -> String {
        guard scaleIndex >= 0 && scaleIndex < numScales else { return "?" }
        return scaleNames[scaleIndex]
    }
}

// MARK: - Commands

/// Every outbound action as plain MIDI bytes.
///
/// Ported from `rnd-companion`'s `RndCommands`, which exists because there are
/// two ways to reach the device and they need identical bytes — the plug-in's
/// host stream, or a port the app opens itself. Building the messages in one
/// place is what keeps "send a seed" meaning the same thing in both.
///
/// Everything is a `[UInt8]` that `PluginAudioUnit.sendBurst` accepts directly:
/// a leading `F0` is a SysEx frame, anything else a short channel message. The
/// device needs all three kinds — seed over SysEx, scale over CC, tonic as a
/// note — which is why the burst carries messages rather than only SysEx.
///
/// Channel numbers here are **1-based**, as MIDI channels are spoken about, and
/// converted at the one place that builds a status byte.
public enum RndCommand {

    /// A status byte from a 1-based channel.
    private static func status(_ kind: UInt8, channel: Int) -> UInt8 {
        (kind << 4) | UInt8((max(1, channel) - 1) & 0x0F)
    }

    public static func controlChange(channel: Int, controller: UInt8, value: Int) -> [UInt8] {
        [status(0xB, channel: channel), controller & 0x7F, UInt8(max(0, min(127, value)))]
    }

    public static func noteOn(channel: Int, note: Int, velocity: Int = 100) -> [UInt8] {
        [status(0x9, channel: channel), UInt8(max(0, min(127, note))),
         UInt8(max(0, min(127, velocity)))]
    }

    public static func noteOff(channel: Int, note: Int) -> [UInt8] {
        [status(0x8, channel: channel), UInt8(max(0, min(127, note))), 0]
    }

    /// Loads a seed.
    public static func seed(_ value: UInt32) -> [[UInt8]] {
        [RND.seedMessage(value)]
    }

    /// Clears the play-lock and asks for a dump. **Audible: a brief mute.**
    /// Drive it from an explicit user action, never from a timer.
    public static func unlockAndDump() -> [[UInt8]] {
        [RND.unlockAndDump()]
    }

    /// Selects a scale band on CC9. Locks on the hardware — see
    /// `RND.scaleAndTonicLockOnDevice`.
    public static func scale(_ scaleIndex: Int) -> [[UInt8]] {
        [controlChange(channel: RND.masterChannel,
                       controller: RND.CC.scale,
                       value: Int(RND.scaleCCValue(scaleIndex)))]
    }

    /// Pulses a note on channel 1. Also locks.
    ///
    /// The note-off is a *separate message in the same burst*, which is a
    /// difference from the JUCE version worth naming: that one carried a
    /// millisecond delay per message and a transport that honoured it. Here both
    /// messages leave in the same render block, so the pulse is as short as a
    /// buffer. Whether the device needs a longer gate is unknown and untested —
    /// if it turns out to, that is a delay the burst does not currently express.
    public static func tonic(_ pitchClass: Int) -> [[UInt8]] {
        let note = RND.tonicNote(pitchClass)
        return [noteOn(channel: RND.masterChannel, note: note),
                noteOff(channel: RND.masterChannel, note: note)]
    }

    /// Volume and reverb go to the master plus the per-track takeover band.
    private static func mix(_ controller: UInt8, _ value: Int) -> [[UInt8]] {
        (1...(1 + RND.maxTracks)).map {
            controlChange(channel: $0, controller: controller, value: value)
        }
    }

    public static func volume(_ value: Int) -> [[UInt8]] { mix(RND.CC.volume, value) }
    public static func reverb(_ value: Int) -> [[UInt8]] { mix(RND.CC.reverb, value) }

    /// One track's own volume, on its own channel.
    ///
    /// Muting is value 0; there is no separate mute message because the device
    /// does not need one. This is what makes a track auditionable, and it was in
    /// the protocol long before anything exposed it.
    public static func trackVolume(_ trackIndex: Int, _ value: Int) -> [[UInt8]] {
        guard trackIndex >= 0 && trackIndex < RND.maxTracks else { return [] }
        return [controlChange(channel: RND.trackChannel(trackIndex),
                              controller: RND.CC.volume, value: value)]
    }
}

// MARK: - Accumulated device state

/// Everything the device has told us about what it is currently playing.
///
/// A dump arrives as several frames in a row, so this folds them together.
/// Fields stay nil until the device actually reports them, which is the point:
/// an unsolicited seed broadcast tells you the seed and nothing else, and
/// showing a stale tempo beside a fresh seed would be a lie.
public struct RndDeviceStatus: Hashable, Sendable {
    public var seed: UInt32?
    public var patchMode: UInt8?
    public var tempoBPM: UInt16?
    public var tonic: UInt8?
    public var scaleIndex: UInt8?
    /// Sorted by track index.
    public var engines: [RND.TrackEngine] = []

    public init() {}

    public var hasSeed: Bool { seed != nil }

    /// Folds one decoded frame in.
    ///
    /// A `seed` or `dumpBegin` frame clears the engine list, because both mean a
    /// new patch is being described and the old engine names no longer apply.
    public mutating func apply(_ message: RND.Message) {
        switch message {
        case .seed(let value):
            seed = value
            engines.removeAll()
        case .dumpBegin:
            engines.removeAll()
        case .globals(let globals):
            patchMode = globals.patchMode
            tempoBPM = globals.tempoBPM
            tonic = globals.tonic
            scaleIndex = globals.scaleIndex
        case .trackEngine(let engine):
            if let existing = engines.firstIndex(where: { $0.index == engine.index }) {
                engines[existing] = engine
            } else {
                engines.append(engine)
            }
            engines.sort { $0.index < $1.index }
        }
    }

    public mutating func clear() { self = RndDeviceStatus() }
}

// The tempo field is reported in BPM and Seed Lab treats it as such, but a
// capture at 125 BPM had a note grid whose pulse does not divide evenly into
// that tempo (roughly a 4:5 relationship). Treat `tempoBPM` as "what the device
// says" and calibrate before driving MIDI clock from it.
