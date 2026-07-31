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

    /// Charts needs a real `Date` to lay out and format a time axis. `Day.raw` is a
    /// `"YYYY-MM-DD"` string (see `Day`'s own doc comment: "Not a Date") — plotting it directly
    /// as the x-value made Charts treat every day as a nominal category and print the raw ISO
    /// string as the axis label, which is what actually made this chart hard to read.
    private func date(for c: DailyConstruct) -> Date {
        c.day.date(in: .current) ?? Date()
    }

    private var averageBaseline: Double? {
        let baselines = withValues.compactMap { $0.confidence > 0 ? $0.baseline : nil }
        guard !baselines.isEmpty else { return nil }
        return baselines.reduce(0, +) / Double(baselines.count)
    }

    private struct HistogramBin: Identifiable {
        let id = UUID()
        let midpoint: Double
        let count: Int
    }

    /// A real histogram — equal-width bins over the observed range — rather than one bar per
    /// distinct raw value, which produced a chaotic comb of near-duplicate bars.
    private var histogram: [HistogramBin] {
        let values = withValues.compactMap(\.value)
        guard let lo = values.min(), let hi = values.max() else { return [] }
        guard hi > lo else { return [HistogramBin(midpoint: lo, count: values.count)] }
        let binCount = min(8, max(4, values.count / 3))
        let width = (hi - lo) / Double(binCount)
        var counts = Array(repeating: 0, count: binCount)
        for v in values {
            let idx = min(binCount - 1, max(0, Int((v - lo) / width)))
            counts[idx] += 1
        }
        return counts.enumerated().map { HistogramBin(midpoint: lo + width * (Double($0) + 0.5), count: $1) }
    }

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
                if let baseline = averageBaseline {
                    RuleMark(y: .value("Baseline", baseline))
                        .foregroundStyle(Theme.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
                ForEach(withValues, id: \.day) { c in
                    LineMark(x: .value("Date", date(for: c)), y: .value("Value", c.value ?? 0))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    // Ghosted where the baseline gate has not opened — visibly not the same
                    // epistemic status as the rest of the line.
                    if c.confidence == 0 {
                        PointMark(x: .value("Date", date(for: c)), y: .value("Value", c.value ?? 0))
                            .foregroundStyle(Theme.textTertiary)
                            .symbolSize(18)
                    }
                }
                if let last = withValues.last {
                    PointMark(x: .value("Date", date(for: last)), y: .value("Value", last.value ?? 0))
                        .foregroundStyle(Theme.accent)
                        .symbolSize(50)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.7))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.5))
                    AxisValueLabel().font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 200)

            if averageBaseline != nil {
                Label("Dashed line is your rolling baseline over this period.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .cardStyle(padding: 16)
    }

    // MARK: - Distribution

    private var distribution: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Distribution").font(.headline).foregroundStyle(Theme.textPrimary)
            Chart(histogram) { bin in
                BarMark(x: .value(metric.displayName, bin.midpoint), y: .value("Days", bin.count))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel().font(.caption2).foregroundStyle(Theme.textSecondary)
                }
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
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle(padding: 14)
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
