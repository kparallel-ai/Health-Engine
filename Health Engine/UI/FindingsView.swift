// FindingsView.swift
// Epistemic role: display. The tier badge is the most important element on this screen —
// it is what stops a co-occurrence from reading like a cause.

import Charts
import Combine
import SwiftUI

struct FindingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var findings: [Finding] = []
    @State private var survivedCount: Int = 0
    @State private var lastComputedAt: Date?
    @State private var verdicts: [String: String] = [:]
    @State private var familySize: Int = 0
    @State private var showingScan = false

    var body: some View {
        NavigationStack {
            List {
                if familySize > 0 {
                    Section {
                        testSummary
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }

                if findings.isEmpty {
                    Section {
                        Text("""
                             No associations have cleared the evidence gates yet. That is the \
                             expected state early on — most tested patterns never should.
                             """)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.surfaceRaised)
                } else {
                    ForEach(findings) { finding in
                        Section {
                            FindingRow(finding: finding, store: services.store)
                            FindingStats(finding: finding)
                            verdictButtons(for: finding)
                        }
                        .listRowBackground(Theme.surfaceRaised)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .pageBackground()
            .navigationTitle(findings.isEmpty ? "Findings" : "Findings · \(findings.count)")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingScan = true
                    } label: {
                        Label("Update Insights", systemImage: "arrow.clockwise")
                    }
                    .tint(Theme.accent)
                }
            }
            .sheet(isPresented: $showingScan) {
                InsightsScanView(lastComputedAt: lastComputedAt)
            }
            .task { reload() }
            .onReceive(services.recompute.$lastCompleted.compactMap { $0 }) { _ in reload() }
        }
        .tint(Theme.accent)
    }

    /// What used to be a small caption buried at the bottom of the list — the actual headline
    /// number ("how many tests ran, how many survived") belongs at the top, not as a footnote.
    private var testSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                statBlock(value: "\(familySize)", label: "Tested")
                statBlock(value: "\(survivedCount)", label: "Survived")
            }
            if survivedCount != findings.count {
                Text("""
                     Showing \(findings.count) distinct relationships — related metrics \
                     (Body Battery min/max, different sleep measures, and so on) are collapsed \
                     to their single strongest result.
                     """)
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Corrected together via Benjamini–Hochberg, q = 0.10.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 16)
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func reload() {
        let all = (try? services.store.surfacedFindings()) ?? []
        survivedCount = all.count
        lastComputedAt = all.map(\.computedAt).max()
        findings = FindingsView.dedupedByPair(all)
        verdicts = (try? services.store.verdicts()) ?? [:]
        // Two independently BH-corrected families now feed this screen (context associations,
        // which need calendar/location permission and months of history, and associations
        // between the app's own metrics, which don't) — "tested" has to count both.
        let contextSize = (try? services.store.familySize(ScanFamily.contextAssociations.id)) ?? 0
        let biometricSize = (try? services.store.familySize(ScanFamily.biometricAssociations.id)) ?? 0
        familySize = contextSize + biometricSize
    }

    /// Body Battery min and max both correlating with sleep isn't two findings, it's one
    /// finding told twice — same for the different sleep sub-measures, or SDNN vs. rMSSD HRV.
    /// Collapsing by metric *family* rather than exact metric catches that in a way exact-pair
    /// dedup (lag 0 vs. lag 1 of the *same* metric pair) couldn't. Keeps only the single
    /// strongest result per unordered family pair; the BH correction and "Tested" count
    /// upstream are untouched — this only changes what's displayed.
    static func dedupedByPair(_ all: [Finding]) -> [Finding] {
        var best: [String: Finding] = [:]
        for f in all {
            guard let subject = Metric(rawValue: f.subject) else { continue }
            let objectFamily = f.object.flatMap { Metric(rawValue: $0)?.correlationFamily }
            let key = [subject.correlationFamily.rawValue, objectFamily?.rawValue ?? (f.object ?? "")]
                .sorted().joined(separator: "|")
            if let existing = best[key], !isStronger(f, than: existing) { continue }
            best[key] = f
        }
        return best.values.sorted { isStronger($0, than: $1) }
    }

    private static func isStronger(_ a: Finding, than b: Finding) -> Bool {
        if a.tier != b.tier { return a.tier > b.tier }
        return abs(a.effectSize ?? 0) > abs(b.effectSize ?? 0)
    }

    @ViewBuilder
    private func verdictButtons(for finding: Finding) -> some View {
        HStack(spacing: 16) {
            if let verdict = verdicts[finding.id] {
                Label(verdict == "confirmed" ? "You confirmed this" : "You dismissed this",
                      systemImage: verdict == "confirmed" ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Button("Rings true") { record(finding, "confirmed") }
                Button("Doesn't") { record(finding, "dismissed") }
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .tint(Theme.accent)
    }

    private func record(_ finding: Finding, _ verdict: String) {
        try? services.store.setVerdict(findingID: finding.id, verdict: verdict)
        verdicts[finding.id] = verdict
    }
}

// MARK: - Row

struct FindingRow: View {
    let finding: Finding
    let store: Store
    @EnvironmentObject private var services: AppServices

    private enum NarrationState {
        case pending
        case ready(Narrator.Output)
    }
    @State private var narration: NarrationState = .pending

    /// Which candidate pool this came from — context associations require calendar/location
    /// permission and months of data; biometric ones don't, so the two read very differently
    /// in terms of how much to trust them being available at all.
    private var familyLabel: String? {
        if finding.familyID == ScanFamily.biometricAssociations.id { return "Between your own metrics" }
        if finding.familyID == ScanFamily.contextAssociations.id { return "Context" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TierBadge(tier: finding.tier)
                if let familyLabel {
                    Text(familyLabel.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if case .ready(let output) = narration, !output.isTemplated {
                    AIGeneratedBadge()
                }
            }

            explanation

            FindingTimeline(finding: finding, store: store)
        }
        .padding(.vertical, 4)
        .task(id: finding.id) {
            guard services.llmEnabled else { narration = .pending; return }
            let query = FindingNarration.query(for: finding, profile: services.profile)
            let facts = FindingNarration.facts(for: finding)
            let output = await services.narrator.narrate(finding: finding, facts: facts, query: query)
            narration = .ready(output)
        }
    }

    /// The on-device model, when it actually spoke, replaces the template line *and* the
    /// hand-written rationale with its own grounded prose plus the evidence it cited — that's
    /// the whole point of running it. Anything short of a clean generation (disabled, refused,
    /// below the retrieval floor, model unavailable) falls straight back to the same deterministic
    /// copy this screen always showed, unlabeled, because a template is not a failure state.
    @ViewBuilder
    private var explanation: some View {
        switch narration {
        case .pending:
            VStack(alignment: .leading, spacing: 6) {
                Text(Templates.finding(finding))
                    .font(.body).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let rationale = Templates.rationale(for: finding) {
                    Text(rationale).font(.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ready(let output) where !output.isTemplated:
            VStack(alignment: .leading, spacing: 6) {
                Text(output.text)
                    .font(.body).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !output.citations.isEmpty {
                    Text("Based on: " + output.citations.map(\.citation).joined(separator: "; "))
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                Text(Templates.finding(finding))
                    .font(.body).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let rationale = Templates.rationale(for: finding) {
                    Text(rationale).font(.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Honest labeling for the one line per finding that actually came from the on-device model —
/// everything else on this screen, including the fallback copy right next to it, is a fixed
/// template. Matches `Narrator.Output.isTemplated`'s doc comment: surfaced, never hidden.
struct AIGeneratedBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
            Text("ON-DEVICE AI")
        }
        .font(.caption2.weight(.bold))
        .tracking(0.4)
        .foregroundStyle(Theme.accent)
    }
}

/// What "these move together" actually looks like: both metrics' own real trend, over real
/// calendar days, each independently rescaled to 0–1 so wildly different units (bpm vs. ms vs.
/// a 0–100 score) sit on the same visual axis. A scatterplot of dimensionless normalized values
/// makes the reader do the work of translating dots back into "these move together" — two
/// labeled lines that visibly rise and fall together do that translation for them.
struct FindingTimeline: View {
    let finding: Finding
    let store: Store

    private struct Series: Identifiable {
        let id: String
        let label: String
        let color: Color
        let points: [(day: Date, value: Double)]
    }

    private enum LoadState { case pending, ready([Series]), empty }
    @State private var state: LoadState = .pending

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
            .task(id: finding.id) {
                let loaded = FindingTimeline.loadSeries(for: finding, store: store)
                state = loaded.count == 2 ? .ready(loaded) : .empty
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .pending:
            Text("Loading trend…").font(.caption2).foregroundStyle(Theme.textTertiary)
        case .empty:
            Text("Not enough overlapping data to plot a trend for this pair yet.")
                .font(.caption2).foregroundStyle(Theme.textTertiary)
        case .ready(let series):
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(series) { s in
                        ForEach(Array(s.points.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Day", p.day), y: .value("Value", p.value))
                                // `.foregroundStyle(by:)`, not a static `.foregroundStyle(Color)` —
                                // a flat color applied per-mark across two interleaved series
                                // doesn't reliably keep them visually distinct in Swift Charts;
                                // grouping by a categorical value is what actually separates them.
                                .foregroundStyle(by: .value("Series", s.label))
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                // `chartForegroundStyleScale` takes a `KeyValuePairs` literal, not a `Dictionary` —
                // safe to index directly since this branch only exists when `series.count == 2`.
                .chartForegroundStyleScale([series[0].label: series[0].color, series[1].label: series[1].color])
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 90)

                HStack(spacing: 14) {
                    ForEach(series) { s in
                        HStack(spacing: 4) {
                            Circle().fill(s.color).frame(width: 6, height: 6)
                            Text(s.label).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("7-day trend").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    /// Raw daily values are genuinely this noisy — people don't sleep the same amount every
    /// night — and compressed into a chart a few dozen points wide, that noise is all that's
    /// visible; the correlation the numbers describe disappears into it. A centered rolling
    /// average reveals the trend the statistic is actually about. Computed purely for display;
    /// the correlation itself is still computed upstream on the raw daily values, untouched.
    private static func rollingAverage(_ points: [(Date, Double)], window: Int) -> [(Date, Double)] {
        guard points.count > window else { return points }
        let half = window / 2
        return points.indices.map { i in
            let lo = max(0, i - half), hi = min(points.count - 1, i + half)
            let slice = points[lo...hi]
            return (points[i].0, slice.map(\.1).reduce(0, +) / Double(slice.count))
        }
    }

    private static func loadSeries(for finding: Finding, store: Store) -> [Series] {
        guard let subject = Metric(rawValue: finding.subject),
              let objectRaw = finding.object, let object = Metric(rawValue: objectRaw),
              let subjectRows = try? store.constructs(version: DeriveVersion.current, construct: subject),
              let objectRows = try? store.constructs(version: DeriveVersion.current, construct: object)
        else { return [] }

        let calendar = Calendar.autoupdatingCurrent
        func normalizedPoints(_ rows: [DailyConstruct]) -> [(day: Date, value: Double)] {
            let raw = rows.compactMap { c -> (Date, Double)? in
                guard let v = c.value, let d = c.day.date(in: calendar) else { return nil }
                return (d, v)
            }
            guard raw.count >= 4 else { return [] }
            let smoothed = rollingAverage(raw, window: 7)
            guard let lo = smoothed.map(\.1).min(), let hi = smoothed.map(\.1).max(), hi > lo else { return [] }
            return smoothed.map { ($0.0, ($0.1 - lo) / (hi - lo)) }
        }

        let subjectPoints = normalizedPoints(subjectRows)
        let objectPoints = normalizedPoints(objectRows)
        guard subjectPoints.count >= 4, objectPoints.count >= 4 else { return [] }

        return [
            Series(id: "subject", label: subject.displayName, color: Theme.accent, points: subjectPoints),
            Series(id: "object", label: object.displayName, color: Theme.textSecondary.opacity(0.9), points: objectPoints)
        ]
    }
}

/// T1 and T3 must be distinguishable at a glance — colour, shape, *and* wording, because
/// colour alone fails for a meaningful share of users and in bright sunlight.
struct TierBadge: View {
    let tier: EvidenceTier

    private var colour: Color {
        switch tier {
        case .t0: return .gray
        case .t1: return .blue
        case .t2: return .teal
        case .t3: return .orange
        case .t4: return .green
        }
    }

    private var icon: String {
        switch tier {
        case .t0: return "circle"
        case .t1: return "link"
        case .t2: return "arrow.left.arrow.right"
        case .t3: return "arrow.right"
        case .t4: return "checkmark.seal"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text("\(tier.rawValue) · \(tier.label)")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(colour)
        .background(colour.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(colour.opacity(0.35), lineWidth: tier >= .t3 ? 1 : 0))
    }
}

struct FindingStats: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                stat("Effect", finding.effectSize.map { String(format: "r = %+.2f", $0) } ?? "—")
                stat("Days", "\(finding.nObservations)")
                stat("q", finding.qValue.map { String(format: "%.3f", $0) } ?? "—")
            }
            if let low = finding.effectCILow, let high = finding.effectCIHigh {
                Text(String(format: "95%% CI %.2f to %.2f", low, high))
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            if finding.tier == .t3 {
                // SPEC §5.2. This limit is permanent and stating it is the point.
                Text("""
                     Observational. This can't separate a direct effect from something that \
                     reliably travels with it.
                     """)
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
    }
}
