// ContextService.swift
// Epistemic role: boundary. Turns calendars and coarse location into context features.
// A denied permission produces *no rows*, never zero-valued rows. Zero means "no meetings";
// absent means "we don't know". Confusing the two poisons every association downstream.

import Foundation
import EventKit
import CoreLocation
import CoreMotion

public final class ContextService: NSObject {
    private let db: Store
    private let calendar: Calendar
    private let eventStore = EKEventStore()
    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()

    public init(store: Store, calendar: Calendar = .autoupdatingCurrent) {
        self.db = store
        self.calendar = calendar
        super.init()
        locationManager.delegate = self
    }

    // MARK: - Permissions

    public enum Availability { case granted, denied, notDetermined }

    public var calendarAvailability: Availability {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:                  return .granted
        case .notDetermined:               return .notDetermined
        default:                           return .denied
        }
    }

    public var locationAvailability: Availability {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .notDetermined:                          return .notDetermined
        default:                                      return .denied
        }
    }

    /// No explicit request API: `queryActivityStarting` triggers the system prompt itself on
    /// first use. `isActivityAvailable()` is false on devices with no motion coprocessor —
    /// treated the same as denied, since the feature is equally absent either way.
    public var motionAvailability: Availability {
        guard CMMotionActivityManager.isActivityAvailable() else { return .denied }
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized:    return .granted
        case .notDetermined: return .notDetermined
        default:             return .denied
        }
    }

    public func requestCalendarAccess() async -> Bool {
        (try? await eventStore.requestFullAccessToEvents()) ?? false
    }

    /// Significant-change monitoring only. Never `startUpdatingLocation` — continuous GPS is
    /// a battery and privacy cost with no analytic payoff at daily resolution.
    public func startLocationMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        locationManager.requestAlwaysAuthorization()
        locationManager.startMonitoringSignificantLocationChanges()
    }

    // MARK: - EventKit features

    public func calendarFeatures(from: Date, to: Date, boundary: DayBoundary) -> [ContextFeature] {
        guard calendarAvailability == .granted else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = eventStore.events(matching: predicate)

        var byDay: [Day: [EKEvent]] = [:]
        for event in events {
            guard let start = event.startDate else { continue }
            byDay[boundary.day(for: start), default: []].append(event)
        }

        // Every day in range gets rows, including days with no events — that is a measured zero.
        var out: [ContextFeature] = []
        var cursor = Day(from, calendar: calendar)
        let last = Day(to, calendar: calendar)

        while cursor <= last {
            let dayEvents = byDay[cursor] ?? []
            // All-day events are excluded from hour counts: a week-long "Conference" entry is
            // not 168 hours of meeting.
            let timed = dayEvents.filter { !$0.isAllDay && $0.startDate != nil && $0.endDate != nil }

            out.append(ContextFeature(day: cursor, feature: .ctxMeetingHours,
                                      value: ContextService.mergedHours(timed),
                                      isDense: true, source: .eventkit,
                                      deriveVersion: IngestVersion.eventKit))

            if let first = timed.map(\.startDate!).min() {
                out.append(ContextFeature(day: cursor, feature: .ctxFirstEventHour,
                                          value: hourOfDay(first), isDense: true,
                                          source: .eventkit, deriveVersion: IngestVersion.eventKit))
            }
            if let lastEnd = timed.map(\.endDate!).max() {
                out.append(ContextFeature(day: cursor, feature: .ctxLastEventHour,
                                          value: hourOfDay(lastEnd), isDense: true,
                                          source: .eventkit, deriveVersion: IngestVersion.eventKit))
            }

            // Sparse categorical: an all-day entry is an annotation on the timeline, not a
            // variable. Six occurrences a year cannot be tested at any N.
            if dayEvents.contains(where: \.isAllDay) {
                out.append(ContextFeature(day: cursor, feature: .ctxMeetingHours, value: nil,
                                          isDense: false, source: .eventkit,
                                          deriveVersion: IngestVersion.eventKit))
            }

            guard let next = cursor.adding(days: 1, calendar: calendar) else { break }
            cursor = next
        }
        return out
    }

    /// Overlapping meetings are one block of occupied time, not two. Double-counting makes a
    /// heavily-double-booked day look like a 14-hour day.
    static func mergedHours(_ events: [EKEvent]) -> Double {
        let intervals = events.compactMap { e -> (Date, Date)? in
            guard let s = e.startDate, let t = e.endDate, t > s else { return nil }
            return (s, t)
        }.sorted { $0.0 < $1.0 }

        guard !intervals.isEmpty else { return 0 }

        var total: TimeInterval = 0
        var currentStart = intervals[0].0
        var currentEnd = intervals[0].1

        for (start, end) in intervals.dropFirst() {
            if start <= currentEnd {
                currentEnd = max(currentEnd, end)
            } else {
                total += currentEnd.timeIntervalSince(currentStart)
                currentStart = start; currentEnd = end
            }
        }
        total += currentEnd.timeIntervalSince(currentStart)
        return total / 3600
    }

    private func hourOfDay(_ d: Date) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Location features

    /// Home is inferred, never asked for and never stored as an address — only as the centre
    /// of the densest overnight cluster of coarse fixes.
    public func locationFeatures(visits: [CLVisit], boundary: DayBoundary) -> [ContextFeature] {
        guard locationAvailability == .granted, !visits.isEmpty else { return [] }
        guard let home = ContextService.inferHome(from: visits, calendar: calendar) else { return [] }

        var minutesAway: [Day: Double] = [:]
        var timezones: [Day: Int] = [:]

        for visit in visits {
            guard visit.departureDate != Date.distantFuture else { continue }
            let day = boundary.day(for: visit.arrivalDate)
            let location = CLLocation(latitude: visit.coordinate.latitude,
                                      longitude: visit.coordinate.longitude)
            if location.distance(from: home) > 150 {
                let minutes = visit.departureDate.timeIntervalSince(visit.arrivalDate) / 60
                minutesAway[day, default: 0] += max(0, minutes)
            }
            timezones[day] = TimeZone.current.secondsFromGMT(for: visit.arrivalDate)
        }

        var out: [ContextFeature] = []
        let homeOffset = TimeZone.current.secondsFromGMT()
        for (day, minutes) in minutesAway.sorted(by: { $0.key < $1.key }) {
            out.append(ContextFeature(day: day, feature: .ctxMinutesOutsideHome, value: minutes,
                                      isDense: true, source: .location,
                                      deriveVersion: IngestVersion.location))
            if let offset = timezones[day] {
                let shiftHours = Double(offset - homeOffset) / 3600
                // A timezone shift happens a handful of times a year. Annotation, not variable.
                out.append(ContextFeature(day: day, feature: .ctxTimezoneShift, value: shiftHours,
                                          isDense: false, source: .location,
                                          deriveVersion: IngestVersion.location))
            }
        }
        return out
    }

    /// The modal overnight location across the history. Coarse on purpose.
    static func inferHome(from visits: [CLVisit], calendar: Calendar) -> CLLocation? {
        let overnight = visits.filter {
            let hour = calendar.component(.hour, from: $0.arrivalDate)
            return hour >= 22 || hour <= 5
        }
        guard !overnight.isEmpty else { return nil }

        // Grid-snap to ~100 m and take the densest cell, then average within it.
        func key(_ v: CLVisit) -> String {
            String(format: "%.3f,%.3f", v.coordinate.latitude, v.coordinate.longitude)
        }
        let clusters = Dictionary(grouping: overnight, by: key)
        guard let densest = clusters.max(by: { $0.value.count < $1.value.count })?.value else { return nil }

        let lat = densest.map(\.coordinate.latitude).reduce(0, +) / Double(densest.count)
        let lon = densest.map(\.coordinate.longitude).reduce(0, +) / Double(densest.count)
        return CLLocation(latitude: lat, longitude: lon)
    }

    // MARK: - Motion features

    /// This app's own vocabulary for a `CMMotionActivity` — `CMMotionActivity` itself has no
    /// public initialiser, so anything downstream that touches it can't be unit tested. Mapping
    /// to this immediately after the query keeps `deriveMotionFeatures` pure and testable,
    /// mirroring `HeartRateSample`/`SleepSession` for HealthKit.
    public struct MotionSample: Sendable {
        public let start: Date
        public let stationary: Bool
        public let automotive: Bool
        public let walking: Bool
        public let running: Bool
        public let cycling: Bool

        public init(start: Date, stationary: Bool, automotive: Bool, walking: Bool,
                   running: Bool, cycling: Bool) {
            self.start = start; self.stationary = stationary; self.automotive = automotive
            self.walking = walking; self.running = running; self.cycling = cycling
        }
    }

    /// `CMMotionActivityManager` keeps at most 7 days of history — a hard platform limit, not
    /// a choice. This always asks for the trailing 7 days regardless of when it was last called;
    /// a gap wider than that between calls (the app not opened in over a week) is permanently
    /// unrecoverable, and those days are simply never covered — not backfilled, not
    /// interpolated. `db.replace(features:)` upserts by (day, feature, derive_version), so
    /// calling this repeatedly with overlapping windows is idempotent, which is what makes
    /// "query on launch and on background refresh" a correct self-healing strategy rather than
    /// something that needs its own anchor bookkeeping.
    public func motionContextFeatures(boundary: DayBoundary) async -> [ContextFeature] {
        guard motionAvailability != .denied else { return [] }
        let to = Date()
        guard let from = calendar.date(byAdding: .day, value: -7, to: to) else { return [] }

        let samples: [MotionSample] = await withCheckedContinuation { continuation in
            motionActivityManager.queryActivityStarting(from: from, to: to, to: .main) { activities, _ in
                let mapped = (activities ?? []).map {
                    MotionSample(start: $0.startDate, stationary: $0.stationary,
                                automotive: $0.automotive, walking: $0.walking,
                                running: $0.running, cycling: $0.cycling)
                }
                continuation.resume(returning: mapped)
            }
        }
        guard !samples.isEmpty else { return [] }
        return ContextService.deriveMotionFeatures(samples: samples, upTo: to,
                                                    boundary: boundary, calendar: calendar)
    }

    /// Pure. A `CMMotionActivity` marks the *start* of a state; it persists until the next
    /// sample (or `upTo`, for the last one). Each segment is attributed to the day it starts
    /// in — the same simplification `calendarFeatures` makes for events that could technically
    /// straddle midnight, rather than splitting a segment across two days for a marginal gain
    /// in precision.
    static func deriveMotionFeatures(samples: [MotionSample], upTo: Date,
                                     boundary: DayBoundary, calendar: Calendar) -> [ContextFeature] {
        let sorted = samples.sorted { $0.start < $1.start }

        struct Segment { let day: Day; let minutes: Double; let stationary: Bool; let automotive: Bool
                         let signature: String }

        var raw: [Segment] = []
        for (index, sample) in sorted.enumerated() {
            let end = index + 1 < sorted.count ? sorted[index + 1].start : upTo
            guard end > sample.start else { continue }
            let minutes = end.timeIntervalSince(sample.start) / 60
            let signature = "\(sample.stationary)-\(sample.walking)-\(sample.running)"
                          + "-\(sample.automotive)-\(sample.cycling)"
            raw.append(Segment(day: boundary.day(for: sample.start), minutes: minutes,
                               stationary: sample.stationary, automotive: sample.automotive,
                               signature: signature))
        }
        guard !raw.isEmpty else { return [] }

        // CoreMotion re-emits an entry when only *confidence* changes, even if the state
        // itself didn't — two "stationary" entries in a row are one continuous block, not two.
        // Merge adjacent same-state, same-day entries before computing anything downstream, so
        // "longest continuous segment" means what it says rather than "longest raw log entry."
        var segments: [Segment] = []
        for r in raw {
            if let last = segments.last, last.day == r.day, last.signature == r.signature {
                segments[segments.count - 1] = Segment(day: last.day, minutes: last.minutes + r.minutes,
                                                        stationary: last.stationary,
                                                        automotive: last.automotive,
                                                        signature: last.signature)
            } else {
                segments.append(r)
            }
        }

        var sedentaryMaxByDay: [Day: Double] = [:]
        var automotiveByDay: [Day: Double] = [:]
        var transitionsByDay: [Day: Int] = [:]
        var previousSignature: String?

        for segment in segments {
            if segment.stationary {
                sedentaryMaxByDay[segment.day] = max(sedentaryMaxByDay[segment.day] ?? 0, segment.minutes)
            }
            if segment.automotive {
                automotiveByDay[segment.day, default: 0] += segment.minutes
            }
            // A confidence-only re-emission of the same state is not a transition — only count
            // when the state itself changed.
            if let previousSignature, previousSignature != segment.signature {
                transitionsByDay[segment.day, default: 0] += 1
            }
            previousSignature = segment.signature
        }

        // Every day that had any coverage gets a row for all three features, including zero —
        // a day with zero automotive minutes is a measured zero, not a missing observation,
        // since the day was actually covered. Only days with no coverage at all get no row.
        let coveredDays = Set(segments.map(\.day))
        var out: [ContextFeature] = []
        for day in coveredDays {
            out.append(ContextFeature(day: day, feature: .ctxSedentaryMaxBlock,
                                      value: sedentaryMaxByDay[day] ?? 0, isDense: true,
                                      source: .motion, deriveVersion: IngestVersion.motion))
            out.append(ContextFeature(day: day, feature: .ctxActivityTransitions,
                                      value: Double(transitionsByDay[day] ?? 0), isDense: true,
                                      source: .motion, deriveVersion: IngestVersion.motion))
            out.append(ContextFeature(day: day, feature: .ctxAutomotiveMinutes,
                                      value: automotiveByDay[day] ?? 0, isDense: true,
                                      source: .motion, deriveVersion: IngestVersion.motion))
        }
        return out
    }

    // MARK: - Persistence

    public func persist(_ features: [ContextFeature]) throws {
        try db.replace(features: features)
    }
}

extension ContextService: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // Visits are held in memory by the caller and folded in at recompute time. Nothing
        // location-shaped is written to the observation log — only derived daily minutes.
        NotificationCenter.default.post(name: .contextVisitRecorded, object: visit)
    }
}

public extension Notification.Name {
    static let contextVisitRecorded = Notification.Name("ContextService.visitRecorded")
}
