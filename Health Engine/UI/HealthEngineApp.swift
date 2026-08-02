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
        // `path(percentEncoded:)` must be false: the zero-arg `.path()` returns a percent-encoded
        // string (spaces as %20), which SQLite reads as a literal filename and fails to open.
        self.store = (try? Store(path: url.path(percentEncoded: false))) ?? (try! Store.inMemory())
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
            Task { @MainActor in
                self?.triggerRecompute()
                self?.syncPassiveContext()
            }
        }
        // Visit monitoring is what "places" runs on — unlike calendar, which stays an
        // unrequested, documented gap pending a real onboarding affordance, this one starts
        // itself: `startMonitoringVisits()` triggers the system prompt on its own, the same way
        // the CoreMotion query does, so there's no separate UI moment it's waiting on.
        context.startLocationMonitoring()
        updateTier()
        triggerRecompute()
        syncPassiveContext()
    }

    /// Cheap on-device queries, not statistical computation — safe to run on launch and on
    /// every background HealthKit delivery, unlike the association scan (which stays
    /// manual-only via `triggerFullScan`). Each source's own derive function decides what "no
    /// row" means for it; this just fetches, derives, and persists.
    func syncPassiveContext() {
        Task { [context, healthKit] in
            let now = Date()
            guard let weekAgo = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -7, to: now),
                  let monthAgo = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: now)
            else { return }
            let sleep = (try? await healthKit.sleepSessions(from: weekAgo, to: now)) ?? []
            let boundary = DayBoundary(sleepSessions: sleep)
            let calendar = Calendar.autoupdatingCurrent

            // Motion respects CoreMotion's own hard 7-day limit internally.
            let motion = await context.motionContextFeatures(boundary: boundary)

            // Steps, headphone audio, and flights climbed all carry HealthKit's own backfilled
            // history rather than a platform limit like CoreMotion's — a 30-day trailing window
            // keeps each passive sync cheap while still covering the whole history over enough
            // launches, the same self-healing overlap `motionContextFeatures` relies on.
            let stepBuckets = (try? await healthKit.hourlyStepBuckets(from: monthAgo, to: now)) ?? []
            let dayShape = ContextService.deriveDayShapeFeatures(buckets: stepBuckets,
                                                                 boundary: boundary, calendar: calendar)

            let headphoneSamples = (try? await healthKit.headphoneAudioSamples(from: monthAgo, to: now)) ?? []
            let headphone = ContextService.deriveHeadphoneFeatures(samples: headphoneSamples, boundary: boundary)

            let flightsSamples = (try? await healthKit.flightsClimbedSamples(from: monthAgo, to: now)) ?? []
            let flights = ContextService.deriveFlightsFeatures(samples: flightsSamples, boundary: boundary)

            // Places reads visits already durably persisted by the location delegate — nothing
            // to fetch here, just derive from what's accumulated since the last sync.
            let places = context.placesFeatures(boundary: boundary)

            let all = motion + dayShape + headphone + flights + places
            guard !all.isEmpty else { return }
            try? context.persist(all)
        }
    }

    func updateTier() {
        var t = 0
        if (try? store.availableMetrics())?.contains(where: { $0.tier == 1 }) == true { t = 1 }
        if context.calendarAvailability == .granted || context.locationAvailability == .granted { t = max(t, 2) }
        if (try? store.availableMetrics())?.contains(where: { $0.tier == 3 }) == true { t = 3 }
        tier = t
    }

    /// Cheap and automatic — today's numbers and rolling baselines only. Safe to call from
    /// background HealthKit delivery, pull-to-refresh, or right after an import. Never runs
    /// the association scan; that is a real, user-visible wait the person has to opt into.
    func triggerRecompute() {
        recompute.runDeriveOnly(
            profile: profile,
            heartRateProvider: { [healthKit] from, to in
                try await healthKit.heartRateSamples(from: from, to: to)
            },
            sleepProvider: { [healthKit] from, to in
                try await healthKit.sleepSessions(from: from, to: to)
            })
    }

    /// The expensive path. Called only from the explicit "start scan" action on
    /// `InsightsScanView` — never automatically.
    func triggerFullScan() {
        recompute.runFullScan(
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

    init() {
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Theme.surfaceRaised)
        tabAppearance.shadowColor = UIColor(Theme.hairline)
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        let titleColor = UIColor(Theme.textPrimary)
        let largeTitleFont = UIFont.systemFont(ofSize: 32, weight: .bold)

        // Two distinct states, not one: transparent and blended with the page while at the
        // top of a scroll (so the big title reads as part of the content), opaque with a
        // hairline shadow once scrolled (so the header stays legible over moving content).
        // A flat single appearance is what made every screen feel titleless — cream-on-cream
        // with no separation at all.
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        scrollEdge.backgroundColor = UIColor(Theme.background)
        scrollEdge.titleTextAttributes = [.foregroundColor: titleColor]
        scrollEdge.largeTitleTextAttributes = [.foregroundColor: titleColor, .font: largeTitleFont]

        let standard = UINavigationBarAppearance()
        standard.configureWithOpaqueBackground()
        standard.backgroundColor = UIColor(Theme.surfaceRaised)
        standard.shadowColor = UIColor(Theme.hairline)
        standard.titleTextAttributes = [.foregroundColor: titleColor]
        standard.largeTitleTextAttributes = [.foregroundColor: titleColor, .font: largeTitleFont]

        UINavigationBar.appearance().standardAppearance = standard
        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdge
        UINavigationBar.appearance().compactAppearance = standard
    }

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Today", systemImage: "waveform.path.ecg") }
            FindingsView()
                .tabItem { Label("Findings", systemImage: "list.bullet.rectangle") }
            ExplainerView()
                .tabItem { Label("Learn", systemImage: "book") }
        }
        .tint(Theme.accent)
        // A deliberate warm light theme, not a system-dependent default — this is the fix
        // for "the app looks black," not merely "the app currently looks black on this phone."
        .preferredColorScheme(.light)
    }
}
