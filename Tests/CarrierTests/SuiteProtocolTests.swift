//
//  SuiteProtocolTests.swift
//  CarrierTests
//
//  The Swift protocol against the committed frames, in both directions.
//
//  `packages/protocol/vectors/protocol.json` holds ten messages with their
//  **byte-exact SysEx frames**, and the TypeScript's own header calls those "the
//  cross-language contract for that C++ side, exactly like @enkerli/theory's
//  rhythm vectors". This is that contract, checked from Swift.
//
//  Both directions are checked and they are not the same claim:
//
//   · **Decode is byte-exact.** Every committed frame must parse to exactly the
//     committed message. This is the direction that faces the web app, and
//     tolerance here would mean silently misreading somebody else's message.
//   · **Encode is byte-exact too**, which is only possible because `JSONValue`
//     keeps object key order. A dictionary would have lost it and the strongest
//     available claim would have been "parses to an equal value" — worth knowing
//     as the reason that type exists.
//
//  Without a music-suite checkout these do not run, and say so in those words. A
//  skip is not a pass.
//

import Foundation
import Testing
@testable import Carrier

private enum ProtocolVectors {
    static let root: URL? = {
        let fm = FileManager.default
        if let named = ProcessInfo.processInfo.environment["MUSIC_SUITE"] {
            let url = URL(fileURLWithPath: named)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = here.appendingPathComponent("music-suite")
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }()

    struct Case {
        var name: String
        var msgID: Int
        var chunkBytes: Int?
        var message: JSONValue
        var frames: [[UInt8]]
    }

    static func load() -> [Case]? {
        guard let root else {
            print("""

                ── no music-suite checkout, so the protocol vectors did not run ──
                  git clone https://github.com/Enkerli/music-suite ../music-suite
                  (or MUSIC_SUITE=/path/to/music-suite swift test)
                """)
            return nil
        }
        let url = root.appendingPathComponent("packages/protocol/vectors/protocol.json")
        guard let data = try? Data(contentsOf: url),
              let parsed = JSONValue.parse(data),
              let items = parsed.arrayValue else { return nil }
        return items.compactMap { item in
            guard let name = item["name"]?.stringValue,
                  let msgID = item["msgId"]?.intValue,
                  let message = item["message"],
                  let frames = item["frames"]?.arrayValue else { return nil }
            return Case(name: name,
                        msgID: msgID,
                        chunkBytes: item["chunkBytes"]?.intValue,
                        message: message,
                        frames: frames.compactMap { $0.stringValue.map(hexBytes) })
        }
    }

    static func hexBytes(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = text.startIndex
        while let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
            out.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }
}

@Test func everyCommittedFrameDecodesToItsMessage() {
    guard let cases = ProtocolVectors.load() else { return }
    #expect(cases.count == 10, "\(cases.count) vectors")

    for testCase in cases {
        let reassembler = SuiteProtocol.Reassembler()
        var decoded: SuiteMessage?
        for frame in testCase.frames {
            if let message = reassembler.push(frame) { decoded = message }
        }
        guard let decoded else {
            Issue.record("no message came out of \(testCase.frames.count) frame(s): \(testCase.name)")
            continue
        }
        #expect(decoded.json == testCase.message, "\(testCase.name)")
    }
}

@Test func everyMessageEncodesToItsCommittedFrames() {
    guard let cases = ProtocolVectors.load() else { return }

    for testCase in cases {
        guard let message = SuiteMessage(testCase.message) else {
            Issue.record("could not read the vector's own message: \(testCase.name)")
            continue
        }
        let chunk = testCase.chunkBytes ?? SuiteProtocol.defaultChunkBytes
        guard let frames = SuiteProtocol.encode(message,
                                                chunkBytes: chunk,
                                                msgID: testCase.msgID) else {
            let why = message.validate().joined(separator: "; ")
            Issue.record("encode refused a committed message: \(testCase.name) — \(why)")
            continue
        }
        #expect(frames.count == testCase.frames.count,
                "\(testCase.name): \(frames.count) frames, expected \(testCase.frames.count)")
        for (index, frame) in frames.enumerated() where index < testCase.frames.count {
            let expected = testCase.frames[index].count
            #expect(frame == testCase.frames[index],
                    "\(testCase.name), frame \(index): \(frame.count) bytes vs \(expected)")
        }
    }
}

@Test func packingIsSevenBitCleanAndReversible() {
    // The property the whole transport rests on: no byte on the wire may reach
    // 0x80, or the frame ends early and the message is truncated in a way the
    // receiver cannot distinguish from a short message.
    for length in [0, 1, 6, 7, 8, 13, 14, 15, 100, 721] {
        let bytes = (0..<length).map { UInt8(($0 * 37 + 11) & 0xFF) }
        let packed = SuiteProtocol.pack7(bytes)
        #expect(packed.allSatisfy { $0 < 0x80 }, "\(length) bytes")
        #expect(SuiteProtocol.unpack7(packed) == bytes, "\(length) bytes")
    }
    #expect(SuiteProtocol.unpack7([0x80]) == nil, "a high bit in a packed stream is malformed")
    #expect(SuiteProtocol.unpack7([0x00, 0xFF]) == nil)
}

@Test func foreignSysExIsNotOurs() {
    // Everything the kernel's ring carries goes through this, so "not ours" has
    // to be cheap and total. An RND seed frame is the realistic neighbour.
    let rnd: [UInt8] = [0xF0, 0x6F, 0x62, 0x78, 0x10, 0x67, 0x59, 0x10, 0x52, 0x0A, 0xF7]
    #expect(SuiteProtocol.decodeFrame(rnd) == nil)
    #expect(SuiteProtocol.decodeFrame([]) == nil)
    #expect(SuiteProtocol.decodeFrame([0xF0, 0xF7]) == nil)
    // Our manufacturer and tag, a version we do not speak.
    #expect(SuiteProtocol.decodeFrame([0xF0, 0x7D, 0x45, 0x4B, 0x63,
                                       0, 1, 0, 0, 0, 1, 0x00, 0xF7]) == nil)
}

@Test func aChunkedMessageSurvivesArrivingBackwards() {
    guard let cases = ProtocolVectors.load() else { return }
    guard let chunked = cases.first(where: { $0.frames.count > 1 }) else {
        Issue.record("no chunked vector to check")
        return
    }
    let reassembler = SuiteProtocol.Reassembler()
    var decoded: SuiteMessage?
    for frame in chunked.frames.reversed() {
        if let message = reassembler.push(frame) { decoded = message }
    }
    #expect(decoded?.json == chunked.message,
            "out-of-order arrival is normal on a shared MIDI bus")
}

@Test func twoMessagesInFlightDoNotContaminateEachOther() {
    guard let cases = ProtocolVectors.load(),
          let chunked = cases.first(where: { $0.frames.count > 1 }),
          let single = cases.first(where: { $0.frames.count == 1 }) else { return }

    let reassembler = SuiteProtocol.Reassembler()
    var results: [SuiteMessage] = []
    // One frame of the chunked message, then a whole other message, then the
    // rest. Interleaving is what a shared bus does.
    if let message = reassembler.push(chunked.frames[0]) { results.append(message) }
    if let message = reassembler.push(single.frames[0]) { results.append(message) }
    for frame in chunked.frames.dropFirst() {
        if let message = reassembler.push(frame) { results.append(message) }
    }
    #expect(results.count == 2, "\(results.count) messages came out")
    #expect(results.contains { $0.json == single.message })
    #expect(results.contains { $0.json == chunked.message })
}

@Test func aMalformedMessageNeverReachesTheWire() {
    // The rule from the TypeScript: never put a malformed message on the wire.
    // A receiver's only defence is to drop it, and a dropped message looks
    // exactly like a routing problem — which is the most expensive thing to
    // debug on a MIDI bus.
    let good = SuiteMessage(id: "vec-scale-cmajor", from: "pickpcs", to: "pitchfold",
                            sentAt: "2026-07-05T12:00:00Z", type: "scale",
                            body: .object([("mask", .number(2741))]))
    #expect(good.validate().isEmpty)
    #expect(SuiteProtocol.encode(good, msgID: 1) != nil)

    var strangerDanger = good
    strangerDanger.from = "not-an-app"
    #expect(SuiteProtocol.encode(strangerDanger, msgID: 1) == nil)

    var shortID = good
    shortID.id = "abc"
    #expect(!shortID.validate().isEmpty)

    var relativeTime = good
    relativeTime.sentAt = "yesterday"
    #expect(!relativeTime.validate().isEmpty)

    var thirteenBits = good
    thirteenBits.body = .object([("mask", .number(4096))])
    #expect(!thirteenBits.validate().isEmpty, "a 12-bit mask has 12 bits")

    var unknownType = good
    unknownType.type = "telepathy"
    #expect(!unknownType.validate().isEmpty)
}

@Test func theConventionSurvivesTheCrossing() {
    // Leftmost = LSB, everywhere in this suite. The vector's own name says
    // "mask 2741 = 0xAB5", and the number that would mean C major under the
    // other convention is 2773 — the confusion this suite has now hit in three
    // separate places.
    guard let cases = ProtocolVectors.load(),
          let scale = cases.first(where: { $0.name.contains("C major") }) else { return }
    #expect(scale.message["body"]?["mask"]?.intValue == 2741)
    #expect(scale.message["body"]?["mask"]?.intValue != 2773)
}
