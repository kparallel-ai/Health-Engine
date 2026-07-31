// FindingsView.swift
// Epistemic role: display. The tier badge is the most important element on this screen —
// it is what stops a co-occurrence from reading like a cause.

import Combine
import SwiftUI

struct FindingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var findings: [Finding] = []
    @State private var verdicts: [String: String] = [:]
    @State private var familySize: Int = 0

    var body: some View {
        NavigationStack {
            List {
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

                if familySize > 0 {
                    Section {
                        Text("""
                             \(familySize) hypotheses were tested and corrected together \
                             (Benjamini–Hochberg, q = 0.10). \(findings.count) survived.
                             """)
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    } header: {
                        Text("How many tests ran")
                    }
                    .listRowBackground(Theme.surfaceRaised)
                }
            }
            .scrollContentBackground(.hidden)
            .pageBackground()
            .navigationTitle("Findings")
            .task { reload() }
            .onReceive(services.recompute.$lastCompleted.compactMap { $0 }) { _ in reload() }
        }
        .tint(Theme.accent)
    }

    private func reload() {
        findings = (try? services.store.surfacedFindings()) ?? []
        verdicts = (try? services.store.verdicts()) ?? [:]
        familySize = findings.first?.familySize
            ?? ((try? services.store.familySize(ScanFamily.contextAssociations.id)) ?? 0)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TierBadge(tier: finding.tier)
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
