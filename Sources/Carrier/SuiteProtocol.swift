//
//  SuiteProtocol.swift
//  Carrier
//
//  The suite's live message protocol, ported from `@enkerli/protocol`.
//
//  A versioned JSON envelope carried over MIDI SysEx. SysEx is the deliberately
//  boring transport: these are MIDI plug-ins, so messages ride ordinary MIDI
//  routing — web app to web app over an IAC bus, web to plug-in and plug-in to
//  plug-in through host MIDI routing.
//
//  **This is why the port was worth doing, and why the earlier argument against
//  a Swift Workspace was wrong.** That argument looked at `modules.js` — 2,223
//  lines importing a dozen monorepo packages — concluded the product was the web
//  app, and stopped. Underneath it is *this*: a small package with committed
//  byte-exact vectors, whose own header says the vectors are "the cross-language
//  contract for that C++ side, exactly like @enkerli/theory's rhythm vectors."
//  It is the same mistake as Vane, at a different layer: looking at the wrong
//  thing and generalising from it.
//
//  And the transport was already here. The kernel grew SysEx in and out for the
//  RND companion, frames included; this rides the same burst and the same ring.
//
//  Frame layout, every data byte 7-bit clean:
//
//      F0 7D 'E' 'K' <ver> | msgId(2x7) | chunkIndex(2x7) | chunkTotal(2x7)
//      | payload, 7-in-8 packed | F7
//
//  0x7D is the MIDI manufacturer id reserved for non-commercial use — unlike the
//  RND's 0x6F, which is a real allocation and therefore proves nothing about the
//  sender on its own.
//
//  Masks are **leftmost = LSB** throughout, which is the suite convention
//  everywhere: C major = 0xAB5 = 2741, tresillo over 8 steps = 73. Masks are
//  numbers here; hex-digit display conventions stay in the app.
//

import Foundation

public enum SuiteProtocol {

    public static let name = "enkerli-suite"
    public static let version = 1

    /// The app vocabulary, from `@enkerli/library`. One authority for who can
    /// send and who can be addressed — a message from an app not in this list is
    /// invalid, which is what keeps the plane's membership a decision rather
    /// than a typo.
    public static let apps = [
        "proggenie", "midicurator", "serpe", "vane", "drawnqurve",
        "pitchfold", "exquisite-fingerings", "pickpcs", "chord-dictionary",
        "drums", "rnd-companion", "external",
    ]

    public static let messageTypes = [
        // data-sharing
        "scale", "chord", "progression", "pattern",
        // control and interop plane
        "manifest", "param", "command",
        // performance: what actually sounds
        "note",
    ]

    // MARK: - Framing constants

    public static let sysExStart: UInt8 = 0xF0
    public static let sysExEnd: UInt8 = 0xF7
    /// Reserved for non-commercial and educational use.
    public static let manufacturerID: UInt8 = 0x7D
    /// "E" "K", both 7-bit clean.
    public static let tag: [UInt8] = [0x45, 0x4B]
    static let headerLength = 11

    /// Raw payload bytes per frame before packing. 720 raw becomes 823 packed
    /// and an 834-byte frame — comfortably under the 1 KB that hosts and drivers
    /// commonly cap SysEx at.
    public static let defaultChunkBytes = 720

    // MARK: - Packing

    /// Pack arbitrary bytes into 7-bit-clean groups: each group of up to seven
    /// input bytes becomes one MSB byte (bit i is input byte i's high bit)
    /// followed by the seven-bit remainders.
    ///
    /// The classic SysEx packing. It is what lets the payload be UTF-8 JSON —
    /// without it a flat sign or a sharp would put a byte over 0x7F on the wire
    /// and end the message early.
    public static func pack7(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + (bytes.count + 6) / 7)
        var start = 0
        while start < bytes.count {
            let count = min(7, bytes.count - start)
            var msb: UInt8 = 0
            for offset in 0..<count where bytes[start + offset] & 0x80 != 0 {
                msb |= UInt8(1 << offset)
            }
            out.append(msb)
            for offset in 0..<count { out.append(bytes[start + offset] & 0x7F) }
            start += 7
        }
        return out
    }

    /// Reverse of `pack7`. Nil on a malformed stream — any byte at or above
    /// 0x80, which cannot occur inside a well-formed SysEx frame.
    public static func unpack7(_ packed: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var index = 0
        while index < packed.count {
            let msb = packed[index]
            index += 1
            if msb & 0x80 != 0 { return nil }
            let count = min(7, packed.count - index)
            for offset in 0..<count {
                let byte = packed[index + offset]
                if byte & 0x80 != 0 { return nil }
                out.append(byte | ((msb >> UInt8(offset)) & 1 != 0 ? 0x80 : 0))
            }
            index += count
        }
        return out
    }

    // MARK: - Encoding

    /// Encode a message into complete SysEx frames, `F0` and `F7` included.
    ///
    /// Nil when the message does not validate. **Never put a malformed message
    /// on the wire** — a receiver's only defence is to drop it, and a dropped
    /// message looks exactly like a routing problem.
    public static func encode(_ message: SuiteMessage,
                              chunkBytes: Int = defaultChunkBytes,
                              msgID: Int) -> [[UInt8]]? {
        guard message.validate().isEmpty else { return nil }
        let chunk = max(1, chunkBytes)
        let json = Array(message.json.serializedData())
        let total = max(1, (json.count + chunk - 1) / chunk)
        guard total <= 16383 else { return nil }
        let identifier = msgID & 0x3FFF

        var frames: [[UInt8]] = []
        for index in 0..<total {
            let start = index * chunk
            let raw = Array(json[start..<min(start + chunk, json.count)])
            var frame: [UInt8] = [sysExStart, manufacturerID, tag[0], tag[1], UInt8(version)]
            frame += fourteenBit(identifier)
            frame += fourteenBit(index)
            frame += fourteenBit(total)
            frame += pack7(raw)
            frame.append(sysExEnd)
            frames.append(frame)
        }
        return frames
    }

    static func fourteenBit(_ value: Int) -> [UInt8] {
        [UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    // MARK: - Decoding

    public struct FrameInfo: Equatable, Sendable {
        public var msgID: Int
        public var index: Int
        public var total: Int
        /// This frame's *unpacked* payload bytes.
        public var data: [UInt8]
    }

    /// Parse one SysEx frame.
    ///
    /// Nil for anything that is not a suite frame — another manufacturer,
    /// another tag, a version we do not speak. Safe to feed every SysEx byte the
    /// plug-in receives, which is exactly how it is used: the kernel's ring
    /// carries whatever arrives and this decides what was ours.
    public static func decodeFrame(_ frame: [UInt8]) -> FrameInfo? {
        guard frame.count >= headerLength + 1,
              frame.first == sysExStart, frame.last == sysExEnd,
              frame[1] == manufacturerID, frame[2] == tag[0], frame[3] == tag[1],
              frame[4] == UInt8(version) else { return nil }
        func at(_ offset: Int) -> Int { Int(frame[headerLength - 6 + offset]) }
        let msgID = (at(0) << 7) | at(1)
        let index = (at(2) << 7) | at(3)
        let total = (at(4) << 7) | at(5)
        guard total >= 1, index < total,
              let data = unpack7(Array(frame[headerLength..<(frame.count - 1)])) else {
            return nil
        }
        return FrameInfo(msgID: msgID, index: index, total: total, data: data)
    }

    /// Reassembles chunked messages, tolerant of interleaving and out-of-order
    /// arrival.
    ///
    /// Incomplete messages are evicted after `staleSeconds`, so a lost chunk
    /// cannot leak memory — which matters more here than in the web app, because
    /// a plug-in can sit in a project for a month.
    public final class Reassembler {
        private struct Pending {
            var total: Int
            var parts: [Int: [UInt8]]
            var at: Date
        }
        private var pending: [Int: Pending] = [:]
        private let staleSeconds: TimeInterval

        public init(staleSeconds: TimeInterval = 60) {
            self.staleSeconds = staleSeconds
        }

        /// The completed message, or nil while waiting — and nil for foreign
        /// SysEx, which is not an error and is most of what arrives.
        public func push(_ frame: [UInt8], now: Date = Date()) -> SuiteMessage? {
            evict(now)
            guard let info = decodeFrame(frame) else { return nil }

            var entry = pending[info.msgID]
            if entry == nil || entry!.total != info.total {
                entry = Pending(total: info.total, parts: [:], at: now)
            }
            entry!.parts[info.index] = info.data
            entry!.at = now
            guard entry!.parts.count >= entry!.total else {
                pending[info.msgID] = entry
                return nil
            }
            pending.removeValue(forKey: info.msgID)

            var bytes: [UInt8] = []
            for index in 0..<entry!.total {
                guard let part = entry!.parts[index] else { return nil }
                bytes += part
            }
            guard let value = JSONValue.parse(Data(bytes)),
                  let message = SuiteMessage(value), message.validate().isEmpty else {
                return nil
            }
            return message
        }

        private func evict(_ now: Date) {
            pending = pending.filter { now.timeIntervalSince($0.value.at) <= staleSeconds }
        }
    }
}

// MARK: - The envelope

/// One message on the plane.
///
/// The envelope is typed and the body is a `JSONValue`, which is exactly how the
/// TypeScript declares it (`body: Record<string, unknown>`) and is not laziness:
/// the body's shape depends on `type`, new types are additive within protocol
/// v1, and a receiver that does not know a type must reject it rather than
/// mangle it. Typed accessors live on the bodies, not on the envelope.
public struct SuiteMessage: Equatable, Sendable {
    public var id: String
    public var from: String
    /// An app id, or `*` for broadcast.
    public var to: String
    /// Absolute ISO 8601, seconds precision. Never a file-system date.
    public var sentAt: String
    public var type: String
    public var body: JSONValue

    public init(id: String, from: String, to: String, sentAt: String,
                type: String, body: JSONValue) {
        self.id = id
        self.from = from
        self.to = to
        self.sentAt = sentAt
        self.type = type
        self.body = body
    }

    /// The envelope as JSON, in the declared field order.
    ///
    /// The order is the TypeScript interface's, so a message built here
    /// serializes to the same bytes as one built there — which is what makes the
    /// committed vectors checkable in both directions rather than only on decode.
    public var json: JSONValue {
        .object([
            ("protocol", .string(SuiteProtocol.name)),
            ("v", .number(Double(SuiteProtocol.version))),
            ("id", .string(id)),
            ("from", .string(from)),
            ("to", .string(to)),
            ("sentAt", .string(sentAt)),
            ("type", .string(type)),
            ("body", body),
        ])
    }

    public init?(_ value: JSONValue) {
        guard value.isObject,
              let id = value["id"]?.stringValue,
              let from = value["from"]?.stringValue,
              let to = value["to"]?.stringValue,
              let sentAt = value["sentAt"]?.stringValue,
              let type = value["type"]?.stringValue,
              let body = value["body"] else { return nil }
        self.init(id: id, from: from, to: to, sentAt: sentAt, type: type, body: body)
    }

    // MARK: - Validation

    /// Every reason this message is not sendable. Empty means it is.
    ///
    /// Ported rule for rule from `validateMessage`. The list rather than a bool
    /// because a rejected message is a debugging problem, and "invalid" without
    /// a reason is the least useful thing a protocol can say.
    public func validate() -> [String] {
        var errors: [String] = []
        if id.count < 8 { errors.append("id: string >= 8 chars required") }
        if !SuiteProtocol.apps.contains(from) {
            errors.append("from: not in the app vocabulary (\(from))")
        }
        if to != "*" && !SuiteProtocol.apps.contains(to) {
            errors.append("to: \"*\" or an app id required (\(to))")
        }
        if !Self.isISO8601(sentAt) { errors.append("sentAt: absolute ISO 8601 required") }
        if !SuiteProtocol.messageTypes.contains(type) {
            errors.append("type: not a known message type (\(type))")
        }
        guard body.isObject else {
            errors.append("body: object required")
            return errors
        }

        func mask(_ value: JSONValue?, bits: Int) -> Bool {
            guard let number = value?.intValue else { return false }
            return number >= 0 && number < (1 << bits)
        }

        switch type {
        case "scale":
            if !mask(body["mask"], bits: 12) {
                errors.append("body.mask: 12-bit integer required (leftmost = LSB)")
            }
            if let root = body["root"], root.intValue == nil
                || root.intValue! < 0 || root.intValue! > 11 {
                errors.append("body.root: pitch class 0-11 required")
            }
        case "chord":
            if let pcs = body["pcs"], !mask(pcs, bits: 12) {
                errors.append("body.pcs: 12-bit integer required")
            }
            if let notes = body["notes"] {
                guard let items = notes.arrayValue,
                      items.allSatisfy({ ($0.intValue ?? -1) >= 0 && ($0.intValue ?? 128) <= 127 })
                else {
                    errors.append("body.notes: array of MIDI notes 0-127 required")
                    break
                }
            }
            if body["pcs"] == nil && body["notes"] == nil && body["symbol"] == nil {
                errors.append("body: chord needs at least one of pcs / notes / symbol")
            }
        case "progression":
            if body["prog"]?.isObject != true {
                errors.append("body.prog: the canonical Progression object required")
            }
        case "pattern":
            let steps = body["steps"]?.intValue ?? 0
            if steps < 1 || steps > 128 { errors.append("body.steps: integer 1-128 required") }
            if (body["mask"]?.intValue ?? -1) < 0 {
                errors.append("body.mask: non-negative integer required (leftmost = LSB)")
            }
        case "manifest":
            if body["app"]?.stringValue.map(SuiteProtocol.apps.contains) != true {
                errors.append("body.app: an app id required")
            }
            if body["params"]?.arrayValue == nil {
                errors.append("body.params: array required")
            }
            if body["commands"]?.arrayValue == nil {
                errors.append("body.commands: array required")
            }
        case "param":
            let hasSingle = body["id"]?.stringValue != nil && body["value"]?.numberValue != nil
            let hasBatch = body["params"]?.arrayValue != nil
            if !hasSingle && !hasBatch {
                errors.append("body: param needs id+value or params[]")
            }
        case "command":
            if (body["name"]?.stringValue ?? "").isEmpty {
                errors.append("body.name: command name required")
            }
        case "note":
            guard let notes = body["notes"]?.arrayValue, !notes.isEmpty,
                  notes.allSatisfy({ ($0.intValue ?? -1) >= 0 && ($0.intValue ?? 128) <= 127 })
            else {
                errors.append("body.notes: non-empty array of MIDI notes 0-127 required")
                break
            }
        default:
            break
        }
        return errors
    }

    /// ISO 8601 with a timezone, which is what "absolute" means here — a
    /// timestamp without one is a fact about somebody else's clock.
    static func isISO8601(_ text: String) -> Bool {
        guard text.count >= 20 else { return false }
        let pattern = "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:\\d{2})$"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
