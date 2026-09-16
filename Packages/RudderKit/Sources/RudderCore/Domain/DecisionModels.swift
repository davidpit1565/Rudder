import Foundation

/// A single thing the decision is judged on.
public struct Criterion: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    /// Raw importance. Normalised by the engine — callers do not need to make these sum to 1.
    public var weight: Double
    public var rationale: String?

    public init(id: String, name: String, weight: Double, rationale: String? = nil) {
        self.id = id
        self.name = name
        self.weight = max(0, weight)
        self.rationale = rationale
    }
}

/// One of the things the user could choose.
public struct DecisionOption: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var summary: String?
    /// criterionID -> performance in 0...1. Missing entries are treated as unknown (0.5).
    public var scores: [String: Double]
    /// Hard constraints this option fails. A non-empty list eliminates the option.
    public var failedConstraints: [String]

    public init(
        id: String,
        name: String,
        summary: String? = nil,
        scores: [String: Double] = [:],
        failedConstraints: [String] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.scores = scores
        self.failedConstraints = failedConstraints
    }

    public func score(for criterionID: String) -> Double {
        guard let value = scores[criterionID] else { return 0.5 }
        return min(max(value, 0), 1)
    }

    public var isEliminated: Bool { !failedConstraints.isEmpty }
}

public struct Assumption: Hashable, Codable, Sendable, Identifiable {
    public var id: String { statement }
    public var statement: String
    public var impactIfWrong: String

    public init(statement: String, impactIfWrong: String) {
        self.statement = statement
        self.impactIfWrong = impactIfWrong
    }
}

public struct Risk: Hashable, Codable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var detail: String
    public var severity: RiskSeverity

    public init(title: String, detail: String, severity: RiskSeverity) {
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

/// A piece of information the system looked up rather than asked the user for.
public struct ResearchFinding: Hashable, Codable, Sendable, Identifiable {
    public var id: String { claim + (sourceURL?.absoluteString ?? "") }
    public var claim: String
    public var sourceTitle: String?
    public var sourceURL: URL?
    public var retrievedAt: Date?
    /// True when the system could not stand behind the claim.
    public var unverified: Bool

    public init(
        claim: String,
        sourceTitle: String? = nil,
        sourceURL: URL? = nil,
        retrievedAt: Date? = nil,
        unverified: Bool = false
    ) {
        self.claim = claim
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.retrievedAt = retrievedAt
        self.unverified = unverified
    }

    /// Research that is older than this is presented as potentially stale rather than current.
    public func isStale(now: Date = Date(), maximumAge: TimeInterval = 60 * 60 * 24 * 30) -> Bool {
        guard let retrievedAt else { return true }
        return now.timeIntervalSince(retrievedAt) > maximumAge
    }
}

public struct InformationConflict: Hashable, Codable, Sendable, Identifiable {
    public var id: String { topic }
    public var topic: String
    public var detail: String

    public init(topic: String, detail: String) {
        self.topic = topic
        self.detail = detail
    }
}

/// What the user gains and gives up by taking the recommendation.
public struct TradeOff: Hashable, Codable, Sendable, Identifiable {
    public var id: String { gaining + givingUp }
    public var gaining: String
    public var givingUp: String

    public init(gaining: String, givingUp: String) {
        self.gaining = gaining
        self.givingUp = givingUp
    }
}

public struct RecommendationReason: Hashable, Codable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// What RUDDER restated back to the user before analysing.
public struct DecisionUnderstanding: Hashable, Codable, Sendable {
    public var restatement: String
    public var knownContext: [String]
    public var whatMatters: [String]

    public init(restatement: String, knownContext: [String] = [], whatMatters: [String] = []) {
        self.restatement = restatement
        self.knownContext = knownContext
        self.whatMatters = whatMatters
    }
}

/// The finished analysis. Everything the recommendation screen and the details
/// screen render comes from here.
public struct DecisionResult: Hashable, Codable, Sendable {
    public var understanding: DecisionUnderstanding
    public var category: DecisionCategory
    public var complexity: DecisionComplexity
    public var criteria: [Criterion]
    public var options: [DecisionOption]
    public var eliminated: [EliminatedOption]
    public var ranking: [ScoredOption]
    /// nil when there is no responsible recommendation to make.
    public var recommendedOptionID: String?
    public var headline: String
    public var reasons: [RecommendationReason]
    public var tradeOffs: [TradeOff]
    public var strength: DecisionStrength
    public var stability: StabilityReport
    public var challenge: SelfChallenge?
    public var assumptions: [Assumption]
    public var risks: [Risk]
    public var research: [ResearchFinding]
    public var conflicts: [InformationConflict]
    public var researchLevel: ResearchLevel
    public var unverifiedResearch: Bool

    public init(
        understanding: DecisionUnderstanding,
        category: DecisionCategory,
        complexity: DecisionComplexity,
        criteria: [Criterion],
        options: [DecisionOption],
        eliminated: [EliminatedOption] = [],
        ranking: [ScoredOption],
        recommendedOptionID: String?,
        headline: String,
        reasons: [RecommendationReason],
        tradeOffs: [TradeOff],
        strength: DecisionStrength,
        stability: StabilityReport,
        challenge: SelfChallenge? = nil,
        assumptions: [Assumption] = [],
        risks: [Risk] = [],
        research: [ResearchFinding] = [],
        conflicts: [InformationConflict] = [],
        researchLevel: ResearchLevel = .none,
        unverifiedResearch: Bool = false
    ) {
        self.understanding = understanding
        self.category = category
        self.complexity = complexity
        self.criteria = criteria
        self.options = options
        self.eliminated = eliminated
        self.ranking = ranking
        self.recommendedOptionID = recommendedOptionID
        self.headline = headline
        self.reasons = reasons
        self.tradeOffs = tradeOffs
        self.strength = strength
        self.stability = stability
        self.challenge = challenge
        self.assumptions = assumptions
        self.risks = risks
        self.research = research
        self.conflicts = conflicts
        self.researchLevel = researchLevel
        self.unverifiedResearch = unverifiedResearch
    }

    public func option(withID id: String?) -> DecisionOption? {
        guard let id else { return nil }
        return options.first { $0.id == id }
    }

    public var recommendedOption: DecisionOption? { option(withID: recommendedOptionID) }

    /// True when the honest answer is "there is no clear winner".
    public var hasClearWinner: Bool {
        recommendedOptionID != nil && strength != .unclear
    }
}

/// A decision the user completed, as stored in history.
public struct DecisionRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var prompt: String
    public var createdAt: Date
    public var updatedAt: Date
    public var result: DecisionResult
    /// What the user actually chose. May differ from the recommendation.
    public var chosenOptionID: String?
    public var chosenAt: Date?
    public var outcome: Outcome?
    /// Set when the world may have moved on since the decision was made.
    public var needsReview: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        result: DecisionResult,
        chosenOptionID: String? = nil,
        chosenAt: Date? = nil,
        outcome: Outcome? = nil,
        needsReview: Bool = false
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.result = result
        self.chosenOptionID = chosenOptionID
        self.chosenAt = chosenAt
        self.outcome = outcome
        self.needsReview = needsReview
    }

    public var chosenOption: DecisionOption? { result.option(withID: chosenOptionID) }

    public var followedRecommendation: Bool? {
        guard let chosenOptionID, let recommended = result.recommendedOptionID else { return nil }
        return chosenOptionID == recommended
    }
}

/// How it went. Kept separate from decision data and from memory data.
public struct Outcome: Hashable, Codable, Sendable {
    public enum Rating: String, Codable, CaseIterable, Sendable {
        case great
        case mixed
        case notGreat = "not_great"
    }

    public var rating: Rating
    public var note: String?
    public var recordedAt: Date

    public init(rating: Rating, note: String? = nil, recordedAt: Date = Date()) {
        self.rating = rating
        self.note = note
        self.recordedAt = recordedAt
    }
}
