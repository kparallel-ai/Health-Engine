// Store.swift
// Epistemic role: the append-only record of what was observed. It never revises history.

import Foundation
import GRDB

public final class Store {
    private let dbQueue: DatabaseQueue
    private let calendar: Calendar

    public init(path: String, calendar: Calendar = .autoupdatingCurrent) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        self.calendar = calendar
        try Store.migrator.migrate(dbQueue)
    }

    public static func inMemory(calendar: Calendar = .autoupdatingCurrent) throws -> Store {
        try Store(path: ":memory:", calendar: calendar)
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE observation (
                    id              INTEGER PRIMARY KEY,
                    metric          TEXT    NOT NULL,
                    value           REAL,
                    unit            TEXT    NOT NULL,
                    effective_start TEXT    NOT NULL,
                    effective_end   TEXT,
                    recorded_at     TEXT    NOT NULL,
                    source          TEXT    NOT NULL,
                    source_id       TEXT,
                    quality         REAL    NOT NULL DEFAULT 1.0,
                    flags           TEXT    NOT NULL DEFAULT '[]',
                    ingest_version  TEXT    NOT NULL
                );
                CREATE INDEX ix_obs_metric_time ON observation(metric, effective_start);
                CREATE UNIQUE INDEX ux_obs_dedup ON observation(source, source_id, metric)
                    WHERE source_id IS NOT NULL;

                CREATE TABLE daily_construct (
                    day             TEXT NOT NULL,
                    construct       TEXT NOT NULL,
                    value           REAL,
                    baseline        REAL,
                    deviation_z     REAL,
                    n_samples       INTEGER NOT NULL,
                    confidence      REAL NOT NULL,
                    flags           TEXT NOT NULL DEFAULT '[]',
                    derive_version  TEXT NOT NULL,
                    PRIMARY KEY (day, construct, derive_version)
                );

                CREATE TABLE context_feature (
                    day             TEXT NOT NULL,
                    feature         TEXT NOT NULL,
                    value           REAL,
                    is_dense        INTEGER NOT NULL,
                    source          TEXT NOT NULL,
                    derive_version  TEXT NOT NULL,
                    PRIMARY KEY (day, feature, derive_version)
                );

                CREATE TABLE finding (
                    id              TEXT PRIMARY KEY,
                    kind            TEXT NOT NULL,
                    tier            TEXT NOT NULL,
                    subject         TEXT NOT NULL,
                    object          TEXT,
                    lag_days        INTEGER,
                    effect_size     REAL,
                    effect_ci_low   REAL,
                    effect_ci_high  REAL,
                    p_raw           REAL,
                    q_value         REAL,
                    n_observations  INTEGER NOT NULL,
                    family_id       TEXT NOT NULL,
                    family_size     INTEGER NOT NULL,
                    method          TEXT NOT NULL,
                    windows_stable  INTEGER NOT NULL DEFAULT 0,
                    computed_at     TEXT NOT NULL,
                    infer_version   TEXT NOT NULL
                );
                CREATE INDEX ix_finding_tier ON finding(tier, q_value);

                CREATE TABLE sync_anchor (
                    key         TEXT PRIMARY KEY,
                    payload     BLOB NOT NULL,
                    updated_at  TEXT NOT NULL
                );

                CREATE TABLE user_verdict (
                    finding_id  TEXT PRIMARY KEY,
                    verdict     TEXT NOT NULL,
                    noted_at    TEXT NOT NULL
                );
            """)
        }

        // Durable `CLVisit` storage. Without this, visits only ever existed in memory for the
        // lifetime of one delegate callback — "places" context was unbuildable at all, since a
        // day's visits from a week ago are long gone by the time a scan runs.
        m.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE location_visit (
                    id              INTEGER PRIMARY KEY,
                    arrival         TEXT NOT NULL,
                    departure       TEXT,
                    latitude        REAL NOT NULL,
                    longitude       REAL NOT NULL,
                    recorded_at     TEXT NOT NULL
                );
                CREATE INDEX ix_visit_arrival ON location_visit(arrival);
            """)
        }
        return m
    }

    // MARK: - Observations (append-only; never UPDATE, never DELETE)

    /// Returns rows actually inserted. Re-importing identical data returns 0.
    @discardableResult
    public func insert(observations: [Observation]) throws -> Int {
        guard !observations.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var inserted = 0
            for o in observations {
                let sql = """
                    INSERT OR IGNORE INTO observation
                    (metric, value, unit, effective_start, effective_end, recorded_at,
                     source, source_id, quality, flags, ingest_version)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """
                try db.execute(sql: sql, arguments: [
                    o.metric.rawValue, o.value, o.unit,
                    Self.iso(o.effectiveStart), o.effectiveEnd.map(Self.iso),
                    Self.iso(o.recordedAt), o.source.rawValue, o.sourceID,
                    o.quality, Self.encodeFlags(o.flags), o.ingestVersion
                ])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    public func observations(metric: Metric, from: Date? = nil, to: Date? = nil) throws -> [Observation] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM observation WHERE metric = ?"
            var args: [DatabaseValueConvertible?] = [metric.rawValue]
            if let from { sql += " AND effective_start >= ?"; args.append(Self.iso(from)) }
            if let to   { sql += " AND effective_start <  ?"; args.append(Self.iso(to)) }
            sql += " ORDER BY effective_start ASC"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .compactMap(Self.decodeObservation)
        }
    }

    public func observationDateRange() throws -> (first: Date, last: Date)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT MIN(effective_start) AS a, MAX(effective_start) AS b FROM observation"),
                let a: String = row["a"], let b: String = row["b"],
                let first = Self.parse(a), let last = Self.parse(b) else { return nil }
            return (first, last)
        }
    }

    public func availableMetrics() throws -> Set<Metric> {
        try dbQueue.read { db in
            let raws = try String.fetchAll(db, sql: "SELECT DISTINCT metric FROM observation")
            return Set(raws.compactMap(Metric.init(rawValue:)))
        }
    }

    // MARK: - Derived tables (idempotent upsert; keyed by derive_version)

    public func replace(constructs: [DailyConstruct]) throws {
        try dbQueue.write { db in
            for c in constructs {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO daily_construct
                    (day, construct, value, baseline, deviation_z, n_samples,
                     confidence, flags, derive_version)
                    VALUES (?,?,?,?,?,?,?,?,?)
                """, arguments: [c.day.raw, c.construct.rawValue, c.value, c.baseline,
                                 c.deviationZ, c.nSamples, c.confidence,
                                 Self.encodeFlags(c.flags), c.deriveVersion])
            }
        }
    }

    public func replace(features: [ContextFeature]) throws {
        try dbQueue.write { db in
            for f in features {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO context_feature
                    (day, feature, value, is_dense, source, derive_version)
                    VALUES (?,?,?,?,?,?)
                """, arguments: [f.day.raw, f.feature.rawValue, f.value,
                                 f.isDense ? 1 : 0, f.source.rawValue, f.deriveVersion])
            }
        }
    }

    public func constructs(version: String, construct: Metric? = nil) throws -> [DailyConstruct] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM daily_construct WHERE derive_version = ?"
            var args: [DatabaseValueConvertible?] = [version]
            if let construct { sql += " AND construct = ?"; args.append(construct.rawValue) }
            sql += " ORDER BY day ASC"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .compactMap(Self.decodeConstruct)
        }
    }

    public func features(version: String, denseOnly: Bool = false) throws -> [ContextFeature] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM context_feature WHERE derive_version = ?"
            if denseOnly { sql += " AND is_dense = 1" }
            sql += " ORDER BY day ASC"
            return try Row.fetchAll(db, sql: sql, arguments: [version])
                .compactMap(Self.decodeFeature)
        }
    }

    // MARK: - Location visits (append-only)

    /// A `CLVisit` arrives once, at the moment it happens — there is no re-querying it later
    /// the way HealthKit or EventKit can be re-queried. If this isn't written down immediately,
    /// it's gone.
    public func insert(visit: LocationVisit) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO location_visit (arrival, departure, latitude, longitude, recorded_at)
                VALUES (?,?,?,?,?)
            """, arguments: [Self.iso(visit.arrival), visit.departure.map(Self.iso),
                             visit.latitude, visit.longitude, Self.iso(visit.recordedAt)])
        }
    }

    public func visits(from: Date? = nil, to: Date? = nil) throws -> [LocationVisit] {
        try dbQueue.read { db in
            var sql = "SELECT * FROM location_visit"
            var conditions: [String] = []
            var args: [DatabaseValueConvertible?] = []
            if let from { conditions.append("arrival >= ?"); args.append(Self.iso(from)) }
            if let to   { conditions.append("arrival <  ?"); args.append(Self.iso(to)) }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY arrival ASC"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .compactMap(Self.decodeVisit)
        }
    }

    // MARK: - Findings

    public func replace(findings: [Finding], familyID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM finding WHERE family_id = ?", arguments: [familyID])
            for f in findings {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO finding
                    (id, kind, tier, subject, object, lag_days, effect_size, effect_ci_low,
                     effect_ci_high, p_raw, q_value, n_observations, family_id, family_size,
                     method, windows_stable, computed_at, infer_version)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [f.id, f.kind.rawValue, f.tier.rawValue, f.subject, f.object,
                                 f.lagDays, f.effectSize, f.effectCILow, f.effectCIHigh,
                                 f.pRaw, f.qValue, f.nObservations, f.familyID, f.familySize,
                                 f.method, f.windowsStable ? 1 : 0,
                                 Self.iso(f.computedAt), f.inferVersion])
            }
        }
    }

    /// Surfaced findings only. Failed tests stay in the table for audit but never reach a screen.
    public func surfacedFindings() throws -> [Finding] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM finding WHERE tier IN ('T1','T2','T3','T4')
                ORDER BY tier DESC, ABS(effect_size) DESC
            """).compactMap(Self.decodeFinding)
        }
    }

    public func familySize(_ familyID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM finding WHERE family_id = ?",
                             arguments: [familyID]) ?? 0
        }
    }

    public func setVerdict(findingID: String, verdict: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO user_verdict (finding_id, verdict, noted_at) VALUES (?,?,?)
            """, arguments: [findingID, verdict, Self.iso(Date())])
        }
    }

    public func verdicts() throws -> [String: String] {
        try dbQueue.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT finding_id, verdict FROM user_verdict") {
                if let k: String = row["finding_id"], let v: String = row["verdict"] { out[k] = v }
            }
            return out
        }
    }

    // MARK: - Sync anchors (opaque HKQueryAnchor blobs; the store does not interpret them)

    public func saveAnchor(key: String, payload: Data) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO sync_anchor (key, payload, updated_at) VALUES (?,?,?)
            """, arguments: [key, payload, Self.iso(Date())])
        }
    }

    public func anchor(key: String) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM sync_anchor WHERE key = ?", arguments: [key])
        }
    }

    /// A single transaction spanning many writes — used by GarminImport so a failed import adds nothing.
    public func writeTransaction<T>(_ body: (Database) throws -> T) throws -> T {
        try dbQueue.write(body)
    }

    // MARK: - Coding helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    static func parse(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: s)
    }

    static func encodeFlags(_ f: [String]) -> String {
        (try? String(data: JSONEncoder().encode(f), encoding: .utf8)) as? String ?? "[]"
    }

    static func decodeFlags(_ s: String?) -> [String] {
        guard let s, let d = s.data(using: .utf8),
              let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return a
    }

    static func decodeObservation(_ row: Row) -> Observation? {
        guard let raw: String = row["metric"], let metric = Metric(rawValue: raw),
              let startS: String = row["effective_start"], let start = parse(startS),
              let recS: String = row["recorded_at"], let rec = parse(recS),
              let srcS: String = row["source"], let src = Source(rawValue: srcS) else { return nil }
        var o = Observation(metric: metric, value: row["value"], effectiveStart: start,
                            effectiveEnd: (row["effective_end"] as String?).flatMap(parse),
                            recordedAt: rec, source: src, sourceID: row["source_id"],
                            quality: row["quality"] ?? 1.0,
                            flags: decodeFlags(row["flags"]),
                            ingestVersion: row["ingest_version"] ?? "unknown")
        o.id = row["id"]
        return o
    }

    static func decodeConstruct(_ row: Row) -> DailyConstruct? {
        guard let dayS: String = row["day"], let raw: String = row["construct"],
              let m = Metric(rawValue: raw) else { return nil }
        return DailyConstruct(day: Day(raw: dayS), construct: m, value: row["value"],
                              baseline: row["baseline"], deviationZ: row["deviation_z"],
                              nSamples: row["n_samples"] ?? 0, confidence: row["confidence"] ?? 0,
                              flags: decodeFlags(row["flags"]),
                              deriveVersion: row["derive_version"] ?? "unknown")
    }

    static func decodeFeature(_ row: Row) -> ContextFeature? {
        guard let dayS: String = row["day"], let raw: String = row["feature"],
              let m = Metric(rawValue: raw), let srcS: String = row["source"],
              let src = Source(rawValue: srcS) else { return nil }
        return ContextFeature(day: Day(raw: dayS), feature: m, value: row["value"],
                              isDense: (row["is_dense"] as Int? ?? 1) == 1, source: src,
                              deriveVersion: row["derive_version"] ?? "unknown")
    }

    static func decodeVisit(_ row: Row) -> LocationVisit? {
        guard let arrivalS: String = row["arrival"], let arrival = parse(arrivalS),
              let recS: String = row["recorded_at"], let rec = parse(recS),
              let lat: Double = row["latitude"], let lon: Double = row["longitude"] else { return nil }
        return LocationVisit(arrival: arrival, departure: (row["departure"] as String?).flatMap(parse),
                             latitude: lat, longitude: lon, recordedAt: rec)
    }

    static func decodeFinding(_ row: Row) -> Finding? {
        guard let id: String = row["id"], let kindS: String = row["kind"],
              let kind = FindingKind(rawValue: kindS), let tierS: String = row["tier"],
              let tier = EvidenceTier(rawValue: tierS), let subject: String = row["subject"],
              let atS: String = row["computed_at"], let at = parse(atS) else { return nil }
        return Finding(id: id, kind: kind, tier: tier, subject: subject, object: row["object"],
                       lagDays: row["lag_days"], effectSize: row["effect_size"],
                       effectCILow: row["effect_ci_low"], effectCIHigh: row["effect_ci_high"],
                       pRaw: row["p_raw"], qValue: row["q_value"],
                       nObservations: row["n_observations"] ?? 0,
                       familyID: row["family_id"] ?? "", familySize: row["family_size"] ?? 0,
                       method: row["method"] ?? "", windowsStable: (row["windows_stable"] as Int? ?? 0) == 1,
                       computedAt: at, inferVersion: row["infer_version"] ?? "unknown")
    }
}
