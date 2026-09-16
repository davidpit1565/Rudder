import Foundation

/// Turns a validated response into a finished `DecisionResult` by running the
/// local engines. The model proposes; the engines decide how strong it is.
public enum DecisionAssembler {

    public static func assemble(_ response: ValidatedAIResponse, now: Date = Date()) -> DecisionResult {
        let evaluation = DecisionEngine.evaluate(options: response.options, criteria: response.criteria)
        let stability = StabilityEngine.analyse(options: response.options, criteria: response.criteria)

        // The model's pick is the starting point; the engine's own winner takes over
        // when the model picked something the numbers do not support.
        var recommendedID = response.recommendedOptionID ?? evaluation.winner?.optionID
        if let id = recommendedID,
           let engineWinner = evaluation.winner?.optionID,
           id != engineWinner,
           let picked = evaluation.ranking.first(where: { $0.optionID == id }),
           let top = evaluation.ranking.first,
           top.score - picked.score > 0.05 {
            recommendedID = engineWinner
        }

        let outcome = SelfChallengeEngine.challenge(
            recommendedOptionID: recommendedID,
            stability: stability,
            options: response.options,
            counterpoints: response.counterpoints
        )
        recommendedID = outcome.recommendedOptionID

        // The leading option is kept even when the strength is Unclear: the UI shows
        // the "no clear winner" screen and only reveals it behind "choose for me
        // anyway", as a conditional suggestion rather than a recommendation.
        let strength = stability.strength
        let finalRecommendedID: String? = recommendedID

        let winner = response.options.first { $0.id == finalRecommendedID }
        let runnerUpID = evaluation.ranking.first { $0.optionID != finalRecommendedID }?.optionID
        let runnerUp = response.options.first { $0.id == runnerUpID }

        var tradeOffs = response.tradeOffs
        if tradeOffs.isEmpty, let winner {
            tradeOffs = DecisionEngine.tradeOffs(
                winner: winner,
                runnerUp: runnerUp,
                criteria: response.criteria
            )
        }

        let headline: String
        if !response.headline.isEmpty {
            headline = response.headline
        } else if let winner {
            headline = "\(winner.name) looks like the better fit."
        } else {
            headline = "There isn't a clear winner."
        }

        let unverified = response.research.contains(where: \.unverified)
            || response.research.contains { $0.isStale(now: now) }

        return DecisionResult(
            understanding: response.understanding,
            category: response.category,
            complexity: response.complexity,
            criteria: response.criteria,
            options: response.options,
            eliminated: evaluation.eliminated,
            ranking: evaluation.ranking,
            recommendedOptionID: finalRecommendedID,
            headline: headline,
            reasons: response.reasons,
            tradeOffs: tradeOffs,
            strength: strength,
            stability: stability,
            challenge: outcome.challenge,
            assumptions: response.assumptions,
            risks: response.risks,
            research: response.research,
            conflicts: response.conflicts,
            researchLevel: response.researchLevel,
            unverifiedResearch: unverified
        )
    }

    /// How much of what matters is actually backed by something the system knows.
    ///
    /// Used by the readiness check to refuse to recommend on thin air.
    public static func evidenceCoverage(_ response: ValidatedAIResponse) -> Double {
        guard !response.criteria.isEmpty, !response.options.isEmpty else { return 0 }

        // A score of exactly 0.5 is the validator's "no information" marker.
        let total = Double(response.criteria.count * response.options.count)
        var known = 0.0
        for option in response.options {
            for criterion in response.criteria {
                if let raw = option.scores[criterion.id], abs(raw - 0.5) > 1e-9 { known += 1 }
            }
        }
        let scoreCoverage = known / total

        // Verified research raises coverage; nothing beyond the user's own words keeps it low.
        let verifiedResearch = response.research.filter { !$0.unverified }.count
        let researchBoost = min(Double(verifiedResearch) * 0.1, 0.3)

        return min(scoreCoverage + researchBoost, 1)
    }
}
