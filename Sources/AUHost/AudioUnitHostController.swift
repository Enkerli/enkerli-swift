//
//  AudioUnitHostController.swift
//  AUHost
//
//  The AUv3 view-controller lifecycle, with nothing in it about what kind of
//  audio unit this is.
//
//  It was `PluginViewController` in `Shell`, which was fine while every plug-in
//  in the suite was an `aumi` MIDI processor. A synth is an `aumu` instrument:
//  it has an audio render block, it does not advertise a MIDI output, and it
//  cannot subclass `PluginAudioUnit` — but the lifecycle around it is *exactly*
//  the same, and it is the fiddly part. Create the audio unit on the main queue,
//  install the parameter tree before building the `@AUParameterUI` properties,
//  host a SwiftUI view, pin it to the bounds.
//
//  So the lifecycle moved down here and `PluginViewController` is now a subclass
//  that narrows the two overrides back to `PluginAudioUnit`. Nothing in the seven
//  MIDI plug-in repos changed.
//
//  A generic parameter was the shape PORTING.md §3 predicted and it still cannot
//  be one: the principal class is looked up by name out of Info.plist through the
//  ObjC runtime, and a generic Swift class has no ObjC name. A base class and two
//  overrides is what survives that constraint.
//

import Combine
import CoreAudioKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.enkerli.AUHost", category: "AudioUnitHostController")

/// An audio unit that can be handed a parameter tree built from a spec.
///
/// A protocol rather than a base class, because the two kinds of audio unit in
/// this suite — the MIDI processor and the instrument — already have different
/// superclasses' worth of behaviour and share only this. Both implement it the
/// same way and neither could inherit it from the other.
public protocol ParameterTreeHosting: AUAudioUnit {
    func setupParameterTree(_ parameterTree: AUParameterTree)
}

@MainActor
open class AudioUnitHostController: AUViewController, AUAudioUnitFactory {
    public var audioUnit: AUAudioUnit?

    public var hostingController: HostingController<AnyView>?

    // MARK: - What a plug-in supplies

    /// The audio unit this plug-in is.
    ///
    /// Returns `AUAudioUnit` rather than a suite type so an instrument can
    /// return one. Swift allows a covariant return in an override, which is how
    /// `PluginViewController` narrows it back to `PluginAudioUnit` without
    /// changing a single call site.
    open func makeAudioUnit(componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        throw NSError(domain: "com.enkerli.AUHost", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "makeAudioUnit was not overridden"
        ])
    }

    /// The root view. Type-erased rather than generic, for the reason in the
    /// file comment: one `AnyView` at the top of a plug-in's view tree costs a
    /// box per rebuild of the root and nothing else.
    open func makeRootView(parameterTree: ObservableAUParameterGroup,
                           audioUnit: AUAudioUnit) -> AnyView {
        AnyView(EmptyView())
    }

    /// The parameters the host sees.
    open var parameterTreeSpec: ParameterTreeSpec { ParameterTreeSpec {} }

    private var observation: NSKeyValueObservation?

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Touching `audioUnit` prompts the AU to be created via
        // createAudioUnit(with:).
        guard let audioUnit = self.audioUnit else { return }
        configureSwiftUIView(audioUnit: audioUnit)
    }

    nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        try DispatchQueue.main.sync {
            let created = try makeAudioUnit(componentDescription: componentDescription)
            audioUnit = created

            defer {
                // After creating the AU rather than in viewDidLoad, so the
                // parameter tree exists before the `@AUParameterUI` properties
                // are built.
                DispatchQueue.main.async {
                    self.configureSwiftUIView(audioUnit: created)
                }
            }

            guard let hosting = created as? ParameterTreeHosting else {
                log.error("Audio unit does not accept a parameter tree")
                return created
            }
            hosting.setupParameterTree(parameterTreeSpec.createAUParameterTree())

            observation = created.observe(\.allParameterValues, options: [.new]) { _, _ in
                guard let tree = created.parameterTree else { return }
                // Makes the audio unit take initial values from the host.
                for param in tree.allParameters { param.value = param.value }
            }

            if created.parameterTree == nil {
                log.error("Unable to access AU ParameterTree")
            }
            return created
        }
    }

    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        if let host = hostingController {
            host.removeFromParent()
            host.view.removeFromSuperview()
        }

        guard let observableParameterTree = audioUnit.observableParameterTree else { return }

        let content = makeRootView(parameterTree: observableParameterTree, audioUnit: audioUnit)
        let host = HostingController(rootView: content)
        addChild(host)
        host.view.frame = view.bounds
        view.addSubview(host.view)
        hostingController = host

        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
        host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        view.bringSubviewToFront(host.view)
    }
}
