// DashboardView.swift
// Epistemic role: display. Every uncertainty in the data has a visual counterpart here —
// nothing is rendered as solid unless it was measured.

import Combine
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var model: DashboardViewModel
    @State private var showingGarminImporter = false
    @State private var garminImportResult: String?

    /// The metric currently "popped out" in place. Nil means the grid is flat.
    @State private var expandedConstruct: DailyConstruct?

    private static let dateHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f
    }()

    /// The nav title is the actual date, not the word "Today" — the tab bar already says
    /// "Today"; repeating it in the header carries no information the tab didn't already give.
    private var dateHeader: String {
        Self.dateHeaderFormatter.string(from: Date())
    }

    init() {
        // Replaced in .task with the real store; this keeps the initialiser total.
        _model = StateObject(wrappedValue: DashboardViewModel(store: try! Store.inMemory()))
    }

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if services.recompute.isRunning { progressBanner }

                        if model.dayCount == 0 {
                            EmptyStateView(tier: services.tier)
                        } else {
                            summaryCard
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Your Metrics · \(model.today.count) tracked")
                                constructGrid
                            }
                            if model.dayCount < ScanConfig().minNSameDay {
                                UnlockTimeline(unlocks: model.unlocks(currentTier: services.tier),
                                               tier: services.tier)
                            }
                            if !model.findings.isEmpty { findingsPreview }
                        }
                    }
                    .padding()
                    .animation(.spring(duration: 0.35), value: model.dayCount)
                }
                .pageBackground()
                .navigationTitle(dateHeader)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        // Tier 3 is optional and never gates anything else — this is the one
                        // affordance for it, reachable regardless of current tier or history length.
                        Button {
                            showingGarminImporter = true
                        } label: {
                            Label("Import Garmin Data", systemImage: "square.and.arrow.down")
                        }
                        .tint(Theme.accent)
                    }
                }
                .fileImporter(isPresented: $showingGarminImporter,
                             allowedContentTypes: [.zip, .json, .commaSeparatedText]) { result in
                    handleGarminImport(result)
                }
                .alert("Garmin Import", isPresented: .constant(garminImportResult != nil),
                      presenting: garminImportResult) { _ in
                    Button("OK") { garminImportResult = nil }
                } message: { Text($0) }
                .refreshable { services.triggerRecompute(); model.reload() }
                .task { model.attach(store: services.store); model.reload() }
                .onReceive(services.recompute.$lastCompleted.compactMap { $0 }) { _ in model.reload() }
            }

            if let construct = expandedConstruct {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { closeExpanded() }
                    .transition(.opacity)

                ExpandedMetricCard(construct: construct, store: services.store, onClose: closeExpanded)
                    .padding(.horizontal, 20)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .center).combined(with: .opacity),
                        removal: .scale(scale: 0.92, anchor: .center).combined(with: .opacity)))
            }
        }
        .tint(Theme.accent)
    }

    // A snappy, low-overshoot spring: transform-only (scale + opacity), never frame/size, so
    // the compositor animates it directly instead of re-running layout every frame. The earlier
    // matchedGeometryEffect version morphed the card's actual frame across two separate view
    // trees inside a LazyVGrid/ScrollView — correct in principle, but SwiftUI re-solves layout
    // and re-rasterizes both trees' shadows on every frame of that animation, which is what
    // read as choppy on device.
    private static let popAnimation = Animation.spring(response: 0.32, dampingFraction: 0.88)

    private func closeExpanded() {
        withAnimation(Self.popAnimation) {
            expandedConstruct = nil
        }
    }

    private func handleGarminImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            garminImportResult = error.localizedDescription
        case .success(let url):
            do {
                let report = try services.garmin.importFile(at: url)
                garminImportResult = report.summary
                services.updateTier()
                services.triggerRecompute()
            } catch {
                garminImportResult = error.localizedDescription
            }
        }
    }

    private var progressBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(services.recompute.phase.label).font(.caption).foregroundStyle(Theme.textSecondary)
            ProgressView(value: services.recompute.phase.fraction)
                .tint(Theme.accent)
        }
        .cardStyle()
    }

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Theme.accentGradient)
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.summary)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(model.dayCount) days of history · tier \(services.tier)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 16)
    }

    private var constructGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(model.today, id: \.construct) { construct in
                let isExpanding = expandedConstruct?.construct == construct.construct
                Button {
                    withAnimation(Self.popAnimation) {
                        expandedConstruct = construct
                    }
                } label: {
                    ConstructCard(construct: construct)
                        // A cheap opacity cue that "this one is open" — no frame matching,
                        // so it costs nothing during the popup's own animation.
                        .opacity(isExpanding ? 0.45 : 1)
                }
                .buttonStyle(PressableCardStyle())
            }
        }
    }

    private var findingsPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Findings · \(model.findings.count) surfaced")
            ForEach(model.findings.prefix(3)) { finding in
                FindingRow(finding: finding)
                    .cardStyle()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(Theme.accentSoft)
                    Image(systemName: construct.construct.symbolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 20, height: 20)

                Text(construct.construct.displayName)
                    .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }

            // Today's reading if there is one; otherwise the baseline, ghosted, so the card
            // never goes blank just because nothing was measured yet today. It is never
            // confusable with a measurement — different weight, tertiary colour, and the
            // caption below always says explicitly which one is on screen.
            if let value = construct.value {
                Text(DashboardViewModel.format(construct))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(confidence == .insufficient ? Theme.textTertiary : Theme.textPrimary)
            } else if let baseline = construct.baseline {
                Text(DashboardViewModel.formatValue(baseline, for: construct.construct))
                    .font(.title2.weight(.regular).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("—")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }

            if let label = DashboardViewModel.deviationLabel(construct) {
                BaselineBand(construct: construct)
                Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
            } else if construct.value == nil {
                // A real baseline can exist with full confidence and still have nothing to
                // compare today against — that's "not measured today," not "not enough history."
                // Conflating the two is what used to make a healthy month of history read as
                // if it were still short of the gate.
                Text(construct.confidence > 0 ? "baseline shown · not measured today" : "no reading yet")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            } else {
                // Not an error. It is the honest statement that no baseline exists yet.
                Text(construct.flags.contains("vendor_warmup")
                     ? "baseline still settling"
                     : "baseline needs \(Baselines.minimumSamples) days")
                    .font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
        .cardStyle()
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Capsule().fill(Theme.hairline).frame(height: 4)
                Capsule().fill(Theme.accentSoft)
                    .frame(width: geo.size.width / 3, height: 4)
                    .offset(x: geo.size.width / 3)
                Circle().fill(Theme.accentGradient)
                    .frame(width: 7, height: 7)
                    .offset(x: max(0, min(position - 3.5, geo.size.width - 7)))
            }
            .frame(height: 8)
        }
        .frame(height: 8)
    }
}

// MARK: - Metric expand-in-place

/// Replaces the old bottom-sheet quick look. Tapping a card pops this view up in place — a
/// scale-and-fade grow, the iOS "force touch" cue — rather than an unrelated sheet sliding up
/// from the bottom.
struct ExpandedMetricCard: View {
    let construct: DailyConstruct
    let store: Store
    let onClose: () -> Void

    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Theme.accentGradient)
                        Image(systemName: construct.construct.symbolName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)

                    Text(construct.construct.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            HStack(spacing: 0) {
                quickStat(label: "Today",
                         value: construct.value.map { DashboardViewModel.formatValue($0, for: construct.construct) },
                         emphasis: true)
                Divider().frame(height: 44)
                quickStat(label: "Baseline",
                         value: construct.baseline.map { DashboardViewModel.formatValue($0, for: construct.construct) },
                         emphasis: false)
            }

            if let label = DashboardViewModel.deviationLabel(construct) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.accentSoft, in: Capsule())
            }

            Button {
                showHistory = true
            } label: {
                Label("View full history", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(22)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 28, x: 0, y: 14)
        .fullScreenCover(isPresented: $showHistory) {
            NavigationStack {
                MetricDetailView(metric: construct.construct, store: store)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showHistory = false }
                        }
                    }
            }
            .tint(Theme.accent)
        }
    }

    private func quickStat(label: String, value: String?, emphasis: Bool) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(value ?? "—")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Theme.textTertiary
                                 : (emphasis ? Theme.textPrimary : Theme.textSecondary))
        }
        .frame(maxWidth: .infinity)
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
                .foregroundStyle(Theme.textPrimary)
            Text("""
                 The explainers work right now with no data at all. Everything else starts \
                 once there are enough days to say something that isn't noise.
                 """)
                .foregroundStyle(Theme.textSecondary)

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
            Text("What unlocks and when").font(.headline).foregroundStyle(Theme.textPrimary)
            ForEach(unlocks) { unlock in
                HStack(spacing: 10) {
                    Image(systemName: unlock.isUnlocked ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(unlock.isUnlocked ? .green : Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(unlock.capability).font(.subheadline).foregroundStyle(Theme.textPrimary)
                        if !unlock.isUnlocked {
                            Text("\(unlock.daysRemaining) more days"
                                 + (unlock.tierRequired > tier ? " · needs tier \(unlock.tierRequired)" : ""))
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                }
            }
        }
        .cardStyle(padding: 14)
    }
}

struct TierPrompt: View {
    let tier: Int
    let unlocks: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tier \(tier)").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            Text(unlocks).font(.subheadline).foregroundStyle(Theme.textPrimary)
            Text(tier == 3 ? "Optional one-time import. Nothing here is required."
                           : "Permission-gated. Denying it removes these features and nothing else.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
    }
}
