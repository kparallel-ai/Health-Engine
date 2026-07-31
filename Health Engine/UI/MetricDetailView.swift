// MetricDetailView.swift
// Epistemic role: display. The normative-comparison rule (SPEC §7.3) is enforced by
// `Metric.permitsNormativePercentile`, not by remembering not to add it here.

import SwiftUI
import Charts

struct MetricDetailView: View {
    let metric: Metric
    let store: Store

    @State private var series: [DailyConstruct] = []

    private var withValues: [DailyConstruct] { series.filter { $0.value != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if withValues.isEmpty {
                    Text("No \(metric.displayName.lowercased()) recorded yet.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    timeSeries
                    distribution
                    normativeSection
                }
                explainerLink
            }
            .padding()
        }
        .pageBackground()
        .navigationTitle(metric.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task { series = (try? store.constructs(version: DeriveVersion.current, construct: metric)) ?? [] }
    }

    // MARK: - Time series with baseline band

    private var timeSeries: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Over time").font(.headline).foregroundStyle(Theme.textPrimary)
            Chart {
                // The band is drawn from the actual robust SD, so its width carries meaning.
                ForEach(withValues, id: \.day) { c in
                    if let baseline = c.baseline, c.confidence > 0, let z = c.deviationZ,
                       let value = c.value, z != 0 {
                        let sd = abs(value - baseline) / abs(z)
                        AreaMark(x: .value("Day", c.day.raw),
                                 yStart: .value("Low", baseline - sd),
                                 yEnd: .value("High", baseline + sd))
                            .foregroundStyle(Theme.accent.opacity(0.14))
                    }
                }
                ForEach(withValues, id: \.day) { c in
                    LineMark(x: .value("Day", c.day.raw), y: .value("Value", c.value ?? 0))
                        .foregroundStyle(Theme.accent)
                    // Ghosted where the baseline gate has not opened — visibly not the same
                    // epistemic status as the rest of the line.
                    if c.confidence == 0 {
                        PointMark(x: .value("Day", c.day.raw), y: .value("Value", c.value ?? 0))
                            .foregroundStyle(Theme.textTertiary)
                            .symbolSize(20)
                    }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .frame(height: 220)

            Label("Shaded band is one robust SD of your own rolling baseline.",
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .cardStyle(padding: 16)
    }

    // MARK: - Distribution

    private var distribution: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Distribution").font(.headline).foregroundStyle(Theme.textPrimary)
            Chart(withValues, id: \.day) { c in
                BarMark(x: .value(metric.displayName, c.value ?? 0))
                    .foregroundStyle(Theme.accent.opacity(0.6))
            }
            .chartYAxis(.hidden)
            .frame(height: 120)
        }
        .cardStyle(padding: 16)
    }

    // MARK: - Normative comparison

    @ViewBuilder
    private var normativeSection: some View {
        if metric.permitsNormativePercentile {
            VStack(alignment: .leading, spacing: 6) {
                Text("Compared to others").font(.headline).foregroundStyle(Theme.textPrimary)
                Text(Normative.description(for: metric))
                    .font(.subheadline).foregroundStyle(Theme.textPrimary)
                // Every normative comparison states its reference population and method.
                // If that sentence cannot be written, the comparison is not shown.
                Text(Normative.reference(for: metric))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .cardStyle(padding: 14)
        } else if metric == .hrvSDNNOvernight || metric == .hrvRMSSDOvernight {
            VStack(alignment: .leading, spacing: 6) {
                Text("Why there's no percentile here").font(.headline).foregroundStyle(Theme.textPrimary)
                Text("""
                     Published HRV reference values come from short supine ECG recordings. \
                     These come from overnight wrist PPG — a different window, posture, \
                     modality and artifact profile. The two aren't comparable, so this app \
                     compares your HRV only to your own rolling baseline.
                     """)
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .cardStyle(padding: 14)
        }
    }

    private var explainerLink: some View {
        NavigationLink {
            ExplainerView(focus: ExplainerTopic.forMetric(metric))
        } label: {
            Label("What \(metric.displayName.lowercased()) actually measures", systemImage: "book")
        }
    }
}

/// Percentiles only where the reference population and measurement method can be stated.
enum Normative {
    static func description(for metric: Metric) -> String {
        switch metric {
        case .vo2maxRunning:
            return "Percentiles are shown by age band and sex."
        case .hrResting:
            return "Percentiles are shown by age band and sex."
        default:
            return ""
        }
    }

    static func reference(for metric: Metric) -> String {
        switch metric {
        case .vo2maxRunning:
            return "Reference: Cooper Institute treadmill norms, direct and estimated VO\u{2082}max, "
                 + "adults 20–79. Your value is a wrist-based running estimate, which is not the "
                 + "same measurement."
        case .hrResting:
            return "Reference: large-cohort resting heart rate distributions, seated daytime "
                 + "measurement. Your value is an overnight wrist-based estimate."
        default:
            return ""
        }
    }
}
