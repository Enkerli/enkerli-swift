//
//  InstrumentViewController.swift
//  Instrument
//
//  An instrument's principal class: the lifecycle, narrowed to
//  `InstrumentAudioUnit`.
//
//  The mirror image of `Shell.PluginViewController`, and the reason
//  `AudioUnitHostController` was split out at all. Same two overrides, same
//  asymmetry: the return is covariant so the declaration *is* the override,
//  while the parameter is contravariant so it downcasts and forwards to an
//  overload.
//

import CoreAudioKit
import SwiftUI
import AUHost

@MainActor
open class InstrumentViewController: AudioUnitHostController {

    open override func makeAudioUnit(componentDescription: AudioComponentDescription) throws -> InstrumentAudioUnit {
        try InstrumentAudioUnit(componentDescription: componentDescription, options: [])
    }

    open func makeRootView(parameterTree: ObservableAUParameterGroup,
                           audioUnit: InstrumentAudioUnit) -> AnyView {
        AnyView(EmptyView())
    }

    open override func makeRootView(parameterTree: ObservableAUParameterGroup,
                                    audioUnit: AUAudioUnit) -> AnyView {
        guard let instrument = audioUnit as? InstrumentAudioUnit else { return AnyView(EmptyView()) }
        return makeRootView(parameterTree: parameterTree, audioUnit: instrument)
    }
}
