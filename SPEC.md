# Health Intelligence — Specification

**Platform:** iOS 26+, iPhone 15 Pro and later
**Posture:** on-device, no server, no account, no network calls
**Sources:** HealthKit, EventKit, CoreLocation; Garmin import optional

---

## 1. Product

Every wearable tells you *that* your HRV dropped. None tells you *why*, because none has a model of your life. This does — and refuses to speak when the evidence isn't there.

Four capabilities, ranked by what carries the product:

| | Capability | Role |
|---|---|---|
| 1 | Statistical inference with FDR control, autocorrelation correction, and evidence tiering | The product. All credibility lives here. |
| 2 | Grounded generation — the model narrates, never computes, never invents a citation | The differentiator. |
| 3 | Personal analytics surface | Makes 1 and 2 legible. |
| 4 | Metric explainers | Cold-start content. Works on day one with zero data. |

---

## 2. Objectives

| ID | Objective |
|---|---|
| E1 | Systems design under hard constraints — layered architecture, explicit contracts, versioned pure derivations |
| E2 | Statistical rigour — BH-FDR, block bootstrap, power curves, negative controls in CI |
| E3 | Applied LLM engineering — hybrid retrieval, guided generation, numeric grounding, refusal paths |
| E4 | Product judgement — a documented list of what was deliberately not built |

Secondary: answer, on real data, what actually moves the author's recovery. Requires ~90 days of history; the architecture supports it now.

Not an objective for this build: App Store release.

---

## 3. Architecture

All computation runs on the phone.

```
HealthKit ──┐
EventKit  ──┼──► Store ──► Derive ──► Analyzer ──► Findings
Location  ──┤              (measurements)  (facts)      │
Garmin    ──┘                                           ▼
(optional import)                          Retrieval ──► Narrator ──► UI
                                        (bundled corpus)  (phrasing)
```

**One rule:** epistemic status changes exactly once per boundary. `Derive` produces measurements. `Analyzer` produces facts, not conclusions. `Narrator` phrases facts, never makes them. Enforce in types, not conventions.

```
HealthIntelligence/
├── Health/
│   ├── HealthKitService.swift   — HealthKit boundary: auth, queries, units
│   ├── GarminImport.swift       — optional export → observations, dedup
│   ├── ContextService.swift     — EventKit, CoreLocation
│   └── HealthModels.swift       — app-level model, no framework dependency
├── Store/
│   └── Store.swift              — observations, constructs, findings
├── Intelligence/
│   ├── Stats.swift              — ACF, block bootstrap, BH-FDR
│   ├── Derive.swift             — baselines, TRIMP, constructs
│   └── Analyzer.swift           — scan → findings. Facts, not conclusions.
├── Evidence/
│   ├── Retrieval.swift          — BM25 + embeddings
│   └── Narrator.swift           — Foundation Models. Phrases facts, never makes them.
└── UI/
    ├── HealthIntelligenceApp.swift
    ├── DashboardViewModel.swift
    ├── DashboardView.swift
    ├── MetricDetailView.swift
    ├── FindingsView.swift
    └── ExplainerView.swift
```

Do not add folders beyond these. Split a file only past ~400 lines, and split by domain.

---

## 4. Data Sources — Tiered

The app works at tier 1. Each tier above unlocks capability and says so in the UI.

| Tier | Source | Unlocks |
|---|---|---|
| 0 | None | Explainers |
| 1 | **HealthKit** — automatic | RHR, HRV (SDNN), VO₂max, sleep stages, workouts, respiratory rate, wrist temperature. Baselines, deviations, trends, T0–T1 findings. |
| 2 | **+ EventKit, CoreLocation** — automatic, permission-gated | Meeting density, schedule shape, time away from home, timezone shift. Context associations, T2–T3 findings. |
| 3 | **+ Garmin import** — manual, optional | Body Battery, HRV status, training readiness, lactate threshold, endurance score, stress, longer history. Deeper baselines, more constructs, higher-confidence findings. |

**Never required, always rewarded.** Tier 3 is a power-user path — a one-time historical backfill, not an ongoing dependency. Nothing about it gates the core experience.

Progressive disclosure is the onboarding: each tier's screen shows what connecting it would unlock, computed from the real gates in `Analyzer`.

### 4.1 Data volume gates

| Analysis | Min days | Comfortable |
|---|---|---|
| Baseline + deviation | 21 | 60 |
| Change point | 45 | 90 |
| Two-variable correlation | 60 | 120 |
| Context association with lag | 90 | 180 |

"Not enough data yet" is a designed screen showing what unlocks and when — never an error state.

---

## 5. Statistics

Scanning 25 constructs × 20 context features × 4 lags is 2,000 tests. At α = 0.05 that yields ~100 findings from noise. Daily physiological series are also strongly autocorrelated, so naive Pearson standard errors are wrong — usually by a factor of two or three, always toward overconfidence.

| Control | Method |
|---|---|
| Multiple comparisons | Benjamini–Hochberg at q = 0.10; family defined per scan and stored with every result |
| Autocorrelation | Moving-block bootstrap, block length from the ACF. AR(p) pre-whitening as optional cross-check. |
| Effect floor | \|r\| < 0.25 never surfaces, regardless of q |
| Minimum N | Per-finding gates from §4.1, enforced and surfaced |
| Stability | Must hold in ≥2 non-overlapping windows to reach T2 |

### 5.1 Evidence tiers

Displayed in the UI. This is the honesty mechanism.

| Tier | Requirement | Phrasing |
|---|---|---|
| T0 | Descriptive | "Your HRV was 12% below baseline." |
| T1 | FDR + effect floor + autocorrelation correction | "This has co-occurred 9 times." |
| T2 | T1 + stable across two non-overlapping windows | "These tend to move together." |
| T3 | T2 + temporal precedence, no identified confounder | "This may be contributing." |
| T4 | Within-person randomised trial | "In your own test, this changed X by Y." |

Most findings stay at T1–T2 permanently. Saying so is the credibility.

T4 requires the n-of-1 experiment engine — out of scope, documented as roadmap.

### 5.2 The permanent limit

Observational data cannot separate "late meetings hurt my HRV" from "days with late meetings end with a drink." Nothing here fixes that. The tier ladder stops the system pretending otherwise, and T3 language is hedged deliberately.

---

## 6. Evidence Layer

### 6.1 Corpus

Scope: **endurance training and recovery only.** The best-evidenced corner of exercise science, and narrow scope buys retrieval precision — which matters more than breadth given the token budget.

120–200 chunks, hand-curated, shippable under their licences: position stands and guidelines (ACSM, WHO), HRV methodology consensus, HRV-guided training meta-analyses, training intensity distribution, VO₂max trainability and HIIT, sleep extension and performance, alcohol and sleep architecture, tapering and detraining, training load and injury.

Every chunk carries: population, design, N, effect size and direction, certainty grade (`high` / `moderate` / `low` / `contested`), and applicability flags — age band, sex, training status, and HRV measurement modality.

**Include contested findings, graded as contested.** ACWR is the canonical example: widely implemented in consumer products, methodologically criticised. Grading it honestly demonstrates more than citing it as settled.

### 6.2 Retrieval

Hybrid — dense embeddings conflate `RMSSD` with `SDNN`, and that distinction matters.

- Dense: CoreML MiniLM/GTE-small class, fp16
- Sparse: BM25 over the same chunks
- Fusion: reciprocal rank, then a hard applicability filter before the model sees anything

No vector database. At 200 chunks brute-force cosine via Accelerate is faster than an index build.

### 6.3 Token budget

Apple's on-device model has a 4,096-token window covering input **and** output, and throws on overflow.

| | Tokens |
|---|---|
| System instructions | 250 |
| Injected state facts | 350 |
| Retrieved chunks (3 × 250) | 750 |
| Schema overhead | 200 |
| Output reserve | 2,000 |
| Headroom | 550 |

Consequences: stateless single-shot sessions, no conversation history, chunks pre-summarised into claim form at build time, three chunks maximum. Retrieval *precision* is what matters, not recall.

### 6.4 Grounding contract

**The model does not generate findings or recommendations. It phrases a finding the analyzer produced and a recommendation the catalogue selected.** Enforced in code, not prompt text:

1. `@Generable` typed output; free prose confined to capped fields
2. Every numeral in output checked against the injected fact set — fail → regenerate once → template
3. Citations are IDs selected from a provided list; the model cannot name a study
4. Retrieval gate: below threshold, refuse rather than generate
5. Scope classifier runs *before* retrieval — deterministic deny-list for conditions, medications, diagnostic thresholds

Every generated surface has a deterministic template fallback. **The app is fully functional with the LLM disabled.**

---

## 7. Presentation

### 7.1 Metric explainers

Every headline metric gets a clean visual explanation of what it measures and what moves it. Accuracy is enforced structurally: **no claim in an explainer ships without a corresponding evidence chunk.**

Three screens: **oxygen cascade** (VO₂max — where the ceiling actually sits, from air through to mitochondria), **autonomic balance** (HRV, and what rMSSD is a proxy for), **fitness and fatigue** (the two-component adaptation model).

SVG with light Metal motion. No licensed anatomical assets, no SceneKit — the visual budget belongs in the data views.

### 7.2 Data views

- Baseline bands where the band width *is* the uncertainty
- Lag-correlation heatmap (construct × context × lag) — the most direct expression of what the app does
- Change-point timeline with annotated context
- Sleep architecture as a continuous ribbon
- Consistent confidence language: solid = measured, hatched = estimated, ghosted = insufficient data

Swift Charts covers most of it; Canvas for the heatmap and the cascade.

### 7.3 Normative comparison

VO₂max and RHR percentiles by age and sex are well established — use them.

**HRV gets no population percentile.** Published references come from short supine ECG; these values come from overnight wrist PPG. Different window, posture, modality, and artifact profile. Compare HRV only to the user's own rolling baseline.

Every normative comparison states its reference population and measurement method in the UI. If it can't be stated, it isn't shown.

---

## 8. Deliberately Not Built

| Omitted | Why |
|---|---|
| Physiological estimation from raw signal | Duplicates decades of lab-validated vendor work. Ingest converged estimates as observations. |
| n-of-1 experiment engine | Multi-week latency per question, requires user-supplied hypotheses. Roadmap. |
| Daily logging as a dependency | Unrealistic burden. Optional one-tap tags only. |
| 3D anatomy | Licensed assets are expensive; a heart beating at your RHR conveys nothing the number didn't. |
| ANN vector index | 200 chunks. Brute force is faster than the index build. |
| Cloud sync, accounts, subscription | The privacy thesis. No server also means no recurring cost. |

---

## 9. Regulatory Note

Deferred, recorded for any future public release.

FDA general-wellness enforcement discretion (revised January 2026) accommodates non-invasive physiologic estimation including HRV, provided no disease, diagnostic, or clinical-management claim is made. Patient-facing clinical decision support offering diagnostic or treatment recommendations remains regulated. EU MDR places most mobile SaMD at Class IIa.

Practical line: *"Your recovery is low, consider an easier session"* is wellness framing. *"Your HRV pattern suggests overtraining syndrome"* names a condition. The scope classifier in §6.4 enforces this from day one at no cost.

---

## 10. Build

Two documents:

- **`BUILD-APP.md`** — the app. Stands alone. Ships.
- **`BUILD-ORACLE.md`** — the Python reference implementation and validation harness. Built after, verifies the app's statistics.

Indicative pace: app surface and data plumbing first, statistics core next, evidence layer last, oracle after that. The cut order in each document is the thing to follow under pressure, not a calendar.
