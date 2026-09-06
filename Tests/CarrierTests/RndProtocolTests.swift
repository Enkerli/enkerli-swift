//
//  RndProtocolTests.swift
//  CarrierTests
//
//  The Swift port of the RND codec, held to the C++ one's contract.
//
//  The fixtures are not invented: `capturedSeedFrame` and the three device
//  frames below are copied byte for byte out of `rnd-companion`'s
//  `Tests/ProtocolTests.cpp`, where they came from a capture taken off real
//  hardware (`Tests/fixtures/CymaRNDfirmUp.mid`). Two implementations that
//  agree with each other and not with the device would be worth nothing; these
//  bytes are what the device actually sent.
//
//  The seed round-trip cases are the same list too, and they are the same list
//  on purpose: 0x0FFFFFFF and 0x10000000 straddle the nibble boundary in the
//  fifth septet, which is where a packing that shifted by 28 instead of masking
//  to 0x0F would first go wrong.
//

import Testing
import Foundation
@testable import Carrier

private let capturedSeed: UInt32 = 0xAA442CE7

private let capturedSeedFrame: [UInt8] =
    [0xF0, 0x6F, 0x62, 0x78, 0x10, 0x67, 0x59, 0x10, 0x52, 0x0A, 0xF7]
private let dumpBeginFrame: [UInt8] =
    [0xF0, 0x6F, 0x62, 0x78, 0x20, 0xF7]
private let globalsFrame: [UInt8] =
    [0xF0, 0x6F, 0x62, 0x78, 0x21, 0x02, 0x7D, 0x00, 0x02, 0x11, 0xF7]
private let trackEngineFrame: [UInt8] =
    [0xF0, 0x6F, 0x62, 0x78, 0x22, 0x00, 0x00, 0x01, 0x46, 0x4D, 0x00, 0xF7]

@Test func seedRoundTripsThroughFiveSeptets() {
    for seed: UInt32 in [0x00000000, 0x00000001, 0x0000007F, 0x00000080,
                         0x0FFFFFFF, 0x10000000, 0x7FFFFFFF, 0x80000000,
                         0xFFFFFFFF, 0xDEADBEEF, capturedSeed] {
        #expect(RND.unpackSeed(RND.packSeed(seed)) == seed,
                "\(RND.formatSeed(seed))")
    }
}

@Test func everyPackedByteIsSevenBitClean() {
    // A byte with bit 7 set inside a SysEx frame is a status byte, and would
    // end the message early wherever it landed.
    for seed: UInt32 in [0xFFFFFFFF, 0xAAAAAAAA, 0x55555555] {
        for byte in RND.packSeed(seed) {
            #expect(byte & 0x80 == 0, "\(RND.formatSeed(seed)) produced \(byte)")
        }
    }
}

@Test func theCapturedSeedPacksToTheCapturedBytes() {
    #expect(RND.packSeed(capturedSeed) == [0x67, 0x59, 0x10, 0x52, 0x0A])
    #expect(RND.unpackSeed([0x67, 0x59, 0x10, 0x52, 0x0A]) == capturedSeed)
}

@Test func seedTextIsTheFormTheDeviceUses() {
    #expect(RND.formatSeed(capturedSeed) == "0xaa442ce7")
    #expect(RND.formatSeed(0) == "0x00000000")
    #expect(RND.parseSeed(RND.formatSeed(0xFFFFFFFF)) == 0xFFFFFFFF)
}

@Test func seedTextIsAcceptedInEveryFormPeopleWriteIt() {
    #expect(RND.parseSeed("0xaa442ce7") == capturedSeed)
    #expect(RND.parseSeed("0xAA442CE7") == capturedSeed)
    #expect(RND.parseSeed("  0xaa442ce7  ") == capturedSeed)
    #expect(RND.parseSeed("aa442ce7") == capturedSeed)
    // A plausible decimal stays decimal — typing 125 means 125, not 0x125.
    #expect(RND.parseSeed("125") == 125)
    #expect(RND.parseSeed("0x125") == 0x125)
}

@Test func nonsenseIsRejectedRatherThanGuessedAt() {
    #expect(RND.parseSeed("") == nil)
    #expect(RND.parseSeed("   ") == nil)
    #expect(RND.parseSeed("0xdeadbeeff") == nil)   // nine hex digits
    #expect(RND.parseSeed("4294967296") == nil)    // 2^32
    #expect(RND.parseSeed("nope!") == nil)
}

@Test func aSeedMessageIsTheFrameTheHardwareSent() {
    #expect(RND.seedMessage(capturedSeed) == capturedSeedFrame)
    #expect(RND.unlockAndDump() == [0xF0, 0x6F, 0x62, 0x78, 0x11, 0x00, 0xF7])
}

@Test func everySeedSurvivesEncodeAndDecode() {
    for seed: UInt32 in [0, 1, capturedSeed, 0xFFFFFFFF] {
        #expect(RND.parse(RND.seedMessage(seed)) == .seed(seed),
                "\(RND.formatSeed(seed))")
    }
}

@Test func theCapturedFramesDecodeToWhatTheyMeant() {
    #expect(RND.parse(capturedSeedFrame) == .seed(capturedSeed))
    #expect(RND.parse(dumpBeginFrame) == .dumpBegin)

    guard case .globals(let globals)? = RND.parse(globalsFrame) else {
        Issue.record("globals frame did not decode")
        return
    }
    #expect(globals.patchMode == 0x02)
    // 0x7D low septet, 0x00 high: 125 BPM, which is what the capture was taken at.
    #expect(globals.tempoBPM == 125)
    #expect(globals.tonic == 2)
    #expect(globals.scaleIndex == 0x11)
    #expect(RND.tonicName(Int(globals.tonic)) == "D")
    #expect(RND.scaleName(Int(globals.scaleIndex)) == "prometheus")

    guard case .trackEngine(let engine)? = RND.parse(trackEngineFrame) else {
        Issue.record("track engine frame did not decode")
        return
    }
    #expect(engine.index == 0)
    #expect(engine.name == "FM", "NUL-terminated ASCII on the wire")
}

@Test func framingBytesAreOptionalInEveryCombination() {
    // Hosts and drivers disagree about whether F0/F7 belong to the frame, and
    // the kernel's UMP path strips them. All four combinations decode.
    let full = capturedSeedFrame
    let noBegin = Array(full.dropFirst())
    let noEnd = Array(full.dropLast())
    let neither = Array(full.dropFirst().dropLast())
    for variant in [full, noBegin, noEnd, neither] {
        #expect(RND.parse(variant) == .seed(capturedSeed), "\(variant.count) bytes")
    }
}

@Test func aDamagedFrameIsToldApartFromSomebodyElsesFrame() {
    // The distinction the probe exists to draw: a host that delivers another
    // vendor's frame intact has proved it passes SysEx; one that delivers ours
    // broken has proved the opposite.
    let ours = capturedSeedFrame
    var damaged = ours
    damaged[6] = 0x00                       // a septet clobbered
    let truncated = Array(ours.prefix(6)) + [0xF7]
    let foreign: [UInt8] = [0xF0, 0x41, 0x10, 0x42, 0x12, 0xF7]

    #expect(RND.hasManufacturerTag(ours))
    #expect(RND.hasManufacturerTag(damaged), "the tag survives even when the body doesn't")
    #expect(RND.hasManufacturerTag(truncated))
    #expect(!RND.hasManufacturerTag(foreign))

    #expect(RND.parse(truncated) == nil, "our tag, but not a usable frame")
    #expect(RND.parse(foreign) == nil)
    #expect(RND.describeForeign(foreign) == "manufacturer 0x41 SysEx")
    #expect(RND.describeForeign([0xF0, 0x7E, 0x00, 0xF7]) == "universal non-real-time SysEx")
    #expect(RND.describeForeign([0xF0, 0x7F, 0x00, 0xF7]) == "universal real-time SysEx")
    #expect(RND.describeForeign(ours) == "", "ours is not foreign")
}

@Test func anUnlockEchoCarriesNoDeviceState() {
    // Host→device only. Seeing it means watching our own output come back,
    // which is not an error and is not news about the device.
    #expect(RND.parse(RND.unlockAndDump()) == nil)
}

@Test func theScaleBandsAreTheDevicesOwn() {
    for index in 0..<RND.numScales {
        #expect(RND.scaleIndex(forCC: RND.scaleCCValue(index)) == index,
                "\(RND.scaleName(index))")
    }
    #expect(RND.scaleCCValue(0) == 3)
    #expect(RND.scaleCCValue(19) == 124)
    // Out of range clamps to the first band rather than crashing or wrapping.
    #expect(RND.scaleCCValue(-1) == 3)
    #expect(RND.scaleCCValue(99) == 3)
}

@Test func tonicIsANoteNotAControlChange() {
    #expect(RND.tonicNote(0) == 60)
    #expect(RND.tonicNote(11) == 71)
    #expect(RND.tonicNote(-1) == 71, "a negative pitch class wraps rather than going below C")
    #expect(RND.tonicNote(12) == 60)
}

@Test func aDumpFoldsIntoOneStatus() {
    var status = RndDeviceStatus()
    #expect(!status.hasSeed)

    status.apply(.seed(capturedSeed))
    #expect(status.seed == capturedSeed)
    #expect(status.hasSeed)

    status.apply(.globals(RND.Globals(patchMode: 2, tempoBPM: 125, tonic: 2, scaleIndex: 17)))
    status.apply(.trackEngine(RND.TrackEngine(index: 1, name: "Wave")))
    status.apply(.trackEngine(RND.TrackEngine(index: 0, name: "FM")))
    #expect(status.engines.map(\.name) == ["FM", "Wave"], "sorted by track index")

    status.apply(.trackEngine(RND.TrackEngine(index: 0, name: "Granular")))
    #expect(status.engines.count == 2, "a repeated track replaces rather than appends")
    #expect(status.engines.first?.name == "Granular")

    // A new seed means a new patch, so the engine names no longer describe it.
    status.apply(.seed(0x12345678))
    #expect(status.engines.isEmpty)
    #expect(status.tempoBPM == 125, "but what the globals said is still what they said")
}
