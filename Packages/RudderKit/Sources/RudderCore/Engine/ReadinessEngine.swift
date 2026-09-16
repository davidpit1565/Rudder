import Foundation

public struct ReadinessInput: Sendable {
    public var viableOptionCount: Int
    public var criteriaCount: Int
    /// 0...1 — how much of what matters is actually backed by something.
    public var evidenceCoverage: Double
    public var requestedResearchLevel: ResearchLevel
    public var researchAttempted: Bool
    public var hasUnresolvedConflicts: Bool
    public var questionPlan: QuestionPlan
    public var margin: Double

    public init(
        viableOptionCount: Int,
        criteriaCount: Int,
        evidenceCoverage: Double,
        requestedResearchLevel: ResearchLevel,
        researchAttempted: Bool,
        hasUnresolvedConflicts: Bool,
        questionPlan: QuestionPlan,
        margin: Double
    ) {
        self.viableOptionCount = viableOptionCount
        self.criteriaCount = criteriaCount
        self.evidenceCoverage = min(max(evidenceCoverage, 0), 1)
        self.requestedResearchLevel = requestedResearchLevel
        self.researchAttempted = researchAttempted
        self.hasUnresolvedConflicts = hasUnresolvedConflicts
        self.questionPlan = questionPlan
        self.margin = margin
    }
}

public struct ReadinessAssessment: Hashable, Sendable {
    public let state: ReadinessState
    /// Plain-language explanation of what is missing. Empty when ready.
    public let missing: [String]

    public init(state: ReadinessState, missing: [String] = []) {
        self.state = state
        self.missing = missing
    }
}

/// Decides whether RUDDER is allowed to recommend anything yet.
public enum ReadinessEngine {

    /// Below this, the system does not have enough to stand behind a recommendation.
    public static let minimumEvidenceCoverage = 0.3

    public static func assess(_ input: ReadinessInput) -> ReadinessAssessment {
        if input.viableOptionCount == 0 {
            return ReadinessAssessment(
                state: .notEnoughToDecide,
                missing: ["I don't have any option left that meets your requirements."]
            )
        }

        if input.criteriaCount == 0 {
            return ReadinessAssessment(
                state: .notEnoughToDecide,
                missing: ["I couldn't work out what this decision should be judged on."]
            )
        }

        if input.requestedResearchLevel != .none && !input.researchAttempted {
            return ReadinessAssessment(state: .needsResearch)
        }

        if input.questionPlan.shouldAsk {
            return ReadinessAssessment(state: .needsOneQuestion)
        }

        if input.evidenceCoverage < minimumEvidenceCoverage {
            var missing = ["I don't have enough reliable information about the options."]
            if input.hasUnresolvedConflicts {
                missing.append("The information I did find contradicts itself.")
            }
            return ReadinessAssessment(state: .notEnoughToDecide, missing: missing)
        }

        return ReadinessAssessment(state: .ready)
    }
}
