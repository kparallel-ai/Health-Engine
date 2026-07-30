# Build status

Against `BUILD-APP.md`. Swift only, no network calls, no networking entitlement.

| Task | State | Notes |
|---|---|---|
| A1 Store | done | GRDB migrations, append-only, dedup index, `INSERT OR IGNORE` so re-import adds zero rows |
| A2 HealthKit | done | Anchored queries, background delivery, sleep-stage collapse, denied reads return empty rather than throwing |
| A3 Context | done | EventKit merged-interval hours, all-day excluded, CoreLocation significant-change only, home inferred from overnight clustering |
| A4 Garmin import | done | CSV + JSON, deterministic `source_id`, single transaction, unmapped fields counted and surfaced |
| A5 Derive | done | Physiological day boundary, n=14 baseline gate, 21-day vendor suppression, TRIMP with 60 s delta cap |
| A6 Stats | done | **See the deviation below.** SplitMix64, ACF, τ-based block length, MBB, BH-FDR |
| A7 Analyzer | done | Family bookkeeping exact, effect floor, N gates, tier ladder as a pure function |
| A8 Recompute | done | Detached CPU work, phased progress, cancellable, output hash for reproducibility checks |
| A9 Dashboard | done | Designed 0-day and mid-history states computed from the real gates |
| A10 Metric detail | done | Baseline band drawn at actual robust SD; HRV percentile blocked by `Metric.permitsNormativePercentile` |
| A11 Findings | done | Tier badges differ in colour, icon *and* wording; family size shown |
| A12 Corpus | **not done** | Curation labour, not code — see below |
| A13 Retrieval | done | BM25 + brute-force cosine via Accelerate, RRF, applicability filter before fusion |
| A14 Narrator | done | Scope classifier, numeral membership check, citation validation, retrieval gate, template fallback |
| A15 Explainers | done | Three screens; claims carry chunk IDs, audited by `ExplainerAudit` |

---

## The one deviation from spec, and why

`BUILD-APP.md` A6 specifies:

```swift
func blockLength(fromACF: [Double]) -> Int   // first lag where ACF < 1/e
```

and separately declares a **CI hard gate**: on two independent AR(1) series at ρ = 0.7,
the block bootstrap must land in [0.03, 0.07].

**These two requirements are incompatible.** The 1/e rule gives L = 3 at ρ = 0.7, because
0.7³ = 0.343 < 1/e. That is far too short to preserve the dependence structure, and the
bootstrap under-covers badly. Measured, 1,000 trials × 2,000 resamples:

| Construction | FPR at ρ = 0.7, n = 365 |
|---|---|
| Naive Pearson | 0.258 |
| Paired MBB percentile CI, L from 1/e rule | 0.140 |
| Null-distribution MBB, L from 1/e rule | 0.152 |
| Null-distribution MBB, **L = τ_int · n^(1/3)** | **0.053** |

Two changes were needed:

1. **Block length.** `blockLength(fromACF:)` is retained as a diagnostic, and a second
   overload `blockLength(x:y:)` implements `L = τ_int · n^(1/3)`, clamped to `[2, n/4]`,
   where τ_int is the Sokal-windowed integrated autocorrelation time. This is what the
   bootstrap uses.

2. **Where the p-value comes from.** Inverting a paired percentile CI does not calibrate
   (0.14 above). The p-value instead comes from a null distribution built by resampling
   x-blocks and y-blocks with *independent* starts — this destroys cross-dependence while
   preserving each series' own autocorrelation. The paired resample still produces the
   reported CI, which is what the CI is for.

Calibration across the space, 600 trials each:

| ρ | n = 90 | n = 120 | n = 365 |
|---|---|---|---|
| 0.00 | 0.062 | 0.033 | 0.048 |
| 0.30 | 0.065 | 0.042 | 0.067 |
| 0.50 | 0.063 | 0.050 | 0.067 |
| 0.70 | 0.062 | 0.058 | 0.053 |
| 0.85 | 0.097 | 0.070 | 0.048 |

Power is retained: at n = 365, ρ = 0.7, the joint requirement (p < 0.05 **and** |r| ≥ 0.25)
detects ρ = 0.3 at 75%, ρ = 0.4 at 97%, ρ = 0.5 at 100%.

**Known weak spot:** ρ = 0.85 at n = 90 sits at 0.097, outside the gate. That combination —
near-unit-root autocorrelation on under three months of data — is below the 90-day lagged
association gate anyway, so nothing reaches T1 there. It is recorded rather than hidden, and
it is the first thing to revisit if the minimum-N gates are ever loosened.

Everything above is reproducible from `Health EngineTests/StatsTests.swift`, which runs the
gate at 500 trials in PR CI and 1,000 nightly.

---

## Xcode project — wired

- App target "Health Engine" (module name `HealthIntelligence`, matching `SPEC.md` §3's
  `HealthIntelligence/` source root), sources laid out exactly per §3 as file-system
  synchronized groups — `Health/`, `Store/`, `Intelligence/`, `Evidence/`, `UI/`.
- GRDB via SPM (`groue/GRDB.swift`, up to next major from 7.0.0), linked into the app target.
- `Info.plist` carries `NSHealthShareUsageDescription`, `NSCalendarsFullAccessUsageDescription`,
  `NSLocationAlwaysAndWhenInUseUsageDescription`/`NSLocationWhenInUseUsageDescription`, and
  `UIBackgroundModes: [healthkit]`, merged with the build-setting-generated Info.plist.
  Deliberately **no** networking entitlement, per invariant 1.
- HealthKit capability (`com.apple.developer.healthkit`, `.access`) is in
  `Health Engine.entitlements` and registered in the project's `SystemCapabilities` so
  automatic signing provisions it — including on a free/Personal Team, which does support
  HealthKit despite an earlier, incorrect assumption to the contrary here.
- `Health EngineTests` unit test target (hosted in the app, `@testable import
  HealthIntelligence`), wired with a shared `.xcscheme` covering build + test.
  `testBHHandlesTiesAndEdgeCases`' hardcoded tie-case expectation was wrong (0.08 instead of
  the correct 0.02·4/3 ≈ 0.02667) — verified independently against R's `p.adjust(method="BH")`
  and against the passing `testBHMatchesReferenceValues` test; the test literal was fixed, not
  `benjaminiHochberg`.
- Builds and runs on both iOS Simulator and a physical device. Full test suite passes,
  including the AR(1) false-positive gate (§A6, ~210s at 500 trials) and the white-noise and
  power-retention checks.

---

## A12 corpus — not built

120–200 hand-curated chunks rewritten into claim form is curation labour and it does not
survive being generated. It gates A13 and A15 in the sense that both are empty without it,
but neither is *blocked*: retrieval degrades to BM25-only with no model bundled and returns
nothing with no chunks, and the narrator's retrieval gate then correctly refuses and falls
back to templates. That refusal path is exercised today.

What A12 needs, concretely:

- `Resources/corpus.sqlite` with an `evidence_chunk` table matching the columns read in
  `Retrieval.loadBundled` — `id`, `claim`, `citation`, `population`, `design`, `n`,
  `effect_size`, `direction`, `certainty`, `age_band_low`, `age_band_high`, `sex`,
  `training_status`, `hrv_modality`, `token_count`
- `Resources/embeddings.bin` — fp16, row-major, one vector per chunk in `id` order
- `Resources/MiniLM.mlpackage` and a `TextEmbedder` conformance wrapping it
- At least one chunk graded `contested` (ACWR is the intended one; `acwr-contested` is
  already referenced by the fitness/fatigue explainer)
- The ten IDs in `ExplainerAudit.allChunkIDs` must all exist, or the audit test fails

---

## Not yet wired

- **CoreLocation visit accumulation.** `ContextService` posts visits on a notification;
  nothing yet holds them between launches. Third in the cut order, and EventKit alone
  reaches tier 2.
- **Strain calibration.** `Strain.compressionC` (90) and `compressionFull` (480) are
  placeholders. They need tuning against reference days before the 0–21 number means
  anything. Until then it is an internally consistent ordinal, not a comparable score.
- **Optional items, in the documented cut order:** AR(p) pre-whitening cross-check,
  change-point detection, lag heatmap. None started; all correctly listed as cuttable.

## Invariant check

1. No network calls — nothing imports `URLSession` or `Network`.
2. The LLM never computes — enforced in `GroundingContract.validate`, not in prompt text.
3. Derivations pure and versioned — `DeriveVersion.current` / `InferVersion.current` on
   every derived row; `Recompute.outputHash` makes drift detectable.
4. Missingness never imputed — `value: nil` means measured-absent; a missing row means not
   observed; `ContextService` returns no rows on permission denial rather than zeros.
5. Works at tier 1 — every tier-2 and tier-3 path returns empty on denial.
6. Prefer boring — no folders beyond §3, no abstraction with one implementation except
   `TextEmbedder`, which exists so the app runs without a bundled model.
