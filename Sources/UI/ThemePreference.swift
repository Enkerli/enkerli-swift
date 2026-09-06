//
//  ThemePreference.swift
//  UI
//
//  Choosing a theme, rather than inheriting one.
//
//  Every plug-in in the suite reads `colorScheme` from the environment and picks
//  `.light` or `.dark` from it. That is the right default and it is not
//  sufficient, for a reason specific to this kind of software: **an AUv3 lives
//  inside somebody else's window.** A host can present a dark chrome and hand
//  the extension a light environment, or the reverse, or change its mind when
//  the plug-in is moved between a rack and a full-screen view. The JUCE
//  DrawnQurve has an explicit Light/Dark switch for exactly this, and it is on
//  this register as a shared gap because five plug-ins want the same one.
//
//  Three states rather than two. "System" is not a third theme — it is the
//  absence of a choice, and collapsing it into a stored light/dark would mean a
//  plug-in that stops following the host the first time somebody looks at the
//  control.
//

import SwiftUI

public enum ThemePreference: String, Codable, CaseIterable, Sendable {
    /// Follow the environment. The default, and what every plug-in did before
    /// there was a choice.
    case system
    case light
    case dark

    public var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// The theme to paint with.
    ///
    /// Takes the environment's scheme rather than reading it, so this stays a
    /// pure function and a plug-in can be rendered either way in a preview or a
    /// screenshot without lying about which it chose.
    public func theme(in scheme: ColorScheme) -> MelGenTheme {
        switch self {
        case .system: return scheme == .dark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// What the next tap gives you: Auto → Light → Dark → Auto.
    ///
    /// A cycle rather than a picker because this is one control in a corner, and
    /// three states are few enough to tap through. The order puts the two
    /// explicit choices together so a person who wants "not what the host says"
    /// finds both without passing back through Auto.
    public var next: ThemePreference {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

/// The control. One button, in a corner, cycling three states.
public struct ThemeChip: View {
    @Binding public var preference: ThemePreference
    public let theme: MelGenTheme

    public init(preference: Binding<ThemePreference>, theme: MelGenTheme) {
        self._preference = preference
        self.theme = theme
    }

    public var body: some View {
        Button {
            preference = preference.next
        } label: {
            Label(preference.label, systemImage: preference.symbolName)
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.iconOnly)
                .frame(width: MelGenMetrics.controlHeight,
                       height: MelGenMetrics.controlHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textSecondary)
        .background(RoundedRectangle(cornerRadius: MelGenMetrics.radiusSmall)
            .stroke(theme.border))
        // Icon-only, so the label has to carry the whole meaning — and the
        // value has to say what the *current* state is rather than what the
        // button does, or a screen reader announces the next state as the
        // present one.
        .accessibilityLabel("Theme")
        .accessibilityValue(preference == .system
                            ? "following the host" : preference.label)
        .accessibilityHint("Cycles between following the host, light and dark")
    }
}
