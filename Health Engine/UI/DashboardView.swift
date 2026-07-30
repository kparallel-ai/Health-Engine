// DashboardView.swift
// Epistemic role: display. Every uncertainty in the data has a visual counterpart here —
// nothing is rendered as solid unless it was measured.

import Combine
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: DashboardViewModel

    init() {
        // Replaced in .task with the real store; this keeps the initialiser total.
        _model = StateObject(wrappedValue: DashboardViewModel(store: try! Store.inMemory()))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if services.recompute.isRunning { progressBanner }

                    if model.dayCount == 0 {
                        EmptyStateView(tier: services.tier)
                    } else {
                        summaryCard
                        constructGrid
                        if model.dayCount < ScanConfig().minNSameDay {
                            UnlockTimeline(unlocks: model.unlocks(currentTier: services.tier),
                                           tier: services.tier)
                        }
                        if !model.findings.isEmpty { findingsPreview }
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
            .refreshable { services.triggerRecompute(); model.reload() }
            .task { model.attach(store: services.store); model.reload() }
            .onReceive(services.recompute.$lastCompleted.compactMap { $0 }) { _ in model.reload() }
        }
    }

    private var progressBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(services.recompute.phase.label).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: services.recompute.phase.fraction)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.summary).font(.title3.weight(.medium))
            Text("\(model.dayCount) days of history · tier \(services.tier)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var constructGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(model.today, id: \.construct) { construct in
                NavigationLink {
                    MetricDetailView(metric: construct.construct, store: services.store)
                } label: {
                    ConstructCard(construct: construct)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var findingsPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Findings").font(.headline)
            ForEach(model.findings.prefix(3)) { finding in
                FindingRow(finding: finding)
            }
        }
    }
}

// MARK: - Construct card

struct ConstructCard: View {
    let construct: DailyConstruct

    private var confidence: DashboardViewModel.Confidence {
        DashboardViewModel.confidence(construct)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(construct.construct.displayName)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            Text(DashboardViewModel.format(construct))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(confidence == .insufficient ? .tertiary : .primary)

            if let label = DashboardViewModel.deviationLabel(construct) {
                BaselineBand(construct: construct)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            } else {
                // Not an error. It is the honest statement that no baseline exists yet.
                Text(construct.flags.contains("vendor_warmup")
                     ? "baseline still settling"
                     : "baseline needs \(Baselines.minimumSamples) days")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The band width *is* the uncertainty. A wide band is not a rendering choice; it is the
/// robust SD of the rolling window, drawn to scale.
struct BaselineBand: View {
    let construct: DailyConstruct

    var body: some View {
        GeometryReader { geo in
            let z = min(max(construct.deviationZ ?? 0, -3), 3)
            let centre = geo.size.width / 2
            let position = centre + CGFloat(z / 3) * centre

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(.tint.opacity(0.25))
                    .frame(width: geo.size.width / 3, height: 4)
                    .offset(x: geo.size.width / 3)
                Circle().fill(.tint)
                    .frame(width: 7, height: 7)
                    .offset(x: max(0, min(position - 3.5, geo.size.width - 7)))
            }
            .frame(height: 8)
        }
        .frame(height: 8)
    }
}

// MARK: - Designed empty states

/// Day zero. This is a screen, not an error. It says what exists now, what arrives when, and
/// which tier would add more — all computed from the same gates the analyzer enforces.
struct EmptyStateView: View {
    let tier: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Nothing measured yet")
                .font(.title2.weight(.semibold))
            Text("""
                 The explainers work right now with no data at all. Everything else starts \
                 once there are enough days to say something that isn't noise.
                 """)
                .foregroundStyle(.secondary)

            UnlockTimeline(unlocks: [
                .init(capability: "Baselines and deviations",
                      daysRequired: Baselines.minimumSamples, daysHave: 0, tierRequired: 1),
                .init(capability: "Two-variable associations",
                      daysRequired: ScanConfig().minNSameDay, daysHave: 0, tierRequired: 2),
                .init(capability: "Lagged context associations",
                      daysRequired: ScanConfig().minNLagged, daysHave: 0, tierRequired: 2)
            ], tier: tier)

            if tier < 2 {
                TierPrompt(tier: 2, unlocks: "Meeting density, schedule shape, time away from home")
            }
            if tier < 3 {
                TierPrompt(tier: 3, unlocks: "Body Battery, HRV status, training load, longer history")
            }
        }
    }
}

struct UnlockTimeline: View {
    let unlocks: [DashboardViewModel.Unlock]
    let tier: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What unlocks and when").font(.headline)
            ForEach(unlocks) { unlock in
                HStack(spacing: 10) {
                    Image(systemName: unlock.isUnlocked ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(unlock.isUnlocked ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unlock.capability).font(.subheadline)
                        if !unlock.isUnlocked {
                            Text("\(unlock.daysRemaining) more days"
                                 + (unlock.tierRequired > tier ? " · needs tier \(unlock.tierRequired)" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TierPrompt: View {
    let tier: Int
    let unlocks: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tier \(tier)").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            Text(unlocks).font(.subheadline)
            Text(tier == 3 ? "Optional one-time import. Nothing here is required."
                           : "Permission-gated. Denying it removes these features and nothing else.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
