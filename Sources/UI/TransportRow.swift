//
//  TransportRow.swift
//  UI
//
//  Play, host sync, and which way the loop runs — one control, once.
//
//  Five plug-ins wanted this and none had it. MelGen surfaced the three
//  parameters; ProgGenie and SwiftSerpe declared them and showed nothing;
//  SwiftPitchFold and SwiftDrawnQurve had no transport at all, which for a
//  looping gesture plug-in is a real limitation — a loop a host cannot start is
//  a loop you have to start by hand every time.
//
//  ── Why this lives in `UI` and not in `AUHost` ──────────────────────────────
//
//  Because it takes **bindings and closures, not `AUParameter`s.** The boundary
//  check forbids `ui → auhost` for a reason it learned the hard way: a control
//  bound to an AU parameter is not a control a plug-in without AU parameters can
//  use, and two of those sat in the UI kit unremarked until the package was
//  built. So the parameter half is `AUHost.TransportParameters`, which knows how
//  to find the three and hands back plain bindings; this half knows only that
//  something is playing.
//
//  The split costs one small type and buys a transport row that a plug-in with
//  no parameter tree at all can still draw — which is exactly what a MIDI
//  curator auditioning a clip needs.
//

import SwiftUI

/// What a plug-in offers. Absent bindings are absent controls.
///
/// Direction is optional because it is the one of the three that is not always
/// meaningful: a curator auditioning a clip backwards would be judging music
/// that is not in its library, and a probe has no loop at all. An optional
/// binding says "this plug-in does not have that" in a way a disabled control
/// cannot — a disabled control still claims the feature exists.
public struct TransportRow: View {
    @Binding public var isPlaying: Bool
    @Binding public var followsHost: Bool
    /// 0 forward, 1 backward, 2 ping-pong — matching `PluginPlaybackDirection`.
    public var direction: Binding<Int>?
    public let theme: MelGenTheme
    /// Shown beside the controls when there is something to say — a bar count, a
    /// phase, "no clip loaded". Empty draws nothing rather than an empty row.
    public var caption: String

    public init(isPlaying: Binding<Bool>,
                followsHost: Binding<Bool>,
                direction: Binding<Int>? = nil,
                theme: MelGenTheme,
                caption: String = "") {
        self._isPlaying = isPlaying
        self._followsHost = followsHost
        self.direction = direction
        self.theme = theme
        self.caption = caption
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MelGenMetrics.space2) {
            HStack(spacing: MelGenMetrics.space2) {
                playButton
                ToggleChip(title: "Host",
                           systemImage: "metronome",
                           isOn: $followsHost,
                           theme: theme)
                if let direction { directionPicker(direction) }
                Spacer(minLength: 0)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
            }
        }
    }

    /// Filled when playing, outlined when not — state never depends on colour
    /// alone, which is the suite's rule for every toggle.
    private var playButton: some View {
        Button {
            isPlaying.toggle()
        } label: {
            Label(isPlaying ? "Stop" : "Play",
                  systemImage: isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 84, minHeight: MelGenMetrics.controlHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPlaying ? theme.accentText : theme.text)
        .background(RoundedRectangle(cornerRadius: MelGenMetrics.radiusSmall)
            .fill(isPlaying ? theme.accent : theme.raised))
        .overlay(RoundedRectangle(cornerRadius: MelGenMetrics.radiusSmall)
            .stroke(isPlaying ? .clear : theme.borderStrong))
        .accessibilityLabel("Transport")
        .accessibilityValue(isPlaying ? "playing" : "stopped")
    }

    private func directionPicker(_ direction: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.directions.enumerated()), id: \.offset) { index, entry in
                Button {
                    direction.wrappedValue = index
                } label: {
                    DirectionIcon(direction: entry.icon)
                        .stroke(direction.wrappedValue == index ? theme.accent : theme.textMuted,
                                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        .frame(width: 26, height: 16)
                        .frame(width: MelGenMetrics.controlHeight,
                               height: MelGenMetrics.controlHeight)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: MelGenMetrics.radiusSmall)
                    .fill(direction.wrappedValue == index ? theme.sunken : .clear))
                .accessibilityLabel(entry.name)
                .accessibilityAddTraits(direction.wrappedValue == index
                                        ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// Index order is `PluginPlaybackDirection`'s — forward 0, backward 1,
    /// ping-pong 2 — and the *display* order is not, deliberately: backward,
    /// forward, ping-pong reads left to right the way the motion does, which is
    /// how DrawnQurve draws it. Getting these two orders confused would make a
    /// control that means one thing and stores another.
    private static let directions: [(icon: DirectionIcon.Direction, name: String)] = [
        (.forward, "Forward"), (.backward, "Backward"), (.pingPong, "Ping-pong"),
    ]
}
