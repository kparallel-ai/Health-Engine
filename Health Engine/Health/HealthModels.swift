// HealthModels.swift
// Epistemic role: the app's own vocabulary. Nothing here knows HealthKit, EventKit or GRDB exists.

import Foundation

// MARK: - Metric ontology (BUILD-APP.md §Schema). Fixed. Changing later is expensive.

public enum Metric: String, Codable, CaseIterable, Sendable {
    // Tier 1 — HealthKit
    case hrResting                = "hr.resting"
    case hrvSDNNOvernight         = "hrv.sdnn_overnight"
    case vo2maxRunning            = "vo2max.running"
    case sleepDuration            = "sleep.duration"
    case sleepEfficiency          = "sleep.efficiency"
    case sleepDeep                = "sleep.deep"
    case sleepREM                 = "sleep.rem"
    case sleepOnset               = "sleep.onset"
    case respirationAvgOvernight  = "respiration.avg_overnight"
    case tempWristDeviation       = "temp.wrist_deviation"
    case loadStrainTrimp          = "load.strain_trimp"

    // Tier 2 — EventKit, CoreLocation
    case ctxMeetingHours          = "ctx.meeting_hours"
    case ctxFirstEventHour        = "ctx.first_event_hour"
    case ctxLastEventHour         = "ctx.last_event_hour"
    case ctxMinutesOutsideHome    = "ctx.minutes_outside_home"
    case ctxTimezoneShift         = "ctx.timezone_shift"

    // Tier 3 — Garmin
    case hrvRMSSDOvernight        = "hrv.rmssd_overnight"
    case hrvStatusGarmin          = "hrv.status_garmin"
    case bodyBatteryMin           = "body_battery.min"
    case bodyBatteryMax           = "body_battery.max"
    case stressAvg                = "stress.avg"
    case loadTrainingGarmin       = "load.training_garmin"
    case spo2AvgOvernight         = "spo2.avg_overnight"
    case thresholdLactateHR       = "threshold.lactate_hr"
    case enduranceScore           = "endurance.score"

    public var unit: String {
        switch self {
        case .hrResting, .thresholdLactateHR:            return "bpm"
        case .hrvSDNNOvernight, .hrvRMSSDOvernight:      return "ms"
        case .vo2maxRunning:                             return "ml_kg_min"
        case .sleepDuration, .sleepDeep, .sleepREM:      return "min"
        case .sleepOnset:                                return "min_from_midnight"
        case .sleepEfficiency, .spo2AvgOvernight:        return "frac"
        case .respirationAvgOvernight:                   return "brpm"
        case .tempWristDeviation:                        return "C"
        case .loadStrainTrimp:                           return "au_0_21"
        case .ctxMeetingHours, .ctxFirstEventHour,
             .ctxLastEventHour, .ctxTimezoneShift:       return "h"
        case .ctxMinutesOutsideHome:                     return "min"
        case .hrvStatusGarmin:                           return "enum"
        case .bodyBatteryMin, .bodyBatteryMax,
             .stressAvg:                                 return "0_100"
        case .loadTrainingGarmin, .enduranceScore:       return "au"
        }
    }

    public var tier: Int {
        switch self {
        case .ctxMeetingHours, .ctxFirstEventHour, .ctxLastEventHour,
             .ctxMinutesOutsideHome, .ctxTimezoneShift:
            return 2
        case .hrvRMSSDOvernight, .hrvStatusGarmin, .bodyBatteryMin, .bodyBatteryMax,
             .stressAvg, .loadTrainingGarmin, .spo2AvgOvernight,
             .thresholdLactateHR, .enduranceScore:
            return 3
        default:
            return 1
        }
    }

    /// Overnight metrics belong to the day they *precede* (Derive §physiological day).
    ///
    /// Garmin's daily summary (`bodyBattery`, `allDayStress`) is keyed by a `calendarDate` that
    /// itself spans afternoon through the following pre-dawn hours — already a wake-to-wake
    /// bucket, not a midnight-to-midnight one. Tagging these `false` sent their midnight-anchored
    /// timestamp through the *daytime* assignment path (`day(for:)`, `mostRecentWake(atOrBefore:)`),
    /// which resolves a midnight instant to the **previous** day's wake and silently shifted every
    /// Garmin daily reading back by a day. `bodyBatteryMax` was already correctly `true`.
    public var isOvernight: Bool {
        switch self {
        case .hrResting, .hrvSDNNOvernight, .hrvRMSSDOvernight, .sleepDuration,
             .sleepEfficiency, .sleepDeep, .sleepREM, .sleepOnset,
             .respirationAvgOvernight, .tempWristDeviation, .spo2AvgOvernight,
             .bodyBatteryMax, .bodyBatteryMin, .stressAvg:
            return true
        default:
            return false
        }
    }

    /// SPEC §7.3 — hard requirement. HRV never gets a population percentile.
    public var permitsNormativePercentile: Bool {
        switch self {
        case .vo2maxRunning, .hrResting: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .hrResting:               return "Resting Heart Rate"
        case .hrvSDNNOvernight:        return "HRV (SDNN, overnight)"
        case .hrvRMSSDOvernight:       return "HRV (rMSSD, overnight)"
        case .vo2maxRunning:           return "VO\u{2082}max"
        case .sleepDuration:           return "Sleep Duration"
        case .sleepEfficiency:         return "Sleep Efficiency"
        case .sleepDeep:               return "Deep Sleep"
        case .sleepREM:                return "REM Sleep"
        case .sleepOnset:              return "Sleep Onset"
        case .respirationAvgOvernight: return "Respiratory Rate"
        case .tempWristDeviation:      return "Wrist Temperature Deviation"
        case .loadStrainTrimp:         return "Strain"
        case .ctxMeetingHours:         return "Meeting Hours"
        case .ctxFirstEventHour:       return "First Event"
        case .ctxLastEventHour:        return "Last Event"
        case .ctxMinutesOutsideHome:   return "Time Away From Home"
        case .ctxTimezoneShift:        return "Timezone Shift"
        case .hrvStatusGarmin:         return "HRV Status"
        case .bodyBatteryMin:          return "Body Battery (min)"
        case .bodyBatteryMax:          return "Body Battery (max)"
        case .stressAvg:               return "Stress"
        case .loadTrainingGarmin:      return "Training Load"
        case .spo2AvgOvernight:        return "SpO\u{2082}"
        case .thresholdLactateHR:      return "Lactate Threshold HR"
        case .enduranceScore:          return "Endurance Score"
        }
    }

    /// SF Symbol used as the small badge icon on cards — purely decorative, no epistemic weight.
    public var symbolName: String {
        switch self {
        case .hrResting:                                    return "heart.fill"
        case .hrvSDNNOvernight, .hrvRMSSDOvernight,
             .hrvStatusGarmin:                                return "waveform.path.ecg"
        case .vo2maxRunning:                                return "lungs.fill"
        case .sleepDuration, .sleepEfficiency, .sleepDeep,
             .sleepREM, .sleepOnset:                          return "moon.zzz.fill"
        case .respirationAvgOvernight:                      return "wind"
        case .tempWristDeviation:                           return "thermometer.medium"
        case .loadStrainTrimp, .loadTrainingGarmin:          return "flame.fill"
        case .ctxMeetingHours, .ctxFirstEventHour,
             .ctxLastEventHour:                               return "calendar"
        case .ctxMinutesOutsideHome:                        return "figure.walk"
        case .ctxTimezoneShift:                             return "globe"
        case .bodyBatteryMin, .bodyBatteryMax:               return "battery.75"
        case .stressAvg:                                    return "brain.head.profile"
        case .spo2AvgOvernight:                             return "drop.fill"
        case .thresholdLactateHR:                           return "bolt.heart.fill"
        case .enduranceScore:                               return "figure.run"
        }
    }
}

public enum Source: String, Codable, Sendable {
    case healthkit, eventkit, location, garmin
}

// MARK: - Observation

/// Two time axes, always. `effectiveStart` is when the physiology happened;
/// `recordedAt` is when we learned it. HealthKit backfills and Garmin reprocesses.
public struct Observation: Codable, Equatable, Sendable {
    public var id: Int64?
    public var metric: Metric
    /// nil == measured-absent. Absence of a row == not observed. Never conflate them.
    public var value: Double?
    public var unit: String
    public var effectiveStart: Date
    public var effectiveEnd: Date?
    public var recordedAt: Date
    public var source: Source
    public var sourceID: String?
    public var quality: Double
    public var flags: [String]
    public var ingestVersion: String

    public init(metric: Metric, value: Double?, effectiveStart: Date, effectiveEnd: Date? = nil,
                recordedAt: Date = Date(), source: Source, sourceID: String? = nil,
                quality: Double = 1.0, flags: [String] = [], ingestVersion: String) {
        self.id = nil
        self.metric = metric
        self.value = value
        self.unit = metric.unit
        self.effectiveStart = effectiveStart
        self.effectiveEnd = effectiveEnd
        self.recordedAt = recordedAt
        self.source = source
        self.sourceID = sourceID
        self.quality = quality
        self.flags = flags
        self.ingestVersion = ingestVersion
    }
}

// MARK: - Derived values

/// A measurement. Produced by Derive, consumed by Analyzer. Carries its own uncertainty.
public struct DailyConstruct: Codable, Equatable, Sendable {
    public var day: Day
    public var construct: Metric
    public var value: Double?
    public var baseline: Double?
    public var deviationZ: Double?
    public var nSamples: Int
    /// 0 when the minimum-sample gate suppressed the baseline. Never a number in that case.
    public var confidence: Double
    public var flags: [String]
    public var deriveVersion: String
}

public struct ContextFeature: Codable, Equatable, Sendable {
    public var day: Day
    public var feature: Metric
    public var value: Double?
    /// false == timeline annotation only. Excluded from scans: six occurrences a year cannot be tested.
    public var isDense: Bool
    public var source: Source
    public var deriveVersion: String
}

// MARK: - Findings

public enum FindingKind: String, Codable, Sendable { case trend, changepoint, association }

public enum EvidenceTier: String, Codable, Comparable, Sendable {
    case t0 = "T0", t1 = "T1", t2 = "T2", t3 = "T3", t4 = "T4"

    private var rank: Int { ["T0": 0, "T1": 1, "T2": 2, "T3": 3, "T4": 4][rawValue] ?? 0 }
    public static func < (a: EvidenceTier, b: EvidenceTier) -> Bool { a.rank < b.rank }

    /// SPEC §5.1. Exact phrasing. This is the honesty mechanism; do not soften it.
    public var phrasingTemplate: String {
        switch self {
        case .t0: return "%@ was %@ relative to your baseline."
        case .t1: return "%@ and %@ have co-occurred %@ times."
        case .t2: return "%@ and %@ tend to move together."
        case .t3: return "%@ may be contributing to %@."
        case .t4: return "In your own test, %@ changed %@ by %@."
        }
    }

    public var label: String {
        switch self {
        case .t0: return "Descriptive"
        case .t1: return "Co-occurrence"
        case .t2: return "Stable association"
        case .t3: return "Possible contribution"
        case .t4: return "Tested in your own trial"
        }
    }
}

public struct Finding: Codable, Equatable, Identifiable, Sendable {
    public var id: String              // deterministic hash of the hypothesis
    public var kind: FindingKind
    public var tier: EvidenceTier
    public var subject: String
    public var object: String?
    public var lagDays: Int?
    public var effectSize: Double?
    public var effectCILow: Double?
    public var effectCIHigh: Double?
    public var pRaw: Double?
    public var qValue: Double?
    public var nObservations: Int
    /// Stored on *every* finding including failures. Auditability requires knowing how many tests ran.
    public var familyID: String
    public var familySize: Int
    public var method: String
    public var windowsStable: Bool
    public var computedAt: Date
    public var inferVersion: String

    /// Only findings that cleared FDR + effect floor + N gate are shown.
    public var isSurfaced: Bool { tier >= .t1 }
}

// MARK: - Day

/// A physiological day: YYYY-MM-DD in the user's local calendar. Not a Date.
public struct Day: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let raw: String

    public init(raw: String) { self.raw = raw }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.raw = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func date(in calendar: Calendar) -> Date? {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = 12
        return calendar.date(from: c)
    }

    /// DST-safe: adds calendar days, not 86 400 s.
    public func adding(days: Int, calendar: Calendar) -> Day? {
        guard let d = date(in: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: d) else { return nil }
        return Day(shifted, calendar: calendar)
    }

    public static func < (a: Day, b: Day) -> Bool { a.raw < b.raw }
    public var description: String { raw }
}
