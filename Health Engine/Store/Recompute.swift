// Recompute.swift
// Epistemic role: orchestration only. It decides *when* derive and scan run, never *what*
// they conclude. Every number it produces comes from Derive or Analyzer unchanged.

import Combine
import Foundation

@MainActor
public final class Recompute: ObservableObject {

    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case deriving(Double)
        case joiningContext
        case scanning(Double)
        case persisting
        case failed(String)

        public var label: String {
            switch self {
            case .idle:            return "Up to date"
            case .loading:         return "Reading observations"
            case .deriving:        return "Computing baselines"
            case .joiningContext:  return "Joining context"
            case .scanning:        return "Testing associations"
            case .persisting:      return "Saving"
            case .failed(let m):   return "Stopped: \(m)"
            }
        }

        public var fraction: Double {
            switch self {
            case .idle:               return 1
            case .loading:            return 0.05
            case .deriving(let f):    return 0.05 + 0.25 * f
            case .joiningContext:     return 0.35
            case .scanning(let f):    return 0.35 + 0.60 * f
            case .persisting:         return 0.97
            case .failed:             return 0
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var lastCompleted: Date?
    /// Hash of the last scan's output. Re-running on unchanged input must reproduce it exactly.
    @Published public private(set) var lastOutputHash: String?

    private let db: Store
    private let calendar: Calendar
    private var task: Task<Void, Never>?

    public init(store: Store, calendar: Calendar = .autoupdatingCurrent) {
        self.db = store
        self.calendar = calendar
    }

    public var isRunning: Bool { task != nil && !(task?.isCancelled ?? true) }

    public func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Coalesces: a second call while running is ignored rather than queued.
    private func launch(_ body: @escaping @Sendable () async throws -> Void) {
        guard !isRunning else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await body()
            } catch is CancellationError {
                await MainActor.run { self.phase = .idle }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
            await MainActor.run { self.task = nil }
        }
    }

    /// The cheap, automatic path: today's numbers and rolling baselines only. Safe to call from
    /// HealthKit background delivery, pull-to-refresh, or right after an import — none of those
    /// deserve a surprise minute of background CPU. Never touches the association scan.
    public func runDeriveOnly(profile: UserProfile,
                              heartRateProvider: @escaping @Sendable (Date, Date) async throws -> [HeartRateSample],
                              sleepProvider: @escaping @Sendable (Date, Date) async throws -> [SleepSession]) {
        launch { [weak self] in
            guard let self else { return }
            _ = try await self.deriveAndPersist(profile: profile, heartRateProvider: heartRateProvider,
                                                sleepProvider: sleepProvider)
            await MainActor.run {
                self.lastCompleted = Date()
                self.phase = .idle
            }
        }
    }

    /// The expensive path — every metric tested against every other metric, and, once granted,
    /// against calendar/location context. This is real, minutes-scale CPU work; it runs only
    /// when the user explicitly starts it (see `InsightsScanView`), never automatically.
    public func runFullScan(profile: UserProfile,
                            heartRateProvider: @escaping @Sendable (Date, Date) async throws -> [HeartRateSample],
                            sleepProvider: @escaping @Sendable (Date, Date) async throws -> [SleepSession],
                            contextProvider: @escaping @Sendable (DayBoundary) -> [ContextFeature]) {
        launch { [weak self] in
            guard let self else { return }
            try await self.executeFullScan(profile: profile, heartRateProvider: heartRateProvider,
                                           sleepProvider: sleepProvider, contextProvider: contextProvider)
        }
    }

    /// Shared by both entry points. Loads observations, derives constructs and baselines off
    /// the main actor, persists them, and returns the constructs plus the sleep-derived day
    /// boundary the scan path needs for joining context.
    private func deriveAndPersist(profile: UserProfile,
                                  heartRateProvider: @escaping @Sendable (Date, Date) async throws -> [HeartRateSample],
                                  sleepProvider: @escaping @Sendable (Date, Date) async throws -> [SleepSession])
        async throws -> (constructs: [DailyConstruct], boundary: DayBoundary) {

        phase = .loading
        guard let range = try db.observationDateRange() else {
            phase = .idle
            return ([], DayBoundary(sleepSessions: [], calendar: calendar))
        }

        var observations: [Observation] = []
        for metric in Metric.allCases {
            try Task.checkCancellation()
            observations += try db.observations(metric: metric)
        }

        let sleep = (try? await sleepProvider(range.first, range.last)) ?? []
        let boundary = DayBoundary(sleepSessions: sleep, calendar: calendar)
        let heartRate = (try? await heartRateProvider(range.first, range.last)) ?? []

        try Task.checkCancellation()
        phase = .deriving(0.1)

        // Derive is pure and CPU-bound; keep it off the main actor.
        let input = DeriveInput(observations: observations, heartRateSamples: heartRate,
                                sleepSessions: sleep, profile: profile, calendar: calendar)
        let constructs = await Task.detached(priority: .utility) {
            Derive.constructs(from: input)
        }.value

        try Task.checkCancellation()
        phase = .deriving(1.0)
        try db.replace(constructs: constructs)

        return (constructs, boundary)
    }

    private func executeFullScan(profile: UserProfile,
                                 heartRateProvider: @escaping @Sendable (Date, Date) async throws -> [HeartRateSample],
                                 sleepProvider: @escaping @Sendable (Date, Date) async throws -> [SleepSession],
                                 contextProvider: @escaping @Sendable (DayBoundary) -> [ContextFeature]) async throws {

        let (constructs, boundary) = try await deriveAndPersist(profile: profile,
                                                                 heartRateProvider: heartRateProvider,
                                                                 sleepProvider: sleepProvider)
        guard !constructs.isEmpty else { phase = .idle; return }

        phase = .joiningContext
        let features = contextProvider(boundary)
        if !features.isEmpty { try db.replace(features: features) }

        try Task.checkCancellation()
        phase = .scanning(0.05)

        let storedFeatures = try db.features(version: IngestVersion.eventKit)
            + db.features(version: IngestVersion.location)
        let contextFamily = ScanFamily.contextAssociations

        // Calendar/location permission is never requested anywhere in the app today, so
        // `storedFeatures` is routinely empty and the context scan alone would leave this
        // screen permanently blank. Building a second feature set out of the constructs
        // themselves gives the analyzer a real, already-populated candidate pool — sleep vs.
        // next-day HRV, stress vs. body battery, and so on — gated by the same bootstrap/BH/tier
        // machinery, just with a same-day-count floor calibrated for dense biometric pairs
        // instead of sparse calendar/location ones (see `ScanConfig.biometricSelf`).
        let selfFeatures: [ContextFeature] = constructs.compactMap { c in
            guard let v = c.value else { return nil }
            return ContextFeature(day: c.day, feature: c.construct, value: v, isDense: true,
                                  source: .healthkit, deriveVersion: DeriveVersion.current)
        }
        let biometricFamily = ScanFamily.biometricAssociations

        // 365 × 25 × 20 × 4 × 2,000 is real work. Detached, cancellable, never on the main actor,
        // and deliberately `.background` priority — not `.utility` — so a heavy scan degrades
        // gracefully instead of contending with the UI thread for CPU time.
        let (contextFindings, biometricFindings) = await Task.detached(priority: .background) {
            let context = Analyzer.scan(constructs: constructs, features: storedFeatures,
                                        family: contextFamily)
            let biometric = Analyzer.scan(constructs: constructs, features: selfFeatures,
                                          family: biometricFamily, config: .biometricSelf,
                                          symmetric: true)
            return (context, biometric)
        }.value

        try Task.checkCancellation()
        phase = .persisting
        try db.replace(findings: contextFindings, familyID: contextFamily.id)
        try db.replace(findings: biometricFindings, familyID: biometricFamily.id)

        lastOutputHash = Recompute.outputHash(contextFindings + biometricFindings)
        lastCompleted = Date()
        phase = .idle
    }

    /// Order-independent hash of the finding set. A9's "re-running produces identical output"
    /// requirement is checked against this.
    static func outputHash(_ findings: [Finding]) -> String {
        let parts = findings
            .map { "\($0.id):\(String(format: "%.12f", $0.effectSize ?? .nan)):\($0.tier.rawValue)" }
            .sorted()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "|").utf8 {
            h ^= UInt64(byte); h = h &* 0x1000_0000_01b3
        }
        return String(h, radix: 16)
    }
}
