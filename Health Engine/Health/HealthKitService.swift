// HealthKitService.swift
// Epistemic role: boundary. No HKObject, HKUnit or HKQuantityType escapes this file.
// Everything leaves as an Observation in ontology units.

import Foundation
import HealthKit

public enum IngestVersion {
    public static let healthKit = "hk-1.0.0"
    public static let eventKit  = "ek-1.0.0"
    public static let location  = "loc-1.1.0"
    public static let garmin    = "garmin-1.0.0"
    public static let motion    = "motion-1.0.0"
    public static let dayShape  = "dayshape-1.0.0"
    public static let hkContext = "hkctx-1.0.0"
}

/// One hour's step total from `HKStatisticsCollectionQuery`'s own pre-aggregation.
public struct StepHourBucket: Sendable {
    public let hourStart: Date
    public let steps: Double
}

/// A generic HealthKit sample shape shared by headphone audio exposure and flights climbed —
/// both are (interval, value) triplets; what differs is only which half of the pair the
/// downstream feature actually needs.
public struct QuantitySample: Sendable {
    public let start: Date
    public let end: Date
    public let value: Double
}

public final class HealthKitService {
    private let store = HKHealthStore()
    private let db: Store
    private let calendar: Calendar

    public init(store db: Store, calendar: Calendar = .autoupdatingCurrent) {
        self.db = db
        self.calendar = calendar
    }

    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Type mapping

    /// Quantity types we read, with the unit each is normalised into.
    private static let quantityMap: [(id: HKQuantityTypeIdentifier, metric: Metric, unit: HKUnit)] = [
        (.restingHeartRate,          .hrResting,               HKUnit.count().unitDivided(by: .minute())),
        (.heartRateVariabilitySDNN,  .hrvSDNNOvernight,        HKUnit.secondUnit(with: .milli)),
        (.vo2Max,                    .vo2maxRunning,
             HKUnit.literUnit(with: .milli)
                 .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))),
        (.respiratoryRate,           .respirationAvgOvernight, HKUnit.count().unitDivided(by: .minute())),
        (.appleSleepingWristTemperature, .tempWristDeviation,  HKUnit.degreeCelsius()),
        (.walkingSpeed,              .walkingSpeedMean,        HKUnit.meter().unitDivided(by: .second()))
    ]

    /// Read only — never synced into `observation`, never turned into a `DailyConstruct`.
    /// These feed `ContextService`'s dedicated fetch methods for context-role features instead;
    /// they still need their own authorisation request or the queries just come back empty.
    private static let contextOnlyQuantityIDs: [HKQuantityTypeIdentifier] = [
        .stepCount, .headphoneAudioExposure, .flightsClimbed
    ]

    private static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for entry in quantityMap {
            if let t = HKQuantityType.quantityType(forIdentifier: entry.id) { types.insert(t) }
        }
        for id in contextOnlyQuantityIDs {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    // MARK: - Authorisation

    /// Partial grants are the normal case, not an error. HealthKit deliberately will not tell
    /// us which reads were denied — a denied type simply returns nothing, which is
    /// indistinguishable from having no data. Both mean "not observed", so both are correct.
    public func requestAuthorisation() async throws {
        guard HealthKitService.isAvailable else { throw HealthKitError.unavailable }
        try await store.requestAuthorization(toShare: [], read: HealthKitService.readTypes)
    }

    // MARK: - Incremental sync

    @discardableResult
    public func sync() async throws -> Int {
        var inserted = 0
        for entry in HealthKitService.quantityMap {
            inserted += try await syncQuantity(entry.id, metric: entry.metric, unit: entry.unit)
        }
        inserted += try await syncSleep()
        return inserted
    }

    private func syncQuantity(_ id: HKQuantityTypeIdentifier, metric: Metric,
                              unit: HKUnit) async throws -> Int {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return 0 }
        let key = "hk.anchor.\(id.rawValue)"
        let anchor = try loadAnchor(key)

        let (samples, newAnchor) = try await runAnchoredQuery(type: type, anchor: anchor)
        guard !samples.isEmpty else {
            if let newAnchor { try saveAnchor(key, newAnchor) }
            return 0
        }

        let observations = samples.compactMap { sample -> Observation? in
            guard let q = sample as? HKQuantitySample else { return nil }
            return Observation(metric: metric,
                               value: q.quantity.doubleValue(for: unit),
                               effectiveStart: q.startDate,
                               effectiveEnd: q.endDate == q.startDate ? nil : q.endDate,
                               recordedAt: Date(),
                               source: .healthkit,
                               sourceID: q.uuid.uuidString,
                               quality: q.device == nil ? 0.8 : 1.0,
                               ingestVersion: IngestVersion.healthKit)
        }

        let count = try db.insert(observations: observations)
        if let newAnchor { try saveAnchor(key, newAnchor) }
        return count
    }

    private func syncSleep() async throws -> Int {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return 0 }
        let key = "hk.anchor.sleepAnalysis"
        let (samples, newAnchor) = try await runAnchoredQuery(type: type, anchor: try loadAnchor(key))

        let categories = samples.compactMap { $0 as? HKCategorySample }
        let sessions = HealthKitService.collapseSleepSessions(categories, calendar: calendar)

        var observations: [Observation] = []
        for session in sessions {
            let wake = session.end
            observations.append(Observation(metric: .sleepDuration, value: session.asleepMinutes,
                                            effectiveStart: session.start, effectiveEnd: wake,
                                            source: .healthkit, sourceID: "\(session.id).duration",
                                            ingestVersion: IngestVersion.healthKit))
            observations.append(Observation(metric: .sleepEfficiency, value: session.efficiency,
                                            effectiveStart: session.start, effectiveEnd: wake,
                                            source: .healthkit, sourceID: "\(session.id).efficiency",
                                            ingestVersion: IngestVersion.healthKit))
            observations.append(Observation(metric: .sleepDeep, value: session.deepMinutes,
                                            effectiveStart: session.start, effectiveEnd: wake,
                                            source: .healthkit, sourceID: "\(session.id).deep",
                                            ingestVersion: IngestVersion.healthKit))
            observations.append(Observation(metric: .sleepREM, value: session.remMinutes,
                                            effectiveStart: session.start, effectiveEnd: wake,
                                            source: .healthkit, sourceID: "\(session.id).rem",
                                            ingestVersion: IngestVersion.healthKit))
            observations.append(Observation(metric: .sleepOnset,
                                            value: session.onsetMinutesFromMidnight(calendar: calendar),
                                            effectiveStart: session.start, effectiveEnd: wake,
                                            source: .healthkit, sourceID: "\(session.id).onset",
                                            ingestVersion: IngestVersion.healthKit))
        }

        let count = try db.insert(observations: observations)
        if let newAnchor { try saveAnchor(key, newAnchor) }
        return count
    }

    // MARK: - Raw series for Derive

    /// Strain needs the raw HR trace, which is far too large to keep as observations.
    /// It is fetched on demand and never stored.
    public func heartRateSamples(from: Date, to: Date) async throws -> [HeartRateSample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let out = (samples as? [HKQuantitySample] ?? []).map {
                    HeartRateSample(time: $0.startDate, bpm: $0.quantity.doubleValue(for: unit))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// One bucket per clock hour, `stats.startDate` on the hour — `HKStatisticsCollectionQuery`'s
    /// own pre-aggregation, far cheaper than pulling every raw pedometer sample and summing
    /// client-side. `anchorDate` is rounded down to the hour so buckets land on natural clock
    /// hours rather than drifting by whatever fraction of an hour `from` happened to be.
    public func hourlyStepBuckets(from: Date, to: Date) async throws -> [StepHourBucket] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return [] }
        let unit = HKUnit.count()
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let anchor = calendar.dateInterval(of: .hour, for: from)?.start ?? from
        var interval = DateComponents()
        interval.hour = 1

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum, anchorDate: anchor,
                                                    intervalComponents: interval)
            query.initialResultsHandler = { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                var out: [StepHourBucket] = []
                results?.enumerateStatistics(from: from, to: to) { stats, _ in
                    let sum = stats.sumQuantity()?.doubleValue(for: unit) ?? 0
                    out.append(StepHourBucket(hourStart: stats.startDate, steps: sum))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    /// Each sample's own `startDate`/`endDate` interval is what's summed downstream — for
    /// headphone audio that's listening-session duration; for flights climbed the interval is
    /// typically an instant and `value` (the count) is what matters. Same shape for both keeps
    /// `ContextService`'s derivation generic over the two.
    public func headphoneAudioSamples(from: Date, to: Date) async throws -> [QuantitySample] {
        try await quantitySamples(.headphoneAudioExposure,
                                  unit: .decibelAWeightedSoundPressureLevel(), from: from, to: to)
    }

    public func flightsClimbedSamples(from: Date, to: Date) async throws -> [QuantitySample] {
        try await quantitySamples(.flightsClimbed, unit: .count(), from: from, to: to)
    }

    private func quantitySamples(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                                 from: Date, to: Date) async throws -> [QuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let out = (samples as? [HKQuantitySample] ?? []).map {
                    QuantitySample(start: $0.startDate, end: $0.endDate,
                                   value: $0.quantity.doubleValue(for: unit))
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    public func sleepSessions(from: Date, to: Date) async throws -> [SleepSession] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, e in
                if let e { continuation.resume(throwing: e) }
                else { continuation.resume(returning: s as? [HKCategorySample] ?? []) }
            }
            store.execute(query)
        }
        return HealthKitService.collapseSleepSessions(samples, calendar: calendar)
            .map { SleepSession(start: $0.start, end: $0.end) }
    }

    // MARK: - Background delivery

    public func enableBackgroundDelivery() async throws {
        for entry in HealthKitService.quantityMap {
            guard let t = HKQuantityType.quantityType(forIdentifier: entry.id) else { continue }
            try? await store.enableBackgroundDelivery(for: t, frequency: .hourly)
        }
    }

    /// Long-running observers. The handler is called on a background queue; it must complete
    /// the HealthKit completion handler or iOS escalates to killing background delivery.
    public func startObserving(onNewData: @escaping @Sendable () -> Void) {
        for entry in HealthKitService.quantityMap {
            guard let t = HKQuantityType.quantityType(forIdentifier: entry.id) else { continue }
            let query = HKObserverQuery(sampleType: t, predicate: nil) { _, completion, _ in
                onNewData()
                completion()
            }
            store.execute(query)
        }
    }

    // MARK: - Plumbing

    private func runAnchoredQuery(type: HKSampleType,
                                  anchor: HKQueryAnchor?) async throws -> ([HKSample], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor,
                                              limit: HKObjectQueryNoLimit) { _, added, _, newAnchor, error in
                if let error {
                    // A denied read surfaces here. Absence of capability, not failure of the app.
                    if (error as NSError).code == HKError.errorAuthorizationDenied.rawValue {
                        continuation.resume(returning: ([], nil))
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: (added ?? [], newAnchor))
            }
            store.execute(query)
        }
    }

    private func loadAnchor(_ key: String) throws -> HKQueryAnchor? {
        guard let data = try db.anchor(key: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ key: String, _ anchor: HKQueryAnchor) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        try db.saveAnchor(key: key, payload: data)
    }

    // MARK: - Sleep session assembly

    struct AssembledSleep {
        let id: String
        let start: Date
        let end: Date
        let asleepMinutes: Double
        let inBedMinutes: Double
        let deepMinutes: Double
        let remMinutes: Double

        var efficiency: Double { inBedMinutes > 0 ? min(1, asleepMinutes / inBedMinutes) : 1 }

        func onsetMinutesFromMidnight(calendar: Calendar) -> Double {
            let c = calendar.dateComponents([.hour, .minute], from: start)
            let raw = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            // Onset after noon is "last night"; express it as negative minutes so that
            // 23:30 and 00:30 are 60 minutes apart, not 1,380.
            return raw >= 720 ? raw - 1440 : raw
        }
    }

    /// Apple emits sleep as many short overlapping stage samples. Collapse anything separated
    /// by less than an hour into one session.
    static func collapseSleepSessions(_ samples: [HKCategorySample],
                                      calendar: Calendar) -> [AssembledSleep] {
        guard !samples.isEmpty else { return [] }
        let sorted = samples.sorted { $0.startDate < $1.startDate }

        var groups: [[HKCategorySample]] = []
        var current: [HKCategorySample] = [sorted[0]]
        for s in sorted.dropFirst() {
            if let last = current.last, s.startDate.timeIntervalSince(last.endDate) > 3600 {
                groups.append(current); current = [s]
            } else {
                current.append(s)
            }
        }
        groups.append(current)

        return groups.compactMap { group in
            guard let start = group.map(\.startDate).min(),
                  let end = group.map(\.endDate).max() else { return nil }

            func minutes(_ predicate: (HKCategorySample) -> Bool) -> Double {
                group.filter(predicate).reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } / 60
            }

            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            ]

            let asleep = minutes { asleepValues.contains($0.value) }
            let inBed = max(end.timeIntervalSince(start) / 60, asleep)

            return AssembledSleep(
                id: group[0].uuid.uuidString,
                start: start, end: end,
                asleepMinutes: asleep,
                inBedMinutes: inBed,
                deepMinutes: minutes { $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue },
                remMinutes: minutes { $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue }
            )
        }
    }
}

public enum HealthKitError: Error {
    case unavailable
}
