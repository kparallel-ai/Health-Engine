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
    case sleepArchitecture = "Sleep architecture"
    case bodyBatteryStress = "Body Battery and stress"
    case breathingOxygen = "Breathing and blood oxygen"
    case temperature = "Wrist temperature"

    var id: String { rawValue }

    static func forMetric(_ m: Metric) -> ExplainerTopic {
        switch m {
        case .vo2maxRunning:                            return .oxygenCascade
        case .hrvSDNNOvernight, .hrvRMSSDOvernight,
             .hrResting, .hrvStatusGarmin:              return .autonomicBalance
        case .sleepDuration, .sleepEfficiency, .sleepDeep,
             .sleepREM, .sleepOnset:                    return .sleepArchitecture
        case .bodyBatteryMin, .bodyBatteryMax, .stressAvg: return .bodyBatteryStress
        case .respirationAvgOvernight, .spo2AvgOvernight:  return .breathingOxygen
        case .tempWristDeviation:                          return .temperature
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
                    // Seven topics no longer fit a segmented control without truncating —
                    // a horizontal row of chips scales the way a tab bar wouldn't.
                    topicPicker

                    switch selected {
                    case .oxygenCascade:     OxygenCascadeExplainer()
                    case .autonomicBalance:  AutonomicExplainer()
                    case .fitnessFatigue:    FitnessFatigueExplainer()
                    case .sleepArchitecture: SleepArchitectureExplainer()
                    case .bodyBatteryStress: BodyBatteryStressExplainer()
                    case .breathingOxygen:   BreathingOxygenExplainer()
                    case .temperature:       TemperatureExplainer()
                    }
                }
                .padding()
            }
            .pageBackground()
            // The tab bar already says "Learn" — the title says which of the three topics is
            // actually open, which is the thing the tab label can't tell you.
            .navigationTitle(selected.rawValue)
            .navigationBarTitleDisplayMode(.large)
            .onAppear { selected = focus }
        }
        .tint(Theme.accent)
    }

    private var topicPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ExplainerTopic.allCases) { topic in
                    let isSelected = topic == selected
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = topic }
                    } label: {
                        Text(topic.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(isSelected ? Color.white : Theme.textPrimary)
                            .background(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceRaised),
                                        in: Capsule())
                            .overlay(
                                Capsule().strokeBorder(Theme.hairline.opacity(isSelected ? 0 : 0.7), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
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
            Text("Where the ceiling actually sits").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)

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

            HStack(spacing: 16) {
                Label("Air → alveoli: shallow drop", systemImage: "wind").foregroundStyle(.cyan)
                Label("Arterial → capillary: steepest drop", systemImage: "arrow.down.right").foregroundStyle(Theme.accent)
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Text("""
                 Oxygen falls in pressure at every handoff from the air to the mitochondria. \
                 The steepest drop is at delivery, not at intake — which is why the ceiling is \
                 usually cardiac, not pulmonary.
                 """)
                .foregroundStyle(Theme.textSecondary)

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
            Text("What rMSSD is a proxy for").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            AutonomicDial()
            Text("""
                 Heart rate variability is the spacing between beats, not the rate itself. \
                 Wider spacing under rest generally means more parasympathetic influence. \
                 It is a proxy — a good one, but a proxy — and it moves for reasons that have \
                 nothing to do with training.
                 """)
                .foregroundStyle(Theme.textSecondary)
            ClaimList(claims: claims)
        }
    }
}

struct AutonomicDial: View {
    @State private var t: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { context, size in
                let midY = size.height / 2
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                var x: CGFloat = 0
                var beat = 0
                var peaks: [(x: CGFloat, wide: Bool)] = []
                while x < size.width {
                    // Irregular spacing is the entire point of the drawing.
                    let interval = 34 + 12 * sin(t + Double(beat) * 1.1)
                    let peakX = x + CGFloat(interval) * 0.55
                    path.addLine(to: CGPoint(x: x + CGFloat(interval) * 0.5, y: midY))
                    path.addLine(to: CGPoint(x: peakX, y: midY - 26))
                    path.addLine(to: CGPoint(x: x + CGFloat(interval) * 0.62, y: midY + 10))
                    path.addLine(to: CGPoint(x: x + CGFloat(interval) * 0.70, y: midY))
                    peaks.append((peakX, interval > 34))
                    x += CGFloat(interval)
                    beat += 1
                }
                context.stroke(path, with: .color(.pink.opacity(0.55)), lineWidth: 1.6)

                // The spacing is the entire signal, so a plain squiggle doesn't actually show
                // it — color-coding each beat by whether its interval ran wide or narrow makes
                // the variability itself legible, not just implied by jaggedness.
                for peak in peaks {
                    context.fill(
                        Path(ellipseIn: CGRect(x: peak.x - 3.5, y: midY - 26 - 3.5, width: 7, height: 7)),
                        with: .color(peak.wide ? .teal : .orange))
                }
            }
            .frame(height: 90)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(60))
                    t += 0.05
                }
            }

            HStack(spacing: 16) {
                Label("Wider spacing", systemImage: "arrow.left.and.right").foregroundStyle(.teal)
                Label("Narrower spacing", systemImage: "arrow.left.and.right").foregroundStyle(.orange)
            }
            .font(.caption)
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
            Text("Two curves, not one").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Canvas { context, size in
                func pixelY(decay: Double, gain: Double, x: Double) -> Double {
                    let value = gain * exp(-x / decay)
                    return Double(size.height) - value * Double(size.height) * 0.8
                }
                func curve(decay: Double, gain: Double) -> Path {
                    var path = Path()
                    for i in 0...Int(size.width) {
                        let point = CGPoint(x: Double(i), y: pixelY(decay: decay, gain: gain, x: Double(i)))
                        i == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                    return path
                }

                // The gap between the curves is the actual point of this drawing — "what you
                // can do today" — so it gets shaded, not left for the reader to eyeball between
                // two stroked lines. Green once fitness has pulled back above fatigue.
                for i in 0..<Int(size.width) {
                    let x = Double(i)
                    let fitY = pixelY(decay: 180, gain: 0.55, x: x)
                    let fatY = pixelY(decay: 45, gain: 0.85, x: x)
                    let netPositive = fitY < fatY
                    let rect = CGRect(x: x, y: min(fitY, fatY), width: 1.4, height: max(abs(fatY - fitY), 0.5))
                    context.fill(Path(rect),
                                 with: .color(netPositive ? .green.opacity(0.20) : Theme.textTertiary.opacity(0.20)))
                }

                context.stroke(curve(decay: 180, gain: 0.55), with: .color(.blue), lineWidth: 2)
                context.stroke(curve(decay: 45, gain: 0.85), with: .color(.orange), lineWidth: 2)
            }
            .frame(height: 150)

            HStack(spacing: 16) {
                Label("Fitness", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Fatigue", systemImage: "circle.fill").foregroundStyle(.orange)
                Label("Net gain", systemImage: "square.fill").foregroundStyle(.green)
            }
            .font(.caption)

            Text("""
                 A hard session raises both. Fatigue is larger at first and fades sooner, so \
                 the gap between the curves — what you can actually do on the day — often peaks \
                 well after the work was done.
                 """)
                .foregroundStyle(Theme.textSecondary)

            ClaimList(claims: claims)
        }
    }
}

// MARK: - Sleep architecture

struct SleepArchitectureExplainer: View {
    @State private var phase: Double = 0

    /// A stylised, illustrative night — deep sleep front-loaded, REM lengthening toward
    /// morning. Not this user's actual data; `MetricDetailView` is where their own night lives.
    /// This is here to explain the *shape* the real chart follows.
    private let cycles: [(deep: Double, rem: Double)] = [
        (0.85, 0.10), (0.65, 0.20), (0.45, 0.30), (0.25, 0.42), (0.12, 0.52)
    ]

    private let claims = [
        Claim(text: "Sleep proceeds in roughly 90-minute cycles, and the mix within each cycle "
                  + "shifts across the night — deep sleep is front-loaded early on, and REM "
                  + "sleep lengthens toward morning.",
              chunkID: "sleep-cycle-architecture"),
        Claim(text: "Deep (slow-wave) sleep is when most physical restoration happens; REM sleep "
                  + "is linked to memory consolidation and emotional processing.",
              chunkID: "sleep-stage-function"),
        Claim(text: "Total time asleep is a coarser number than architecture — two nights of "
                  + "equal length can differ a lot in how much deep and REM sleep they contain.",
              chunkID: "sleep-architecture-vs-duration")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A night is not one thing").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)

            Canvas { context, size in
                let cycleWidth = size.width / CGFloat(cycles.count)
                for (index, cycle) in cycles.enumerated() {
                    let x = CGFloat(index) * cycleWidth
                    let wobble = 1 + 0.05 * sin(phase + Double(index))
                    let deepHeight = size.height * 0.6 * cycle.deep * wobble
                    let remHeight = size.height * 0.6 * cycle.rem * wobble

                    let deepRect = CGRect(x: x + 4, y: size.height - deepHeight,
                                          width: cycleWidth * 0.4, height: deepHeight)
                    context.fill(Path(roundedRect: deepRect, cornerRadius: 4), with: .color(.indigo.opacity(0.75)))

                    let remRect = CGRect(x: x + cycleWidth * 0.5, y: size.height - remHeight,
                                         width: cycleWidth * 0.4, height: remHeight)
                    context.fill(Path(roundedRect: remRect, cornerRadius: 4), with: .color(.purple.opacity(0.55)))
                }
            }
            .frame(height: 130)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    phase += 0.06
                }
            }

            HStack(spacing: 16) {
                Label("Deep", systemImage: "circle.fill").foregroundStyle(.indigo)
                Label("REM", systemImage: "circle.fill").foregroundStyle(.purple)
                Spacer()
                Text("Early night → morning").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            .font(.caption)

            Text("""
                 The same eight hours can look completely different depending on when the deep \
                 and REM sleep land. Early cycles lean toward physical repair; later cycles lean \
                 toward the brain. Cutting a night short doesn't shave time evenly off both.
                 """)
                .foregroundStyle(Theme.textSecondary)

            ClaimList(claims: claims)
        }
    }
}

// MARK: - Body Battery and stress

struct BodyBatteryStressExplainer: View {
    @State private var phase: Double = 0

    private let claims = [
        Claim(text: "Composite recovery scores like Body Battery are typically derived from "
                  + "heart rate variability, detected stress, sleep, and recent activity folded "
                  + "into a single 0-100 number, rather than measured directly.",
              chunkID: "body-battery-composite-score"),
        Claim(text: "Because measured stress is one of its direct inputs, a high-stress day will "
                  + "mechanically show the battery draining faster — the two aren't independent "
                  + "observations of each other.",
              chunkID: "body-battery-stress-mechanical-link"),
        Claim(text: "These composite scores are proprietary and not independently validated the "
                  + "way heart rate or HRV are, so they read best as a convenient summary, not a "
                  + "precise measurement.",
              chunkID: "body-battery-validation-caveat")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("One number, four inputs").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)

            Canvas { context, size in
                var path = Path()
                let steps = 60
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    // Illustrative shape only: full after overnight charging, a steady drain
                    // across the day, and a dip for an afternoon stress spike — kept to a smooth
                    // decline rather than an early plateau, or most of the day reads as "dead."
                    let base = 0.92 - 0.74 * t
                    let stressDip = exp(-pow((t - 0.6) * 9, 2)) * 0.22
                    let level = max(0.08, min(0.97, base - stressDip + 0.02 * sin(phase + t * 6)))
                    let point = CGPoint(x: t * size.width, y: size.height * (1 - level))
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                var fill = path
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.03)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(path, with: .color(Theme.accent), lineWidth: 2.5)
            }
            .frame(height: 120)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    phase += 0.05
                }
            }

            HStack(spacing: 16) {
                Label("Sleep charges it", systemImage: "moon.fill").foregroundStyle(Theme.accent)
                Label("Stress drains it", systemImage: "bolt.fill").foregroundStyle(Theme.textSecondary)
            }
            .font(.caption)

            Text("""
                 It looks like one clean measurement, but it's really an index — mostly your own \
                 HRV and stress detection, rolled up and re-scaled. Reading it alongside the \
                 inputs that built it tells you more than the single number alone.
                 """)
                .foregroundStyle(Theme.textSecondary)

            ClaimList(claims: claims)
        }
    }
}

// MARK: - Breathing and blood oxygen

struct BreathingOxygenExplainer: View {
    @State private var t: Double = 0

    private let claims = [
        Claim(text: "Resting breathing rate is normally quite stable from night to night, so a "
                  + "noticeable shift is usually more informative than the absolute number.",
              chunkID: "respiration-night-to-night-stability"),
        Claim(text: "Overnight pulse oximetry from a wrist-worn sensor is a general-wellness "
                  + "estimate, not a clinical-grade measurement — motion, fit, and skin "
                  + "perfusion all add noise.",
              chunkID: "spo2-wrist-measurement-limits"),
        Claim(text: "Breathing rate and blood oxygen typically move together overnight, since "
                  + "breathing depth and rate are part of how the body maintains oxygen "
                  + "saturation.",
              chunkID: "respiration-oxygen-coupling")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Two numbers, one system").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)

            Canvas { context, size in
                let bandRect = CGRect(x: 0, y: size.height * 0.06, width: size.width, height: size.height * 0.18)
                context.fill(Path(roundedRect: bandRect, cornerRadius: 6), with: .color(.cyan.opacity(0.18)))
                context.draw(Text("Typical overnight range").font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height * 0.15), anchor: .center)

                let midY = size.height * 0.68
                var path = Path()
                let points = 120
                for i in 0...points {
                    let x = Double(i) / Double(points) * size.width
                    let y = midY - sin(Double(i) * 0.24 + t) * 22
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
                context.stroke(path, with: .color(.teal), lineWidth: 2.2)
            }
            .frame(height: 130)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(40))
                    t += 0.06
                }
            }

            HStack(spacing: 16) {
                Label("Breathing rate", systemImage: "wind").foregroundStyle(.teal)
                Label("Blood oxygen", systemImage: "drop.fill").foregroundStyle(.cyan)
            }
            .font(.caption)

            Text("""
                 Breathing is the mechanism, oxygen saturation is the outcome — a wrist sensor is \
                 watching both from the outside. Neither one means much as a single night's \
                 reading; the pattern over weeks is the more trustworthy signal.
                 """)
                .foregroundStyle(Theme.textSecondary)

            ClaimList(claims: claims)
        }
    }
}

// MARK: - Wrist temperature

struct TemperatureExplainer: View {
    @State private var t: Double = 0

    private let claims = [
        Claim(text: "Core and wrist temperature drop as part of normal sleep onset, then rise "
                  + "again toward morning wake — a circadian pattern, not a symptom by itself.",
              chunkID: "temperature-circadian-pattern"),
        Claim(text: "Wrist temperature is reported as a deviation from your own baseline, not an "
                  + "absolute body temperature — skin temperature runs cooler than core and "
                  + "varies with room temperature, bedding, and sensor contact.",
              chunkID: "temperature-deviation-not-absolute"),
        Claim(text: "A single night's deviation is weak evidence on its own; a run of nights in "
                  + "the same direction is what's usually worth noticing.",
              chunkID: "temperature-single-night-caveat")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A curve, not a thermostat reading").font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary)

            Canvas { context, size in
                // Canvas y grows downward, so the pre-dawn *low* needs the larger y value —
                // `+ sin` dips the middle of the curve toward the bottom of the frame.
                var path = Path()
                let points = 100
                for i in 0...points {
                    let x = Double(i) / Double(points)
                    let y = 0.5 + 0.34 * sin(.pi * x)
                    let point = CGPoint(x: x * size.width, y: y * size.height)
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                context.stroke(path, with: .color(.pink), lineWidth: 2.5)

                let markerX = 0.5 + 0.06 * sin(t)
                let markerY = 0.5 + 0.34 * sin(.pi * markerX)
                context.fill(
                    Path(ellipseIn: CGRect(x: markerX * size.width - 5, y: markerY * size.height - 5,
                                           width: 10, height: 10)),
                    with: .color(.pink))
            }
            .frame(height: 110)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    t += 0.04
                }
            }

            HStack(spacing: 16) {
                Label("Evening", systemImage: "sunset.fill").foregroundStyle(.orange)
                Spacer()
                Label("Pre-dawn low", systemImage: "moon.zzz.fill").foregroundStyle(.indigo)
                Spacer()
                Label("Wake", systemImage: "sunrise.fill").foregroundStyle(.yellow)
            }
            .font(.caption2)

            Text("""
                 Temperature falls as sleep begins and climbs back before you wake — that's the \
                 shape the app is comparing against your own baseline, not a fixed number that's \
                 supposed to stay flat.
                 """)
                .foregroundStyle(Theme.textSecondary)

            ClaimList(claims: claims)
        }
    }
}

// MARK: - Claim rendering and audit

struct ClaimList: View {
    let claims: [Claim]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What the evidence says").font(.headline).foregroundStyle(Theme.textPrimary)
            ForEach(claims) { claim in
                VStack(alignment: .leading, spacing: 3) {
                    Text(claim.text).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    Text(claim.chunkID).font(.caption2.monospaced()).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .cardStyle(padding: 14)
    }
}

/// Called from a test, not at runtime. If an explainer claim names a chunk that isn't in the
/// bundled corpus, the build fails rather than the claim shipping unsupported.
enum ExplainerAudit {
    static let allChunkIDs: [String] = [
        "vo2-limitation-central", "vo2-cardiac-output", "vo2-trainability-hiit",
        "hrv-rmssd-parasympathetic", "hrv-methodology-consensus",
        "hrv-guided-training-meta", "alcohol-sleep-architecture",
        "banister-two-component", "tapering-performance", "acwr-contested",
        "sleep-cycle-architecture", "sleep-stage-function", "sleep-architecture-vs-duration",
        "body-battery-composite-score", "body-battery-stress-mechanical-link",
        "body-battery-validation-caveat",
        "respiration-night-to-night-stability", "spo2-wrist-measurement-limits",
        "respiration-oxygen-coupling",
        "temperature-circadian-pattern", "temperature-deviation-not-absolute",
        "temperature-single-night-caveat"
    ]

    static func missingChunks(in corpus: [EvidenceChunk]) -> [String] {
        let present = Set(corpus.map(\.id))
        return allChunkIDs.filter { !present.contains($0) }
    }
}
