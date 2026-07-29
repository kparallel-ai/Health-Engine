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
}
