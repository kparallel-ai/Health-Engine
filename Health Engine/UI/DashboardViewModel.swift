// DashboardViewModel.swift
// Epistemic role: presentation state. It formats; it does not compute anything statistical.

import Combine
import Foundation
import SwiftUI

@MainActor
public final class DashboardViewModel: ObservableObject {

    @Published public private(set) var today: [DailyConstruct] = []
    @Published public private(set) var findings: [Finding] = []
    @Published public private(set) var dayCount: Int = 0
    @Published public private(set) var summary: String = ""
    @Published public private(set) var summaryIsTemplated = true

    private let store: Store
    private let calendar: Calendar

    public init(store: Store, calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.calendar = calendar
    }

    public func reload() {
        let constructs = (try? store.constructs(version: DeriveVersion.current)) ?? []
        let days = Set(constructs.map(\.day))
        dayCount = days.count

        if let latest = days.max() {
            today = constructs.filter { $0.day == latest }
                .sorted { $0.construct.rawValue < $1.construct.rawValue }
        } else {
            today = []
        }

        findings = (try? store.surfacedFindings()) ?? []
        summary = Templates.dailySummary(constructs: today)
        summaryIsTemplated = true
    }

    // MARK: - Progressive disclosure

    /// What is still locked, and what would unlock it. Computed from the real gates in
    /// `ScanConfig` and `Baselines` — not a hardcoded marketing list. If the gates change,
    /// this screen changes with them.
    public struct Unlock: Identifiable {
        public let id = UUID()
        public let capability: String
        public let daysRequired: Int
        public let daysHave: Int
        public let tierRequired: Int

        public var isUnlocked: Bool { daysHave >= daysRequired }
        public var daysRemaining: Int { max(0, daysRequired - daysHave) }
    }

    public func unlocks(currentTier: Int) -> [Unlock] {
        let config = ScanConfig()
        return [
            Unlock(capability: "Baselines and deviations",
                   daysRequired: Baselines.minimumSamples, daysHave: dayCount, tierRequired: 1),
            Unlock(capability: "Stable baselines",
                   daysRequired: Baselines.vendorWarmupDays, daysHave: dayCount, tierRequired: 1),
            Unlock(capability: "Two-variable associations",
                   daysRequired: config.minNSameDay, daysHave: dayCount, tierRequired: 2),
            Unlock(capability: "Lagged context associations",
                   daysRequired: config.minNLagged, daysHave: dayCount, tierRequired: 2),
            Unlock(capability: "Stable associations across windows",
                   daysRequired: config.minWindowN * 2, daysHave: dayCount, tierRequired: 2)
        ]
    }

    public var nextUnlock: Unlock? {
        unlocks(currentTier: 1).first { !$0.isUnlocked }
    }

    // MARK: - Formatting

    /// Confidence language is consistent across the app: solid = measured, hatched = estimated,
    /// ghosted = insufficient data. Nothing is ever silently rendered as if it were solid.
    public enum Confidence { case measured, estimated, insufficient }

    public static func confidence(_ c: DailyConstruct) -> Confidence {
        if c.value == nil { return .insufficient }
        if c.confidence == 0 || c.baseline == nil { return .estimated }
        return c.confidence >= 0.7 ? .measured : .estimated
    }

    public static func format(_ c: DailyConstruct) -> String {
        guard let v = c.value else { return "—" }
        switch c.construct {
        case .sleepEfficiency, .spo2AvgOvernight: return String(format: "%.0f%%", v * 100)
        case .tempWristDeviation:                 return String(format: "%+.2f °C", v)
        case .loadStrainTrimp:                    return String(format: "%.1f", v)
        case .sleepDuration, .sleepDeep, .sleepREM:
            return "\(Int(v) / 60)h \(Int(v) % 60)m"
        default:                                  return String(format: "%.0f", v)
        }
    }

    public static func deviationLabel(_ c: DailyConstruct) -> String? {
        guard let z = c.deviationZ, c.confidence > 0 else { return nil }
        if abs(z) < 0.5 { return "at baseline" }
        return String(format: "%.1f SD %@ baseline", abs(z), z > 0 ? "above" : "below")
    }

    /// Facts handed to the narrator. Building this is the *only* way a number reaches the model.
    public func facts(for construct: DailyConstruct) -> FactSet {
        var facts = FactSet()
        if let v = construct.value {
            facts.add(label: construct.construct.displayName, value: v,
                      unit: construct.construct.unit)
        }
        if let b = construct.baseline, construct.confidence > 0 {
            facts.add(label: "baseline", value: b, unit: construct.construct.unit)
        }
        if let z = construct.deviationZ, construct.confidence > 0 {
            facts.add(label: "deviation in SD", value: z, unit: "SD")
        }
        facts.add(label: "days of history", count: dayCount)
        return facts
    }
}
