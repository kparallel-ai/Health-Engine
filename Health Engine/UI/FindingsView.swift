// FindingsView.swift
// Epistemic role: display. The tier badge is the most important element on this screen —
// it is what stops a co-occurrence from reading like a cause.

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
                            FindingRow(finding: finding)
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
                     Showing \(findings.count) distinct relationships — repeats of the same \
                     pair at a different lag are collapsed to their strongest result.
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

    /// Same two metrics tested at lag 0 vs. lag 1, or in both directions, read to a user as
    /// "the same finding again" — statistically distinct hypotheses, but not distinct enough
    /// to be worth scrolling past three times. Keep only the strongest result per unordered
    /// metric pair; the BH correction and "Tested" count upstream are untouched by this —
    /// it only changes what's *displayed*.
    static func dedupedByPair(_ all: [Finding]) -> [Finding] {
        var best: [String: Finding] = [:]
        for f in all {
            let key = [f.subject, f.object ?? ""].sorted().joined(separator: "|")
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
            }
            Text(Templates.finding(finding))
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
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
