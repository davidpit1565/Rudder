import Foundation

/// The budget a single decision is allowed to spend.
public struct DecisionBudget: Hashable, Sendable {
    public let researchLevel: ResearchLevel
    public let maximumResearchCalls: Int
    public let maximumSources: Int
    /// How many model round-trips the whole pipeline may use, including retries.
    public let maximumModelCalls: Int
    public let questionCeiling: Int

    public init(
        researchLevel: ResearchLevel,
        maximumResearchCalls: Int,
        maximumSources: Int,
        maximumModelCalls: Int,
        questionCeiling: Int
    ) {
        self.researchLevel = researchLevel
        self.maximumResearchCalls = maximumResearchCalls
        self.maximumSources = maximumSources
        self.maximumModelCalls = maximumModelCalls
        self.questionCeiling = questionCeiling
    }
}

/// Keeps RUDDER from doing deep research on "pizza or pasta?" while still doing
/// it properly for "which car should I buy?".
public enum ResearchPolicy {

    public static func budget(
        complexity: DecisionComplexity,
        category: DecisionCategory,
        requestedLevel: ResearchLevel? = nil
    ) -> DecisionBudget {
        var level: ResearchLevel
        switch complexity {
        case .simple: level = .none
        case .medium: level = .light
        case .complex: level = .deep
        }

        // Categories where public, current facts usually decide the outcome.
        let researchHeavy: Set<DecisionCategory> = [
            .purchase, .technology, .travel, .finance, .home, .education, .subscription
        ]
        if researchHeavy.contains(category), level == .none {
            level = .light
        }

        // The model may ask for research, but never for more than the budget allows.
        if let requestedLevel, requestedLevel.maximumCalls < level.maximumCalls {
            level = requestedLevel
        }

        let modelCalls: Int
        switch complexity {
        case .simple: modelCalls = 2
        case .medium: modelCalls = 4
        case .complex: modelCalls = 6
        }

        return DecisionBudget(
            researchLevel: level,
            maximumResearchCalls: level.maximumCalls,
            maximumSources: level.maximumSources,
            maximumModelCalls: modelCalls,
            questionCeiling: complexity.questionCeiling
        )
    }
}
