//
//  PluginAudioUnit.swift
//  MelGenExtension
//
//  The AU half of a plug-in: the kernel, the parameter tree, the transport
//  readings and the capture ring. No session state, no melody, no MelGen.
//
//  It was `MelGenExtensionAudioUnit` and it held both halves, which is
//  PORTING.md's `MelGenExtensionAudioUnit → MelGenState` and `→ SetupStore`
//  seams: the shell may not reach up into the app, and it was reaching for the
//  app's entire session type. What is left here is the ~900 lines PORTING.md §2
//  measures against enkerli-juce's 921, and a sibling plug-in subclasses it the
//  way MelGen now does — see MelGenExtensionAudioUnit.swift.
//

import AVFoundation
import AUHost
import Kernel
import Carrier

open class PluginAudioUnit: AUAudioUnit, ParameterTreeHosting, @unchecked Sendable
{
	// C++ Objects
	public var kernel = PluginDSPKernel()
    public var processHelper: AUProcessHelper?

	private var outputBus: AUAudioUnitBus?
	private var _outputBusses: AUAudioUnitBusArray!

	private var format:AVAudioFormat

	@objc public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
		self.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
		try super.init(componentDescription: componentDescription, options: options)
		outputBus = try AUAudioUnitBus(format: self.format)
        outputBus?.maximumChannelCount = 2
		_outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: AUAudioUnitBusType.output, busses: [outputBus!])
        kernel.initialize(outputBus!.format.sampleRate)
        processHelper = AUProcessHelper(&kernel)
	}

	public override var outputBusses: AUAudioUnitBusArray {
		return _outputBusses
	}
    
    public override var  maximumFramesToRender: AUAudioFrameCount {
        get {
            return kernel.maximumFramesToRender()
        }

        set {
            kernel.setMaximumFramesToRender(newValue)
        }
    }

    public override var  shouldBypassEffect: Bool {
        get {
            return kernel.isBypassed()
        }

        set {
            kernel.setBypass(newValue)
        }
    }

    // MARK: - MIDI
    public override var audioUnitMIDIProtocol: MIDIProtocolID {
        return kernel.AudioUnitMIDIProtocol()
    }

    /// Advertises a MIDI output port. Hosts only expose a MIDI output for the
    /// plug-in — and only connect `midiOutputEventListBlock` /
    /// `midiOutputEventBlock` — when this array is non-empty, so without it the
    /// kernel has nowhere to send the melody it generates.
    public override var midiOutputNames: [String] {
        return ["MelGen Out"]
    }

    // MARK: - Melody
    /// Hands a generated melody to the DSP kernel. The kernel loops it for
    /// `lengthBeats` quarter-note beats while the playMelody parameter is on.
    /// Safe to call from the main thread while rendering.
    /// - Parameter restartFromTop: begin the new sequence at its first beat.
    ///   Asked for when the take changes, not when the same take is re-rendered.
    public func setMelody(_ notes: [SequencedNote], lengthBeats: Double, restartFromTop: Bool = false) {
        kernel.beginSequenceUpdate()
        for note in notes {
            kernel.appendSequenceNote(note.startBeat, note.durationBeats, note.note, note.velocity)
        }
        kernel.commitSequence(lengthBeats, restartFromTop)
    }

    /// How many complete loop passes have played. The UI polls this to decide
    /// when to generate the next take.
    // MARK: - Panic

    /// Ends every note this plug-in could be responsible for.
    ///
    /// Nothing in the suite had this, and it is the cheapest possible insurance
    /// against the worst bug a MIDI processor has: a note-on whose note-off
    /// never came, sounding in somebody else's synth, outliving the plug-in
    /// being removed from the chain. The kernel already tracks what it holds for
    /// two of its jobs; what was missing was a way for a person to say "stop".
    ///
    /// Three things, in this order, and the order matters:
    ///
    ///  1. **The kernel releases what it is holding**, with the mapping each
    ///     note actually used — a transformed note-on needs its own note-off,
    ///     not the original's.
    ///  2. **All-sound-off (CC120) on all sixteen channels.** Stops notes this
    ///     plug-in never started, which is most of what a person means by panic.
    ///  3. **All-notes-off (CC123)** after it, because some instruments treat
    ///     120 as an envelope cut and 123 as a release, and a stuck note wants
    ///     both.
    ///
    /// Deliberately *not* a parameter: a host automating panic at bar 17 is a
    /// project that silences itself, and the situation this is for — a sender
    /// that went away — is not one a timeline knows about.
    public func panic() {
        kernel.requestPanic()
        var messages: [[UInt8]] = []
        for controller: UInt8 in [120, 123] {
            for channel in 0..<16 {
                messages.append([0xB0 | UInt8(channel), controller, 0])
            }
        }
        sendBurst(messages)
    }

    // MARK: - Talking to a device

    /// How far the UI has read into the kernel's inbound SysEx ring.
    private var sysExCursor: UInt64 = 0

    /// Sends a burst of messages, once.
    ///
    /// A burst is not only SysEx, because talking to a device rarely is: the RND
    /// takes its seed over SysEx, its scale over CC9 and its tonic as a *note*.
    /// A message starting with `F0` is a SysEx frame; anything else is a short
    /// channel message sent verbatim. One buffer rather than three mechanisms.
    ///
    /// A SysEx frame includes its own `F0` and `F7`, because that is how every
    /// device protocol document in this suite is written. The kernel strips them
    /// on the way into UMP and puts them back on the way out, so nothing above
    /// this line has to know that MIDI 2.0 removed the framing bytes.
    ///
    /// A burst, not a queue: this is sent exactly once, on the next render
    /// block. Sending the same bytes again means calling this again — which is
    /// what makes it possible to tell *this* burst's answer from the last one's.
    ///
    /// - Returns: the messages that were refused, if any. One is refused when it
    ///   is longer than the kernel's slot or when the burst is full. Refusing is
    ///   deliberate: a SysEx frame that is silently truncated is precisely the
    ///   failure this whole path exists to detect.
    @discardableResult
    public func sendBurst(_ frames: [[UInt8]]) -> [[UInt8]] {
        kernel.beginSysExBurst()
        var refused: [[UInt8]] = []
        for frame in frames {
            let accepted = frame.withUnsafeBufferPointer { buffer in
                kernel.addSysExFrame(buffer.baseAddress, UInt32(frame.count))
            }
            if !accepted { refused.append(frame) }
        }
        kernel.commitSysExBurst()
        return refused
    }

    /// Everything that has arrived since the last drain, `F0` and `F7` included.
    ///
    /// Same ring discipline as the note capture: single writer, single reader,
    /// lock-free, and the oldest frames are lost rather than the render thread
    /// waiting for anybody. Unlike notes, a lost frame here is not a nuisance —
    /// it is a missing answer — so `sysExTruncatedCount` exists to say when the
    /// ring could not hold what arrived.
    public func drainSysEx() -> [[UInt8]] {
        let written = kernel.sysExInCount()
        guard written > sysExCursor else { return [] }
        var index = max(sysExCursor, kernel.oldestSysExIn())
        var frames: [[UInt8]] = []
        while index < written {
            let length = kernel.sysExInLength(index)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(length))
            for offset in 0..<length {
                bytes.append(kernel.sysExInByte(index, offset))
            }
            frames.append(bytes)
            index += 1
        }
        sysExCursor = written
        return frames
    }

    /// How many arriving frames were longer than the kernel could hold.
    ///
    /// Not zero means a byte dump above is shorter than the wire was, and any
    /// conclusion drawn from it is wrong. Worth showing rather than logging.
    public var sysExTruncatedCount: UInt64 { kernel.sysExInTruncated() }

    // MARK: - Capture

    /// How far the UI has read into the kernel's capture ring.
    private var captureCursor: UInt64 = 0

    /// Whether incoming MIDI is being collected for learning.
    public var isCapturing: Bool {
        get { kernel.isCaptureEnabled() }
        set {
            if newValue { captureCursor = kernel.capturedEventCount() }
            kernel.setCaptureEnabled(newValue)
        }
    }

    /// Everything captured since the last drain.
    ///
    /// The ring is single-writer, single-reader and lock-free: the render thread
    /// only ever appends, and this only ever reads forward from its own cursor.
    /// If playing outran the UI the oldest events are simply gone — a dropped
    /// phrase is a nuisance, a glitch on the audio thread is a bug.
    public func drainCapturedEvents() -> [CapturedMIDIEvent] {
        let written = kernel.capturedEventCount()
        guard written > captureCursor else { return [] }
        let oldest = kernel.oldestCapturedEvent()
        var index = max(captureCursor, oldest)
        var events: [CapturedMIDIEvent] = []
        events.reserveCapacity(Int(written - index))
        while index < written {
            events.append(CapturedMIDIEvent(beat: kernel.capturedBeat(index),
                                            note: kernel.capturedNote(index),
                                            velocity: kernel.capturedVelocity(index),
                                            isOn: kernel.capturedIsOn(index)))
            index += 1
        }
        captureCursor = written
        return events
    }

    public var currentPass: Int64 {
        kernel.currentPass()
    }

    /// Where the loop is now, in beats from its start, or nil when nothing is
    /// playing. What the piano roll's playhead follows.
    public var loopPhaseBeats: Double? {
        let phase = kernel.currentPhaseBeats()
        return phase < 0 ? nil : phase
    }

    /// How long one pass through the loop lasts, in seconds, at the tempo the
    /// render thread is actually using — so the UI can say whether generating a
    /// take fits inside a loop. Nil until something has played.
    public var loopDuration: TimeInterval? {
        let tempo = kernel.currentTempo()
        let beats = kernel.currentLoopBeats()
        guard tempo > 0, beats > 0 else { return nil }
        return beats / tempo * 60
    }

    // MARK: - Rendering
    public override var internalRenderBlock: AUInternalRenderBlock {
        return processHelper!.internalRenderBlock()
    }

    // Allocate resources required to render.
    // Subclassers should call the superclass implementation.
    public override func allocateRenderResources() throws {		
        kernel.setMusicalContextBlock(self.musicalContextBlock)
        kernel.setMIDIOutputEventBlock(self.midiOutputEventListBlock)
        kernel.setLegacyMIDIOutputEventBlock(self.midiOutputEventBlock)
        kernel.initialize(outputBus!.format.sampleRate)
		try super.allocateRenderResources()
	}

    // Deallocate resources allocated in allocateRenderResourcesAndReturnError:
    // Subclassers should call the superclass implementation.
    public override func deallocateRenderResources() {
        
        // Deallocate your resources.
        kernel.deInitialize()
        
        super.deallocateRenderResources()
    }

	public func setupParameterTree(_ parameterTree: AUParameterTree) {
		self.parameterTree = parameterTree

		// Set the Parameter default values before setting up the parameter callbacks
		for param in parameterTree.allParameters {
            kernel.setParameter(param.address, param.value)
		}

		setupParameterCallbacks()
	}

	private func setupParameterCallbacks() {
		// implementorValueObserver is called when a parameter changes value.
		parameterTree?.implementorValueObserver = { [weak self] param, value -> Void in
            self?.kernel.setParameter(param.address, value)
		}

		// implementorValueProvider is called when the value needs to be refreshed.
		parameterTree?.implementorValueProvider = { [weak self] param in
            return self!.kernel.getParameter(param.address)
		}

		// A function to provide string representations of parameter values.
		parameterTree?.implementorStringFromValueCallback = { param, valuePtr in
			guard let value = valuePtr?.pointee else {
				return "-"
			}
			return NSString.localizedStringWithFormat("%.f", value) as String
		}
	}
}
