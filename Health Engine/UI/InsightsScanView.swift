// InsightsScanView.swift
// Epistemic role: display, and a deliberate speed bump. The association scan is real,
// minutes-scale background CPU work — this screen exists so starting it is a choice the user
// makes with eyes open, not something that happens silently the moment they open the app.

import SwiftUI

struct InsightsScanView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    let lastComputedAt: Date?

    @State private var didStart = false

    private var isRunning: Bool { services.recompute.isRunning }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accent)

                Text(isRunning ? "Looking for patterns…" : (didStart ? "Done" : "Look for new patterns"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("""
                     This tests every one of your tracked metrics against every other \
                     metric — and against calendar or location data, if you've granted \
                     access — then statistically corrects for the number of tests run, so \
                     nothing survives by chance alone.
                     """)
                    .foregroundStyle(Theme.textSecondary)

                Label("Takes about a minute. It runs in the background at low priority, so the app should stay usable, but your phone may feel slower until it finishes.",
                      systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .cardStyle(padding: 14)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $services.llmEnabled) {
                        Label("On-device AI explanations", systemImage: "sparkles")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.accent)
                    Text("""
                         When on, Apple's on-device model writes a short explanation for each \
                         finding, grounded only in your own numbers and a bundled research \
                         corpus — nothing leaves your phone. It never states a figure that \
                         wasn't handed to it, and falls back to a plain-language template \
                         automatically if it can't produce a grounded answer.
                         """)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                .cardStyle(padding: 14)

                if let lastComputedAt {
                    Text("Last updated \(lastComputedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                actionArea
            }
            .padding(24)
            .pageBackground()
            .navigationTitle("Update Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isRunning ? "Run in Background" : "Close") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .interactiveDismissDisabled(isRunning)
    }

    @ViewBuilder
    private var actionArea: some View {
        if isRunning {
            VStack(spacing: 10) {
                ProgressView(value: services.recompute.phase.fraction)
                    .tint(Theme.accent)
                Text(services.recompute.phase.label)
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        } else if didStart {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Findings are up to date.").foregroundStyle(Theme.textPrimary)
            }
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        } else {
            Button {
                didStart = true
                services.triggerFullScan()
            } label: {
                Label("Start Scan", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }
}
