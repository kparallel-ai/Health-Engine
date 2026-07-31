<p align="center">
  <img src="health-engine-app-icon-1024.png" width="120" alt="Health Engine icon" />
</p>

<h1 align="center">Health Engine</h1>

<p align="center">
  <b>Every wearable tells you <i>that</i> your HRV dropped. This tells you <i>why</i> —<br/>
  or says nothing at all when the evidence isn't there.</b>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS-black?logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-orange?logo=swift&logoColor=white">
  <img alt="On-device" src="https://img.shields.io/badge/on--device-no%20server%2C%20no%20account-blue">
  <img alt="Status" src="https://img.shields.io/badge/status-personal%20project-lightgrey">
</p>

---

Health Engine is an iOS app that turns HealthKit, Garmin, calendar, and location data into **statistically defensible statements about your own physiology** — not another dashboard of numbers you have to interpret yourself, and not another wellness app that turns every correlation into a headline.

It runs entirely on your phone. No server, no account, no network call, ever.

## The idea

Most health apps have exactly one epistemic mode: confident. Steps go up, a badge appears. HRV dips, a red banner tells you you're "overtraining." None of them separate *what the data shows* from *what the app is willing to claim* — and rolling that up into a global "Recovery Score" is exactly the intellectually dishonest step most other tools take.

Health Engine refuses to. Every statement it makes is tagged with an **evidence tier**, and the tier is the honesty mechanism, not a footnote:

| Tier | What it takes to get there | How it's phrased |
|---|---|---|
| **T0** | A single day outside your rolling baseline | *"Your HRV was 12% below baseline."* |
| **T1** | FDR-corrected, effect-size floor, autocorrelation-adjusted | *"These have co-occurred 9 times."* |
| **T2** | T1 + stable across two non-overlapping time windows | *"These tend to move together."* |
| **T3** | T2 + temporal precedence, no identified confounder | *"This may be contributing."* |
| **T4** | A within-person randomized trial | *"In your own test, this changed X by Y."* |

Most findings live at T1–T2, permanently. Saying so — instead of quietly rounding up to causation — is the entire product.

## What it actually does

- **Derives real physiological constructs** from raw HealthKit/Garmin observations — resting heart rate, HRV (SDNN/rMSSD), VO₂max, sleep architecture, Body Battery, training strain, respiratory rate, wrist temperature deviation — each with a rolling baseline and a deviation shown as a percentage, not an opaque z-score.
- **Tests every metric against every other metric** (and against calendar/location context, once you grant it) with a real statistical pipeline: moving-block bootstrap for autocorrelated daily series, Benjamini–Hochberg correction across the whole family of hypotheses, a hard `|r| < 0.25` effect floor, and a stability check across split time windows before anything is allowed to look causal.
- **Explains itself.** Every surfaced finding ships with a plain-language, hedged physiological rationale ("Body Battery is explicitly drained by measured stress, so this is close to definitional") — never invented, always keyed to an actual mechanism or an honest "no single mechanism is established here."
- **Shows its work.** Every finding gets a small trend chart — both metrics, smoothed, real calendar days — so "these move together" is something you can see, not just a number you have to trust.
- **Costs you nothing to try.** The heavy statistical scan is a deliberate, disclosed, user-initiated action — not something that silently chews CPU the moment you open the app.
- **Never overclaims.** HRV gets no population percentile (wrist PPG isn't supine ECG — comparing them would be a category error). Observational findings are permanently labeled as unable to separate direct effects from confounders. An on-device LLM *narrates* findings the statistics layer already produced — it never computes a number or invents a citation, and the app is fully functional with it turned off.

## Architecture

```
HealthKit ──┐
EventKit  ──┼──► Store ──► Derive ──► Analyzer ──► Findings
Location  ──┤              (measurements)  (facts)      │
Garmin    ──┘                                           ▼
(optional import)                          Retrieval ──► Narrator ──► UI
                                        (bundled corpus)  (phrasing)
```

One rule holds the whole thing together: **epistemic status changes exactly once per boundary.** `Derive` produces measurements. `Analyzer` produces facts — never conclusions. `Narrator` phrases facts — never makes them. It's enforced in the types, not left to convention.

```
Health Engine/
├── Health/            HealthKit, Garmin import, EventKit/CoreLocation, the app's own vocabulary
├── Store/              SQLite (GRDB) persistence + the recompute/scan orchestrator
├── Intelligence/       Block bootstrap, BH-FDR, baselines, the association scanner
├── Evidence/           Retrieval over a hand-curated corpus + grounded on-device narration
└── UI/                 SwiftUI — Today, Findings, Learn
```

## Data, tiered — nothing is ever required

| Tier | Source | Unlocks |
|---|---|---|
| 1 | **HealthKit** *(automatic)* | Resting HR, HRV, VO₂max, sleep stages, respiratory rate, wrist temperature — baselines, deviations, trends |
| 2 | **+ Calendar / Location** *(permission-gated)* | Meeting density, schedule shape, time away from home — context associations |
| 3 | **+ Garmin import** *(manual, optional, one-time)* | Body Battery, HRV status, training load, stress, longer history |

Every tier says exactly what connecting it would unlock, computed from the app's own real gates — never a guess, never a growth-hack dark pattern.

## Stack

- **SwiftUI** — no UIKit, no Storyboards
- **GRDB** — the entire store is one SQLite file, on-device, never synced
- **Swift Charts** — trend lines, distributions, baseline bands
- **ZIPFoundation** — parses Garmin's actual GDPR export format, not a simplified stand-in
- **Foundation Models** — on-device LLM narration, grounded and refusal-capable, zero required

## Building it

```bash
git clone https://github.com/kparallel-ai/Health-Engine.git
cd Health-Engine
open "Health Engine.xcodeproj"
```

Free Apple Developer account is enough — HealthKit doesn't require a paid enrollment, it just needs the capability registered correctly. Build and run on a physical device to get real HealthKit data; the simulator works but has nothing to read.

## What's deliberately not here

| Omitted | Why |
|---|---|
| Physiological estimation from raw signal | Duplicates decades of lab-validated vendor work — ingest converged estimates instead |
| An n-of-1 experiment engine (true T4 evidence) | Multi-week latency per question, needs a user-supplied hypothesis — roadmap, not v1 |
| Daily logging as a dependency | Unrealistic burden; optional one-tap tags only |
| Cloud sync, accounts, subscriptions | The privacy thesis *is* the product. No server also means no recurring cost. |

See `SPEC.md` for the full specification this app was built against.

---

<p align="center"><i>Built to say "I don't know" more often than any wellness app you've used — on purpose.</i></p>
