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

    static let hairline = Color(red: 0.878, green: 0.839, blue: 0.796)
}

/// One consistent card treatment: raised surface, soft shadow instead of a flat fill, so
/// depth comes from light rather than a grey block.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 3)
    }
}

extension View {
    func cardStyle(padding: CGFloat = 14) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// The page background every scroll surface in the app sits on.
    func pageBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
