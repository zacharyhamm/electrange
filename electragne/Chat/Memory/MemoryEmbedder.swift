//
//  MemoryEmbedder.swift
//  electragne
//
//  Sentence embeddings for the memory graph via Apple's on-device
//  NLEmbedding: offline, free, and one model forever so stored vectors
//  never go stale. ponytail: quality is mediocre but it only nominates
//  retrieval candidates; upgrade to NLContextualEmbedding if recall
//  proves dumb in practice.
//

import Accelerate
import NaturalLanguage

/// Produces unit-length sentence vectors. A protocol so tests inject
/// fixed vectors instead of the real model.
protocol TextEmbedding {
    func vector(for text: String) -> [Float]?
}

final class NLTextEmbedder: TextEmbedding {
    private lazy var embedding = NLEmbedding.sentenceEmbedding(for: .english)

    func vector(for text: String) -> [Float]? {
        guard let raw = embedding?.vector(for: text) else { return nil }
        let floats = raw.map(Float.init)
        let norm = sqrt(vDSP.sumOfSquares(floats))
        guard norm > 0 else { return nil }
        return vDSP.divide(floats, norm)
    }
}

/// Cosine similarity of two unit vectors; 0 when either is missing or
/// they come from different models (mismatched dimensions).
nonisolated func memoryCosine(_ a: [Float], _ b: [Float]) -> Float {
    guard !a.isEmpty, a.count == b.count else { return 0 }
    return vDSP.dot(a, b)
}
