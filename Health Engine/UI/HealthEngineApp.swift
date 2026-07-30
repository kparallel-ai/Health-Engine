// HealthEngineApp.swift
// Epistemic role: composition root. It wires the layers together and owns nothing else.

import Combine
import SwiftUI

@main
struct HealthEngineApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .task { await services.bootstrap() }
        }
    }
}

@MainActor
final class AppServices: ObservableObject {
    let store: Store
    let healthKit: HealthKitService
    let context: ContextService
    let garmin: GarminImport
    let recompute: Recompute
    let narrator: Narrator

    @Published var profile = UserProfile()
    @Published var tier: Int = 0
    @Published var llmEnabled = true

    init() {
        let url = URL.applicationSupportDirectory.appending(path: "health.sqlite")
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory,
                                                 withIntermediateDirectories: true)
        // A store that cannot open is a fatal condition, not a degraded one — there is nowhere
        // to put anything. In-memory keeps the app inspectable rather than crashing on launch.
        self.store = (try? Store(path: url.path())) ?? (try! Store.inMemory())
        self.healthKit = HealthKitService(store: store)
        self.context = ContextService(store: store)
        self.garmin = GarminImport(store: store)
        self.recompute = Recompute(store: store)
        let retrieval = (try? Retrieval.loadBundled(embedder: nil))
            ?? Retrieval(chunks: [], embeddings: [], embedder: nil)
        self.narrator = Narrator(retrieval: retrieval, enabled: true)
    }

    func bootstrap() async {
        try? await healthKit.requestAuthorisation()
        try? await healthKit.sync()
        try? await healthKit.enableBackgroundDelivery()
        healthKit.startObserving { [weak self] in
            Task { @MainActor in self?.triggerRecompute() }
        }
        updateTier()
        triggerRecompute()
    }

    func updateTier() {
        var t = 0
        if (try? store.availableMetrics())?.contains(where: { $0.tier == 1 }) == true { t = 1 }
        if context.calendarAvailability == .granted || context.locationAvailability == .granted { t = max(t, 2) }
        if (try? store.availableMetrics())?.contains(where: { $0.tier == 3 }) == true { t = 3 }
        tier = t
    }

    func triggerRecompute() {
        recompute.run(
            profile: profile,
            heartRateProvider: { [healthKit] from, to in
                try await healthKit.heartRateSamples(from: from, to: to)
            },
            sleepProvider: { [healthKit] from, to in
                try await healthKit.sleepSessions(from: from, to: to)
            },
            contextProvider: { [context, store] boundary in
                guard let range = try? store.observationDateRange() else { return [] }
                return context.calendarFeatures(from: range.first, to: range.last, boundary: boundary)
            })
    }
}

struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Today", systemImage: "waveform.path.ecg") }
            FindingsView()
                .tabItem { Label("Findings", systemImage: "list.bullet.rectangle") }
            ExplainerView()
                .tabItem { Label("Learn", systemImage: "book") }
        }
    }
}
