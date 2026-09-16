import Foundation

/// The kind of decision. Detected internally — never presented as a selection step to the user.
public enum DecisionCategory: String, Codable, CaseIterable, Sendable {
    case purchase
    case career
    case education
    case travel
    case home
    case subscription
    case finance
    case technology
    case lifePlanning = "life_planning"
    case other
}

/// Drives the question ceiling, the research budget and the model budget.
public enum DecisionComplexity: String, Codable, CaseIterable, Sendable {
    case simple
    case medium
    case complex

    /// Maximum number of questions that may *ever* be asked for a decision of this
    /// complexity. This is a ceiling, not a target: zero questions is a success.
    public var questionCeiling: Int {
        switch self {
        case .simple: return 1
        case .medium: return 3
        case .complex: return 5
        }
    }
}

/// How much external research the decision justifies.
public enum ResearchLevel: String, Codable, CaseIterable, Sendable {
    case none
    case light
    case deep

    public var maximumCalls: Int {
        switch self {
        case .none: return 0
        case .light: return 2
        case .deep: return 6
        }
    }

    public var maximumSources: Int {
        switch self {
        case .none: return 0
        case .light: return 4
        case .deep: return 12
        }
    }
}

/// Result of the readiness check that runs before any recommendation.
public enum ReadinessState: String, Codable, CaseIterable, Sendable {
    case ready
    case needsResearch = "needs_research"
    case needsOneQuestion = "needs_one_question"
    case notEnoughToDecide = "not_enough_to_decide"
}

/// How stable the recommendation is under reasonable variation.
/// Deliberately not a percentage — RUDDER never fakes numeric confidence.
public enum DecisionStrength: String, Codable, CaseIterable, Sendable {
    case strong
    case moderate
    case unclear

    public var title: String {
        switch self {
        case .strong: return "Strong"
        case .moderate: return "Moderate"
        case .unclear: return "Unclear"
        }
    }

    public var explanation: String {
        switch self {
        case .strong:
            return "The recommendation stays the same across reasonable changes in priorities."
        case .moderate:
            return "Some reasonable changes in priorities would flip this recommendation."
        case .unclear:
            return "There is no option that stays ahead across reasonable changes."
        }
    }
}

public enum RiskSeverity: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}
