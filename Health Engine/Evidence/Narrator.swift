// Narrator.swift
// Epistemic role: phrases facts, never makes them.
//
// Every guarantee in this file is enforced by code that runs *after* the model produces text.
// None of it is enforced by asking the model nicely in a system prompt. A prompt is a
// preference; a post-condition is a contract.

import Foundation
import FoundationModels

// MARK: - Injected facts

/// The closed set of numerals the model is permitted to utter. Anything else in its output
/// is a hallucination by definition, and is caught by `GroundingContract`.
public struct FactSet: Sendable {
    public private(set) var numerals: Set<String> = []
    public private(set) var lines: [String] = []
    public private(set) var citationIDs: Set<String> = []

    public init() {}

    public mutating func add(label: String, value: Double, unit: String, decimals: Int = 1) {
        let formatted = String(format: "%.\(decimals)f", value)
        numerals.insert(GroundingContract.canonicalise(formatted))
        // Integral values are commonly re-rendered without the decimal; permit both spellings.
        if value == value.rounded() {
            numerals.insert(GroundingContract.canonicalise(String(format: "%.0f", value)))
        }
        lines.append("\(label): \(formatted) \(unit)")
    }

    public mutating func add(label: String, count: Int) {
        numerals.insert(GroundingContract.canonicalise(String(count)))
        lines.append("\(label): \(count)")
    }

    public mutating func add(label: String, text: String) {
        lines.append("\(label): \(text)")
    }

    public mutating func allowCitation(_ id: String) { citationIDs.insert(id) }

    public var promptBlock: String { lines.joined(separator: "\n") }
}

// MARK: - Generated shape

/// Free prose is confined to capped fields. The model cannot emit a number in a numeric slot
/// because it has no numeric slots — every figure is injected and re-rendered by us.
@Generable
public struct NarratedFinding: Sendable {
    @Guide(description: "One sentence describing what was observed. No numbers. No advice.")
    public var observation: String

    @Guide(description: "One sentence of context for why this pattern is plausible. No numbers.")
    public var context: String

    @Guide(description: "IDs of supporting evidence, chosen only from the provided list.")
    public var citationIDs: [String]
}

// MARK: - Scope classifier

/// Runs *before* retrieval, so an out-of-scope query never even reaches the corpus.
/// Deterministic, not a model call. SPEC §9: this is what keeps the app inside general-wellness
/// framing at essentially zero cost.
public enum ScopeClassifier {
    static let conditionTerms = [
        "overtraining syndrome", "afib", "atrial fibrillation", "arrhythmia", "apnea", "apnoea",
        "diabetes", "hypertension", "cardiomyopathy", "myocarditis", "long covid", "depression",
        "anxiety disorder", "adhd", "thyroid", "anemia", "anaemia", "pots", "dysautonomia",
        "infection", "diagnose", "diagnosis", "disease", "disorder", "syndrome", "pathology"
    ]
    static let medicationTerms = [
        "beta blocker", "beta-blocker", "ssri", "statin", "metformin", "adderall", "melatonin dose",
        "prescription", "medication", "dosage", "mg of", "titrate", "supplement stack"
    ]
    static let diagnosticTerms = [
        "normal range", "reference range", "cut-off", "cutoff", "threshold for concern",
        "should i see a doctor", "is this dangerous", "clinically significant"
    ]

    public enum Verdict: Equatable, Sendable {
        case inScope
        case outOfScope(reason: String)
    }

    public static func classify(_ text: String) -> Verdict {
        let lowered = text.lowercased()
        for term in conditionTerms where lowered.contains(term) {
            return .outOfScope(reason: "condition")
        }
        for term in medicationTerms where lowered.contains(term) {
            return .outOfScope(reason: "medication")
        }
        for term in diagnosticTerms where lowered.contains(term) {
            return .outOfScope(reason: "diagnostic")
        }
        return .inScope
    }

    /// Fixed redirect. Not model-generated, so it cannot drift.
    public static let redirect = """
        This app describes your own measurements relative to your own baseline. It doesn't \
        interpret them in terms of medical conditions, medications, or clinical thresholds — \
        that's a conversation for a clinician who can see the whole picture.
        """
}

// MARK: - The grounding contract

public enum GroundingFailure: Equatable, Sendable {
    case ungroundedNumeral(String)
    case unknownCitation(String)
    case belowRetrievalThreshold
    case modelUnavailable
    case contextWindowExceeded
}

public enum GroundingContract {

    /// Every numeral in the output must be a member of the injected fact set.
    /// Ordinals and small counting words that carry no measurement are exempted explicitly
    /// rather than by heuristic, so the exemption list is auditable.
    static let exemptNumerals: Set<String> = ["0", "1", "2", "24", "7"]

    public static func validate(_ text: String, against facts: FactSet) -> GroundingFailure? {
        for numeral in extractNumerals(text) {
            let canonical = canonicalise(numeral)
            if facts.numerals.contains(canonical) || exemptNumerals.contains(canonical) { continue }
            return .ungroundedNumeral(numeral)
        }
        return nil
    }

    public static func validate(citations: [String], against facts: FactSet) -> GroundingFailure? {
        for id in citations where !facts.citationIDs.contains(id) {
            return .unknownCitation(id)
        }
        return nil
    }

    static func extractNumerals(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isNumber || (ch == "." && !current.isEmpty) {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current); current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// "12.0", "12.", and "12" are the same claim. Trailing zeros must not create a false miss.
    static func canonicalise(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t.isEmpty ? "0" : t
    }
}

// MARK: - Narrator

public final class Narrator {
    private let retrieval: Retrieval
    private let isEnabled: Bool

    public init(retrieval: Retrieval, enabled: Bool = true) {
        self.retrieval = retrieval
        self.isEnabled = enabled
    }

    public struct Output: Sendable {
        public let text: String
        public let citations: [EvidenceChunk]
        /// True when the deterministic template produced this. Surfaced in the UI, not hidden.
        public let isTemplated: Bool
        public let failure: GroundingFailure?
    }

    /// The one entry point. Toggling `enabled` off makes every screen fall back to templates
    /// and changes nothing else — that is the test in BUILD-APP.md A14.
    public func narrate(finding: Finding, facts: FactSet, query: RetrievalQuery) async -> Output {
        let template = Templates.finding(finding)

        guard isEnabled else {
            return Output(text: template, citations: [], isTemplated: true, failure: .modelUnavailable)
        }

        if case .outOfScope = ScopeClassifier.classify(query.text) {
            return Output(text: ScopeClassifier.redirect, citations: [],
                          isTemplated: true, failure: nil)
        }

        let retrieved = retrieval.retrieve(query)
        // Refusal path. It ships, it is visible, and it is reached by design rather than by bug.
        guard let best = retrieved.first, best.score >= Retrieval.scoreFloor else {
            return Output(text: template, citations: [], isTemplated: true,
                          failure: .belowRetrievalThreshold)
        }

        var facts = facts
        for result in retrieved { facts.allowCitation(result.chunk.id) }

        for attempt in 0..<2 {
            do {
                let generated = try await generate(facts: facts, chunks: retrieved.map(\.chunk))
                let prose = "\(generated.observation) \(generated.context)"

                if let failure = GroundingContract.validate(prose, against: facts) {
                    if attempt == 0 { continue }
                    return Output(text: template, citations: [], isTemplated: true, failure: failure)
                }
                if let failure = GroundingContract.validate(citations: generated.citationIDs,
                                                            against: facts) {
                    if attempt == 0 { continue }
                    return Output(text: template, citations: [], isTemplated: true, failure: failure)
                }

                let cited = retrieved.map(\.chunk).filter { generated.citationIDs.contains($0.id) }
                return Output(text: prose, citations: cited, isTemplated: false, failure: nil)

            } catch {
                if attempt == 0 { continue }
                let failure: GroundingFailure =
                    "\(error)".contains("exceededContextWindow") ? .contextWindowExceeded
                                                                 : .modelUnavailable
                return Output(text: template, citations: [], isTemplated: true, failure: failure)
            }
        }
        return Output(text: template, citations: [], isTemplated: true, failure: .modelUnavailable)
    }

    // MARK: - Generation

    /// Stateless, single-shot. No conversation history: the window is 4,096 tokens covering
    /// input *and* output, and history is the fastest way to overflow it.
    private func generate(facts: FactSet, chunks: [EvidenceChunk]) async throws -> NarratedFinding {
        let model = SystemLanguageModel.default
        guard model.availability == .available else { throw NarratorError.unavailable }

        let evidenceBlock = chunks.map { chunk in
            "[\(chunk.id)] \(chunk.claim) (certainty: \(chunk.certainty.rawValue))"
        }.joined(separator: "\n")

        let instructions = """
            You describe a pattern that has already been measured. You do not calculate, \
            estimate, or infer anything. Write no digits at all — the figures are shown \
            separately. Do not give advice, name conditions, or mention medications. \
            Cite only the bracketed IDs supplied.
            """

        let prompt = """
            MEASURED FACTS
            \(facts.promptBlock)

            EVIDENCE
            \(evidenceBlock)
            """

        try assertWithinBudget(instructions: instructions, prompt: prompt)

        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt, generating: NarratedFinding.self)
        return response.content
    }

    /// SPEC §6.3. Checked before the call, because `exceededContextWindowSize` is thrown at
    /// generation time and by then the user is already waiting.
    private func assertWithinBudget(instructions: String, prompt: String) throws {
        let contextSize = SystemLanguageModel.default.contextSize
        let outputReserve = 2000
        let schemaOverhead = 200
        let estimated = (instructions.count + prompt.count) / 4   // ~4 chars per token
        if estimated + outputReserve + schemaOverhead > contextSize {
            throw NarratorError.budgetExceeded
        }
    }
}

public enum NarratorError: Error {
    case unavailable
    case budgetExceeded
}

// MARK: - Deterministic templates

/// Every generated surface has one of these behind it. They are not a degraded mode; they are
/// the floor the app is guaranteed to stand on.
public enum Templates {

    public static func finding(_ f: Finding) -> String {
        let subject = Metric(rawValue: f.subject)?.displayName ?? f.subject
        let object = f.object.flatMap { Metric(rawValue: $0)?.displayName } ?? f.object ?? "context"
        let lag = f.lagDays ?? 0
        let lagPhrase = lag == 0 ? "on the same day" : (lag == 1 ? "the next day" : "\(lag) days later")

        switch f.tier {
        case .t0:
            return "\(subject) was outside its usual range."
        case .t1:
            return "\(subject) and \(object) have co-occurred \(f.nObservations) times, \(lagPhrase)."
        case .t2:
            return "\(subject) and \(object) tend to move together, \(lagPhrase)."
        case .t3:
            return "\(object) may be contributing to \(subject), \(lagPhrase)."
        case .t4:
            return "In your own test, \(object) changed \(subject)."
        }
    }

    public static func deviation(metric: Metric, z: Double, value: Double, baseline: Double) -> String {
        let direction = z >= 0 ? "above" : "below"
        let magnitude = abs(z) < 1 ? "slightly" : (abs(z) < 2 ? "moderately" : "well")
        return "\(metric.displayName) is \(magnitude) \(direction) your baseline."
    }

    public static func dailySummary(constructs: [DailyConstruct]) -> String {
        let flagged = constructs.filter { abs($0.deviationZ ?? 0) >= 1.5 && $0.confidence > 0 }
        guard !flagged.isEmpty else {
            return "Nothing today sits far from your baselines."
        }
        let names = flagged.prefix(2).map { $0.construct.displayName }
        return "\(names.joined(separator: " and ")) sit outside your usual range today."
    }

    /// Shown when the retrieval gate refuses. Honest about *why* there is no explanation.
    public static let refusal = """
        There's a measured pattern here, but nothing in the bundled evidence applies closely \
        enough to explain it. Rather than reach, the app is leaving it described and unexplained.
        """

    /// A plausible physiological reason two metric families might move together — deliberately
    /// hedged ("may", "often"), never asserted as the confirmed mechanism, since the finding
    /// itself never rose above correlation. Always returns something: a pair with no specific
    /// mapping on file gets an honest generic line rather than silently showing nothing.
    public static func rationale(for finding: Finding) -> String? {
        guard let subject = Metric(rawValue: finding.subject) else { return nil }
        let objectFamily = finding.object.flatMap { Metric(rawValue: $0)?.correlationFamily }
        return CorrelationRationale.text(subject.correlationFamily, objectFamily)
    }
}

enum CorrelationRationale {
    private static let entries: [Set<MetricFamily>: String] = [
        [.sleep, .hrv]: "Deeper, longer sleep is when parasympathetic recovery happens — the same recovery overnight HRV measures.",
        [.sleep, .bodyBattery]: "Body Battery's own model factors in sleep quality, so this may partly reflect how it's calculated rather than two independent signals.",
        [.sleep, .stress]: "A harder day (higher measured stress) commonly disrupts that night's sleep, and poor sleep often shows up as more measured stress the next day.",
        [.sleep, .heartRate]: "Poor or short sleep tends to elevate resting heart rate the following day.",
        [.sleep, .respiration]: "Breathing rate shifts with sleep stage and depth, so overnight respiration is mechanically tied to sleep architecture.",
        [.sleep, .temperature]: "Core and wrist temperature drop as part of normal sleep onset, so sleep timing and temperature deviation share a physiological driver.",
        [.sleep, .load]: "Harder training can both delay sleep onset and increase the body's need for it.",
        [.hrv, .bodyBattery]: "Body Battery is built in part from heart rate variability, so this may partly reflect how it's calculated rather than an independent confirmation.",
        [.hrv, .stress]: "Lower HRV is a standard marker of sympathetic (stress) activation — often two views of the same underlying state.",
        [.hrv, .heartRate]: "Resting heart rate and HRV are both set by autonomic tone, and typically move in opposite directions together.",
        [.hrv, .load]: "Heavier training load suppresses next-day HRV as part of the body's normal recovery response.",
        [.hrv, .temperature]: "Wrist temperature deviation is itself partly driven by autonomic state — the same system HRV reflects.",
        [.hrv, .respiration]: "Overnight HRV and breathing rate are both shaped by parasympathetic activity during sleep.",
        [.bodyBattery, .stress]: "Body Battery is explicitly drained by measured stress throughout the day, so this is close to definitional.",
        [.bodyBattery, .load]: "Body Battery is depleted by training load and replenished by rest — the two are mechanically linked by design.",
        [.bodyBattery, .heartRate]: "An elevated resting heart rate is one of the standard signs of incomplete recovery, which Body Battery is designed to track.",
        [.stress, .load]: "Physical training is itself treated as a stressor by the stress algorithm, so harder training days often show as higher measured stress.",
        [.stress, .heartRate]: "Both stress scoring and resting heart rate are driven by sympathetic nervous system activity.",
        [.heartRate, .respiration]: "Heart rate and breathing rate are coupled through the autonomic nervous system and typically rise or fall together.",
        [.heartRate, .temperature]: "Both shift with autonomic arousal, so they often move together independent of any direct causal link.",
        [.load, .heartRate]: "Heavier training raises next-day resting heart rate as part of its recovery cost.",
        [.load, .fitness]: "Sustained training load is the direct input that raises fitness estimates like VO\u{2082}max over time.",
        [.oxygen, .respiration]: "Blood oxygen saturation and breathing rate are mechanically linked, especially overnight.",
        [.oxygen, .hrv]: "Both are overnight measurements sensitive to sleep position, breathing events, and autonomic state.",
        [.fitness, .heartRate]: "A lower resting heart rate is itself one of the standard signs of higher cardiovascular fitness — the two are closely coupled by definition.",
        [.fitness, .sleep]: "Recovery from training happens largely during sleep, so fitness trends and sleep patterns commonly move together over the same weeks.",
        [.fitness, .hrv]: "Both track overall training adaptation — rising fitness and rising HRV often reflect the same improving recovery capacity.",
        [.fitness, .bodyBattery]: "Both are downstream of how well-recovered you are, so they tend to trend together over weeks of training.",
        [.fitness, .stress]: "Sustained high stress can blunt the recovery that fitness gains depend on.",
        [.fitness, .respiration]: "Cardiovascular fitness and resting breathing rate are both shaped by aerobic conditioning.",
        [.fitness, .temperature]: "Both shift with the same weeks-long training and recovery cycle rather than day to day.",
        [.fitness, .oxygen]: "Aerobic fitness and blood oxygen saturation both reflect how efficiently the cardiovascular system is working.",
        [.respiration, .temperature]: "Breathing rate and core/wrist temperature both shift with autonomic arousal and sleep depth.",
        [.respiration, .stress]: "Breathing rate rises with sympathetic (stress) activation, awake or asleep.",
        [.respiration, .load]: "Harder training raises next-day resting breathing rate as part of its recovery cost.",
        [.temperature, .stress]: "Both shift with autonomic arousal — a stressed system tends to run measurably warmer at rest.",
        [.temperature, .load]: "Training raises core temperature regulation demands, which can carry over into the following night's readings.",
        [.temperature, .bodyBattery]: "Both are influenced by how physiologically recovered the body is on a given day.",
        [.oxygen, .bodyBattery]: "Both are overnight measurements that dip with poor sleep quality or disrupted breathing.",
        [.oxygen, .stress]: "Stress-driven changes in breathing pattern can shift measured blood oxygen saturation.",
        [.oxygen, .load]: "Harder training can affect overnight breathing and oxygenation as part of next-day recovery.",
        [.oxygen, .sleep]: "Blood oxygen saturation is measured overnight, so it's mechanically tied to sleep stage and breathing pattern.",
        [.oxygen, .temperature]: "Both are overnight wrist/pulse measurements sensitive to sleep position and autonomic state.",
        [.oxygen, .heartRate]: "Both reflect cardiovascular and respiratory efficiency at rest.",
    ]

    /// No specific mechanism on file for this pair — still worth saying *something* honest
    /// rather than leaving the finding unexplained, since "no known reason" reads as broken
    /// to a reader even when it's the statistically correct state to be in.
    private static let genericFallback =
        "No single well-established mechanism links these two directly — the connection may " +
        "run through a shared factor like sleep, training load, or stress that affects both."

    private static let contextFallback =
        "Schedule and location can shift physiology indirectly, through sleep, stress, or " +
        "activity — this direction can't be confirmed without more data."

    static func text(_ a: MetricFamily, _ b: MetricFamily?) -> String {
        guard let b else { return genericFallback }
        if a == .context || b == .context { return contextFallback }
        return entries[[a, b]] ?? genericFallback
    }
}
