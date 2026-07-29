// Analyzer.swift
// Epistemic role: produces facts, not conclusions. It reports what the data does; it never
// says what to do about it. The tier assigned here is the only honesty mechanism in the app.

import Foundation
import CryptoKit

public enum InferVersion {
    public static let current = "infer-1.0.0"
}

// MARK: - Scan configuration

public struct ScanFamily: Hashable, Sendable {
    public let id: String
    public let label: String
    public init(id: String, label: String) { self.id = id; self.label = label }

    public static let contextAssociations = ScanFamily(id: "ctx-assoc-v1",
                                                       label: "Context associations")
}

public struct ScanConfig: Sendable {
    /// SPEC §5: BH at q = 0.10 across the whole family.
    public var q: Double = 0.10
    /// SPEC §5: |r| < 0.25 never surfaces, regardless of q.
    public var effectFloor: Double = 0.25
    public var lags: ClosedRange<Int> = 0...3
    public var nBoot: Int = 2000
    /// SPEC §4.1 minimum days.
    public var minNSameDay: Int = 60
    public var minNLagged: Int = 90
    /// Both halves must clear this and agree in sign to reach T2.
    public var stabilityFloor: Double = 0.15
    public var minWindowN: Int = 30
    /// A third feature correlating this strongly with both sides blocks T3.
    public var confounderThreshold: Double = 0.4
    public var seed: UInt64 = 0x5EED_C0FFEE

    public init() {}
}

// MARK: - Tier assignment

/// Everything the tier ladder is allowed to look at. Assembled by the scan, but the assignment
/// itself is a pure function of this struct — no scan state, no ordering, no side channels.
public struct TierEvidence: Sendable {
    public var n: Int
    public var minN: Int
    public var absEffect: Double
    public var effectFloor: Double
    public var qValue: Double
    public var q: Double
    public var windowsStable: Bool
    public var hasTemporalPrecedence: Bool
    public var confounderIdentified: Bool
    public var isRandomisedTrial: Bool

    public init(n: Int, minN: Int, absEffect: Double, effectFloor: Double, qValue: Double,
                q: Double, windowsStable: Bool, hasTemporalPrecedence: Bool,
                confounderIdentified: Bool, isRandomisedTrial: Bool = false) {
        self.n = n; self.minN = minN; self.absEffect = absEffect; self.effectFloor = effectFloor
        self.qValue = qValue; self.q = q; self.windowsStable = windowsStable
        self.hasTemporalPrecedence = hasTemporalPrecedence
        self.confounderIdentified = confounderIdentified
        self.isRandomisedTrial = isRandomisedTrial
    }
}

public func assignTier(_ e: TierEvidence) -> EvidenceTier {
    // T4 requires a within-person randomised trial. Unreachable in this build by construction.
    if e.isRandomisedTrial { return .t4 }

    // T1: FDR + effect floor + autocorrelation-corrected p + minimum N. All four, no exceptions.
    guard e.n >= e.minN,
          e.absEffect >= e.effectFloor,
          e.qValue <= e.q else { return .t0 }

    guard e.windowsStable else { return .t1 }
    guard e.hasTemporalPrecedence, !e.confounderIdentified else { return .t2 }
    return .t3
}

// MARK: - Analyzer

public enum Analyzer {

    public static func scan(constructs: [DailyConstruct],
                            features: [ContextFeature],
                            family: ScanFamily,
                            config: ScanConfig = ScanConfig()) -> [Finding] {

        // Sparse categorical events are annotations, never variables. A feature with six
        // occurrences a year cannot be tested and must not enter the family count either.
        let dense = features.filter(\.isDense)

        let constructSeries = Dictionary(grouping: constructs, by: \.construct)
            .mapValues { series -> [Day: Double] in
                var m: [Day: Double] = [:]
                for c in series { if let v = c.value { m[c.day] = v } }
                return m
            }
        let featureSeries = Dictionary(grouping: dense, by: \.feature)
            .mapValues { series -> [Day: Double] in
                var m: [Day: Double] = [:]
                for f in series { if let v = f.value { m[f.day] = v } }
                return m
            }

        let calendar = Calendar.autoupdatingCurrent

        // Pass 1 — every hypothesis in the family gets tested. Nothing is skipped for looking
        // unpromising; the family count has to be exact or the FDR correction is a lie.
        struct Candidate {
            let construct: Metric, feature: Metric, lag: Int
            let boot: BootstrapResult
            let stable: Bool, precedence: Bool, confounded: Bool
            let id: String
        }

        var candidates: [Candidate] = []

        for (construct, cSeries) in constructSeries.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for (feature, fSeries) in featureSeries.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                for lag in config.lags {
                    let pair = align(construct: cSeries, feature: fSeries, lag: lag, calendar: calendar)
                    guard pair.x.count >= 8 else { continue }

                    let id = hypothesisID(construct: construct, feature: feature,
                                          lag: lag, family: family)
                    var rng = SeededRNG(seed: config.seed &+ stableSeed(id))
                    let L = blockLength(x: pair.x, y: pair.y)
                    let boot = blockBootstrapCorrelation(pair.x, pair.y, nBoot: config.nBoot,
                                                         blockLength: L, rng: &rng)

                    let stable = isStable(pair.x, pair.y, config: config)
                    let precedence = lag >= 1 && hasTemporalPrecedence(
                        construct: cSeries, feature: fSeries, lag: lag,
                        forward: boot.r, calendar: calendar)
                    let confounded = hasConfounder(construct: cSeries, feature: feature,
                                                   featureSeries: featureSeries, lag: lag,
                                                   calendar: calendar, config: config)

                    candidates.append(Candidate(construct: construct, feature: feature, lag: lag,
                                                boot: boot, stable: stable, precedence: precedence,
                                                confounded: confounded, id: id))
                }
            }
        }

        guard !candidates.isEmpty else { return [] }

        // Pass 2 — one BH correction across the whole family, then tier each result.
        let qValues = benjaminiHochberg(candidates.map(\.boot.p))
        let familySize = candidates.count
        let now = Date()

        return zip(candidates, qValues).map { candidate, qValue in
            let minN = candidate.lag == 0 ? config.minNSameDay : config.minNLagged
            let evidence = TierEvidence(n: candidate.boot.n, minN: minN,
                                        absEffect: abs(candidate.boot.r),
                                        effectFloor: config.effectFloor,
                                        qValue: qValue, q: config.q,
                                        windowsStable: candidate.stable,
                                        hasTemporalPrecedence: candidate.precedence,
                                        confounderIdentified: candidate.confounded)

            return Finding(id: candidate.id, kind: .association, tier: assignTier(evidence),
                           subject: candidate.construct.rawValue,
                           object: candidate.feature.rawValue,
                           lagDays: candidate.lag,
                           effectSize: candidate.boot.r,
                           effectCILow: candidate.boot.ciLow,
                           effectCIHigh: candidate.boot.ciHigh,
                           pRaw: candidate.boot.p, qValue: qValue,
                           nObservations: candidate.boot.n,
                           familyID: family.id, familySize: familySize,
                           method: "moving-block-bootstrap;L=\(candidate.boot.blockLength);"
                                 + "B=\(candidate.boot.nBoot);BH-FDR",
                           windowsStable: candidate.stable,
                           computedAt: now, inferVersion: InferVersion.current)
        }
    }

    // MARK: - Alignment

    /// Feature at day d−lag paired with construct at day d. Lag runs one way by design:
    /// context precedes physiology, not the reverse.
    static func align(construct: [Day: Double], feature: [Day: Double],
                      lag: Int, calendar: Calendar) -> (x: [Double], y: [Double], days: [Day]) {
        var x: [Double] = [], y: [Double] = [], days: [Day] = []
        for day in construct.keys.sorted() {
            guard let cv = construct[day],
                  let lagged = day.adding(days: -lag, calendar: calendar),
                  let fv = feature[lagged] else { continue }
            days.append(day); x.append(fv); y.append(cv)
        }
        return (x, y, days)
    }

    // MARK: - Stability (gate to T2)

    /// Two non-overlapping windows. Same sign, both clearing a reduced floor, both with
    /// enough observations to mean anything.
    static func isStable(_ x: [Double], _ y: [Double], config: ScanConfig) -> Bool {
        let n = min(x.count, y.count)
        guard n >= config.minWindowN * 2 else { return false }
        let mid = n / 2
        let r1 = pearson(Array(x[0..<mid]), Array(y[0..<mid]))
        let r2 = pearson(Array(x[mid..<n]), Array(y[mid..<n]))
        guard r1.sign == r2.sign else { return false }
        return abs(r1) >= config.stabilityFloor && abs(r2) >= config.stabilityFloor
    }

    // MARK: - Temporal precedence (gate to T3)

    /// The forward direction (context → physiology) must beat the reverse (physiology → context)
    /// by a clear margin. Equal strength in both directions is not precedence, it is a shared
    /// weekly rhythm.
    static func hasTemporalPrecedence(construct: [Day: Double], feature: [Day: Double],
                                      lag: Int, forward: Double, calendar: Calendar) -> Bool {
        guard lag >= 1 else { return false }
        let reversePair = align(construct: feature, feature: construct, lag: lag, calendar: calendar)
        guard reversePair.x.count >= 20 else { return false }
        let reverse = pearson(reversePair.x, reversePair.y)
        return abs(forward) > abs(reverse) * 1.5
    }

    // MARK: - Confounder screen (gate to T3)

    /// Necessarily partial. It can only see the features we happen to measure, so it screens
    /// for the confounders in the ontology and is silent about the ones that matter most —
    /// see SPEC §5.2. A negative result here is not evidence of no confounding.
    static func hasConfounder(construct: [Day: Double], feature: Metric,
                              featureSeries: [Metric: [Day: Double]], lag: Int,
                              calendar: Calendar, config: ScanConfig) -> Bool {
        guard let target = featureSeries[feature] else { return false }
        for (other, otherSeries) in featureSeries where other != feature {
            let withFeature = align(construct: target, feature: otherSeries, lag: 0, calendar: calendar)
            guard withFeature.x.count >= 30 else { continue }
            guard abs(pearson(withFeature.x, withFeature.y)) >= config.confounderThreshold else { continue }

            let withConstruct = align(construct: construct, feature: otherSeries,
                                      lag: lag, calendar: calendar)
            guard withConstruct.x.count >= 30 else { continue }
            if abs(pearson(withConstruct.x, withConstruct.y)) >= config.confounderThreshold {
                return true
            }
        }
        return false
    }

    // MARK: - Identity

    /// Deterministic across launches. Swift's `Hasher` is per-process seeded and is unusable
    /// for anything persisted.
    static func hypothesisID(construct: Metric, feature: Metric, lag: Int, family: ScanFamily) -> String {
        let key = "\(family.id)|association|\(construct.rawValue)|\(feature.rawValue)|lag=\(lag)"
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func stableSeed(_ id: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in id.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x1000_0000_01b3
        }
        return h
    }
}

private extension Double {
    var sign: Int { self > 0 ? 1 : (self < 0 ? -1 : 0) }
}
