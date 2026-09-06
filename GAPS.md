# What the Swift plug-ins do not do yet

*A register, and a strategy for it. Written 2026-09-05, covering the five
plug-ins built on this package. Kept here rather than in any one of them because
most of the gaps are shared, and a list that lives in five places is five lists
that disagree.*

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
| **Host sync / transport** | The kernel has `hostSync` and follows host tempo; MelGen uses it. ProgGenie and SwiftSerpe declare the parameter and it works, but no UI surfaces it. SwiftPitchFold and SwiftDrawnQurve have no transport at all | **Build** — in `Shell`. A shared transport row (play, host sync, direction) that a plug-in opts into is one control, once. SwiftDrawnQurve needs it most: a looping gesture plug-in a host cannot start is a real limitation |
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

---

## Keeping this true

`Scripts/check-gaps.sh` in this package fails when a plug-in beside the checkout
has no section here, so a sixth plug-in cannot arrive without its gaps being
written down. It does not check the contents — nothing can — but it makes the
omission loud, which is the failure this file is most likely to have.
