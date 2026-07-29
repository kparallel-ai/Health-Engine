// StatsTests.swift
// The AR(1) false-positive gate is a hard CI requirement. It is never cut, never skipped,
// and never has its bounds relaxed to make a build green.

import XCTest
@testable import HealthIntelligence

final class StatsTests: XCTestCase {

    // MARK: - The critical test

    /// Two *independent* AR(1) series at ρ = 0.7.
    ///
    /// Naive Pearson must show a false-positive rate well above 0.05 — if it doesn't, the
    /// generator is broken and the rest of the test proves nothing. The block bootstrap must
    /// land inside [0.03, 0.07].
    ///
    /// Reference values from the numeric prototype (1,000 trials, 2,000 resamples):
    ///   naive 0.258 · bootstrap 0.053 at n = 365, 0.058 at n = 120.
    func testIndependentAR1FalsePositiveRate() {
        let trials = 500          // 1,000 in the nightly job; 500 keeps PR CI under a minute
        let nBoot = 999
        let n = 365
        let phi = 0.7

        var rng = SeededRNG(seed: 0xA51D_2024)
        var naiveFP = 0
        var bootFP = 0

        for _ in 0..<trials {
            let x = ar1(n: n, phi: phi, rng: &rng)
            let y = ar1(n: n, phi: phi, rng: &rng)

            if naivePearsonPValue(pearson(x, y), n: n) < 0.05 { naiveFP += 1 }

            let L = blockLength(x: x, y: y)
            let result = blockBootstrapCorrelation(x, y, nBoot: nBoot, blockLength: L, rng: &rng)
            if result.p < 0.05 { bootFP += 1 }
        }

        let naiveRate = Double(naiveFP) / Double(trials)
        let bootRate = Double(bootFP) / Double(trials)

        XCTAssertGreaterThan(naiveRate, 0.12,
            "Naive Pearson should be badly miscalibrated on AR(1); got \(naiveRate). "
            + "If this fails the AR(1) generator is wrong.")
        XCTAssertGreaterThanOrEqual(bootRate, 0.03, "Block bootstrap over-conservative: \(bootRate)")
        XCTAssertLessThanOrEqual(bootRate, 0.07, "Block bootstrap false-positive rate: \(bootRate)")
    }

    /// White noise must not be over-corrected into uselessness.
    func testWhiteNoiseFalsePositiveRate() {
        var rng = SeededRNG(seed: 0x0FF1_CE)
        var fp = 0
        let trials = 400
        for _ in 0..<trials {
            let x = ar1(n: 365, phi: 0.0, rng: &rng)
            let y = ar1(n: 365, phi: 0.0, rng: &rng)
            let L = blockLength(x: x, y: y)
            if blockBootstrapCorrelation(x, y, nBoot: 999, blockLength: L, rng: &rng).p < 0.05 { fp += 1 }
        }
        let rate = Double(fp) / Double(trials)
        XCTAssertTrue((0.02...0.08).contains(rate), "White-noise FPR out of range: \(rate)")
    }

    /// The correction must not have destroyed power — a null-only test is trivially passed
    /// by always returning p = 1.
    func testPowerRetainedOnGenuineCoupling() {
        var rng = SeededRNG(seed: 0xD00D)
        var detected = 0
        let trials = 200
        let rho = 0.4
        for _ in 0..<trials {
            let a = ar1(n: 365, phi: 0.7, rng: &rng)
            let b = ar1(n: 365, phi: 0.7, rng: &rng)
            let y = zip(a, b).map { rho * $0 + (1 - rho * rho).squareRoot() * $1 }
            let L = blockLength(x: a, y: y)
            let result = blockBootstrapCorrelation(a, y, nBoot: 999, blockLength: L, rng: &rng)
            if result.p < 0.05 && abs(result.r) >= 0.25 { detected += 1 }
        }
        XCTAssertGreaterThan(Double(detected) / Double(trials), 0.80,
            "Power collapsed; the correction is too conservative.")
    }

    // MARK: - Benjamini–Hochberg

    func testBHMatchesReferenceValues() {
        // R: p.adjust(c(0.001,0.008,0.039,0.041,0.042,0.060,0.074,0.205,0.212,0.216), "BH")
        let p = [0.001, 0.008, 0.039, 0.041, 0.042, 0.060, 0.074, 0.205, 0.212, 0.216]
        let expected = [0.010, 0.040, 0.084, 0.084, 0.084, 0.100, 0.10571428571428573,
                        0.2160, 0.2160, 0.2160]
        let got = benjaminiHochberg(p)
        for (a, b) in zip(got, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    func testBHHandlesTiesAndEdgeCases() {
        XCTAssertTrue(benjaminiHochberg([]).isEmpty)
        XCTAssertEqual(benjaminiHochberg([0.03]), [0.03])

        let ties = benjaminiHochberg([0.02, 0.02, 0.02, 0.9])
        XCTAssertEqual(ties[0], ties[1], accuracy: 1e-12)
        XCTAssertEqual(ties[1], ties[2], accuracy: 1e-12)
        XCTAssertEqual(ties[0], 0.08, accuracy: 1e-12)
    }

    func testBHIsMonotoneInP() {
        var rng = SeededRNG(seed: 7)
        let p = (0..<200).map { _ in Double(rng.nextInt(below: 1_000_000)) / 1_000_000.0 }
        let q = benjaminiHochberg(p)
        let pairs = zip(p, q).sorted { $0.0 < $1.0 }
        for i in 1..<pairs.count {
            XCTAssertGreaterThanOrEqual(pairs[i].1, pairs[i - 1].1 - 1e-12,
                                        "q-values must be non-decreasing in p")
        }
    }

    // MARK: - Determinism

    func testBootstrapIsBitIdenticalAcrossRuns() {
        var seedRNG = SeededRNG(seed: 99)
        let x = ar1(n: 200, phi: 0.5, rng: &seedRNG)
        let y = ar1(n: 200, phi: 0.5, rng: &seedRNG)

        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        let r1 = blockBootstrapCorrelation(x, y, nBoot: 500, blockLength: 12, rng: &a)
        let r2 = blockBootstrapCorrelation(x, y, nBoot: 500, blockLength: 12, rng: &b)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - Baselines

    func testBaselineGateFiresExactlyAtBoundary() {
        let history = (0..<13).map { Double($0) }
        let below = Baselines.compute(today: 5, history: history,
                                      daysOfDeviceHistory: 100, isVendorDerived: false)
        XCTAssertNil(below.baseline)
        XCTAssertEqual(below.confidence, 0)
        XCTAssertTrue(below.flags.contains("below_minimum_samples"))

        let at = Baselines.compute(today: 5, history: history + [13],
                                   daysOfDeviceHistory: 100, isVendorDerived: false)
        XCTAssertNotNil(at.baseline)
        XCTAssertGreaterThan(at.confidence, 0)
    }

    func testBaselineSurvivesSingleFiveSigmaOutlier() {
        let clean = (0..<30).map { _ in 50.0 }
        var dirty = clean
        dirty[15] = 5000.0
        let a = Baselines.compute(today: 50, history: clean, daysOfDeviceHistory: 100, isVendorDerived: false)
        let b = Baselines.compute(today: 50, history: dirty, daysOfDeviceHistory: 100, isVendorDerived: false)
        XCTAssertEqual(a.baseline!, b.baseline!, accuracy: 0.5)
    }

    func testVendorMetricsSuppressedDuringWarmup() {
        let history = (0..<30).map { _ in 0.2 }
        let warm = Baselines.compute(today: 0.9, history: history,
                                     daysOfDeviceHistory: 20, isVendorDerived: true)
        XCTAssertNil(warm.deviationZ)
        XCTAssertTrue(warm.flags.contains("vendor_warmup"))

        let settled = Baselines.compute(today: 0.9, history: history,
                                        daysOfDeviceHistory: 21, isVendorDerived: true)
        XCTAssertNotNil(settled.baseline)
    }

    // MARK: - Strain

    func testSixHourGapDoesNotInflateStrain() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = UserProfile(sex: .male, age: 35)

        let contiguous = (0..<360).map { HeartRateSample(time: t0.addingTimeInterval(Double($0) * 60), bpm: 150) }
        let gapped = [HeartRateSample(time: t0, bpm: 150),
                      HeartRateSample(time: t0.addingTimeInterval(6 * 3600), bpm: 150)]

        let a = Strain.trimp(samples: contiguous, restingHR: 50, profile: profile)
        let b = Strain.trimp(samples: gapped, restingHR: 50, profile: profile)

        XCTAssertLessThan(b.rawTRIMP, a.rawTRIMP * 0.02,
                          "A 6-hour gap must contribute at most one capped interval.")
        XCTAssertEqual(b.secondsCounted, Strain.maxSampleGapSeconds, accuracy: 0.001)
    }

    func testHRRIsClampedAndStrainBounded() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = UserProfile(sex: .female, age: 30)
        // HR above max and below rest — both must clamp rather than produce negative or >1 HRR.
        let samples = (0..<600).map { HeartRateSample(time: t0.addingTimeInterval(Double($0) * 30),
                                                     bpm: $0 % 2 == 0 ? 250 : 30) }
        let result = Strain.trimp(samples: samples, restingHR: 55, profile: profile)
        XCTAssertGreaterThanOrEqual(result.strain, 0)
        XCTAssertLessThanOrEqual(result.strain, 21)
    }

    // MARK: - Tier ladder

    func testTierAssignmentIsPureAndOrdered() {
        func evidence(q: Double = 0.01, effect: Double = 0.4, n: Int = 200,
                      stable: Bool = false, precedence: Bool = false,
                      confounded: Bool = false) -> TierEvidence {
            TierEvidence(n: n, minN: 90, absEffect: effect, effectFloor: 0.25, qValue: q,
                         q: 0.10, windowsStable: stable, hasTemporalPrecedence: precedence,
                         confounderIdentified: confounded)
        }

        XCTAssertEqual(assignTier(evidence(q: 0.5)), .t0)                       // fails FDR
        XCTAssertEqual(assignTier(evidence(effect: 0.24)), .t0)                 // fails effect floor
        XCTAssertEqual(assignTier(evidence(n: 89)), .t0)                        // fails minimum N
        XCTAssertEqual(assignTier(evidence()), .t1)
        XCTAssertEqual(assignTier(evidence(stable: true)), .t2)
        XCTAssertEqual(assignTier(evidence(stable: true, precedence: true)), .t3)
        XCTAssertEqual(assignTier(evidence(stable: true, precedence: true, confounded: true)), .t2)
        // T4 is unreachable without a randomised trial flag, which nothing in this build sets.
    }

    // MARK: - Day arithmetic

    func testDayArithmeticSurvivesDSTTransition() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // 2025-03-09 is the US spring-forward date.
        let before = Day(raw: "2025-03-08")
        XCTAssertEqual(before.adding(days: 1, calendar: cal)?.raw, "2025-03-09")
        XCTAssertEqual(before.adding(days: 2, calendar: cal)?.raw, "2025-03-10")
        XCTAssertEqual(Day(raw: "2025-11-02").adding(days: -1, calendar: cal)?.raw, "2025-11-01")
    }

    // MARK: - Helpers

    /// Stationary AR(1) with unit innovation variance.
    private func ar1(n: Int, phi: Double, rng: inout SeededRNG) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        out[0] = gaussian(&rng) / (1 - phi * phi).squareRoot()
        for i in 1..<n { out[i] = phi * out[i - 1] + gaussian(&rng) }
        return out
    }

    /// Box–Muller from the seeded stream, so the whole test is reproducible.
    private func gaussian(_ rng: inout SeededRNG) -> Double {
        let u1 = max(Double(rng.nextInt(below: 1 << 30)) / Double(1 << 30), 1e-12)
        let u2 = Double(rng.nextInt(below: 1 << 30)) / Double(1 << 30)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    private func naivePearsonPValue(_ r: Double, n: Int) -> Double {
        guard n > 2 else { return 1 }
        let t = abs(r) * (Double(n - 2) / max(1e-12, 1 - r * r)).squareRoot()
        // Normal approximation is fine at n = 365 and keeps the test dependency-free.
        return 2 * (1 - normalCDF(t))
    }

    private func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }
}
