// swift-tools-version: 6.0
//
//  The Swift foundation the suite's AUv3 plug-ins stand on.
//
//  Six targets: one per layer of PORTING.md §2, stacked in that order, plus the
//  C++ kernel the shell talks to. The
//  layering used to be a manifest in `Scripts/tests/foundation-boundary.py` and
//  a promise; here it is a dependency graph, so the compiler refuses an upward
//  reference instead of a Python script reporting one after the fact. The check
//  stays, because it is still the cheapest way to *propose* a reclassification
//  and see what it would cost — but it is no longer the only thing holding the
//  line.
//
//  Named after their music-suite counterparts where they have one: Theory is
//  the Swift `@enkerli/theory`, UI the Swift `@enkerli/ui`. Carrier has no
//  counterpart — it was invented here, and PORTING.md §2 argues it is the thing
//  most worth promoting back into the monorepo.
//

import PackageDescription

// Swift 5 language mode, matching `SWIFT_VERSION = 5.0` in MelGen.xcodeproj.
// The package exists to hold the same code the extension already builds; a
// different concurrency model would make it a different build of it, and the
// Swift 6 migration is its own piece of work with its own reasons.
let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "enkerli-swift",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Theory", targets: ["Theory"]),
        .library(name: "Carrier", targets: ["Carrier"]),
        .library(name: "Kernel", targets: ["Kernel"]),
        .library(name: "AUHost", targets: ["AUHost"]),
        .library(name: "AudioKernel", targets: ["AudioKernel"]),
        .library(name: "Instrument", targets: ["Instrument"]),
        .library(name: "Shell", targets: ["Shell"]),
        .library(name: "UI", targets: ["UI"]),
    ],
    targets: [
        // Primitives with nothing musical in them.
        .target(name: "Core", swiftSettings: mode),

        // Chords, scales, voice leading, progressions — the suite's own.
        .target(name: "Theory", dependencies: ["Core"], swiftSettings: mode),

        // What a take is made of, and how it is stored, judged, exported.
        .target(name: "Carrier", dependencies: ["Core", "Theory"], swiftSettings: mode),

        // Siblings, not stacked: the kernel is handed notes and the piano roll
        // draws them, and neither may name the other. SwiftPM says that by
        // omission — neither target depends on the other — which is exactly the
        // rule the build cannot enforce, and the reason
        // Scripts/tests/foundation-boundary.py is still worth running.
        .target(name: "UI", dependencies: ["Core", "Theory", "Carrier"], swiftSettings: mode),

        // The AU plumbing, and the only target that talks to C++.
        //
        // `Kernel` is the header-only DSP class. It is a separate target rather
        // than files in `Shell` because SwiftPM builds C++ and Swift as separate
        // units, and because the thing the render thread touches is worth being
        // able to point at.
        //
        // The header used to be `MelGenExtensionParameterAddresses.h`, which
        // made the kernel look as if it depended on the melody app — the one
        // seam the boundary check could never see, because everything under the
        // extension's `Common/`, `DSP/` and `Parameters/` was classified shell
        // by its directory rather than by what it named. The dependency was in
        // the name: play, direction and host sync are what a loop player has.
        .target(name: "Kernel"),

        // The AU plumbing that is not about MIDI: the observable parameter
        // tree, the spec DSL, and the view-controller lifecycle every AUv3 in
        // this suite needs.
        //
        // Split out of `Shell` when the synth arrived. `Shell` is an `aumi`
        // MIDI processor's half of an audio unit and an instrument cannot
        // subclass it — but the lifecycle around it is identical, and it is the
        // fiddly part. No C++ here, and no dependency on `Kernel`: this target
        // is what an audio unit needs before it has decided what kind it is.
        .target(name: "AUHost", swiftSettings: mode),

        .target(name: "Shell",
                dependencies: ["Core", "Theory", "Carrier", "Kernel", "AUHost"],
                swiftSettings: mode + [.interoperabilityMode(.Cxx)]),

        // The synth's render path. A sibling of `Kernel`, not a layer of it.
        //
        // This is the one target in the package that produces a *sample*.
        // Everything else here deals in messages, and PORTING.md §8's "nothing
        // generates on the audio thread" is a rule about that world: decide
        // off-thread, look up on it. A synth inverts it by definition — its
        // render block IS the work, and it must produce a number every sample
        // whether or not anything has been decided.
        //
        // GAPS.md argued from that to "no synth on this foundation", and the
        // decision went the other way. What survives the reversal is the shape:
        // `Kernel` and `Shell` do not depend on this and never will, so a MIDI
        // processor links not one line of it, and the separation is a dependency
        // edge rather than a promise in a document.
        .target(name: "AudioKernel"),

        // An instrument's half of an audio unit: output busses, the render
        // block, and the MIDI input a synth is played by.
        //
        // In the package rather than in the SwiftVane repo for one concrete
        // reason: this is the Swift that touches C++, and `-cxx-interoperability-mode`
        // is configured here. Doing it in an Xcode target would be new machinery
        // no other repo in the suite uses. That is an engineering reason, not a
        // purity one, and it is the same reason `Shell` exists.
        .target(name: "Instrument",
                dependencies: ["AUHost", "AudioKernel"],
                swiftSettings: mode + [.interoperabilityMode(.Cxx)]),

        // Conformance, not unit tests. The point of these is that a Swift
        // answer and a TypeScript answer to the same question agree, so they
        // read `packages/theory/vectors/*.json` out of a sibling music-suite
        // checkout and skip — loudly — when it is not there. See
        // Tests/TheoryTests for what that costs and why it is worth it.
        .testTarget(name: "TheoryTests", dependencies: ["Theory"], swiftSettings: mode),
        .testTarget(name: "CarrierTests", dependencies: ["Carrier", "Theory"], swiftSettings: mode),
        .testTarget(name: "ShellTests", dependencies: ["Shell", "Theory"],
                    swiftSettings: mode + [.interoperabilityMode(.Cxx)]),
    ],
    // `std::clamp` is C++17 and SwiftPM's default is older, so the synth's DSP
    // did not compile until this was stated. Worth pinning rather than working
    // around: `Scripts/check-kernel.sh` has always compiled the harnesses with
    // `-std=c++20`, so without this line the kernels were being built to two
    // different standards by the two things that build them — and the harness,
    // the stricter of the two, is the one people trust.
    cxxLanguageStandard: .cxx20
)
