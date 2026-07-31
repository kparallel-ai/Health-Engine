// Derive.swift
// Epistemic role: produces measurements. Pure and versioned — same inputs, bit-identical outputs.
// It never decides what anything means.

import Foundation

public enum DeriveVersion {
    /// Bump on any change to the arithmetic below. Stored on every row it produces.
    /// 1.0.1: fixed day assignment for body_battery.min and stress.avg (see Metric.isOvernight).
    public static let current = "derive-1.0.1"
}

// MARK: - Inputs that are not Observations

public enum BiologicalSex: String, Codable, Sendable { case male, female, unspecified }

public struct UserProfile: Codable, Sendable {
    public var sex: BiologicalSex
    public var age: Int
    /// Measured max HR if known. Otherwise Tanaka: 208 − 0.7·age (better than 220 − age).
    public var measuredMaxHR: Double?

    public init(sex: BiologicalSex = .unspecified, age: Int = 35, measuredMaxHR: Double? = nil) {
        self.sex = sex; self.age = age; self.measuredMaxHR = measuredMaxHR
    }

    public var maxHR: Double { measuredMaxHR ?? (208.0 - 0.7 * Double(age)) }

    /// Banister's intensity exponent. Sex-specific.
    public var trimpExponent: Double {
        switch sex {
        case .female: return 1.67
        case .male, .unspecified: return 1.92
        }
    }
}

public struct HeartRateSample: Sendable {
    public let time: Date
    public let bpm: Double
    public init(time: Date, bpm: Double) { self.time = time; self.bpm = bpm }
}

public struct SleepSession: Sendable {
    public let start: Date
    /// The wake time. This is what defines the day boundary.
    public let end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

// MARK: - Physiological day

/// Wake to following wake.
///
/// Overnight metrics belong to the day they *precede* — the HRV recorded during the night of
/// the 3rd–4th is the 4th's HRV, because it is the state you begin the 4th in. Daytime metrics
/// and context belong to the day they occur in. Get this wrong and every downstream lag is
/// off by one, which is invisible in tests and fatal in findings.
public struct DayBoundary {
    private let calendar: Calendar
    /// Wake times, sorted. Empty is fine — the fallback carries it.
    private let wakeTimes: [Date]

    /// Used when sleep data is missing. 04:00 local: after almost all sleep onsets,
    /// before almost all wakes.
    public static let fallbackHour = 4

    public init(sleepSessions: [SleepSession], calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
        self.wakeTimes = sleepSessions.map(\.end).sorted()
    }

    /// The physiological day a daytime instant belongs to.
    public func day(for instant: Date) -> Day {
        if let wake = mostRecentWake(atOrBefore: instant) {
            return Day(wake, calendar: calendar)
        }
        return fallbackDay(for: instant)
    }

    /// The physiological day an overnight measurement belongs to: the day it precedes,
    /// i.e. the day beginning at the wake that *ends* this sleep.
    public func dayForOvernight(sleepEndingAt wake: Date) -> Day {
        Day(wake, calendar: calendar)
    }

    /// Overnight measurement without an identified sleep session — assign by the fallback rule.
    public func dayForOvernight(measuredAt instant: Date) -> Day {
        if let wake = nextWake(after: instant), wake.timeIntervalSince(instant) < 16 * 3600 {
            return Day(wake, calendar: calendar)
        }
        return fallbackDay(for: instant)
    }

    /// DST-safe: works in calendar components, never by adding 86 400 s.
    private func fallbackDay(for instant: Date) -> Day {
        let hour = calendar.component(.hour, from: instant)
        if hour < DayBoundary.fallbackHour,
           let previous = calendar.date(byAdding: .day, value: -1, to: instant) {
            return Day(previous, calendar: calendar)
        }
        return Day(instant, calendar: calendar)
    }

    private func mostRecentWake(atOrBefore t: Date) -> Date? {
        var lo = 0, hi = wakeTimes.count - 1, best: Date?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if wakeTimes[mid] <= t { best = wakeTimes[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        // A wake more than 36 h old means we lost coverage; don't stretch a day across a gap.
        if let b = best, t.timeIntervalSince(b) > 36 * 3600 { return nil }
        return best
    }

    private func nextWake(after t: Date) -> Date? {
        var lo = 0, hi = wakeTimes.count - 1, best: Date?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if wakeTimes[mid] > t { best = wakeTimes[mid]; hi = mid - 1 } else { lo = mid + 1 }
        }
        return best
    }
}

// MARK: - Rolling baselines

public struct BaselineResult: Sendable {
    public let baseline: Double?
    public let robustSD: Double?
    public let deviationZ: Double?
    public let nSamples: Int
    public let confidence: Double
    public let flags: [String]
}

public enum Baselines {
    public static let window = 30
    /// Hard gate. Below this, return nil with confidence 0 — never a number.
    /// A baseline from nine days is not a weak baseline, it is not a baseline.
    public static let minimumSamples = 14
    /// Vendor deviation metrics are suppressed for this many days of device history.
    /// Wrist-temperature and HRV-status baselines are still warming up; their "anomalies"
    /// are warm-up artifacts, not physiology.
    public static let vendorWarmupDays = 21

    /// `history` is the preceding values in chronological order, excluding today.
    public static func compute(today: Double?, history: [Double],
                               daysOfDeviceHistory: Int,
                               isVendorDerived: Bool) -> BaselineResult {
        let window = Array(history.suffix(Baselines.window))
        var flags: [String] = []

        if isVendorDerived && daysOfDeviceHistory < vendorWarmupDays {
            flags.append("vendor_warmup")
            return BaselineResult(baseline: nil, robustSD: nil, deviationZ: nil,
                                  nSamples: window.count, confidence: 0, flags: flags)
        }

        guard window.count >= minimumSamples, let stat = medianAndRobustSD(window) else {
            flags.append("below_minimum_samples")
            return BaselineResult(baseline: nil, robustSD: nil, deviationZ: nil,
                                  nSamples: window.count, confidence: 0, flags: flags)
        }

        // Confidence ramps from the gate to the full window. Not a p-value; a coverage fraction.
        let confidence = min(1.0, Double(window.count) / Double(Baselines.window))

        var z: Double?
        if let today {
            if stat.sd > 1e-9 {
                z = (today - stat.median) / stat.sd
            } else {
                flags.append("degenerate_spread")
            }
        }
        return BaselineResult(baseline: stat.median, robustSD: stat.sd, deviationZ: z,
                              nSamples: window.count, confidence: confidence, flags: flags)
    }
}

// MARK: - TRIMP strain

public enum Strain {
    /// Sparse-sample guard. Garmin drops to 1-sample-per-2-minutes at rest and stops entirely
    /// when the watch is off. Without this cap, a 6-hour gap credits 6 hours of load at whatever
    /// intensity happened to bracket it.
    public static let maxSampleGapSeconds: Double = 60

    /// Shape constant. Tunable — calibrate against known reference days before trusting the number.
    public static var compressionC: Double = 90
    /// The raw TRIMP that maps to 21. Also tunable.
    public static var compressionFull: Double = 480

    public struct Result: Sendable {
        public let strain: Double
        public let rawTRIMP: Double
        public let secondsCounted: Double
        public let secondsDropped: Double
        public let flags: [String]
    }

    /// Banister TRIMP over one physiological day.
    ///
    ///   HRR   = (HR − RHR) / (HRmax − RHR), clamped to [0, 1]
    ///   TRIMP = Σ Δt(min) · HRR · 0.64 · e^(k·HRR)
    ///
    /// `restingHR` must be a rolling baseline, not a single morning reading — one bad night
    /// otherwise shifts every workout that month.
    public static func trimp(samples: [HeartRateSample], restingHR: Double,
                             profile: UserProfile) -> Result {
        guard samples.count >= 2 else {
            return Result(strain: 0, rawTRIMP: 0, secondsCounted: 0, secondsDropped: 0,
                          flags: samples.isEmpty ? ["no_samples"] : ["insufficient_samples"])
        }
        let maxHR = profile.maxHR
        let reserve = maxHR - restingHR
        guard reserve > 1 else {
            return Result(strain: 0, rawTRIMP: 0, secondsCounted: 0, secondsDropped: 0,
                          flags: ["invalid_hr_reserve"])
        }

        let ordered = samples.sorted { $0.time < $1.time }
        let k = profile.trimpExponent
        var total = 0.0, counted = 0.0, dropped = 0.0

        for i in 1..<ordered.count {
            let gap = ordered[i].time.timeIntervalSince(ordered[i - 1].time)
            guard gap > 0 else { continue }
            let dt = min(gap, maxSampleGapSeconds)
            if gap > maxSampleGapSeconds { dropped += gap - dt }
            counted += dt

            // Trapezoid on HRR, so a ramp is not credited at its endpoint value.
            let h0 = hrr(ordered[i - 1].bpm, restingHR: restingHR, reserve: reserve)
            let h1 = hrr(ordered[i].bpm, restingHR: restingHR, reserve: reserve)
            let hs = [h0, h1]
            for h in hs {
                total += (dt / 60.0 / 2.0) * h * 0.64 * exp(k * h)
            }
        }

        var flags: [String] = []
        if dropped > 3600 { flags.append("large_hr_gaps") }
        if counted < 4 * 3600 { flags.append("partial_coverage") }

        return Result(strain: compress(total), rawTRIMP: total,
                      secondsCounted: counted, secondsDropped: dropped, flags: flags)
    }

    private static func hrr(_ bpm: Double, restingHR: Double, reserve: Double) -> Double {
        min(max((bpm - restingHR) / reserve, 0), 1)
    }

    /// Log compression onto 0–21. Monotone, saturating, and calibrated by two constants
    /// that are meant to be tuned. This is TRIMP-based strain; it is not a reproduction of
    /// any vendor's proprietary score and should not be compared to one.
    public static func compress(_ raw: Double) -> Double {
        guard raw > 0 else { return 0 }
        let numerator = log(1 + raw / compressionC)
        let denominator = log(1 + compressionFull / compressionC)
        guard denominator > 0 else { return 0 }
        return min(21.0, 21.0 * numerator / denominator)
    }
}

// MARK: - Orchestration

public struct DeriveInput {
    public var observations: [Observation]
    public var heartRateSamples: [HeartRateSample]
    public var sleepSessions: [SleepSession]
    public var profile: UserProfile
    public var calendar: Calendar

    public init(observations: [Observation], heartRateSamples: [HeartRateSample] = [],
                sleepSessions: [SleepSession] = [], profile: UserProfile = UserProfile(),
                calendar: Calendar = .autoupdatingCurrent) {
        self.observations = observations
        self.heartRateSamples = heartRateSamples
        self.sleepSessions = sleepSessions
        self.profile = profile
        self.calendar = calendar
    }
}

public enum Derive {
    /// Vendor-computed deviations that must respect the warm-up suppression.
    private static let vendorDerived: Set<Metric> = [
        .tempWristDeviation, .hrvStatusGarmin, .bodyBatteryMin, .bodyBatteryMax,
        .stressAvg, .loadTrainingGarmin, .enduranceScore
    ]

    public static func constructs(from input: DeriveInput) -> [DailyConstruct] {
        let boundary = DayBoundary(sleepSessions: input.sleepSessions, calendar: input.calendar)

        // 1. Bucket observations into physiological days.
        var byMetric: [Metric: [Day: [Double]]] = [:]
        var allDays = Set<Day>()

        for o in input.observations {
            let day: Day = o.metric.isOvernight
                ? boundary.dayForOvernight(measuredAt: o.effectiveStart)
                : boundary.day(for: o.effectiveStart)
            allDays.insert(day)
            guard let v = o.value else { continue }   // NULL is measured-absent, not zero
            byMetric[o.metric, default: [:]][day, default: []].append(v)
        }

        // 2. Strain, from raw HR, needs a rolling RHR that exists before it can be computed.
        let strainByDay = deriveStrain(input: input, boundary: boundary,
                                       rhrByDay: byMetric[.hrResting] ?? [:])
        for (day, value) in strainByDay {
            byMetric[.loadStrainTrimp, default: [:]][day] = [value.strain]
            allDays.insert(day)
        }

        guard let firstDay = allDays.min() else { return [] }
        let orderedDays = allDays.sorted()

        // 3. Roll baselines forward.
        var out: [DailyConstruct] = []
        for (metric, dayValues) in byMetric {
            var history: [Double] = []
            for day in orderedDays {
                let todays = dayValues[day]
                let value = todays.map { median($0) }

                let elapsed = daysBetween(firstDay, day, calendar: input.calendar)
                let baseline = Baselines.compute(today: value, history: history,
                                                 daysOfDeviceHistory: elapsed,
                                                 isVendorDerived: vendorDerived.contains(metric))

                var flags = baseline.flags
                if let s = strainByDay[day], metric == .loadStrainTrimp { flags += s.flags }

                out.append(DailyConstruct(day: day, construct: metric, value: value,
                                          baseline: baseline.baseline,
                                          deviationZ: baseline.deviationZ,
                                          nSamples: todays?.count ?? 0,
                                          confidence: baseline.confidence, flags: flags,
                                          deriveVersion: DeriveVersion.current))
                if let value { history.append(value) }
            }
        }
        return out.sorted { ($0.day, $0.construct.rawValue) < ($1.day, $1.construct.rawValue) }
    }

    private static func deriveStrain(input: DeriveInput, boundary: DayBoundary,
                                     rhrByDay: [Day: [Double]]) -> [Day: Strain.Result] {
        guard !input.heartRateSamples.isEmpty else { return [:] }

        var samplesByDay: [Day: [HeartRateSample]] = [:]
        for s in input.heartRateSamples {
            samplesByDay[boundary.day(for: s.time), default: []].append(s)
        }

        let orderedDays = samplesByDay.keys.sorted()
        var rhrHistory: [Double] = []
        var out: [Day: Strain.Result] = [:]

        for day in orderedDays {
            // Rolling 30-day RHR baseline. If we don't have one yet, fall back to the day's own
            // reading; flag it so the number is visibly provisional.
            let rolling = rhrHistory.count >= Baselines.minimumSamples
                ? median(Array(rhrHistory.suffix(Baselines.window)))
                : rhrByDay[day].map { median($0) }

            if let rhr = rolling, let samples = samplesByDay[day] {
                var result = Strain.trimp(samples: samples, restingHR: rhr, profile: input.profile)
                if rhrHistory.count < Baselines.minimumSamples {
                    result = Strain.Result(strain: result.strain, rawTRIMP: result.rawTRIMP,
                                           secondsCounted: result.secondsCounted,
                                           secondsDropped: result.secondsDropped,
                                           flags: result.flags + ["provisional_rhr_baseline"])
                }
                out[day] = result
            }
            if let today = rhrByDay[day].map({ median($0) }) { rhrHistory.append(today) }
        }
        return out
    }

    /// Calendar-day difference. Not a division by 86 400.
    static func daysBetween(_ a: Day, _ b: Day, calendar: Calendar) -> Int {
        guard let da = a.date(in: calendar), let db = b.date(in: calendar) else { return 0 }
        return calendar.dateComponents([.day], from: da, to: db).day ?? 0
    }
}
