// ContextService.swift
// Epistemic role: boundary. Turns calendars, coarse location, motion, and step shape into
// context features. A denied permission produces *no rows*, never zero-valued rows. Zero means
// "no meetings"; absent means "we don't know". Confusing the two poisons every association
// downstream.

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

    /// Visit monitoring, not continuous updates — `CLVisit` arrival/departure events only,
    /// low power. Significant-change monitoring stays alongside it purely as a background-wake
    /// mechanism; neither of these is `startUpdatingLocation`, which this app never calls.
    public func startLocationMonitoring() {
        locationManager.requestAlwaysAuthorization()
        locationManager.startMonitoringVisits()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
    }

    // MARK: - EventKit features

    public func calendarFeatures(from: Date, to: Date, boundary: DayBoundary) -> [ContextFeature] {
        guard calendarAvailability == .granted else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = eventStore.events(matching: predicate)
        return ContextService.deriveCalendarFeatures(events: events, from: from, to: to,
                                                      boundary: boundary, calendar: calendar)
    }

    /// Pure — separated from `calendarFeatures` purely so it's testable without a live,
    /// permission-gated `EKEventStore` query, the same fetch/derive split every other source
    /// in this file already follows.
    static func deriveCalendarFeatures(events: [EKEvent], from: Date, to: Date,
                                       boundary: DayBoundary, calendar: Calendar) -> [ContextFeature] {
        var byDay: [Day: [EKEvent]] = [:]
        for event in events {
            guard let start = event.startDate else { continue }
            byDay[boundary.day(for: start), default: []].append(event)
        }

        // Every day in range gets rows, including days with no events — that is a measured zero.
        // The walk has to use the same `boundary.day(for:)` assignment `byDay` was built with —
        // a literal calendar-day walk would silently miss anything bucketed by the fallback
        // rule, which is *every* all-day event, since those always start exactly at midnight.
        var out: [ContextFeature] = []
        var cursor = boundary.day(for: from)
        let last = boundary.day(for: to)

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
                                          value: ContextService.hourOfDay(first, calendar: calendar),
                                          isDense: true, source: .eventkit,
                                          deriveVersion: IngestVersion.eventKit))
            }
            if let lastEnd = timed.map(\.endDate!).max() {
                out.append(ContextFeature(day: cursor, feature: .ctxLastEventHour,
                                          value: ContextService.hourOfDay(lastEnd, calendar: calendar),
                                          isDense: true, source: .eventkit,
                                          deriveVersion: IngestVersion.eventKit))
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

    /// Fractional hour of day (7:30am -> 7.5), in the given calendar's time zone — shared by
    /// calendar events and the step-derived day-shape features so "hour" means the same thing
    /// everywhere in this file.
    static func hourOfDay(_ d: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Places (CoreLocation visits)

    /// The one place a `CLVisit` becomes durable. `CLVisit` itself only exists for the lifetime
    /// of this callback; `location_visit` is what survives to the next scan. Coordinates only —
    /// never a place name or category, never geocoded.
    public func persistVisit(_ visit: CLVisit) {
        let record = LocationVisit(arrival: visit.arrivalDate,
                                   departure: visit.departureDate == Date.distantFuture ? nil : visit.departureDate,
                                   latitude: visit.coordinate.latitude,
                                   longitude: visit.coordinate.longitude)
        try? db.insert(visit: record)
    }

    /// Reads every visit ever recorded — unlike CoreMotion, there's no platform history limit
    /// here, since these are our own durably-stored rows, not a live re-query of a system log.
    public func placesFeatures(boundary: DayBoundary) -> [ContextFeature] {
        guard locationAvailability == .granted, let visits = try? db.visits(), !visits.isEmpty
        else { return [] }
        guard let home = cachedOrRecomputedHome(visits: visits) else { return [] }
        return ContextService.derivePlacesFeatures(visits: visits, home: home, boundary: boundary)
    }

    private struct CachedHome: Codable {
        let latitude: Double
        let longitude: Double
        let computedAt: Date
    }

    /// "Recompute weekly" — home doesn't move often, and re-clustering every visit on every
    /// scan is wasted work. `sync_anchor` already exists for exactly this kind of small cached
    /// value; no new table needed.
    private func cachedOrRecomputedHome(visits: [LocationVisit]) -> CLLocation? {
        let key = "context.home_coordinate.v1"
        if let data = try? db.anchor(key: key),
           let cached = try? JSONDecoder().decode(CachedHome.self, from: data),
           Date().timeIntervalSince(cached.computedAt) < 7 * 24 * 3600 {
            return CLLocation(latitude: cached.latitude, longitude: cached.longitude)
        }
        guard let home = ContextService.inferHome(from: visits, calendar: calendar) else { return nil }
        let fresh = CachedHome(latitude: home.coordinate.latitude,
                               longitude: home.coordinate.longitude, computedAt: Date())
        if let data = try? JSONEncoder().encode(fresh) { try? db.saveAnchor(key: key, payload: data) }
        return home
    }

    /// The modal overnight location across the history. Coarse on purpose.
    static func inferHome(from visits: [LocationVisit], calendar: Calendar) -> CLLocation? {
        let overnight = visits.filter {
            let hour = calendar.component(.hour, from: $0.arrival)
            return hour >= 22 || hour <= 5
        }
        guard !overnight.isEmpty else { return nil }

        // Grid-snap to ~100 m and take the densest cell, then average within it.
        func key(_ v: LocationVisit) -> String { String(format: "%.3f,%.3f", v.latitude, v.longitude) }
        let clusters = Dictionary(grouping: overnight, by: key)
        guard let densest = clusters.max(by: { $0.value.count < $1.value.count })?.value else { return nil }

        let lat = densest.map(\.latitude).reduce(0, +) / Double(densest.count)
        let lon = densest.map(\.longitude).reduce(0, +) / Double(densest.count)
        return CLLocation(latitude: lat, longitude: lon)
    }

    /// Pure. `places_visited` counts every visit that arrived that day, departed or not —
    /// `minutes_outside_home` only counts visits that have actually departed, since duration is
    /// unknowable before then. A day with visits but no completed departures still gets a
    /// `places_visited` row and a `minutes_outside_home` row of 0 (a real measured zero: every
    /// visit that day happened to be at home, or hasn't ended yet), not an absent row.
    ///
    /// `timezone_shift` is day-over-day, not relative to home — most days it's genuinely 0,
    /// which is what makes it a dense daily variable rather than a rare travel annotation.
    static func derivePlacesFeatures(visits: [LocationVisit], home: CLLocation,
                                     boundary: DayBoundary) -> [ContextFeature] {
        var visitsByDay: [Day: Int] = [:]
        var minutesAwayByDay: [Day: Double] = [:]
        var timezoneByDay: [Day: Int] = [:]

        for visit in visits {
            let day = boundary.day(for: visit.arrival)
            visitsByDay[day, default: 0] += 1
            timezoneByDay[day] = TimeZone.current.secondsFromGMT(for: visit.arrival)

            guard let departure = visit.departure else { continue }
            let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            if location.distance(from: home) > 150 {
                let minutes = departure.timeIntervalSince(visit.arrival) / 60
                minutesAwayByDay[day, default: 0] += max(0, minutes)
            }
        }

        var out: [ContextFeature] = []
        for (day, count) in visitsByDay {
            out.append(ContextFeature(day: day, feature: .ctxPlacesVisited, value: Double(count),
                                      isDense: true, source: .location,
                                      deriveVersion: IngestVersion.location))
            out.append(ContextFeature(day: day, feature: .ctxMinutesOutsideHome,
                                      value: minutesAwayByDay[day] ?? 0, isDense: true,
                                      source: .location, deriveVersion: IngestVersion.location))
        }

        // Chained against the previous day *with a recorded offset*, not the previous calendar
        // day — a gap in visit coverage shouldn't manufacture a shift out of stale data.
        var previousOffset: Int?
        for day in timezoneByDay.keys.sorted() {
            let offset = timezoneByDay[day]!
            if let previousOffset {
                let shiftHours = Double(offset - previousOffset) / 3600
                out.append(ContextFeature(day: day, feature: .ctxTimezoneShift, value: shiftHours,
                                          isDense: true, source: .location,
                                          deriveVersion: IngestVersion.location))
            }
            previousOffset = offset
        }
        return out
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

        for segment in segments {
            if segment.stationary {
                sedentaryMaxByDay[segment.day] = max(sedentaryMaxByDay[segment.day] ?? 0, segment.minutes)
            }
            if segment.automotive {
                automotiveByDay[segment.day, default: 0] += segment.minutes
            }
        }

        // Every day that had any coverage gets a row for both features, including zero — a day
        // with zero automotive minutes is a measured zero, not a missing observation, since the
        // day was actually covered. Only days with no coverage at all get no row.
        let coveredDays = Set(segments.map(\.day))
        var out: [ContextFeature] = []
        for day in coveredDays {
            out.append(ContextFeature(day: day, feature: .ctxSedentaryMaxBlock,
                                      value: sedentaryMaxByDay[day] ?? 0, isDense: true,
                                      source: .motion, deriveVersion: IngestVersion.motion))
            out.append(ContextFeature(day: day, feature: .ctxAutomotiveMinutes,
                                      value: automotiveByDay[day] ?? 0, isDense: true,
                                      source: .motion, deriveVersion: IngestVersion.motion))
        }
        return out
    }

    // MARK: - Day shape (hourly step buckets)

    /// Named per spec — the line between "active" and "inactive" hour.
    public static let activeStepThreshold: Double = 250

    /// Pure. Each `StepHourBucket` already represents one full clock hour, gap-free across the
    /// query range (`HKStatisticsCollectionQuery` returns a zero-sum bucket for a silent hour,
    /// not a missing one) — which is what makes `activity_fragmentation` a real transition count
    /// rather than an artifact of missing hours.
    static func deriveDayShapeFeatures(buckets: [StepHourBucket], boundary: DayBoundary,
                                       calendar: Calendar) -> [ContextFeature] {
        guard !buckets.isEmpty else { return [] }
        var byDay: [Day: [StepHourBucket]] = [:]
        for b in buckets { byDay[boundary.day(for: b.hourStart), default: []].append(b) }

        var out: [ContextFeature] = []
        for (day, dayBuckets) in byDay {
            let sorted = dayBuckets.sorted { $0.hourStart < $1.hourStart }
            // A day with genuinely no steps at all — phone not carried, or no data yet — is not
            // observed, not a quiet day. No row for any of the four features.
            guard sorted.reduce(0, { $0 + $1.steps }) > 0 else { continue }

            let activeFlags = sorted.map { $0.steps > ContextService.activeStepThreshold }
            var transitions = 0
            for i in 1..<activeFlags.count where activeFlags[i] != activeFlags[i - 1] { transitions += 1 }
            out.append(ContextFeature(day: day, feature: .ctxActivityFragmentation,
                                      value: Double(transitions), isDense: true,
                                      source: .healthkit, deriveVersion: IngestVersion.dayShape))

            // Onset/offset/span need at least one hour to actually cross the threshold — a
            // fully-covered but entirely sedentary day gets a fragmentation row (0) and stops
            // there; there is no "first active hour" to report.
            let active = sorted.filter { $0.steps > ContextService.activeStepThreshold }
            guard let first = active.first, let last = active.last else { continue }
            let onset = ContextService.hourOfDay(first.hourStart, calendar: calendar)
            let offset = ContextService.hourOfDay(last.hourStart, calendar: calendar)
            out.append(ContextFeature(day: day, feature: .ctxActivityOnsetHour, value: onset,
                                      isDense: true, source: .healthkit,
                                      deriveVersion: IngestVersion.dayShape))
            out.append(ContextFeature(day: day, feature: .ctxActivityOffsetHour, value: offset,
                                      isDense: true, source: .healthkit,
                                      deriveVersion: IngestVersion.dayShape))
            out.append(ContextFeature(day: day, feature: .ctxActiveSpanHours, value: offset - onset,
                                      isDense: true, source: .healthkit,
                                      deriveVersion: IngestVersion.dayShape))
        }
        return out
    }

    // MARK: - Additional HealthKit context signals

    /// Pure. Each sample's own interval is the listening-session duration; days with no
    /// sessions logged simply have no entries in `samples`, so they never appear in the output —
    /// no row, not zero.
    static func deriveHeadphoneFeatures(samples: [QuantitySample],
                                        boundary: DayBoundary) -> [ContextFeature] {
        guard !samples.isEmpty else { return [] }
        var minutesByDay: [Day: Double] = [:]
        for s in samples {
            minutesByDay[boundary.day(for: s.start), default: 0] += max(0, s.end.timeIntervalSince(s.start) / 60)
        }
        return minutesByDay.map { day, minutes in
            ContextFeature(day: day, feature: .ctxHeadphoneAudioMinutes, value: minutes,
                          isDense: true, source: .healthkit, deriveVersion: IngestVersion.hkContext)
        }
    }

    static func deriveFlightsFeatures(samples: [QuantitySample],
                                      boundary: DayBoundary) -> [ContextFeature] {
        guard !samples.isEmpty else { return [] }
        var countByDay: [Day: Double] = [:]
        for s in samples { countByDay[boundary.day(for: s.start), default: 0] += s.value }
        return countByDay.map { day, count in
            ContextFeature(day: day, feature: .ctxFlightsClimbed, value: count,
                          isDense: true, source: .healthkit, deriveVersion: IngestVersion.hkContext)
        }
    }

    // MARK: - Persistence

    public func persist(_ features: [ContextFeature]) throws {
        try db.replace(features: features)
    }
}

extension ContextService: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        persistVisit(visit)
    }
}
