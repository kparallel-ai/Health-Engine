// Retrieval.swift
// Epistemic role: selects evidence. It never interprets it. Nothing leaves here that was not
// written by a human into the bundled corpus.

import Foundation
import Accelerate
import GRDB

// MARK: - Corpus model

public enum Certainty: String, Codable, Sendable {
    case high, moderate, low, contested

    /// A contested chunk is shown *as* contested. It is not filtered out — see SPEC §6.1.
    public var display: String {
        switch self {
        case .high:      return "High certainty"
        case .moderate:  return "Moderate certainty"
        case .low:       return "Low certainty"
        case .contested: return "Contested"
        }
    }
}

public enum HRVModality: String, Codable, Sendable {
    case rmssd, sdnn, hfPower = "hf_power", lfhf = "lf_hf", none
}

public struct Applicability: Codable, Equatable, Sendable {
    public var ageBandLow: Int
    public var ageBandHigh: Int
    public var sex: BiologicalSex?
    public var trainingStatus: [String]
    public var hrvModality: HRVModality

    public func admits(age: Int, sex: BiologicalSex, trainingStatus: String,
                       modality: HRVModality?) -> Bool {
        guard age >= ageBandLow, age <= ageBandHigh else { return false }
        if let s = self.sex, s != sex, sex != .unspecified { return false }
        if !trainingStatus.isEmpty, !self.trainingStatus.isEmpty,
           !self.trainingStatus.contains(trainingStatus) { return false }
        // The one that justifies hybrid retrieval: an rMSSD claim does not transfer to SDNN.
        if let modality, self.hrvModality != .none, self.hrvModality != modality { return false }
        return true
    }
}

public struct EvidenceChunk: Codable, Identifiable, Sendable {
    public var id: String
    /// Rewritten into claim form at build time — 200–300 tokens, one assertion per chunk.
    public var claim: String
    public var citation: String
    public var population: String
    public var design: String
    public var n: Int?
    public var effectSize: String?
    public var direction: String?
    public var certainty: Certainty
    public var applicability: Applicability
    public var tokenCount: Int
}

public struct RetrievalQuery: Sendable {
    public var text: String
    public var age: Int
    public var sex: BiologicalSex
    public var trainingStatus: String
    public var modality: HRVModality?

    public init(text: String, age: Int, sex: BiologicalSex,
                trainingStatus: String = "", modality: HRVModality? = nil) {
        self.text = text; self.age = age; self.sex = sex
        self.trainingStatus = trainingStatus; self.modality = modality
    }
}

public struct RetrievalResult: Sendable {
    public let chunk: EvidenceChunk
    public let score: Double
    public let denseRank: Int?
    public let sparseRank: Int?
}

// MARK: - Retrieval

public final class Retrieval {
    /// SPEC §6.3: three chunks maximum. Precision, not recall.
    public static let maxChunks = 3
    /// Below this fused score the narrator refuses rather than generates. The refusal path ships.
    public static let scoreFloor = 0.02

    private let chunks: [EvidenceChunk]
    private let embeddings: [[Float]]          // parallel to `chunks`, L2-normalised, fp32 in memory
    private let embedder: TextEmbedder?
    private let bm25: BM25Index

    public init(chunks: [EvidenceChunk], embeddings: [[Float]], embedder: TextEmbedder?) {
        self.chunks = chunks
        self.embeddings = embeddings
        self.embedder = embedder
        self.bm25 = BM25Index(documents: chunks.map { "\($0.claim) \($0.citation) \($0.population)" })
    }

    public func retrieve(_ query: RetrievalQuery, limit: Int = Retrieval.maxChunks) -> [RetrievalResult] {
        // Hard applicability filter *before* fusion. A chunk about 20-year-old male athletes
        // does not become relevant to a 50-year-old recreational runner by ranking well.
        let admissible = chunks.indices.filter {
            chunks[$0].applicability.admits(age: query.age, sex: query.sex,
                                            trainingStatus: query.trainingStatus,
                                            modality: query.modality)
        }
        guard !admissible.isEmpty else { return [] }

        let sparseRanked = bm25.search(query.text, restrictedTo: Set(admissible))
        let denseRanked = denseSearch(query.text, restrictedTo: admissible)

        // Reciprocal rank fusion. k = 60 is the usual constant; it flattens the head so a
        // document ranked well by both signals beats one ranked first by only one.
        let k = 60.0
        var fused: [Int: Double] = [:]
        var denseRank: [Int: Int] = [:]
        var sparseRank: [Int: Int] = [:]

        for (rank, idx) in denseRanked.enumerated() {
            fused[idx, default: 0] += 1 / (k + Double(rank + 1))
            denseRank[idx] = rank + 1
        }
        for (rank, idx) in sparseRanked.enumerated() {
            fused[idx, default: 0] += 1 / (k + Double(rank + 1))
            sparseRank[idx] = rank + 1
        }

        return fused.sorted { $0.value > $1.value }.prefix(limit).map {
            RetrievalResult(chunk: chunks[$0.key], score: $0.value,
                            denseRank: denseRank[$0.key], sparseRank: sparseRank[$0.key])
        }
    }

    /// Brute-force cosine over ~200 vectors. At this size an ANN index costs more to build
    /// than the scan costs to run.
    private func denseSearch(_ text: String, restrictedTo indices: [Int]) -> [Int] {
        guard let embedder, let q = embedder.embed(text), !embeddings.isEmpty else { return [] }
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(indices.count)
        for i in indices where i < embeddings.count {
            var dot: Float = 0
            vDSP_dotpr(q, 1, embeddings[i], 1, &dot, vDSP_Length(min(q.count, embeddings[i].count)))
            scored.append((i, dot))
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Loading

    public static func loadBundled(embedder: TextEmbedder?) throws -> Retrieval {
        guard let dbURL = Bundle.main.url(forResource: "corpus", withExtension: "sqlite") else {
            return Retrieval(chunks: [], embeddings: [], embedder: nil)
        }
        let queue = try DatabaseQueue(path: dbURL.path)
        let chunks: [EvidenceChunk] = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM evidence_chunk ORDER BY id").compactMap { row in
                guard let id: String = row["id"], let claim: String = row["claim"],
                      let certRaw: String = row["certainty"],
                      let certainty = Certainty(rawValue: certRaw) else { return nil }
                let modality = HRVModality(rawValue: row["hrv_modality"] ?? "none") ?? .none
                let applicability = Applicability(
                    ageBandLow: row["age_band_low"] ?? 0,
                    ageBandHigh: row["age_band_high"] ?? 120,
                    sex: (row["sex"] as String?).flatMap(BiologicalSex.init(rawValue:)),
                    trainingStatus: (row["training_status"] as String? ?? "")
                        .split(separator: ",").map(String.init),
                    hrvModality: modality)
                return EvidenceChunk(id: id, claim: claim, citation: row["citation"] ?? "",
                                     population: row["population"] ?? "", design: row["design"] ?? "",
                                     n: row["n"], effectSize: row["effect_size"],
                                     direction: row["direction"], certainty: certainty,
                                     applicability: applicability, tokenCount: row["token_count"] ?? 0)
            }
        }

        let embeddings = loadEmbeddings(count: chunks.count)
        return Retrieval(chunks: chunks, embeddings: embeddings, embedder: embedder)
    }

    /// fp16 on disk, converted once at load. 200 × 384 × 2 bytes is 150 KB; keeping it resident
    /// is cheaper than any lazy scheme.
    static func loadEmbeddings(count: Int) -> [[Float]] {
        guard count > 0,
              let url = Bundle.main.url(forResource: "embeddings", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return [] }

        let halfCount = data.count / MemoryLayout<UInt16>.size
        guard halfCount % count == 0 else { return [] }
        let dim = halfCount / count

        let halves: [Float16] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float16.self))
        }
        return (0..<count).map { i in
            var vector = (0..<dim).map { Float(halves[i * dim + $0]) }
            var norm: Float = 0
            vDSP_svesq(vector, 1, &norm, vDSP_Length(dim))
            norm = norm.squareRoot()
            if norm > 0 { var d = norm; vDSP_vsdiv(vector, 1, &d, &vector, 1, vDSP_Length(dim)) }
            return vector
        }
    }
}

// MARK: - BM25

/// Sparse retrieval over the same chunks. This is what makes "RMSSD" rank rMSSD chunks above
/// SDNN chunks — a dense model happily conflates them, and the distinction is the whole point.
public struct BM25Index {
    private let k1: Double = 1.2
    private let b: Double = 0.75
    private let docTokens: [[String]]
    private let docLengths: [Double]
    private let averageLength: Double
    private let documentFrequency: [String: Int]

    public init(documents: [String]) {
        self.docTokens = documents.map(BM25Index.tokenise)
        self.docLengths = docTokens.map { Double($0.count) }
        self.averageLength = docLengths.isEmpty ? 1 : docLengths.reduce(0, +) / Double(docLengths.count)
        var df: [String: Int] = [:]
        for tokens in docTokens {
            for term in Set(tokens) { df[term, default: 0] += 1 }
        }
        self.documentFrequency = df
    }

    public func search(_ query: String, restrictedTo allowed: Set<Int>) -> [Int] {
        let terms = BM25Index.tokenise(query)
        guard !terms.isEmpty else { return [] }
        let n = Double(docTokens.count)

        var scores: [(Int, Double)] = []
        for i in docTokens.indices where allowed.contains(i) {
            var counts: [String: Int] = [:]
            for t in docTokens[i] { counts[t, default: 0] += 1 }

            var score = 0.0
            for term in terms {
                guard let f = counts[term], f > 0 else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log((n - df + 0.5) / (df + 0.5) + 1)
                let tf = Double(f)
                score += idf * (tf * (k1 + 1)) /
                         (tf + k1 * (1 - b + b * docLengths[i] / averageLength))
            }
            if score > 0 { scores.append((i, score)) }
        }
        return scores.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Lowercase, split on non-alphanumerics, keep digits. `rMSSD` and `SDNN` survive as
    /// distinct tokens; no stemming, because stemming is what merges them.
    static func tokenise(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count > 1 }
    }
}

// MARK: - Embedder

/// Thin wrapper over the CoreML MiniLM/GTE-small package. Optional: with no model bundled,
/// retrieval degrades to BM25 alone rather than failing.
public protocol TextEmbedder {
    func embed(_ text: String) -> [Float]?
}
