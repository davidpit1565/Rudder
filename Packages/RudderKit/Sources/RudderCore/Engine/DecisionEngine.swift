import Foundation

public struct ScoredOption: Hashable, Codable, Sendable, Identifiable {
    public var id: String { optionID }
    public let optionID: String
    public let name: String
    /// 0...1. RUDDER's assessment based on the available information — not an objective fact.
    public let score: Double
    /// criterionID -> weighted contribution to `score`.
    public let contributions: [String: Double]

    public init(optionID: String, name: String, score: Double, contributions: [String: Double]) {
        self.optionID = optionID
        self.name = name
        self.score = score
        self.contributions = contributions
    }
}

public struct EliminatedOption: Hashable, Codable, Sendable, Identifiable {
    public var id: String { optionID }
    public let optionID: String
    public let name: String
    public let failedConstraints: [String]

    public init(optionID: String, name: String, failedConstraints: [String]) {
        self.optionID = optionID
        self.name = name
        self.failedConstraints = failedConstraints
    }
}

public struct Evaluation: Hashable, Codable, Sendable {
    public var ranking: [ScoredOption]
    public var eliminated: [EliminatedOption]

    public var winner: ScoredOption? { ranking.first }
    public var runnerUp: ScoredOption? { ranking.count > 1 ? ranking[1] : nil }

    /// Distance between the best and the second best option.
    public var margin: Double {
        guard let winner, let runnerUp else { return 1 }
        return winner.score - runnerUp.score
    }
}

/// Weighted additive model over normalised criteria.
///
/// The complexity lives here; the user never sees weights, normalisation or MCDA vocabulary.
public enum DecisionEngine {

    /// Normalises raw weights so they sum to 1. Criteria with no weight at all are treated as equal.
    public static func normalisedWeights(for criteria: [Criterion]) -> [String: Double] {
        guard !criteria.isEmpty else { return [:] }
        let total = criteria.reduce(0) { $0 + max(0, $1.weight) }
        guard total > 0 else {
            let equal = 1.0 / Double(criteria.count)
            return Dictionary(uniqueKeysWithValues: criteria.map { ($0.id, equal) })
        }
        return Dictionary(uniqueKeysWithValues: criteria.map { ($0.id, max(0, $0.weight) / total) })
    }

    public static func evaluate(
        options: [DecisionOption],
        criteria: [Criterion],
        weightOverrides: [String: Double]? = nil
    ) -> Evaluation {
        let weights = weightOverrides ?? normalisedWeights(for: criteria)
        let eliminated = options.filter(\.isEliminated).map {
            EliminatedOption(optionID: $0.id, name: $0.name, failedConstraints: $0.failedConstraints)
        }
        let viable = options.filter { !$0.isEliminated }

        var scored: [ScoredOption] = viable.map { option in
            var contributions: [String: Double] = [:]
            var total = 0.0
            for criterion in criteria {
                let weight = weights[criterion.id] ?? 0
                let contribution = weight * option.score(for: criterion.id)
                contributions[criterion.id] = contribution
                total += contribution
            }
            return ScoredOption(
                optionID: option.id,
                name: option.name,
                score: total,
                contributions: contributions
            )
        }

        // Deterministic ordering: score first, then name, then id, so identical
        // inputs always produce identical output (stability testing depends on this).
        scored.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.optionID < rhs.optionID
        }

        return Evaluation(ranking: scored, eliminated: eliminated)
    }

    /// The honest "you're giving up X to get Y" for the winner against the closest alternative.
    public static func tradeOffs(
        winner: DecisionOption,
        runnerUp: DecisionOption?,
        criteria: [Criterion],
        threshold: Double = 0.1,
        limit: Int = 3
    ) -> [TradeOff] {
        guard let runnerUp else { return [] }
        let weights = normalisedWeights(for: criteria)

        let gains = criteria
            .filter { winner.score(for: $0.id) - runnerUp.score(for: $0.id) > threshold }
            .sorted { (weights[$0.id] ?? 0) > (weights[$1.id] ?? 0) }
        let losses = criteria
            .filter { runnerUp.score(for: $0.id) - winner.score(for: $0.id) > threshold }
            .sorted { (weights[$0.id] ?? 0) > (weights[$1.id] ?? 0) }

        guard !losses.isEmpty else { return [] }

        var result: [TradeOff] = []
        for (index, loss) in losses.prefix(limit).enumerated() {
            let gain = index < gains.count ? gains[index] : gains.first
            result.append(
                TradeOff(
                    gaining: gain?.name ?? winner.name,
                    givingUp: "\(loss.name) — \(runnerUp.name) is better here"
                )
            )
        }
        return result
    }
}
