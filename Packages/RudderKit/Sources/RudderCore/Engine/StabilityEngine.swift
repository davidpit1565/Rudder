import Foundation

/// One reasonable variation of the world, and who wins in it.
public struct StabilityScenario: Hashable, Codable, Sendable, Identifiable {
    public var id: String { label }
    /// Human-readable, user-facing description of the variation.
    public let label: String
    public let winnerOptionID: String?
    public let winnerName: String?
    /// How far this scenario is from the base case, 0...1. Smaller means more likely.
    public let distance: Double

    public init(label: String, winnerOptionID: String?, winnerName: String?, distance: Double) {
        self.label = label
        self.winnerOptionID = winnerOptionID
        self.winnerName = winnerName
        self.distance = distance
    }
}

public struct StabilityReport: Hashable, Codable, Sendable {
    public let baseWinnerOptionID: String?
    /// Fraction of reasonable variations in which the base winner stays ahead, 0...1.
    public let holdRate: Double
    public let margin: Double
    public let strength: DecisionStrength
    /// Variations that flip the recommendation, nearest-first.
    public let flips: [StabilityScenario]
    public let scenarioCount: Int

    public init(
        baseWinnerOptionID: String?,
        holdRate: Double,
        margin: Double,
        strength: DecisionStrength,
        flips: [StabilityScenario],
        scenarioCount: Int
    ) {
        self.baseWinnerOptionID = baseWinnerOptionID
        self.holdRate = holdRate
        self.margin = margin
        self.strength = strength
        self.flips = flips
        self.scenarioCount = scenarioCount
    }

    public static let empty = StabilityReport(
        baseWinnerOptionID: nil,
        holdRate: 0,
        margin: 0,
        strength: .unclear,
        flips: [],
        scenarioCount: 0
    )

    /// The single most useful "what could make me wrong" line, or nil when nothing reasonable flips it.
    public var nearestFlip: StabilityScenario? { flips.first }
}

/// Runs the recommendation against reasonable variations in priorities, weights and
/// assumptions. This — not a model's self-reported confidence — decides Strong /
/// Moderate / Unclear.
public enum StabilityEngine {

    public struct Thresholds: Sendable {
        public var strongHoldRate: Double
        public var moderateHoldRate: Double
        /// Below this margin in the base case the winner is treated as a coin flip.
        public var minimumMargin: Double

        public init(strongHoldRate: Double = 0.85, moderateHoldRate: Double = 0.55, minimumMargin: Double = 0.015) {
            self.strongHoldRate = strongHoldRate
            self.moderateHoldRate = moderateHoldRate
            self.minimumMargin = minimumMargin
        }

        public static let `default` = Thresholds()
    }

    public static func analyse(
        options: [DecisionOption],
        criteria: [Criterion],
        thresholds: Thresholds = .default
    ) -> StabilityReport {
        let viable = options.filter { !$0.isEliminated }
        guard !viable.isEmpty, !criteria.isEmpty else { return .empty }

        let base = DecisionEngine.evaluate(options: options, criteria: criteria)
        guard let baseWinner = base.winner else { return .empty }

        // A single viable option is not a judgement call — it is the only choice.
        guard viable.count > 1 else {
            return StabilityReport(
                baseWinnerOptionID: baseWinner.optionID,
                holdRate: 1,
                margin: 1,
                strength: .strong,
                flips: [],
                scenarioCount: 1
            )
        }

        var scenarios: [StabilityScenario] = []
        let baseWeights = DecisionEngine.normalisedWeights(for: criteria)

        func record(_ label: String, distance: Double, options: [DecisionOption], criteria: [Criterion], weights: [String: Double]?) {
            let evaluation = DecisionEngine.evaluate(options: options, criteria: criteria, weightOverrides: weights)
            scenarios.append(
                StabilityScenario(
                    label: label,
                    winnerOptionID: evaluation.winner?.optionID,
                    winnerName: evaluation.winner?.name,
                    distance: distance
                )
            )
        }

        // 1. Priority variations: each criterion becomes noticeably more, then less, important.
        for criterion in criteria {
            for (multiplier, wording, distance) in [(1.6, "matters more", 0.3), (0.5, "matters less", 0.35)] {
                var adjusted = baseWeights
                adjusted[criterion.id] = (baseWeights[criterion.id] ?? 0) * multiplier
                record(
                    "If \(criterion.name.lowercased()) \(wording) to you",
                    distance: distance,
                    options: options,
                    criteria: criteria,
                    weights: renormalise(adjusted)
                )
            }
        }

        // 2. Equal priorities: the user has no strong ordering at all.
        if criteria.count > 1 {
            let equal = 1.0 / Double(criteria.count)
            record(
                "If everything mattered equally",
                distance: 0.5,
                options: options,
                criteria: criteria,
                weights: Dictionary(uniqueKeysWithValues: criteria.map { ($0.id, equal) })
            )
        }

        // 3. Priority swap: the top two criteria trade places.
        let ordered = criteria.sorted { (baseWeights[$0.id] ?? 0) > (baseWeights[$1.id] ?? 0) }
        if ordered.count > 1 {
            var swapped = baseWeights
            let first = ordered[0], second = ordered[1]
            swapped[first.id] = baseWeights[second.id] ?? 0
            swapped[second.id] = baseWeights[first.id] ?? 0
            record(
                "If \(second.name.lowercased()) mattered more than \(first.name.lowercased())",
                distance: 0.4,
                options: options,
                criteria: criteria,
                weights: renormalise(swapped)
            )
        }

        // 4. Assumption variations: the winner performs worse than assessed, or a
        //    rival performs better, on each criterion.
        for criterion in criteria {
            var pessimistic = options
            if let index = pessimistic.firstIndex(where: { $0.id == baseWinner.optionID }) {
                var option = pessimistic[index]
                option.scores[criterion.id] = max(0, option.score(for: criterion.id) - 0.2)
                pessimistic[index] = option
            }
            record(
                "If \(baseWinner.name) turns out weaker on \(criterion.name.lowercased())",
                distance: 0.45,
                options: pessimistic,
                criteria: criteria,
                weights: baseWeights
            )
        }

        let holds = scenarios.filter { $0.winnerOptionID == baseWinner.optionID }.count
        let holdRate = scenarios.isEmpty ? 1 : Double(holds) / Double(scenarios.count)

        var flips = scenarios.filter { $0.winnerOptionID != baseWinner.optionID }
        flips.sort { lhs, rhs in
            if abs(lhs.distance - rhs.distance) > 1e-9 { return lhs.distance < rhs.distance }
            return lhs.label < rhs.label
        }

        let margin = base.margin
        let strength: DecisionStrength
        if margin < thresholds.minimumMargin {
            strength = .unclear
        } else if holdRate >= thresholds.strongHoldRate {
            strength = .strong
        } else if holdRate >= thresholds.moderateHoldRate {
            strength = .moderate
        } else {
            strength = .unclear
        }

        return StabilityReport(
            baseWinnerOptionID: baseWinner.optionID,
            holdRate: holdRate,
            margin: margin,
            strength: strength,
            flips: flips,
            scenarioCount: scenarios.count
        )
    }

    private static func renormalise(_ weights: [String: Double]) -> [String: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return weights }
        return weights.mapValues { $0 / total }
    }
}
