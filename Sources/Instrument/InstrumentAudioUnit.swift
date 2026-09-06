//
//  InstrumentAudioUnit.swift
//  Instrument
//
//  An `aumu` instrument's half of an audio unit.
//
//  `PluginAudioUnit` next door is the same idea for an `aumi` MIDI processor,
//  and the two cannot share a superclass because they disagree about the three
//  things that define an audio unit:
//
//  · **What comes out.** This one fills the output buffer; that one advertises
//    a MIDI output port and writes nothing to the bus. `midiOutputNames` is
//    empty here on purpose — a host that saw a MIDI output on a synth would
//    offer to route it somewhere, and nothing would ever arrive.
//  · **What goes in.** A synth is *played*. `AUAudioUnit` delivers MIDI to an
//    instrument through the same scheduled `AURenderEvent` list, so there is no
//    input bus and no MIDI callback to install — the events arrive in the render
//    block and the process helper splits the block around them.
//  · **What the render block is for.** `internalRenderBlock` here is the work.
//    In a MIDI processor it is a scheduler that mostly does nothing.
//
//  What they *do* share is the lifecycle around all that, which is why
//  `AUHost.AudioUnitHostController` exists and why this file is 90 lines rather
//  than 250.
//
//  `open` throughout: SwiftVane subclasses this the way MelGen subclasses
//  `PluginAudioUnit`, and adds its session state there.
//

import AVFoundation
import AUHost
import AudioKernel

open class InstrumentAudioUnit: AUAudioUnit, ParameterTreeHosting, @unchecked Sendable {

    public var kernel = VaneDSPKernel()
    public var processHelper: VaneAUProcessHelper?

    private var outputBus: AUAudioUnitBus?
    private var _outputBusses: AUAudioUnitBusArray!
    private let format: AVAudioFormat

    @objc public override init(componentDescription: AudioComponentDescription,
                               options: AudioComponentInstantiationOptions) throws {
        // 44.1k stereo is a starting shape, not a commitment: the host tells us
        // the real rate at `allocateRenderResources`, and the kernel is
        // re-initialized there. Everything rate-dependent — the filter
        // coefficients, the envelope's milliseconds, the mip selection — is
        // computed from that call and not from this one.
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try super.init(componentDescription: componentDescription, options: options)
        outputBus = try AUAudioUnitBus(format: format)
        outputBus?.maximumChannelCount = 2
        _outputBusses = AUAudioUnitBusArray(audioUnit: self,
                                            busType: .output,
                                            busses: [outputBus!])
        kernel.initialize(format.sampleRate, 2)
        processHelper = VaneAUProcessHelper(&kernel)
    }

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { kernel.maximumFramesToRender() }
        set { kernel.setMaximumFramesToRender(newValue) }
    }

    public override var shouldBypassEffect: Bool {
        get { kernel.isBypassed() }
        set { kernel.setBypass(newValue) }
    }

    public override var audioUnitMIDIProtocol: MIDIProtocolID {
        kernel.AudioUnitMIDIProtocol()
    }

    /// A synth is played, not routed onward. Empty rather than absent, so the
    /// intent is legible next to `PluginAudioUnit`, which fills it in.
    public override var midiOutputNames: [String] { [] }

    // MARK: - What the interface may read
    //
    // Both come off the render thread through atomics. Breath is the one that
    // matters: this instrument's whole subject is a continuous gesture, and an
    // interface that could not show it would be describing something else.

    /// Silences the voice.
    ///
    /// The mirror of `PluginAudioUnit.panic`, and it needs no MIDI at all: a
    /// synth *is* the downstream instrument, so there is nobody to send an
    /// all-notes-off to. Everything a note leaves behind is dropped and the
    /// parameters are untouched — panic is "stop", not "forget".
    public func panic() { kernel.requestPanic() }

    public var currentBreath: Float { kernel.currentBreath() }
    public var isSounding: Bool { kernel.isSounding() }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        processHelper!.internalRenderBlock()
    }

    open override func allocateRenderResources() throws {
        // The host's rate, not the placeholder from `init`.
        kernel.initialize(outputBus!.format.sampleRate,
                          Int32(outputBus!.format.channelCount))
        try super.allocateRenderResources()
    }

    open override func deallocateRenderResources() {
        kernel.deInitialize()
        super.deallocateRenderResources()
    }

    // MARK: - Parameters

    public func setupParameterTree(_ parameterTree: AUParameterTree) {
        self.parameterTree = parameterTree

        for parameter in parameterTree.allParameters {
            kernel.setParameter(parameter.address, parameter.value)
        }

        parameterTree.implementorValueObserver = { [weak self] parameter, value in
            self?.kernel.setParameter(parameter.address, value)
        }
        parameterTree.implementorValueProvider = { [weak self] parameter in
            self?.kernel.getParameter(parameter.address) ?? 0
        }
        parameterTree.implementorStringFromValueCallback = { parameter, valuePointer in
            guard let value = valuePointer?.pointee else { return "-" }
            return parameter.string(fromValue: [value])
        }
    }
}
