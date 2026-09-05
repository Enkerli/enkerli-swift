# enkerli-swift

The Swift foundation the suite's native AUv3 plug-ins stand on: chord theory,
the pattern interchange format, a SwiftUI kit, and the AU shell with its C++
kernel. Six targets, stacked, with the compiler enforcing the stacking.

It is the counterpart to [`enkerli-juce`](https://github.com/Enkerli/enkerli-juce)
for the part of the matrix JUCE does not cover well: **AUv3 only, macOS and iOS
only, SwiftUI written once per plug-in, no WebView and no bridge on iPadOS, and
Apple Intelligence and Core ML reachable.** Anything built on it gives up
Windows, Linux, VST3, CLAP and LV2, and floors at Xcode 26+ and iOS/macOS 26.0+.
That trade is worth making for the iPad-first tools and not for anything else —
the long version is [PORTING.md](https://github.com/Enkerli/MelGen/blob/main/PORTING.md)
§0 in MelGen.

## The targets

| Target | What it is | Lines |
|---|---|---:|
| `Core` | Primitives with nothing musical in them. A seeded RNG is the whole layer, and that is the right size for it | 46 |
| `Theory` | 172 chord qualities generated from `packages/theory`, chord-scale, parser, detector, diatonic harmony, taxicab voice leading, voicings, the degree histogram, the progression generator and its corpus tables. The Swift port of `@enkerli/theory` | 3,432 |
| `Carrier` | The interchange format and everything that handles it: a degree-relative pattern and its notes, measurement, provenance, curation as dispositions and passes, the pattern store, SMF read/write. **This one has no counterpart in the monorepo** — it was invented for MelGen and is not melody-specific | 3,708 |
| `UI` | Theme and its WCAG audit, piano roll, mini roll, action badges, curation view, the pinned verb bar | 2,532 |
| `Shell` | AU plumbing: the parameter tree, `ObservableAUParameter`, `PluginAudioUnit` and `PluginViewController` | 906 |
| `Kernel` | The header-only C++ DSP kernel — forward / backward / ping-pong, host sync, loop counter, lock-free capture ring — plus the one Objective-C++ compile unit SwiftPM needs to build it | (in `Shell`'s count) |

`Shell` and `UI` are **siblings, not stacked**: the kernel is handed notes and
the piano roll draws them, and neither may name the other. `Package.swift` says
that by omission, which means the build cannot enforce it — MelGen's
`Scripts/tests/foundation-boundary.py` is what does, and it is worth running from
any repo that consumes this one.

## Building a plug-in on it

A plug-in supplies four things and inherits the rest:

- a subclass of `PluginAudioUnit` holding its own session state and deciding what
  the kernel plays out of it;
- a subclass of `PluginViewController` overriding `makeAudioUnit`,
  `makeRootView` and `parameterTreeSpec`. It keeps the name
  `AudioUnitViewController`, because `Info.plist` names the principal class and
  the ObjC runtime looks it up by name;
- its own `ParameterTreeSpec`;
- its root SwiftUI view.

MelGen's copies of those four are about 800 lines together, and they are the
worked example: see `MelGenExtension/AudioUnit/` in
[MelGen](https://github.com/Enkerli/MelGen).

**Claim a four-character subtype before you build.** Component identity is a
`(type, subtype, manufacturer)` triple and the codes are forever; two plug-ins
sharing one means the host resolves either name to whichever it indexed first.
MelGen's `Scripts/tests/component-identity.py` checks a candidate against every
sibling checkout, JUCE and Swift alike.

## About `public` here, and about the history

Two things a reader deserves up front.

**Everything is `public` because it had to be, not because it was designed as
API.** All of this was one module inside MelGen until 2026-09-05, so no symbol
here is more visible than it already was — but the code has never recorded which
of them were interface and which were helpers nobody meant to expose, and no
compiler can tell those apart. Narrowing it is a pass nobody has done yet. Treat
a `public` in this repo as "was reachable", not as a promise.

**The history starts at the extraction.** `git subtree split` follows a
directory, and this directory is two commits old; the months of history behind
`ChordDictionary.swift`, `MelodyPattern.swift` and the rest is in the MelGen
repo, up to and including the commit that moved them here. If you are trying to
find out why something is the way it is, look there — the commit messages are
where the reasoning lives.

## Licence

Public domain, all the way down. See [LICENSE](LICENSE).
