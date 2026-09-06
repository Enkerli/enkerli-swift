//
//  PluginViewController.swift
//  Shell
//
//  A MIDI processor's principal class: the lifecycle, narrowed to `PluginAudioUnit`.
//
//  Everything this used to do is `AudioUnitHostController` in `AUHost` now — the
//  same lifecycle an instrument needs, with nothing MIDI in it. What is left here
//  is the narrowing, and it exists so that the seven plug-in repos that override
//  these two methods with `PluginAudioUnit` in the signature did not have to
//  change when the synth arrived.
//
//  The two are not symmetrical, and the asymmetry is Swift's:
//
//  · `makeAudioUnit` **returns** an audio unit, so it is covariant. Declaring it
//    with a narrower return type *is* the override — Swift resolves it as one,
//    and writing a second forwarding `-> AUAudioUnit` alongside is an error
//    ("has already been overridden"), not the belt-and-braces it looks like.
//  · `makeRootView` **takes** one, so it is contravariant and an override may
//    not narrow a parameter. So the base method is overridden to downcast and
//    forward to an *overload*, which is what plug-ins actually implement.
//
//  Getting the second one backwards produces a plug-in whose `makeRootView` is
//  never called and whose window is empty, with no diagnostic anywhere.
//

import CoreAudioKit
import SwiftUI

@MainActor
open class PluginViewController: AudioUnitHostController {

    /// The audio unit this plug-in is. Covariant override — see above.
    open override func makeAudioUnit(componentDescription: AudioComponentDescription) throws -> PluginAudioUnit {
        try PluginAudioUnit(componentDescription: componentDescription, options: [])
    }

    /// The root view, given this plug-in's own audio unit.
    open func makeRootView(parameterTree: ObservableAUParameterGroup,
                           audioUnit: PluginAudioUnit) -> AnyView {
        AnyView(EmptyView())
    }

    open override func makeRootView(parameterTree: ObservableAUParameterGroup,
                                    audioUnit: AUAudioUnit) -> AnyView {
        guard let plugin = audioUnit as? PluginAudioUnit else { return AnyView(EmptyView()) }
        return makeRootView(parameterTree: parameterTree, audioUnit: plugin)
    }
}
