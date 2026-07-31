// GarminImportTests.swift
// Fixtures mirror the real shape of Garmin's "Export Your Data" JSON (UDSFile*.json,
// *sleepData.json) — trimmed to the fields the parser reads, values changed from the
// original export this was verified against.

import XCTest
@testable import HealthIntelligence

final class GarminImportTests: XCTestCase {

    func testParsesRealUDSFileShape() {
        let json = """
        [
          {
            "calendarDate": "2026-06-29",
            "restingHeartRate": 63,
            "averageSpo2Value": 93.0,
            "bodyBattery": {
              "calendarDate": "2026-06-29",
              "bodyBatteryStatList": [
                { "bodyBatteryStatType": "HIGHEST", "statsValue": 70 },
                { "bodyBatteryStatType": "LOWEST", "statsValue": 16 },
                { "bodyBatteryStatType": "MOSTRECENT", "statsValue": 27 }
              ]
            },
            "allDayStress": {
              "calendarDate": "2026-06-29",
              "aggregatorList": [
                { "type": "TOTAL", "averageStressLevel": 43 },
                { "type": "AWAKE", "averageStressLevel": 43 },
                { "type": "ASLEEP", "averageStressLevel": -2 }
              ]
            },
            "respiration": {
              "calendarDate": "2026-06-29",
              "avgWakingRespirationValue": 16.0
            },
            "totalSteps": 1707,
            "activeKilocalories": 160.0
          }
        ]
        """.data(using: .utf8)!

        let result = GarminImport.parseUDS(json)
        XCTAssertEqual(result.rowsRead, 1)

        func value(_ metric: Metric) -> Double? {
            result.observations.first { $0.metric == metric }?.value
        }

        XCTAssertEqual(value(.hrResting), 63)
        XCTAssertEqual(value(.spo2AvgOvernight)!, 0.93, accuracy: 1e-9)
        XCTAssertEqual(value(.bodyBatteryMax), 70)
        XCTAssertEqual(value(.bodyBatteryMin), 16)
        XCTAssertEqual(value(.stressAvg), 43)   // TOTAL only, not the -2 ASLEEP reading
        XCTAssertEqual(value(.respirationAvgOvernight), 16.0)

        // totalSteps / activeKilocalories aren't in the ontology — must be logged, not dropped.
        XCTAssertEqual(result.unmapped["totalSteps"], 1)
        XCTAssertEqual(result.unmapped["activeKilocalories"], 1)

        // Deterministic source IDs, so re-importing the same export is a no-op.
        let rhr = result.observations.first { $0.metric == .hrResting }!
        XCTAssertEqual(rhr.sourceID, "uds#2026-06-29#hr.resting")
    }

    func testParsesRealSleepDataShape() {
        let json = """
        [
          {
            "calendarDate": "2026-06-30",
            "sleepStartTimestampGMT": "2026-06-30T02:57:13.0",
            "sleepEndTimestampGMT": "2026-06-30T11:16:13.0",
            "deepSleepSeconds": 7800,
            "remSleepSeconds": 2640,
            "lightSleepSeconds": 15240,
            "awakeSleepSeconds": 4260,
            "averageRespiration": 14.41,
            "restlessMomentCount": 42
          }
        ]
        """.data(using: .utf8)!

        let result = GarminImport.parseSleepExport(json)
        XCTAssertEqual(result.rowsRead, 1)

        func value(_ metric: Metric) -> Double? {
            result.observations.first { $0.metric == metric }?.value
        }

        XCTAssertEqual(value(.sleepDeep)!, 130.0, accuracy: 1e-9)          // 7800s / 60
        XCTAssertEqual(value(.sleepREM)!, 44.0, accuracy: 1e-9)            // 2640s / 60
        let asleepMinutes = (7800.0 + 2640.0 + 15240.0) / 60.0
        XCTAssertEqual(value(.sleepDuration)!, asleepMinutes, accuracy: 1e-9)
        let expectedEfficiency = (7800.0 + 2640.0 + 15240.0) / (7800.0 + 2640.0 + 15240.0 + 4260.0)
        XCTAssertEqual(value(.sleepEfficiency)!, expectedEfficiency, accuracy: 1e-9)
        XCTAssertNotNil(value(.sleepOnset))

        XCTAssertEqual(result.unmapped["restlessMomentCount"], 1)
    }

    func testGarminTimestampParsesSingleDigitFractionalSeconds() {
        // Garmin's GMT timestamps carry one fractional digit; ISO8601DateFormatter rejects this.
        let date = GarminImport.parseGarminTimestamp("2026-06-30T02:57:13.0")
        XCTAssertNotNil(date)
    }

    func testMalformedUDSRecordsAreSkippedNotCrashed() {
        let json = """
        [ { "restingHeartRate": 60 }, { "calendarDate": "not-a-date" } ]
        """.data(using: .utf8)!
        let result = GarminImport.parseUDS(json)
        XCTAssertEqual(result.observations.count, 0)
        XCTAssertEqual(result.rowsRead, 2)
    }
}
