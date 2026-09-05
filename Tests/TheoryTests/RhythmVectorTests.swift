//
//  RhythmVectorTests.swift
//  TheoryTests
//
//  The Swift rhythm port against the suite's own answers.
//
//  These are conformance tests, not unit tests, and the difference matters: a
//  unit test says this code does what its author meant, and these say this code
//  and `packages/theory/src/rhythm.ts` do the same thing. The vectors are the
//  contract — "test vectors are the cross-language contract; any algorithm
//  ported to Lua or C++ gets a JSON vector file here first" (CONVENTIONS.md) —
//  and Swift is the fourth language in it after TypeScript, Lua and C++.
//
//  They read `packages/theory/vectors/rhythm.json` from a sibling music-suite
//  checkout:
//
//      git clone https://github.com/Enkerli/music-suite ../music-suite
//
//  or `MUSIC_SUITE=/path/to/music-suite swift test`. Without it every case here
//  is recorded as a skip with that line printed. A skip is not a pass and is not
//  meant to read like one — MelGen's HANDOFF has warned for months that "a green
//  run with skips is a weaker green than it looks", which is a lesson from this
//  suite rather than a general principle.
//

import Foundation
import Testing
@testable import Theory

// MARK: - Finding the vectors

enum Vectors {
    static let root: URL? = {
        let fm = FileManager.default
        if let named = ProcessInfo.processInfo.environment["MUSIC_SUITE"] {
            let url = URL(fileURLWithPath: named)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        // #filePath is Tests/TheoryTests/…, so four levels up is the directory
        // this package sits in, beside music-suite.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TheoryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // enkerli-swift
            .deletingLastPathComponent()   // the directory the checkouts share
        let candidate = here.appendingPathComponent("music-suite")
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }()

    static func load(_ relativePath: String) throws -> [String: Any] {
        guard let root else { throw Missing() }
        let url = root.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Missing()
        }
        return object
    }

    struct Missing: Error {}

    /// Prints once per suite run rather than per case, and returns whether
    /// there is anything to check.
    ///
    /// A skip is not a pass, and this is written so it cannot be mistaken for
    /// one: the line says the cases were not run, in those words. MelGen's
    /// HANDOFF has warned for months that "a green run with skips is a weaker
    /// green than it looks" — that is a lesson from this suite, not a general
    /// principle, and it was learned by shipping one.
    static func available(_ suite: String) -> Bool {
        if root != nil { return true }
        announce()
        print("  SKIP  \(suite) — NOT RUN")
        return false
    }

    private static var announced = false
    private static func announce() {
        guard !announced else { return }
        announced = true
        print("""

            ── no music-suite checkout, so the conformance cases did not run ──
              git clone https://github.com/Enkerli/music-suite ../music-suite
              (or MUSIC_SUITE=/path/to/music-suite swift test)
            """)
    }
}

private func bits(_ pattern: [Bool]) -> String { RhythmCodec.binaryString(pattern) }
private func pattern(_ string: String) -> [Bool] { string.map { $0 == "1" } }

private func rhythmVectors() throws -> [String: Any] {
    try Vectors.load("packages/theory/vectors/rhythm.json")
}

// MARK: - Euclidean

@Test func euclideanMatchesTheSuite() throws {
    guard Vectors.available("euclidean") else { return }

    let cases = try rhythmVectors()["euclidean"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty, "the euclidean group is empty — wrong file?")
    for c in cases {
        let beats = c["beats"] as! Int
        let steps = c["steps"] as! Int
        let offset = c["offset"] as? Int ?? 0
        let expected = c["pattern"] as! String
        let got = bits(EuclideanRhythm.pattern(beats: beats, steps: steps, offset: offset))
        #expect(got == expected,
                "E(\(beats),\(steps)\(offset != 0 ? ",\(offset)" : "")): \(got) != \(expected)")
    }
}

@Test func complementMatchesTheSuite() throws {
    guard Vectors.available("complement") else { return }
    let cases = try rhythmVectors()["complement"] as? [[String: Any]] ?? []
    for c in cases {
        let beats = c["beats"] as! Int
        let steps = c["steps"] as! Int
        let expected = c["pattern"] as! String
        #expect(bits(EuclideanRhythm.complement(beats: beats, steps: steps)) == expected)
    }
}

// MARK: - Barlow

@Test func barlowTablesMatchTheSuite() throws {
    guard Vectors.available("barlowTables") else { return }
    let cases = try rhythmVectors()["barlowTables"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty)
    for c in cases {
        let length = c["length"] as! Int
        let expected = (c["table"] as! [Any]).map { ($0 as! NSNumber).doubleValue }
        let got = Barlow.table(length: length)
        #expect(got.count == expected.count, "length \(length)")
        for (i, (a, b)) in zip(got, expected).enumerated() {
            #expect(abs(a - b) < 1e-12, "length \(length) position \(i): \(a) != \(b)")
        }
    }
}

@Test func barlowSyncopationMatchesTheSuite() throws {
    guard Vectors.available("syncopation") else { return }
    let cases = try rhythmVectors()["syncopation"] as? [[String: Any]] ?? []
    for c in cases {
        let onsets = c["onsets"] as! [Int]
        let steps = c["steps"] as! Int
        let expected = (c["value"] as! NSNumber).doubleValue
        let got = Barlow.syncopation(onsets: onsets, stepCount: steps)
        #expect(abs(got - expected) < 1e-12,
                "\(c["name"] ?? ""): \(got) != \(expected)")
    }
}

@Test func barlowTransformsMatchTheSuite() throws {
    guard Vectors.available("transforms") else { return }
    let cases = try rhythmVectors()["transforms"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty)
    for c in cases {
        let source = pattern(c["pattern"] as! String)
        let target = c["target"] as! Int
        let options = c["options"] as? [String: Any] ?? [:]
        let result = BarlowTransform.apply(
            source, targetOnsets: target,
            options: .init(wolrab: options["wolrabMode"] as? Bool ?? false,
                           preserveDownbeat: options["preserveDownbeat"] as? Bool ?? true,
                           minimumIndispensability: (options["minimumIndispensability"] as? NSNumber)?.doubleValue,
                           avoidWeakBeats: options["avoidWeakBeats"] as? Bool ?? false))
        #expect(bits(result.pattern) == (c["result"] as! String),
                "\(c["name"] ?? ""): \(bits(result.pattern)) != \(c["result"] as! String)")
        if let transformation = c["transformation"] as? String {
            #expect(result.transformation.rawValue == transformation)
        }
    }
}

// MARK: - Codecs
//
// The group that exists because of one thing: leftmost = LSB, and hex/octal
// digit strings little-endian. A port that inverts it produces real patterns
// that are the wrong ones, which is the failure mode nothing else catches.

@Test func codecsMatchTheSuite() throws {
    guard Vectors.available("codecs") else { return }
    let cases = try rhythmVectors()["codecs"] as? [[String: Any]] ?? []
    #expect(!cases.isEmpty)
    for c in cases {
        let bitString = c["pattern"] as! String
        let p = pattern(bitString)

        #expect(RhythmCodec.binaryString(p) == bitString)
        #expect(RhythmCodec.pattern(binary: bitString) == p)

        if let decimal = (c["decimal"] as? NSNumber)?.uint64Value {
            #expect(RhythmCodec.decimal(p) == decimal, "decimal of \(bitString)")
            #expect(RhythmCodec.pattern(decimal: decimal, steps: p.count) == p)
        }
        if let hex = c["hex"] as? String {
            #expect(RhythmCodec.hexString(p) == hex, "hex of \(bitString)")
            #expect(RhythmCodec.pattern(hex: hex, steps: p.count) == p)
        }
        if let octal = c["octal"] as? String {
            #expect(RhythmCodec.octalString(p) == octal, "octal of \(bitString)")
            #expect(RhythmCodec.pattern(octal: octal, steps: p.count) == p)
        }
    }
}

@Test func theCodecBatchRoundTrips() throws {
    guard Vectors.available("codecBatch") else { return }
    // 128 seeded cases, "read identically by the webapp and plugin conformance
    // suites" — the widest single check in the file, and the reason a bit-order
    // mistake cannot survive it.
    let cases = try rhythmVectors()["codecBatch"] as? [[String: Any]] ?? []
    #expect(cases.count > 100, "expected the full batch, got \(cases.count)")
    for c in cases {
        let bitString = c["pattern"] as! String
        let p = pattern(bitString)
        if let decimal = (c["decimal"] as? NSNumber)?.uint64Value {
            #expect(RhythmCodec.decimal(p) == decimal, "\(bitString)")
        }
        if let hex = c["hex"] as? String {
            #expect(RhythmCodec.hexString(p) == hex, "\(bitString)")
            #expect(RhythmCodec.pattern(hex: hex, steps: p.count) == p, "\(bitString)")
        }
    }
}

// MARK: - The one thing that is ours

@Test func tresilloIsWrittenTheSuitesWayRoundInEveryTranscription() {
    // No vector needed and none wanted: this is the convention stated as a
    // test, so a reader who has forgotten it can find it in ten seconds, and so
    // it fails even in a checkout with no music-suite beside it.
    let tresillo = EuclideanRhythm.pattern(beats: 3, steps: 8)
    #expect(RhythmCodec.binaryString(tresillo) == "10010010")
    #expect(RhythmCodec.decimal(tresillo) == 73)
    #expect(RhythmCodec.hexString(tresillo) == "94")      // NOT 49
    #expect(RhythmCodec.octalString(tresillo) == "111")
    #expect(RhythmCodec.onsets(tresillo) == [0, 3, 6])
    #expect(RhythmCodec.interOnsetIntervals(tresillo) == [3, 3, 2])
}
