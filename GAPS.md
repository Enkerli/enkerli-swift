# What the Swift plug-ins do not do yet

*A register, and a strategy for it. Written 2026-09-05, covering the eight
plug-ins built on this package — and the one that is not. Kept here rather than
in any one of them because most of the gaps are shared, and a list that lives in
seven places is seven lists that disagree.*

---

## The framing, and its limits

Each Swift plug-in is a **skateboard** to its JUCE counterpart's **car** — the
analogy from Henrik Kniberg's "Making sense of MVP", where the point is to ship
something that *moves* at every stage rather than a wheel, then a chassis, then a
car. That is the right frame for these, and it is deliberate: MelGen aside, every
one of them was built in an afternoon on a foundation that already existed, and
each does one thing end to end.

The analogy is also over-used and worth holding loosely. Two ways it misleads
here:

- **A skateboard is not an early car.** It is a different vehicle, and some of
  these plug-ins should stay different. SwiftDrawnQurve draws with a Pencil and
  records pressure; the JUCE build cannot, and never will through a WebView.
  Building "toward" the car would mean building away from that.
- **The car is not obviously the destination.** The JUCE builds accumulated
  features over years, and some of that accumulation is the thing the rewrite is
  a chance to not repeat. A gap is not automatically a debt.

So this register has three columns of intent, not two: **build**, **decide**,
and **won't**. The middle one is the honest majority.

---

## The line that matters most

**A missing control is a gap. A control that lies is a bug.**

That distinction is why this file starts with a fix rather than a list.
SwiftPitchFold and SwiftDrawnQurve each declared `playMelody`,
`playbackDirection` and `hostSync` as AU parameters, inherited by being
scaffolded from a plug-in that schedules notes. The kernel acts on all three
inside `processMelody`, and neither of those two ever commits a sequence — so a
host displayed three automatable controls that did nothing whatsoever.

Both trees are empty now. An empty parameter tree is an honest statement about a
plug-in that has no host-automatable controls yet. Three inert ones were not.

Nothing else in this register is in that category, and anything that lands in it
gets fixed rather than listed.

---

## Shared gaps

Present in every Swift plug-in, and therefore fixable **once, in this package**
rather than five times. That is the main argument for having this file at all.

| Gap | State | Intent |
|---|---|---|
| **Host sync / transport** | The kernel has `hostSync` and follows host tempo; MelGen uses it. ProgGenie and SwiftSerpe declare the parameter and it works, but no UI surfaces it. SwiftPitchFold and SwiftDrawnQurve have no transport at all. SwiftMIDIcurator is the first to put play and host sync on screen, which is what the shared row should look like | **Build** — in `Shell`. A shared transport row (play, host sync, direction) that a plug-in opts into is one control, once. SwiftDrawnQurve needs it most: a looping gesture plug-in a host cannot start is a real limitation |
| **Theme choice** | Every plug-in reads `colorScheme` from the environment. `MelGenTheme` has `.light` and `.dark` and no way to choose | **Build** — in `UI`. An AUv3 lives inside somebody else's window and does not always inherit the scheme its author intended. The JUCE DrawnQurve has an explicit Light/Dark switch for exactly this reason |
| **Presets / factory content** | No plug-in ships presets. `fullState` round-trips a session, so the mechanism exists; nothing populates it | **Decide.** MelGen has `SetupStore`; the others have nothing. Whether a quantizer wants presets is a real question, not an oversight |
| **MIDI panic** | Nothing sends all-notes-off. The kernel releases what *it* is holding when stopped, per plug-in; nothing clears a host's stuck notes | **Build** — in `Shell`, cheap, and the kernel already tracks held notes for two of its three jobs |
| **Inline help** | None. The JUCE builds have a `?` overlay | **Decide.** These interfaces are small enough that the copy on screen may be the help; that is the argument MelGen's design brief already makes |
| **Undo** | None anywhere | **Won't**, for now. A plug-in's undo has to agree with a host's, and getting that wrong is worse than not having it |
| **Accessibility beyond labels** | Every control has a label, value and hint; nothing has been tested with VoiceOver on a device | **Decide** — but this is the one on the list whose absence is least defensible, and it is cheap to start |

---

## Per plug-in

Each entry's first line is the one sentence the plug-in is. A feature that does
not serve that sentence is a candidate for **won't**, and saying so is the point.

### MelGen — `aumi MlGn`

*Composes lines, comps and basslines over a progression and loops them.*

Not a skateboard: it is the original, and its gaps are in
[ISSUES.md](https://github.com/Enkerli/MelGen/blob/main/ISSUES.md) and
[ROADMAP.md](https://github.com/Enkerli/MelGen/blob/main/ROADMAP.md) rather than
here. The one thing it shares with the others: the bass mode has never been
heard on a device.

### ProgGenie — `aumi PgGn`

*Generates chord progressions and keeps a durable opinion about chord changes.*

| Gap | Intent |
|---|---|
| Corpus browsing — seeing what the statistics say, not only hearing them | **Build.** PORTING.md §7 names it as the other half of what ProgGenie has over MelGen |
| Curation steers by rejection sampling over 12 candidates | **Decide.** Weighting the distribution directly is better and means the shared generator learning that opinions exist |
| No per-transition curation export / sharing profile | **Decide.** The JS has it; whether a plug-in wants a file format is a separate question |
| Voicing style, register, inversions | **Won't.** That is MelGen's job, and this plug-in sits beside it |

### SwiftSerpe — `aumi Srpe`

*Turns UPI notation into rhythm.*

| Gap | Intent |
|---|---|
| Progressive notation (`pat>N`, `%N`, `+N`, `*N`) — vectors exist for all four | **Build.** The parser handles them; the plug-in has nowhere to put a trigger index |
| Poly lanes — `poly.json` has covered them since before this port | **Build.** The vectors are ready and the parser is not |
| Analysis readout is one line where the monorepo has six vector-covered measures | **Build**, cheaply |
| `R(k,n)` random patterns | **Won't.** `Math.random` has no cross-language contract; implementing it with a different RNG would look like parity and not be it |
| Accent cycling across playback cycles | **Decide.** The engine precesses accents over loops; this shows the first cycle only |

### SwiftPitchFold — `aumi PtFd`

*Folds incoming notes into a pitch-class set.*

| Gap | Intent |
|---|---|
| Voice modes — mono-merge, poly-spread, chordize, voice-split | **Decide, and not soon.** Three of the four emit *more* notes than they receive, which the kernel's transform cannot do: one note in, one note out. A second capability, not a missing switch |
| Time quantization — delaying notes onto a grid | **Decide.** Needs a render-thread delay buffer, which is a third thing to get right in the render block |
| Performance pads | **Won't.** The JUCE build's pads are a chord-launching surface; this plug-in folds what you play, and a pad that plays for you is a different product |
| Host-automatable fold on/off | **Build**, with the shared transport row |

### SwiftDrawnQurve — `aumi DrwQ`

*Draw a line; it loops as MIDI.*

| Gap | Intent |
|---|---|
| Run/stop is a UI button, not a parameter | **Build** — the most-wanted item on this page. See shared transport |
| X/Y grid quantization ("qurve quantization") — snap the playhead to tick columns, or the value to grid rows | **Build.** It is the JUCE build's most distinctive control and it is cheap: both are arithmetic on a phase and a value, both fit in the render block beside the smoothing that is already there |
| One curve per lane; the JUCE engine holds four "qurves" per lane so a note lane sounds polyphonically | **Decide.** Four lanes × four curves is sixteen playheads and a UI problem; four drawn lanes each with a pressure companion is already eight |
| Per-lane speed and direction, tempo sync | **Build**, with the shared transport. A curve currently loops on its own recorded duration and nothing else |
| Teach / CC-learn | **Decide.** Genuinely useful, and it needs the capture ring the kernel already has |
| Legato mode, one-shot per lane in the UI | **Decide.** `isOneShot` exists in the data and has no control |
| Pencil tilt and azimuth | **Won't**, yet — but noted, because pressure took one file and tilt would take the same one. The question is whether a third curve per gesture is legible, not whether it is possible |

### SwiftMIDIcurator — `aumi MdCr`

*A library of MIDI clips you can audition, judge and find again.*

The skateboard that is furthest from its car, and in a different direction: the
JUCE MIDIcurator is a 252-line shell around a curation model that mostly did not
exist yet. This one has the model — because MelGen needed it and it was built as
foundation — and almost no shell.

| Gap | Intent |
|---|---|
| Harmony is only ever read, never detected. A file with no changes gets no analysis, and the interface says so rather than inventing numbers | **Build.** `Theory` can already name a set from pitch classes; running that over a clip's notes is the missing step, and it turns every unanalysed clip in a library into an analysed one |
| The library is one flat list. No folders, no saved filters, no search | **Build**, in that order. Search first — a library big enough to need curating is big enough to need finding |
| Two instances share one library, and the sharing is not transactional: judgements made in one appear in the other on next read, and simultaneous writes take the last one | **Decide.** The alternative is a coordinated store, which is real work for a case (two curators open at once) nobody has hit |
| No export. A clip you kept cannot be written back out, and `Carrier` has had `MIDIExport.write` the whole time | **Build**, and it is nearly free — the writer is already linked and already round-trips in the test suite |
| Nothing is ever deleted; a skip is a mark, not a removal | **Won't.** That is the model, not a gap, and it is written here so it does not get "fixed" |
| `TakeAspect` — *which part* of a clip works — is in the vocabulary and has no control | **Build.** `AspectPicker` exists in the UI kit; the `partial` disposition is the one of seven that currently records less than it could |
| Playback direction, which the kernel supports and this plug-in deliberately does not declare | **Won't.** A mark records what you heard; hearing a clip backwards and marking the forward one records a judgement of music that is not in the library |
| Clips are matched as duplicates on pitch and start beat only. Two files that differ in tempo but not in notes are one clip | **Decide.** Probably right, and untested against a real folder of exports |

### SwiftRndSysExProbe — `aumi SxPr`

*Answers one question per host: does SysEx survive a plug-in, in and out?*

Not a skateboard version of anything. It is a **diagnostic**, and the JUCE build
is one too — the port is close to feature-complete because there was very little
feature to port. What it gained is the shared kernel's SysEx path and its
harness, which is the half that can be wrong silently.

| Gap | Intent |
|---|---|
| No direct MIDI port. The JUCE probe and companion can open the device themselves, bypassing host routing entirely — which is the only thing that works in Logic and Bitwig | **Decide**, and it is the biggest question on this page. An AUv3 opening its own CoreMIDI port is legal and is also a plug-in doing something a host cannot see |
| No copy-to-clipboard for the report. `ProbeState.report` builds the text and nothing offers it | **Build**, trivially, and it matters more than its size — the output of a diagnostic that cannot be pasted into a bug report mostly does not leave the screen |
| Per-host results are not recorded anywhere in the plug-in; `rnd-companion/docs/SYSEX_PASSTHROUGH.md` is the register | **Won't.** A measurement is about a host and a version, and a plug-in is the wrong place to accumulate that |
| The probe cannot distinguish "the host dropped our output" from "nothing is attached" | **Won't** — it is not a limitation, it is the truth, and the verdict says so in as many words. Anything else would be a green light that means nothing |
| No timestamps in the traffic log beyond arrival order | **Decide.** Ordering is what matters for framing bugs; latency would be a different instrument |

### SwiftRndCompanion — `aumi RnCo`

*Capture and send patch seeds on a Cymaforma RND, and keep the ones worth
remembering.*

The skateboard with the largest car behind it: the JUCE build is 3,237 lines
plus a WebView app from the monorepo, two transports, and a library in the
suite's interchange format. This is one transport, one screen, and a library in
`UserDefaults`.

**It has never been run against the hardware.** Nothing below that line can be
called verified, the protocol itself is observed rather than published, and a
firmware update can invalidate any of it. That is the first row for a reason.

| Gap | Intent |
|---|---|
| Never tested against an RND. Every check is bytes and bookkeeping | **Build** — meaning: take the measurement. This is not a feature gap, it is the thing that decides whether any other row is worth doing |
| **No direct MIDI port.** The JUCE build opens the device itself, which is the only thing that works in Logic and Bitwig; this one is host-routed only, proven in AUM and nowhere else | **Decide**, and it is the biggest question on this page — shared with SwiftRndSysExProbe, which is where the measurement would come from |
| The seed library is `UserDefaults` JSON, not the suite's `enkerli-library-item` envelope. The JUCE build writes files that open in the rest of the suite | **Build.** It is a format, the spec exists, and a library that only this plug-in can read is a library that leaves with the plug-in |
| No export or import of a seed library at all | **Build**, with the above — one job, not two |
| The tonic pulse's note-off is in the same burst as its note-on, so the gate is one render block. The JUCE version carried a millisecond delay | **Decide** — and the honest state is *unknown*: whether the device needs a longer gate has not been tested, and the burst does not currently express a delay |
| No seed randomiser, and no history of what was sent | **Decide.** The device generates; asking a plug-in to guess seeds at it is a different product |
| Nothing reads the two unknown bytes in a `trackEngine` frame | **Won't**, until there is a capture that explains them. Decoding a byte nobody understands into a label would be inventing a fact |
| Scale and tonic lock on the device and only a power cycle is known to clear it. The interface says so; nothing prevents it | **Won't.** A control that refuses to do what it says is worse than one that warns |

### SwiftVane — `aumu Vayn`

*A breath-first wind voice: blow it, do not strike it.*

The first instrument in the suite and the largest car behind any skateboard
here: the JUCE Vane is 10,533 lines with a wavetable importer, MTS-ESP, a
modulation matrix, a formant filter, a comb resonator, transients, presets and
a WebView interface. This is one mono voice, one built-in table, one filter.

What it keeps is what makes it Vane rather than a generic synth: breath is the
amplitude, legato does not retrigger, and everything that could step glides.

| Gap | Intent |
|---|---|
| ~~Never heard~~ — **played on a device 2026-09-06: "limited but working"**. The render path is also covered by 34 checks including aliasing, clicks and segment offsets | **Done, at MVP scope.** "Limited" is this table; "working" is the part no harness could have told us |
| Monophonic. The kernel merges MPE channels deliberately — one voice, whichever finger is expressing it — so a chord is not possible | **Decide.** Vane is "mono-capable" and this is the capable half. Polyphony means a voice allocator and per-note expression state, which is a real piece of work and a different instrument |
| One built-in wavetable — the harmonic stack. No `.wav` import, no Serum/Vital frame detection, no library browser | **Build**, in that order, and the table format already supports it: `VaneWavetable` stores mip levels exactly as Vane's does, so an importer fills in frames and changes nothing else |
| No MTS-ESP. The JUCE build retunes from a host tuning table | **Build.** It is the one feature on this list that this suite has a specific reason to care about, given how much of `Theory` is about what a scale *is* |
| No modulation matrix, no LFOs, no second envelope | **Decide.** The matrix is a third of Vane's source and most of what makes it hard to learn. A skateboard with a mod matrix is a car |
| Filter is low-pass only; band-pass and high-pass are two lines away and not exposed | **Decide.** Nothing here would drive the choice yet |
| No formant filter, comb resonator, wavefolder or transient library | **Won't**, for now — and this is the row most worth having. These are what a decade of accretion looks like, and the rewrite's opportunity is not to do the accretion again |
| The breath envelope's shape is four numbers, where it wants to be a recorded curve | **Build**, and the foundation is already there: `levelFor` is a pure function of phase and segment times precisely so a curve lookup can replace the arithmetic, and SwiftDrawnQurve on this same package already records one |
| No presets. A synth without presets is a synth nobody hears twice | **Build.** Shared gap, and the one plug-in where it stops being optional |
| Resonance at 1.0 is a clean sine, not the rich self-oscillation a real filter gives — no soft saturation on the feedback path | **Decide.** Noted in Vane's own file as future work and still future work |

### SwiftWorkspace — `aumi Bnch`

*The suite's message bus, inside a DAW: watch the plane, and play what crosses it.*

Not a port of the web workspace's modules, and it does not pretend to be. It is
the half of the JUCE plug-in that is a plug-in's job — bus notes out as real host
MIDI, host MIDI in, and the plane made visible — plus the one module a plug-in
most needs, which is a monitor.

| Gap | Intent |
|---|---|
| **Note-offs come from a timer, not the render block.** A `durationMs` is honoured on the main queue, so it is good enough to audition a chord and not good enough to play in time. The JUCE build has `LiveNoteScheduler` for exactly this | **Build.** The kernel already schedules a whole sequence sample-accurately; what is missing is a way to hand it *one* note now, which is a small addition to a path that exists |
| Host MIDI is not announced on the plane. `announcesInput` exists, defaults off, and nothing implements it | **Build.** It is the other half of what makes a workspace a hub, and the capture ring already collects the notes |
| No modules beyond the monitor and a note sender. No control surface, no UPI pattern module, no bindings | **Decide**, module by module. Some of these are better as their own plug-ins on this foundation — SwiftSerpe *is* the UPI module — and a workspace that reimplements them would be the accumulation the rewrite exists to avoid |
| Nothing sends a `manifest`, so nothing on the plane knows what this plug-in can be told | **Build.** The protocol's control plane is the interesting half and this speaks none of it yet |
| The layout does not ride the DAW session, because there is no layout | **Won't**, until there are modules to arrange |
| Two instances see the same routing and both will play it | **Won't** — that is what a bus is. `Play notes` exists to turn one of them off |

---

## The two that changed their minds

**All nine plug-ins in the suite now have a Swift-native version.** This section
used to hold the two we declined to port, and both arguments were overruled —
so what is left of it is the arguments themselves, kept rather than deleted,
because two reversed decisions with the same shape are worth more than a tidy
page.

### Vane — **built after all**

This section used to say **won't**, at length, and the argument was:

> Every plug-in on this package is an `aumi` MIDI processor … None of them
> touches a sample … A "Vane MVP on this foundation" would be one of two things,
> and both are worse than not doing it.

That was overruled, and it should have been. What it got right was the
*architecture* and what it got wrong was treating an architectural constraint as
a reason not to build something. The two options it named were a synth that
emits no audio, and "a second foundation wearing this one's name" — and there
was a third it did not see: a **sibling target** that `Kernel` and `Shell` do
not depend on, so a MIDI processor links not one line of it and the separation
is a dependency edge rather than a promise in a document.

So `AudioKernel` and `Instrument` exist, `AUHost` was split out of `Shell` to
serve both kinds of audio unit, and the plug-in is
[SwiftVane](https://github.com/Enkerli/SwiftVane) — `aumu Vayn`. Its gaps are
below with everyone else's.

The general lesson is worth keeping: **"this foundation cannot do X" is a claim
about a shape, and shapes can be changed.** The question to ask of the next one
is not whether the constraint is real but whether relaxing it costs more than
the thing is worth.

### Suite Workspace — **built after all, and not the way the argument assumed**

This section said **won't** too, and it was wrong in the same shape as Vane's:

> Workspace's 460 lines swap the edges of a bus … Everything a user would call
> "Workspace" is `music-suite/apps/workspace`, in TypeScript … Rewriting the 460
> lines in Swift gains nothing and loses the app.

The mistake was looking at `modules.js` — 2,223 lines importing a dozen monorepo
packages — concluding the product was the web app, and stopping. Underneath it
is `@enkerli/protocol`: a small package with **committed byte-exact vectors**,
whose own header calls them "the cross-language contract for that C++ side,
exactly like @enkerli/theory's rhythm vectors."

Porting *that* is not forking a module system. It is the same job as the theory
and UPI vectors, and it was already half done — the bus rides SysEx, and the
kernel grew SysEx in and out for the RND companion.

So the protocol is `Carrier`'s now, checked in both directions against all ten
vectors, and the plug-in is
[SwiftWorkspace](https://github.com/Enkerli/SwiftWorkspace) — `aumi Bnch`. It is
**not** a port of the web app's modules, and does not pretend to be: it is the
half of that plug-in that is genuinely a plug-in's job.

Twice now the "won't" was an argument about the wrong layer. Rule 5 below is
amended accordingly.


---

## The strategy, in four rules

**1. Shared gaps get built in the package, once.** Two of the seven above are
worth building and both belong in `Shell` or `UI`. Five plug-ins gaining a
transport row and a theme switch from one change is the entire argument for the
foundation, applied to interface rather than to theory.

**2. A specific gap is judged against the plug-in's one sentence.** Every
per-plug-in table above starts with that sentence for this reason. "The JUCE
build has it" is not an argument; "it serves the sentence" is.

**3. What we decline, we write down.** The **won't** rows are the ones that keep
this from being a list of everything the old builds do. A rewrite's real
opportunity is not doing the accumulation again, and that opportunity is only
taken if it is recorded — otherwise every gap becomes a debt by default and the
skateboard grows into the same car.

**4. A control that does nothing gets removed, not listed.** The line at the top
of this file. Gaps are honest; inert controls are not, and they are the one
category here with no "decide" option.

**5. A plug-in we decline to port gets an argument, not a silence — and the
argument is probably about the wrong layer.** Both of the two we declined were
overruled, and both arguments failed the same way: they looked at the largest,
most visible artefact (Vane's 10,533 lines; Workspace's 2,223-line `modules.js`)
and generalised from it, without asking what was *underneath*. Underneath Vane
was a missing audio path, which a sibling target supplies. Underneath Workspace
was a 706-line protocol with committed vectors, which is the suite's most
routine kind of port.

So the rule now has a second half: before writing "won't", name the layer the
obstacle actually lives at, and check whether that layer is the one you looked
at. Both times it was not.

---

## Keeping this true

`Scripts/check-gaps.sh` in this package fails when a plug-in beside the checkout
has no section here, so an eighth plug-in cannot arrive without its gaps being
written down. It does not check the contents — nothing can — but it makes the
omission loud, which is the failure this file is most likely to have.
