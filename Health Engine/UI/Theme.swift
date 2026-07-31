// Theme.swift
// Epistemic role: shared visual language. Colors and card styling live here so every screen
// reads as one app, not a stack of separately-styled views.

import SwiftUI

enum Theme {
    /// Warm cream page background — the app's answer to "not another black screen."
    static let background = Color(red: 0.980, green: 0.965, blue: 0.941)
    /// Card surfaces sit a shade lighter than the page so they lift without a hard edge.
    static let surface = Color(red: 0.996, green: 0.988, blue: 0.976)
    static let surfaceRaised = Color.white

    static let textPrimary = Color(red: 0.169, green: 0.145, blue: 0.129)
    static let textSecondary = Color(red: 0.475, green: 0.412, blue: 0.365)
    static let textTertiary = Color(red: 0.671, green: 0.616, blue: 0.573)

    /// Warm terracotta — the one accent color, used sparingly so it still means something
    /// when it shows up (progress, links, the tint on interactive controls).
    static let accent = Color(red: 0.878, green: 0.404, blue: 0.208)
    static let accentSoft = accent.opacity(0.14)
    /// A lighter, warmer sibling of `accent` — exists only to make `accentGradient` read as
    /// a gradient rather than a flat fill on the small surfaces that use it.
    static let accentBright = Color(red: 0.945, green: 0.573, blue: 0.322)

    static let hairline = Color(red: 0.878, green: 0.839, blue: 0.796)

    /// The one gradient reserved for emphasis surfaces — buttons, badges, the progress track.
    /// Never used as a large fill; a gradient across a whole screen reads as decoration, not signal.
    static let accentGradient = LinearGradient(colors: [accent, accentBright],
                                                startPoint: .topLeading, endPoint: .bottomTrailing)

    /// A near-imperceptible warmth gradient behind every scroll surface. Flat cream is what
    /// read as "stale and mechanical"; this keeps the same palette but gives the eye a
    /// top-to-bottom gradient instead of one flat value.
    static let pageGradient = LinearGradient(
        colors: [Color(red: 0.988, green: 0.976, blue: 0.953), background],
        startPoint: .top, endPoint: .bottom)
}

/// One consistent card treatment: raised surface, hairline border, soft two-layer shadow so
/// depth comes from light rather than a grey block.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 6)
            .shadow(color: .black.opacity(0.045), radius: 2, x: 0, y: 1)
    }
}

extension View {
    func cardStyle(padding: CGFloat = 14, cornerRadius: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding, cornerRadius: cornerRadius))
    }

    /// The page background every scroll surface in the app sits on.
    func pageBackground() -> some View {
        background(Theme.pageGradient.ignoresSafeArea())
    }
}

/// A small uppercase eyebrow label used above major sections, so a screen reads as distinct
/// sections rather than one undifferentiated scroll.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Tactile press feedback for tap targets that open something further — a small scale-down,
/// the same cue iOS uses to signal "this is about to expand."
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
