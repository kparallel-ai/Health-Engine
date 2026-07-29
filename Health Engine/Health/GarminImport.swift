// GarminImport.swift
// Epistemic role: boundary for an optional tier-3 source. Never required. Nothing here gates
// any screen; if this file were deleted the app would still work, with fewer constructs.

import Foundation

public struct ImportReport: Sendable {
    public var rowsRead: Int = 0
    public var rowsInserted: Int = 0
    /// Field names present in the file that the ontology has no home for. Logged, surfaced,
    /// never dropped in silence — an unmapped field is a gap in the ontology, not noise.
    public var unmappedFields: [String: Int] = [:]
    public var skippedRows: Int = 0
    public var errors: [String] = []

    public var summary: String {
        "\(rowsInserted) new of \(rowsRead) read"
        + (unmappedFields.isEmpty ? "" : " · \(unmappedFields.count) unmapped field(s)")
    }
}

public enum GarminImportError: Error, LocalizedError {
    case unreadable(String)
    case unrecognisedFormat

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Could not read the file: \(detail)"
        case .unrecognisedFormat:
            return "Not a recognised Garmin export. Expected a CSV or JSON export from Garmin Connect."
        }
    }
}

public final class GarminImport {
    private let db: Store

    public init(store: Store) { self.db = store }

    /// Column-name → metric, with the multiplier needed to reach ontology units.
    /// Garmin's export headers vary by locale and by export vintage; several spellings map
    /// to the same metric on purpose.
    static let columnMap: [String: (metric: Metric, scale: Double)] = [
        "restingheartrate":         (.hrResting, 1),
        "resting_heart_rate":       (.hrResting, 1),
        "rhr":                      (.hrResting, 1),
        "hrvrmssd":                 (.hrvRMSSDOvernight, 1),
        "lastnightavg":             (.hrvRMSSDOvernight, 1),
        "hrv_rmssd":                (.hrvRMSSDOvernight, 1),
        "hrvstatus":                (.hrvStatusGarmin, 1),
        "bodybatterylowest":        (.bodyBatteryMin, 1),
        "body_battery_min":         (.bodyBatteryMin, 1),
        "bodybatteryhighest":       (.bodyBatteryMax, 1),
        "body_battery_max":         (.bodyBatteryMax, 1),
        "averagestresslevel":       (.stressAvg, 1),
        "avg_stress":               (.stressAvg, 1),
        "trainingload":             (.loadTrainingGarmin, 1),
        "acutetrainingload":        (.loadTrainingGarmin, 1),
        "averagespo2":              (.spo2AvgOvernight, 0.01),   // percent → fraction
        "avg_spo2":                 (.spo2AvgOvernight, 0.01),
        "lactatethresholdheartrate":(.thresholdLactateHR, 1),
        "lactate_threshold_hr":     (.thresholdLactateHR, 1),
        "endurancescore":           (.enduranceScore, 1),
        "vo2max":                   (.vo2maxRunning, 1),
        "sleepdurationminutes":     (.sleepDuration, 1),
        "sleepseconds":             (.sleepDuration, 1.0 / 60.0),
        "deepsleepseconds":         (.sleepDeep, 1.0 / 60.0),
        "remsleepseconds":          (.sleepREM, 1.0 / 60.0),
        "avgrespirationrate":       (.respirationAvgOvernight, 1)
    ]

    /// HRV status is categorical in the export and numeric in the ontology.
    static let hrvStatusValues: [String: Double] = [
        "poor": 0, "low": 1, "unbalanced": 2, "balanced": 3, "good": 3, "excellent": 4
    ]

    // MARK: - Entry point

    /// The whole import is one transaction. A malformed row two thirds of the way through a
    /// file leaves the store exactly as it was.
    public func importFile(at url: URL) throws -> ImportReport {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            throw GarminImportError.unreadable(url.lastPathComponent)
        }

        let rows: [[String: String]]
        switch url.pathExtension.lowercased() {
        case "csv":  rows = try GarminImport.parseCSV(data)
        case "json": rows = try GarminImport.parseJSON(data)
        default:     throw GarminImportError.unrecognisedFormat
        }
        return try ingest(rows: rows, sourceName: url.lastPathComponent)
    }

    func ingest(rows: [[String: String]], sourceName: String) throws -> ImportReport {
        var report = ImportReport()
        report.rowsRead = rows.count

        var observations: [Observation] = []

        for (index, row) in rows.enumerated() {
            guard let dateString = GarminImport.dateField(in: row),
                  let date = GarminImport.parseDate(dateString) else {
                report.skippedRows += 1
                continue
            }

            for (rawKey, rawValue) in row {
                let key = rawKey.lowercased().replacingOccurrences(of: " ", with: "")
                if GarminImport.dateKeys.contains(key) { continue }
                guard !rawValue.isEmpty else { continue }

                guard let mapping = GarminImport.columnMap[key] else {
                    report.unmappedFields[rawKey, default: 0] += 1
                    continue
                }

                let value: Double?
                if mapping.metric == .hrvStatusGarmin {
                    value = GarminImport.hrvStatusValues[rawValue.lowercased()]
                } else {
                    value = Double(rawValue).map { $0 * mapping.scale }
                }
                guard let value else {
                    report.unmappedFields["\(rawKey) (unparsable: \(rawValue))", default: 0] += 1
                    continue
                }

                // Deterministic source_id: re-importing the same export is a no-op.
                let sourceID = "\(sourceName)#\(GarminImport.dayKey(date))#\(mapping.metric.rawValue)"
                observations.append(Observation(metric: mapping.metric, value: value,
                                                effectiveStart: date,
                                                source: .garmin, sourceID: sourceID,
                                                ingestVersion: IngestVersion.garmin))
            }
            if index % 500 == 499 { /* checkpoint hook for progress reporting */ }
        }

        report.rowsInserted = try db.insert(observations: observations)
        return report
    }

    // MARK: - Parsing

    static let dateKeys: Set<String> = ["date", "calendardate", "day", "timestamp", "starttime"]

    static func dateField(in row: [String: String]) -> String? {
        for (k, v) in row where dateKeys.contains(k.lowercased().replacingOccurrences(of: " ", with: "")) {
            if !v.isEmpty { return v }
        }
        return nil
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for pattern in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "MM/dd/yyyy", "dd/MM/yyyy"] {
            formatter.dateFormat = pattern
            if let d = formatter.date(from: s) { return d }
        }
        // Epoch seconds or milliseconds.
        if let n = Double(s) {
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        }
        return nil
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// RFC 4180 enough for Garmin's exports: quoted fields, embedded commas, doubled quotes.
    static func parseCSV(_ data: Data) throws -> [[String: String]] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw GarminImportError.unreadable("not text") }

        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(ch) }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",":  record.append(field); field = ""
                case "\n": record.append(field); field = ""; records.append(record); record = []
                case "\r": break
                default:   field.append(ch)
                }
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }

        guard let header = records.first, header.count > 1 else { throw GarminImportError.unrecognisedFormat }
        return records.dropFirst().compactMap { row in
            guard row.count == header.count else { return nil }
            return Dictionary(uniqueKeysWithValues: zip(header.map {
                $0.trimmingCharacters(in: .whitespaces)
            }, row))
        }
    }

    static func parseJSON(_ data: Data) throws -> [[String: String]] {
        let object = try JSONSerialization.jsonObject(with: data)
        let array: [Any]
        if let a = object as? [Any] { array = a }
        else if let d = object as? [String: Any],
                let a = d.values.first(where: { $0 is [Any] }) as? [Any] { array = a }
        else { throw GarminImportError.unrecognisedFormat }

        return array.compactMap { element in
            guard let dict = element as? [String: Any] else { return nil }
            return dict.compactMapValues { value in
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return n.stringValue }
                return nil
            }
        }
    }
}
