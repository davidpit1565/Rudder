import Foundation

/// The strongest honest case against RUDDER's own recommendation.
public struct SelfChallenge: Hashable, Codable, Sendable {
    /// The option that makes the best case against the recommendation.
    public let contenderOptionID: String?
    public let contenderName: String?
    /// User-facing: "If X becomes important, I'd switch my recommendation to B."
    public let strongestCaseAgainst: String
    /// True when the challenge actually won and the recommendation was changed.
    public let didSwitchRecommendation: Bool
    /// Extra counter-arguments supplied by the analysis, already validated.
    public let additionalCounterpoints: [String]

    public init(
        contenderOptionID: String?,
        contenderName: String?,
        strongestCaseAgainst: String,
        didSwitchRecommendation: Bool,
        additionalCounterpoints: [String] = []
    ) {
        self.contenderOptionID = contenderOptionID
        self.contenderName = contenderName
        self.strongestCaseAgainst = strongestCaseAgainst
        self.didSwitchRecommendation = didSwitchRecommendation
        self.additionalCounterpoints = additionalCounterpoints
    }
}

public struct ChallengeOutcome: Hashable, Sendable {
    public let recommendedOptionID: String?
    public let challenge: SelfChallenge?
}

/// Every recommendation has to survive "what could make me wrong?".
///
/// If a rival option wins in more reasonable variations than the current
/// recommendation does, the recommendation changes. Otherwise the strongest
/// surviving objection is surfaced to the user.
public enum SelfChallengeEngine {

    public static func challenge(
        recommendedOptionID: String?,
        stability: StabilityReport,
        options: [DecisionOption],
        counterpoints: [String] = []
    ) -> ChallengeOutcome {
        guard let recommendedOptionID,
              let recommended = options.first(where: { $0.id == recommendedOptionID })
        else {
            return ChallengeOutcome(recommendedOptionID: recommendedOptionID, challenge: nil)
        }

        guard !stability.flips.isEmpty else {
            return ChallengeOutcome(
                recommendedOptionID: recommendedOptionID,
                challenge: SelfChallenge(
                    contenderOptionID: nil,
                    contenderName: nil,
                    strongestCaseAgainst: "I couldn't find a reasonable change that would make a different option better.",
                    didSwitchRecommendation: false,
                    additionalCounterpoints: counterpoints
                )
            )
        }

        // Which rival wins most often across the variations that flip the result?
        var winCounts: [String: Int] = [:]
        for flip in stability.flips {
            guard let id = flip.winnerOptionID else { continue }
            winCounts[id, default: 0] += 1
        }
        let contenderID = winCounts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
        let contender = options.first { $0.id == contenderID }
        let nearest = stability.flips.first

        let recommendedHolds = stability.scenarioCount - stability.flips.count
        let contenderWins = contenderID.flatMap { winCounts[$0] } ?? 0
        let shouldSwitch = contenderWins > recommendedHolds && contender != nil

        let caseAgainst: String
        if let nearest, let contenderName = nearest.winnerName {
            caseAgainst = "\(nearest.label), \(contenderName) becomes the better choice."
        } else {
            caseAgainst = "Some reasonable changes in priorities would point somewhere else."
        }

        if shouldSwitch, let contender {
            return ChallengeOutcome(
                recommendedOptionID: contender.id,
                challenge: SelfChallenge(
                    contenderOptionID: recommended.id,
                    contenderName: recommended.name,
                    strongestCaseAgainst: "I changed my recommendation: \(contender.name) holds up better than \(recommended.name) once I varied the priorities.",
                    didSwitchRecommendation: true,
                    additionalCounterpoints: counterpoints
                )
            )
        }

        return ChallengeOutcome(
            recommendedOptionID: recommendedOptionID,
            challenge: SelfChallenge(
                contenderOptionID: contender?.id,
                contenderName: contender?.name,
                strongestCaseAgainst: caseAgainst,
                didSwitchRecommendation: false,
                additionalCounterpoints: counterpoints
            )
        )
    }
}
