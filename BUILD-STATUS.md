# Build status

Against `BUILD-APP.md`. Swift only, no network calls, no networking entitlement.

| Task | State | Notes |
|---|---|---|
| A1 Store | done | GRDB migrations, append-only, dedup index, `INSERT OR IGNORE` so re-import adds zero rows |
| A2 HealthKit | done | Anchored queries, background delivery, sleep-stage collapse, denied reads return empty rather than throwing. Free/Personal Team signing confirmed to support the capability — see Xcode project notes below. |
| A3 Context | done | EventKit merged-interval hours, all-day excluded, CoreLocation significant-change only, home inferred from overnight clustering. **Neither permission is ever requested from the UI today** — see "Not yet wired." |
| A4 Garmin import | done | CSV + JSON, **plus real GDPR zip exports** — nested `DI_CONNECT/.../UDSFile_*.json` and `*_sleepData.json`, parsed via ZIPFoundation. Deterministic `source_id`, single transaction, unmapped fields counted and surfaced. Validated end-to-end against a real 3.2 MB export. |
| A5 Derive | done | Physiological day boundary, n=14 baseline gate, 21-day vendor suppression, TRIMP with 60 s delta cap. `derive-1.0.1`: fixed `bodyBatteryMin`/`stressAvg` incorrectly marked non-overnight, which shifted every Garmin daily reading back one day. |
| A6 Stats | done | **See the deviation below.** SplitMix64, ACF, τ-based block length, MBB, BH-FDR |
| A7 Analyzer | done | Family bookkeeping exact, effect floor, N gates, tier ladder as a pure function. **Now runs two independently-corrected families** — see "Second deviation" below. |
| A8 Recompute | done | Detached CPU work, phased progress, cancellable, output hash for reproducibility checks. Split into a cheap automatic derive-only path and a manual, user-initiated full-scan path — see below. |
| A9 Dashboard | done | Designed 0-day and mid-history states computed from the real gates. Warm light theme (cream/terracotta, not system dark mode), percent-of-baseline deviation labels, tap-to-expand quick look per metric, data-driven nav titles (today's date, not the word "Today"). |
| A10 Metric detail | done | Baseline band drawn at actual robust SD; HRV percentile blocked by `Metric.permitsNormativePercentile`. Chart x-axis fixed to plot real `Date`s (was plotting raw `"YYYY-MM-DD"` strings as categorical labels); distribution is a proper equal-width histogram, not one bar per distinct value. |
| A11 Findings | done | Tier badges differ in colour, icon *and* wording; family size shown. Substantially extended beyond spec — manual scan trigger with disclosure screen, family-level dedup, per-finding physiological rationale, smoothed dual-line trend chart. See "Second deviation" below. |
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

## The second deviation from spec, and why

`BUILD-APP.md`/`SPEC.md` design one scan family: constructs tested against calendar/location
**context** features (`ScanFamily.contextAssociations`). In practice, on a real device with
real data, that family is permanently empty — nothing in the shipped UI ever calls
`ContextService.requestCalendarAccess()` or starts location monitoring, so
`context.calendarAvailability` never leaves `.notDetermined`, `storedFeatures` in `Recompute`
is always `[]`, and `Analyzer.scan`'s `guard !candidates.isEmpty else { return [] }` fires on
every run. The Findings screen was permanently empty, independent of tier or history length.

Rather than only wiring the permission request (which still leaves the 60/90-day sample-size
floor in §4.1 out of reach for the first two months of use), a second family was added:

**`ScanFamily.biometricAssociations`** — constructs tested against *each other*, using the same
`Analyzer.scan` machinery (bootstrap, BH-FDR, stability, confounder screen, tier ladder)
unchanged, with two additions:

1. **`symmetric: Bool` mode.** Feeding the same metric universe into both sides of `scan()`
   as `constructs` and `features` needed two new guards that don't apply to context
   associations: a construct can't be tested against itself, and — critically — not against
   another metric in the same `MetricFamily` either. Sleep duration vs. REM sleep, or Body
   Battery min vs. max, will always correlate because one is mechanically close to a function
   of the other; testing them isn't a hypothesis, it's arithmetic. Excluded from the candidate
   pool at generation time, not merely deduplicated after the fact.
2. **`ScanConfig.biometricSelf`.** The base config's `minNSameDay = 60` / `minNLagged = 90`
   are calibrated for sparse, categorical context data — reasonable there, but it means a
   dense, continuous, near-daily biometric pair would also wait two months to say anything.
   Lowered to 21/30 days for this family only, with a matching cut to `nBoot` (2,000 → 400)
   and `lags` (`0...3` → `0...1`): the base bootstrap cost had never actually run at volume in
   production (the context family's candidate list was always empty), and testing every metric
   against every other was enough unoptimized numeric work in a debug build to peg the CPU hard
   enough to make the app briefly unresponsive on-device. Cut until a from-scratch profiling
   pass says otherwise.

Both families are BH-corrected **independently** and persisted under their own `family_id`, so
`familySize`/`q` for one is never contaminated by the other's candidate count.

The scan itself was also made **manual**, not automatic — `Recompute` is split into
`runDeriveOnly` (today's numbers and baselines; safe to run on every launch, background
delivery tick, and pull-to-refresh) and `runFullScan` (the association scan; runs only from
the explicit "Update Insights" screen, which discloses the ~1-minute wait before starting).
`AppServices.bootstrap()` now calls only the former.

The Findings list itself also collapses by `MetricFamily` pair rather than by exact metric —
Body Battery min and max both correlating with sleep is one relationship, not two — keeping
only the single strongest result per family pair. `familySize`/`q` in the stats block still
reflect the full, uncollapsed candidate count; only the *display* list is collapsed.

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

## The third deviation from spec, and why: DeviceActivity was not built

The spec's passive-context-capture update asked for four things: CoreMotion features, a
DeviceActivity tier (Screen Time API, via a new `ActivityMonitor` extension target with the
Family Controls entitlement), rank correlation in the analyzer, and a feature-budget assertion.
Three shipped. DeviceActivity did not, and — as things stand — can't.

This project signs with a **personal development team** (free Apple ID, no paid Developer
Program membership). Confirmed by actually attempting it, not by assumption: adding
`com.apple.developer.family-controls` to the entitlements and building for the device fails
with

```
Cannot create a iOS App Development provisioning profile for "Personal.Health-Engine".
Personal development teams, including "Ketu Patel", do not support the
Family Controls (Development) capability.
```

Family Controls is a restricted entitlement Apple grants only to paid accounts after a manual
review. Unlike the other three changes, this isn't a "not yet wired" gap that a future session
can close by writing more code — no amount of correct Swift changes that. It needs a paid
account and Apple's approval first. (App Groups, by contrast, works fine on a personal team —
tested the same way — so the host-app/extension shared-storage half of the design isn't blocked,
only the entitlement itself is.)

What this took off the table, downstream:

- **The `ActivityMonitor` extension target, `DeviceActivityMonitor` subclass, and the
  `ctx.screen_*` feature derivation.** None of it started. Writing it without the entitlement to
  actually build and run it against would mean shipping code no one could verify — the SPEC's
  own instruction for this situation is to stop and say so rather than do that.
- **The screen-feature-specific pieces of the analyzer changes** — the T2 tier cap for
  `ctx.screen_*` findings, and the independent minimum-N clock keyed to first-callback rather
  than install date. Both are specified entirely in terms of a metric family that doesn't exist
  in this build. What *did* ship is the general mechanism they'd hang off: `Analyzer.scan` now
  takes a `rankTransformed: (Metric) -> Bool` closure (default: Pearson everywhere, so no
  existing behaviour changed) that decides per-feature whether to rank-transform before the
  block bootstrap, and records `"pearson"` or `"spearman"` in `finding.method`. When
  DeviceActivity ships, wiring screen features through it is a few lines at the call site, not a
  redesign.

Everything else in the spec update — CoreMotion features (`ctx.sedentary_max_block`,
`ctx.activity_transitions`, `ctx.automotive_minutes`, derived in `ContextService.swift`, queried
on launch and on every HealthKit background-delivery callback, correctly bounded to CoreMotion's
hard 7-day history limit with no backfill across gaps) and the feature-budget precondition
(`Analyzer.maxDenseContextFeatures = 20`, asserted at scan time against the `contextAssociations`
family only — the biometric self-scan's construct count is a separate, uncapped axis) — shipped
as specified.

## Not yet wired

- **Calendar/location permission is never requested.** `ContextService.requestCalendarAccess()`
  and the location-monitoring entry point exist and work, but nothing in the UI calls them —
  no onboarding screen, no button, no `.task`. This is why `ScanFamily.contextAssociations` is
  empty in practice (see "second deviation" above) and why tier never reaches 2 on a real
  device today. Highest-value next wire: a real affordance for it, most naturally as an action
  on the existing `TierPrompt` view, which currently just displays text. Motion is the one
  exception: `ContextService.motionAvailability`/`motionContextFeatures` are wired into
  `AppServices.bootstrap()` and the background-delivery callback already, since CoreMotion's
  system permission prompt is triggered by the query itself and needs no separate UI.
- **CoreLocation visit accumulation.** `ContextService` posts visits on a notification;
  nothing yet holds them between launches. Moot until the permission above is actually
  requested.
- **Strain calibration.** `Strain.compressionC` (90) and `compressionFull` (480) are
  placeholders. They need tuning against reference days before the 0–21 number means
  anything. Until then it is an internally consistent ordinal, not a comparable score.
- **Biometric-scan bootstrap cost.** `ScanConfig.biometricSelf`'s `nBoot`/`lags` cuts (above)
  were a fast, conservative response to an on-device freeze, not a profiled optimum. A Release
  build (`-O`, not the `-Onone` debug build this was measured under) is very likely fast enough
  to raise them back toward the base config; not yet measured.
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
