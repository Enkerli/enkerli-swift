//
//  TransportParameters.swift
//  AUHost
//
//  The three transport parameters, declared once and found once.
//
//  Every plug-in in the suite that loops something wants the same three —
//  `playMelody`, `playbackDirection`, `hostSync` — at the same addresses,
//  because they are the *kernel's*, not any plug-in's. Six repos were retyping
//  the same `ParameterSpec` blocks or, worse, declaring them and surfacing
//  nothing.
//
//  Two halves, and the split is the layering's:
//
//   · `TransportParameters.specs()` builds the declarations, so a plug-in's tree
//     includes them by calling one function.
//   · `TransportParameters(in:)` finds them in an `ObservableAUParameterGroup`
//     and hands back plain `Binding`s, which `UI.TransportRow` consumes without
//     ever learning that an `AUParameter` exists.
//
//  The addresses live in the `Kernel` target's header and this target does not
//  depend on it, so they are restated here as raw values with the header named.
//  That is a real duplication and the alternative is worse: `AUHost` depending
//  on the MIDI kernel would drag it into the synth, which links neither.
//  `Scripts/check-transport.sh` compares the two.
//

import AudioToolbox
import SwiftUI

public enum TransportParameter: AUParameterAddress, Sendable {
    // Mirrors `PluginParameterAddresses.h`. Addresses 0 and 1 held a MIDI test
    // note and stay unused, so automation saved in an old host session cannot
    // land on an unrelated control.
    case play = 2
    case direction = 3
    case hostSync = 4

    public var identifier: String {
        switch self {
        case .play: return "playMelody"
        case .direction: return "playbackDirection"
        case .hostSync: return "hostSync"
        }
    }
}

public enum TransportParameters {

    /// Which of the three a plug-in wants.
    ///
    /// Direction is separable because it is the one that is not always
    /// meaningful — a curator that played a clip backwards would record a
    /// judgement of music that is not in its library. A plug-in that declares a
    /// control it cannot honour is the bug GAPS.md draws its line under, so the
    /// set is a choice rather than a package.
    public struct Options: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let play = Options(rawValue: 1 << 0)
        public static let hostSync = Options(rawValue: 1 << 1)
        public static let direction = Options(rawValue: 1 << 2)

        /// What a looping player has.
        public static let loop: Options = [.play, .hostSync, .direction]
        /// What something that auditions has: start it, and follow the tempo.
        public static let audition: Options = [.play, .hostSync]
    }

    /// The three as a group a plug-in can drop straight into its tree.
    ///
    /// A group rather than three loose specs, for two reasons. A host displays
    /// groups, and "Transport: Play, Direction, Sync to Host" reads better than
    /// three controls scattered among a plug-in's own knobs. And the parameter
    /// DSL's result builder takes nodes rather than arrays, so a group is the
    /// one shape that drops in without teaching the builder about loops.
    public static func group(_ options: Options = .loop) -> ParameterGroupSpec {
        ParameterGroupSpec(identifier: "transport", name: "Transport",
                           children: specs(options))
    }

    /// The specs, for a plug-in that wants them somewhere of its own.
    public static func specs(_ options: Options = .loop) -> [ParameterSpec] {
        var specs: [ParameterSpec] = []
        if options.contains(.play) {
            specs.append(ParameterSpec(address: TransportParameter.play.rawValue,
                                       identifier: TransportParameter.play.identifier,
                                       name: "Play",
                                       units: .boolean,
                                       valueRange: 0...1,
                                       defaultValue: 0))
        }
        if options.contains(.direction) {
            specs.append(ParameterSpec(address: TransportParameter.direction.rawValue,
                                       identifier: TransportParameter.direction.identifier,
                                       name: "Playback Direction",
                                       units: .indexed,
                                       valueRange: 0...2,
                                       defaultValue: 0,
                                       valueStrings: ["Forward", "Backward", "Ping-Pong"]))
        }
        if options.contains(.hostSync) {
            specs.append(ParameterSpec(address: TransportParameter.hostSync.rawValue,
                                       identifier: TransportParameter.hostSync.identifier,
                                       name: "Sync to Host",
                                       units: .boolean,
                                       valueRange: 0...1,
                                       defaultValue: 0))
        }
        return specs
    }

    // MARK: - Finding them again

    /// Bindings onto whichever of the three a tree actually declares.
    ///
    /// Nil for the ones it does not, so a `TransportRow` shows exactly the
    /// controls that exist. Looking them up by *address* rather than by
    /// identifier, because the address is the thing the kernel acts on and a
    /// renamed identifier should not silently detach a control from its
    /// parameter.
    @MainActor
    public struct Bindings {
        public var play: Binding<Bool>?
        public var hostSync: Binding<Bool>?
        public var direction: Binding<Int>?

        public init(in tree: ObservableAUParameterGroup) {
            let found = TransportParameters.parameters(in: tree)
            if let parameter = found[.play] {
                play = Binding(get: { parameter.boolValue },
                               set: { parameter.boolValue = $0 })
            }
            if let parameter = found[.hostSync] {
                hostSync = Binding(get: { parameter.boolValue },
                                   set: { parameter.boolValue = $0 })
            }
            if let parameter = found[.direction] {
                direction = Binding(get: { Int(parameter.value.rounded()) },
                                    set: { parameter.value = AUValue($0) })
            }
        }
    }

    /// Walks the tree once and picks out the three by address.
    ///
    /// Main-actor, because the observable parameters are: they publish into
    /// SwiftUI and their editing state is touched from a gesture.
    @MainActor
    static func parameters(in tree: ObservableAUParameterGroup)
        -> [TransportParameter: ObservableAUParameter] {
        var found: [TransportParameter: ObservableAUParameter] = [:]
        for node in tree.allObservableParameters {
            guard let transport = TransportParameter(rawValue: node.address) else { continue }
            found[transport] = node
        }
        return found
    }
}
