# BUILD — App

Agent-facing. Read `SPEC.md` for intent; this is mechanics. Swift only. The oracle is a separate document and is not needed to build or run any of this.

Tasks form a dependency graph. Work anything unblocked.

---

## Invariants

1. **No network calls.** No networking entitlement. If a task appears to need one, stop and flag it.
2. **The LLM never computes.** No numeral may appear in generated output that wasn't passed in as an injected fact. Enforced in code (A14), not in a prompt.
3. **Derivations are pure and versioned.** Every derived value stores the version of the function that produced it. Same inputs → bit-identical outputs.
4. **Missingness is never imputed silently.** `NULL` = measured absent. No row = not observed.
5. **The app works at tier 1.** Every source above HealthKit is optional. Permission denial removes capability; it never breaks a screen.
6. **Prefer boring.** No async where sync works, no abstraction with one implementation, no folders beyond `SPEC.md` §3.

Each file's header comment states its epistemic role in one line. If contents stop matching the line, the architecture has drifted.

---

## Schema

`Store/Store.swift`, via GRDB migrations.

```sql
-- Append-only. Never UPDATE. Never DELETE.
CREATE TABLE observation (
    id              INTEGER PRIMARY KEY,
    metric          TEXT    NOT NULL,
    value           REAL,                     -- NULL = measured-absent
    unit            TEXT    NOT NULL,
    effective_start TEXT    NOT NULL,         -- when the physiology happened
    effective_end   TEXT,
    recorded_at     TEXT    NOT NULL,         -- when we learned it
    source          TEXT    NOT NULL,         -- healthkit | eventkit | location | garmin
    source_id       TEXT,
    quality         REAL    NOT NULL DEFAULT 1.0,
    flags           TEXT    NOT NULL DEFAULT '[]',
    ingest_version  TEXT    NOT NULL
);
CREATE INDEX ix_obs_metric_time ON observation(metric, effective_start);
CREATE UNIQUE INDEX ux_obs_dedup ON observation(source, source_id, metric)
    WHERE source_id IS NOT NULL;

CREATE TABLE daily_construct (
    day             TEXT NOT NULL,            -- YYYY-MM-DD, physiological day
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
    is_dense        INTEGER NOT NULL,         -- 0 = annotation, excluded from scans
    source          TEXT NOT NULL,
    derive_version  TEXT NOT NULL,
    PRIMARY KEY (day, feature, derive_version)
);

CREATE TABLE finding (
    id              TEXT PRIMARY KEY,         -- deterministic hash of the hypothesis
    kind            TEXT NOT NULL,            -- trend | changepoint | association
    tier            TEXT NOT NULL,            -- T0..T4
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
```

`evidence_chunk` and `intervention` ship read-only in `Resources/corpus.sqlite` — see A12.

### Metric ontology

Fix now; changing later is expensive.

```
Tier 1 (HealthKit)
hr.resting bpm · hrv.sdnn_overnight ms · vo2max.running ml_kg_min
sleep.duration min · sleep.efficiency frac · sleep.deep min · sleep.rem min
sleep.onset min_from_midnight · respiration.avg_overnight brpm
temp.wrist_deviation C · load.strain_trimp au_0_21

Tier 2 (EventKit, CoreLocation)
ctx.meeting_hours h · ctx.first_event_hour h · ctx.last_event_hour h
ctx.minutes_outside_home min · ctx.timezone_shift h

Tier 3 (Garmin)
hrv.rmssd_overnight ms · hrv.status_garmin enum · body_battery.min 0_100
body_battery.max 0_100 · stress.avg 0_100 · load.training_garmin au
spo2.avg_overnight frac · threshold.lactate_hr bpm · endurance.score au
```

---

## Task Graph

```
A1 Store ───┬── A2 HealthKit ───┬── A5 Derive ───┬── A7 Analyzer ── A8 Recompute ───┬── A9 Dashboard
            ───  A3 Context ─────               │                                 ───  A10 MetricDetail
            ───  A4 GarminImport                A6 Stats                          ───  A11 Findings

A12 Corpus ───┬── A13 Retrieval ── A14 Narrator
              ───  A15 Explainers
```

---

### A1 — Models and store
**Out:** `Health/HealthModels.swift`, `Store/Store.swift`.

GRDB, read-write, on-device. Plain Codable structs; no framework types leak into the model layer. Two time axes on every observation — `effective_start` (when the physiology happened) and `recorded_at` (when we learned it), because HealthKit backfills and Garmin reprocesses.

**Done when:** app launches with an empty database and renders without crashing; writes are transactional; re-importing identical data adds zero rows.

### A2 — HealthKit
**Deps:** A1. **Out:** `Health/HealthKitService.swift`.

Boundary layer — no `HKQuantityType` escapes into the model. Authorisation, anchored queries for incremental sync, background delivery for new samples, unit normalisation to the ontology.

**Done when:** partial permission grants work (some types authorised, others not) without breaking; units normalised; re-sync is incremental, not a full re-read.

### A3 — Context capture
**Deps:** A1. **Out:** `Health/ContextService.swift`.

**EventKit** — meeting hours per physiological day, first/last event hour, all-day events excluded from hour counts, overlapping events not double-counted, correct timezone handling.

**CoreLocation** — significant-change monitoring only, never continuous. Home geofence inferred from overnight location clustering. Emits minutes-outside-home and timezone shift.

Sparse categorical events (flights, holidays) are stored with `is_dense = 0` and **excluded from scans** — a variable with six occurrences a year cannot be tested. They are timeline annotations.

**Done when:** permission denial leaves those features *absent*, not zero-filled; a denied source degrades the app to tier 1 cleanly.

### A4 — Garmin import
**Deps:** A1. **Out:** `Health/GarminImport.swift`.

Optional tier 3. Accepts an exported database or FIT archive via Files / share sheet. Merges with dedup on `(source, source_id, metric)`. Maps to the tier 3 ontology; anything unmapped is logged, never silently dropped.

**Done when:** importing the same file twice adds zero rows; import is transactional; the app is fully functional if this is never used.

### A5 — Derive
**Deps:** A1, A2. **Out:** `Intelligence/Derive.swift`. Produces measurements.

**Physiological day boundary** — wake to following wake. Overnight metrics belong to the day they *precede* — the HRV recorded during the night of the 3rd–4th is the 4th's HRV, because it is the state you begin the 4th in. Daytime metrics and context belong to the day they occur in. Fallback when sleep data is missing: 04:00 local. Get this wrong and every downstream lag is off by one.

**Rolling baselines** — median and MAD-based SD over 30 days. **Minimum-sample gate at n = 14: return nil with confidence 0, never a number.** Vendor deviation metrics suppressed for the first 21 days of device history.

**TRIMP strain** — HRR fraction clamped to [0,1], exponential intensity weight (k = 1.92 male / 1.67 female), log compression to 0–21, rolling 30-day RHR baseline, **time deltas between sparse samples capped at 60s.**

**Done when:** gate fires exactly at the boundary; baseline survives a single 5σ outlier; a 6-hour data gap does not inflate strain; DST transitions and timezone shifts handled in day assignment.

### A6 — Stats
**Deps:** none. **Out:** `Intelligence/Stats.swift`. Pure functions over `[Double]`. No I/O, no async, no classes.

```swift
func autocorrelation(_ x: [Double], maxLag: Int) -> [Double]
func blockLength(fromACF: [Double]) -> Int        // first lag where ACF < 1/e
func blockBootstrapCorrelation(_ x: [Double], _ y: [Double],
    nBoot: Int, blockLength: Int, rng: inout SeededRNG) -> BootstrapResult
func benjaminiHochberg(_ p: [Double], q: Double) -> [Double]
```

Moving-block bootstrap is the primary autocorrelation correction and carries it alone. BH-FDR is roughly ten lines: sort ascending, find the largest *i* where p₍ᵢ₎ ≤ (i/m)·q, reject up to it.

Use a seedable PRNG (SplitMix64 or Xoshiro). **Do not use `Int.random`** — it isn't reproducible, and reproducibility is required by A8 and by the oracle.

Optional: AR(p) pre-whitening via Levinson–Durbin as a cross-check. **First in the cut order.**

**Done when — the critical test:** two **independent** AR(1) series at ρ = 0.7, 1,000 trials. Naive Pearson must show a false-positive rate well above 0.05; the block bootstrap must land within [0.03, 0.07]. **CI hard gate.** Also: BH matches known reference values within 1e-9, including ties, m = 0, and m = 1.

### A7 — Analyzer
**Deps:** A5, A6. **Out:** `Intelligence/Analyzer.swift`. Facts, not conclusions.

```swift
func scan(constructs: [DailyConstruct], features: [ContextFeature],
          family: ScanFamily) -> [Finding]
```

Enumerate (construct × dense feature × lag 0–3). Exclude `is_dense = 0`. Correlate via A6.

- **BH-FDR at q = 0.10 across the whole family.** Store `family_id` and `family_size` on every finding, including ones that fail — auditability requires knowing how many tests ran.
- Effect floor: |r| < 0.25 never surfaces regardless of q.
- Minimum-N gates per `SPEC.md` §4.1.
- T2 requires stability across two non-overlapping windows.
- Tier assignment per `SPEC.md` §5.1. T3 requires temporal precedence. T4 is unreachable in this build.

Optional: change-point detection via **binary segmentation with a BIC penalty**, minimum segment 14 days. Do not attempt PELT. **Second in the cut order.**

**Done when:** family bookkeeping is exact; no finding below the effect floor or minimum-N gate escapes; tier assignment is a pure function with no scan-state dependency.

### A8 — Recompute
**Deps:** A1, A7. **Out:** `Store/Recompute.swift`.

Orchestrates derive → context join → scan on a background queue. Triggered on import, on new HealthKit samples, and manually. Budget realistically: 365 days × 25 constructs × 20 features × 4 lags × 2,000 resamples is real work. Show progress; never block the UI.

**Done when:** completes without blocking; re-running produces identical output hashes; cancellation mid-run leaves the store consistent.

### A9 — Dashboard
**Deps:** A8. **Out:** `UI/DashboardView.swift`, `UI/DashboardViewModel.swift`.

Today's constructs with baseline bands, tier-badged findings, one-line state summary (template-generated until A14).

**Done when:** renders correctly at 0, 1, 25, and 365 days. The 0 and 25-day states are designed screens showing what unlocks and when — computed from the real gates in A7, and showing which *tier* would unlock more. Not error states.

### A10 — Metric detail
**Deps:** A8. **Out:** `UI/MetricDetailView.swift`.

Time series with baseline band (band width *is* the uncertainty), distribution, normative percentile where `SPEC.md` §7.3 permits, link to the relevant explainer.

**Done when:** HRV detail shows **no** population percentile. Hard requirement.

### A11 — Findings
**Deps:** A8. **Out:** `UI/FindingsView.swift`.

Tier badges, effect size, N, exact phrasing from `SPEC.md` §5.1. Local confirm/dismiss.

**Done when:** T1 and T3 findings are visually *and* verbally distinguishable at a glance.

Optional: lag-correlation heatmap (Canvas; construct × context × lag; sub-floor cells ghosted, not coloured). **Fourth in the cut order.**

**Development note:** this screen can be built against a hand-written JSON of sample findings before A7 produces real ones. Don't block on the analyzer.

### A12 — Corpus
**Deps:** none. **Out:** `Resources/corpus.sqlite`, `Resources/embeddings.bin`, `Resources/MiniLM.mlpackage`.

120–200 chunks per `SPEC.md` §6.1, **rewritten into claim form** at 200–300 tokens each. Full metadata including `certainty` and `hrv_modality`. Embeddings fp16 from a CoreML-converted MiniLM/GTE-small. Precomputed BM25 index.

This is curation labour, not code generation. **Start it early and in parallel** — it gates both A13 and A15.

**Done when:** every chunk has complete metadata; token counts verified against the tokenizer; ≥1 chunk graded `contested`.

### A13 — Retrieval
**Deps:** A12. **Out:** `Evidence/Retrieval.swift`.

Brute-force cosine via Accelerate — **no ANN index.** BM25 over the same chunks. Reciprocal rank fusion. **Hard applicability filter before fusion:** age band, sex, training status, HRV modality.

**Done when:** query "RMSSD" ranks rMSSD chunks above SDNN chunks — the test that justifies hybrid over pure dense. Under 10ms.

### A14 — Narrator
**Deps:** A7, A13. **Out:** `Evidence/Narrator.swift`. Phrases facts, never makes them.

`@Generable` typed output; free prose confined to capped string fields. Stateless single-shot sessions, no history. Token budget per `SPEC.md` §6.3, measured with `SystemLanguageModel.contextSize`.

**Scope classifier runs before retrieval** — deterministic deny-list for condition names, medications, diagnostic thresholds. Returns a fixed redirect.

**Grounding contract, in code:**
1. Extract every numeral from output; assert membership in the injected fact set. Fail → regenerate once → template fallback.
2. Every cited ID exists in the retrieved set. The model cannot name a study in free text.
3. Retrieval gate: below threshold, refuse rather than generate. The refusal path ships visibly.
4. Every generated surface has a deterministic template fallback.

**Done when:** never throws `exceededContextWindowSize` across the full findings corpus; a fuzz test with adversarial facts lets no hallucinated numeral escape; **toggling the LLM off leaves every screen functional.**

### A15 — Explainers
**Deps:** A12. **Out:** `UI/ExplainerView.swift`.

Three screens per `SPEC.md` §7.1: oxygen cascade, autonomic balance, fitness and fatigue. SVG with light Metal motion. No licensed assets, no SceneKit.

**Done when:** no claim in an explainer lacks a corresponding evidence chunk in A12. Screens 2 and 3 are **fifth in the cut order**; keep the cascade.

---

## Cut Order

1. AR(p) pre-whitening cross-check (A6)
2. Change-point detection (A7)
3. CoreLocation features (A3) — EventKit alone is enough for tier 2
4. Lag heatmap (A11)
5. Explainer screens 2 and 3 (A15)

**Never cut:** A6's AR(1) false-positive gate, A7's FDR and effect floor, A14's grounding contract.
