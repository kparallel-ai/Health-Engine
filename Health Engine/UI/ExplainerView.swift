// ExplainerView.swift
// Epistemic role: cold-start content. Works on day one with zero data.
//
// Structural accuracy rule (SPEC §7.1): no claim ships without a corresponding evidence
// chunk. Each `Claim` carries the chunk ID, and `ExplainerAudit` fails the build if any ID
// is missing from the bundled corpus.

import SwiftUI

enum ExplainerTopic: String, CaseIterable, Identifiable {
    case oxygenCascade = "Oxygen cascade"
    case autonomicBalance = "Autonomic balance"
    case fitnessFatigue = "Fitness and fatigue"

    var id: String { rawValue }

    static func forMetric(_ m: Metric) -> ExplainerTopic {
        switch m {
        case .vo2maxRunning:                            return .oxygenCascade
        case .hrvSDNNOvernight, .hrvRMSSDOvernight,
             .hrResting, .respirationAvgOvernight:      return .autonomicBalance
        default:                                        return .fitnessFatigue
        }
    }
}

/// A sentence and the chunk that licenses it. There is no way to add prose to an explainer
/// without also naming the evidence for it.
struct Claim: Identifiable {
    let id = UUID()
    let text: String
    let chunkID: String
}

struct ExplainerView: View {
    var focus: ExplainerTopic = .oxygenCascade
    @State private var selected: ExplainerTopic = .oxygenCascade

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Topic", selection: $selected) {
                        ForEach(ExplainerTopic.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch selected {
                    case .oxygenCascade:    OxygenCascadeExplainer()
                    case .autonomicBalance: AutonomicExplainer()
                    case .fitnessFatigue:   FitnessFatigueExplainer()
                    }
                }
                .padding()
            }
            .navigationTitle("Learn")
            .onAppear { selected = focus }
        }
    }
}

// MARK: - Oxygen cascade (never cut)

struct OxygenCascadeExplainer: View {
    @State private var phase: Double = 0

    private let stages: [(String, String, Double)] = [
        ("Inspired air",  "160 mmHg", 1.00),
        ("Alveoli",       "100 mmHg", 0.63),
        ("Arterial blood", "95 mmHg", 0.59),
        ("Capillary",      "40 mmHg", 0.25),
        ("Mitochondria",  "< 5 mmHg", 0.03)
    ]

    private let claims = [
        Claim(text: "VO\u{2082}max is limited primarily by how much oxygenated blood the heart "
                  + "can deliver, not by how much the lungs can take in.",
              chunkID: "vo2-limitation-central"),
        Claim(text: "In trained endurance athletes, cardiac output accounts for the large "
                  + "majority of the difference in VO\u{2082}max between individuals.",
              chunkID: "vo2-cardiac-output"),
        Claim(text: "VO\u{2082}max is trainable, but the achievable improvement narrows "
                  + "considerably as training history lengthens.",
              chunkID: "vo2-trainability-hiit")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where the ceiling actually sits").font(.title3.weight(.semibold))

            Canvas { context, size in
                let stepHeight = size.height / CGFloat(stages.count)
                for (index, stage) in stages.enumerated() {
                    let y = CGFloat(index) * stepHeight
                    let animated = 0.5 + 0.5 * sin(phase + Double(index) * 0.6)
                    let width = size.width * stage.2 * (0.94 + 0.06 * animated)

                    let rect = CGRect(x: 0, y: y + 6, width: max(width, 24), height: stepHeight - 14)
                    context.fill(Path(roundedRect: rect, cornerRadius: 6),
                                 with: .linearGradient(
                                    Gradient(colors: [.blue.opacity(0.75), .cyan.opacity(0.35)]),
                                    startPoint: .zero, endPoint: CGPoint(x: rect.maxX, y: 0)))

                    context.draw(Text(stage.0).font(.caption.weight(.medium)).foregroundStyle(.white),
                                 at: CGPoint(x: 10, y: y + stepHeight / 2), anchor: .leading)
                    context.draw(Text(stage.1).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                                 at: CGPoint(x: size.width - 6, y: y + stepHeight / 2), anchor: .trailing)
                }
            }
            .frame(height: 220)
            .task {
                // Light motion only. The visual budget belongs in the data views.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    phase += 0.08
                }
            }

            Text("""
                 Oxygen falls in pressure at every handoff from the air to the mitochondria. \
                 The steepest drop is at delivery, not at intake — which is why the ceiling is \
                 usually cardiac, not pulmonary.
                 """)
                .foregroundStyle(.secondary)

            ClaimList(claims: claims)
        }
    }
}

// MARK: - Autonomic balance

struct AutonomicExplainer: View {
    private let claims = [
        Claim(text: "rMSSD reflects beat-to-beat variation driven mainly by parasympathetic "
                  + "activity, which is why it is the usual overnight recovery marker.",
              chunkID: "hrv-rmssd-parasympathetic"),
        Claim(text: "HRV values from different measurement modalities are not interchangeable; "
                  + "wrist PPG overnight and supine ECG produce different distributions.",
              chunkID: "hrv-methodology-consensus"),
        Claim(text: "HRV-guided training has shown modest performance advantages over fixed "
                  + "plans in controlled trials, with heterogeneous effect sizes.",
              chunkID: "hrv-guided-training-meta"),
        Claim(text: "Alcohol before sleep reliably suppresses overnight HRV and reduces REM "
                  + "sleep, with effects visible at moderate doses.",
              chunkID: "alcohol-sleep-architecture")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What rMSSD is a proxy for").font(.title3.weight(.semibold))
            AutonomicDial()
            Text("""
                 Heart rate variability is the spacing between beats, not the rate itself. \
                 Wider spacing under rest generally means more parasympathetic influence. \
                 It is a proxy — a good one, but a proxy — and it moves for reasons that have \
                 nothing to do with training.
                 """)
                .foregroundStyle(.secondary)
            ClaimList(claims: claims)
        }
    }
}

struct AutonomicDial: View {
    @State private var t: Double = 0

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY))
            var x: CGFloat = 0
            var beat = 0
            while x < size.width {
                // Irregular spacing is the entire point of the drawing.
                let interval = 34 + 12 * sin(t + Double(beat) * 1.1)
                path.addLine(to: CGPoint(x: x + CGFloat(interval) * 0.5, y: midY))
                path.addLine(to: CGPoint(x: x + CGFloat(interval) * 0.55, y: midY - 26))
                path.addLine(to: CGPoint(x: x + CGFloat(interval) * 0.62, y: midY + 10))
                path.addLine(to: CGPoint(x: x + CGFloat(interval) * 0.70, y: midY))
                x += CGFloat(interval)
                beat += 1
            }
            context.stroke(path, with: .color(.pink), lineWidth: 1.8)
        }
        .frame(height: 90)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                t += 0.05
            }
        }
    }
}

// MARK: - Fitness and fatigue

struct FitnessFatigueExplainer: View {
    private let claims = [
        Claim(text: "The two-component model treats performance as fitness minus fatigue, "
                  + "each decaying on its own timescale after a training stimulus.",
              chunkID: "banister-two-component"),
        Claim(text: "Fatigue rises faster and decays faster than fitness, which is why a taper "
                  + "can raise performance without adding training.",
              chunkID: "tapering-performance"),
        Claim(text: "Acute:chronic workload ratio is widely implemented but has been "
                  + "methodologically criticised, and its predictive value is contested.",
              chunkID: "acwr-contested")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two curves, not one").font(.title3.weight(.semibold))
            Canvas { context, size in
                func curve(decay: Double, gain: Double, colour: Color) {
                    var path = Path()
                    for i in 0...Int(size.width) {
                        let x = Double(i)
                        let y = gain * exp(-x / decay)
                        let point = CGPoint(x: x, y: size.height - y * size.height * 0.8)
                        i == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                    context.stroke(path, with: .color(colour), lineWidth: 2)
                }
                curve(decay: 180, gain: 0.55, colour: .blue)     // fitness: slow
                curve(decay: 45,  gain: 0.85, colour: .orange)   // fatigue: fast
            }
            .frame(height: 150)

            HStack(spacing: 16) {
                Label("Fitness", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Fatigue", systemImage: "circle.fill").foregroundStyle(.orange)
            }
            .font(.caption)

            Text("""
                 A hard session raises both. Fatigue is larger at first and fades sooner, so \
                 the gap between the curves — what you can actually do on the day — often peaks \
                 well after the work was done.
                 """)
                .foregroundStyle(.secondary)

            ClaimList(claims: claims)
        }
    }
}

// MARK: - Claim rendering and audit

struct ClaimList: View {
    let claims: [Claim]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the evidence says").font(.headline)
            ForEach(claims) { claim in
                VStack(alignment: .leading, spacing: 3) {
                    Text(claim.text).font(.subheadline)
                    Text(claim.chunkID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Called from a test, not at runtime. If an explainer claim names a chunk that isn't in the
/// bundled corpus, the build fails rather than the claim shipping unsupported.
enum ExplainerAudit {
    static let allChunkIDs: [String] = [
        "vo2-limitation-central", "vo2-cardiac-output", "vo2-trainability-hiit",
        "hrv-rmssd-parasympathetic", "hrv-methodology-consensus",
        "hrv-guided-training-meta", "alcohol-sleep-architecture",
        "banister-two-component", "tapering-performance", "acwr-contested"
    ]

    static func missingChunks(in corpus: [EvidenceChunk]) -> [String] {
        let present = Set(corpus.map(\.id))
        return allChunkIDs.filter { !present.contains($0) }
    }
}
