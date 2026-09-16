import Foundation

/// The structured response RUDDER's backend must return. The app never parses free text.
///
/// Note what is *absent*: the model does not get to report its own confidence.
/// Decision strength is computed locally by `StabilityEngine`.
public struct AIDecisionResponse: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var decisionStatus: String
    public var category: String
    public var complexity: String
    public var understanding: Understanding
    public var preliminaryRecommendation: Preliminary?
    public var requiredQuestions: [Question]
    public var researchNeeded: ResearchRequest
    public var criteria: [CriterionDTO]
    public var options: [OptionDTO]
    public var recommendation: RecommendationDTO?
    public var tradeoffs: [TradeOffDTO]
    public var risks: [RiskDTO]
    public var assumptions: [AssumptionDTO]
    public var research: [ResearchDTO]
    public var conflicts: [ConflictDTO]
    public var whatCouldMakeMeWrong: [String]

    public struct Understanding: Codable, Hashable, Sendable {
        public var restatement: String
        public var knownContext: [String]
        public var whatMatters: [String]

        public init(restatement: String, knownContext: [String] = [], whatMatters: [String] = []) {
            self.restatement = restatement
            self.knownContext = knownContext
            self.whatMatters = whatMatters
        }
    }

    public struct Preliminary: Codable, Hashable, Sendable {
        public var optionId: String
        public var rationale: String

        public init(optionId: String, rationale: String) {
            self.optionId = optionId
            self.rationale = rationale
        }
    }

    public struct Question: Codable, Hashable, Sendable {
        public var id: String
        public var text: String
        public var kind: String
        public var choices: [String]
        public var expectedImpact: Double
        public var friction: Double
        public var answerableByResearch: Bool
        public var knowledgeKey: String?

        public init(
            id: String,
            text: String,
            kind: String = QuestionKind.singleChoice.rawValue,
            choices: [String] = [],
            expectedImpact: Double,
            friction: Double = 0.25,
            answerableByResearch: Bool = false,
            knowledgeKey: String? = nil
        ) {
            self.id = id
            self.text = text
            self.kind = kind
            self.choices = choices
            self.expectedImpact = expectedImpact
            self.friction = friction
            self.answerableByResearch = answerableByResearch
            self.knowledgeKey = knowledgeKey
        }
    }

    public struct ResearchRequest: Codable, Hashable, Sendable {
        public var level: String
        public var topics: [String]

        public init(level: String, topics: [String] = []) {
            self.level = level
            self.topics = topics
        }
    }

    public struct CriterionDTO: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var weight: Double
        public var rationale: String?

        public init(id: String, name: String, weight: Double, rationale: String? = nil) {
            self.id = id
            self.name = name
            self.weight = weight
            self.rationale = rationale
        }
    }

    public struct OptionDTO: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var summary: String?
        public var scores: [String: Double]
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
    }

    public struct ReasonDTO: Codable, Hashable, Sendable {
        public var title: String
        public var detail: String

        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    public struct RecommendationDTO: Codable, Hashable, Sendable {
        public var optionId: String
        public var headline: String
        public var reasons: [ReasonDTO]

        public init(optionId: String, headline: String, reasons: [ReasonDTO]) {
            self.optionId = optionId
            self.headline = headline
            self.reasons = reasons
        }
    }

    public struct TradeOffDTO: Codable, Hashable, Sendable {
        public var gaining: String
        public var givingUp: String

        public init(gaining: String, givingUp: String) {
            self.gaining = gaining
            self.givingUp = givingUp
        }
    }

    public struct RiskDTO: Codable, Hashable, Sendable {
        public var title: String
        public var detail: String
        public var severity: String

        public init(title: String, detail: String, severity: String) {
            self.title = title
            self.detail = detail
            self.severity = severity
        }
    }

    public struct AssumptionDTO: Codable, Hashable, Sendable {
        public var statement: String
        public var impactIfWrong: String

        public init(statement: String, impactIfWrong: String) {
            self.statement = statement
            self.impactIfWrong = impactIfWrong
        }
    }

    public struct ResearchDTO: Codable, Hashable, Sendable {
        public var claim: String
        public var sourceTitle: String?
        public var sourceUrl: String?
        public var retrievedAt: String?
        public var verified: Bool

        public init(
            claim: String,
            sourceTitle: String? = nil,
            sourceUrl: String? = nil,
            retrievedAt: String? = nil,
            verified: Bool = false
        ) {
            self.claim = claim
            self.sourceTitle = sourceTitle
            self.sourceUrl = sourceUrl
            self.retrievedAt = retrievedAt
            self.verified = verified
        }
    }

    public struct ConflictDTO: Codable, Hashable, Sendable {
        public var topic: String
        public var detail: String

        public init(topic: String, detail: String) {
            self.topic = topic
            self.detail = detail
        }
    }

    public init(
        schemaVersion: Int = AIDecisionResponse.currentSchemaVersion,
        decisionStatus: String,
        category: String,
        complexity: String,
        understanding: Understanding,
        preliminaryRecommendation: Preliminary? = nil,
        requiredQuestions: [Question] = [],
        researchNeeded: ResearchRequest = .init(level: ResearchLevel.none.rawValue),
        criteria: [CriterionDTO] = [],
        options: [OptionDTO] = [],
        recommendation: RecommendationDTO? = nil,
        tradeoffs: [TradeOffDTO] = [],
        risks: [RiskDTO] = [],
        assumptions: [AssumptionDTO] = [],
        research: [ResearchDTO] = [],
        conflicts: [ConflictDTO] = [],
        whatCouldMakeMeWrong: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.decisionStatus = decisionStatus
        self.category = category
        self.complexity = complexity
        self.understanding = understanding
        self.preliminaryRecommendation = preliminaryRecommendation
        self.requiredQuestions = requiredQuestions
        self.researchNeeded = researchNeeded
        self.criteria = criteria
        self.options = options
        self.recommendation = recommendation
        self.tradeoffs = tradeoffs
        self.risks = risks
        self.assumptions = assumptions
        self.research = research
        self.conflicts = conflicts
        self.whatCouldMakeMeWrong = whatCouldMakeMeWrong
    }

    // Tolerant decoding: a missing optional array must never fail the whole response.
    enum CodingKeys: String, CodingKey {
        case schemaVersion, decisionStatus, category, complexity, understanding
        case preliminaryRecommendation, requiredQuestions, researchNeeded, criteria
        case options, recommendation, tradeoffs, risks, assumptions, research
        case conflicts, whatCouldMakeMeWrong
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        decisionStatus = try container.decodeIfPresent(String.self, forKey: .decisionStatus) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? DecisionCategory.other.rawValue
        complexity = try container.decodeIfPresent(String.self, forKey: .complexity) ?? DecisionComplexity.medium.rawValue
        understanding = try container.decodeIfPresent(Understanding.self, forKey: .understanding)
            ?? Understanding(restatement: "")
        preliminaryRecommendation = try container.decodeIfPresent(Preliminary.self, forKey: .preliminaryRecommendation)
        requiredQuestions = try container.decodeIfPresent([Question].self, forKey: .requiredQuestions) ?? []
        researchNeeded = try container.decodeIfPresent(ResearchRequest.self, forKey: .researchNeeded)
            ?? ResearchRequest(level: ResearchLevel.none.rawValue)
        criteria = try container.decodeIfPresent([CriterionDTO].self, forKey: .criteria) ?? []
        options = try container.decodeIfPresent([OptionDTO].self, forKey: .options) ?? []
        recommendation = try container.decodeIfPresent(RecommendationDTO.self, forKey: .recommendation)
        tradeoffs = try container.decodeIfPresent([TradeOffDTO].self, forKey: .tradeoffs) ?? []
        risks = try container.decodeIfPresent([RiskDTO].self, forKey: .risks) ?? []
        assumptions = try container.decodeIfPresent([AssumptionDTO].self, forKey: .assumptions) ?? []
        research = try container.decodeIfPresent([ResearchDTO].self, forKey: .research) ?? []
        conflicts = try container.decodeIfPresent([ConflictDTO].self, forKey: .conflicts) ?? []
        whatCouldMakeMeWrong = try container.decodeIfPresent([String].self, forKey: .whatCouldMakeMeWrong) ?? []
    }
}

extension AIDecisionResponse.Question {
    enum CodingKeys: String, CodingKey {
        case id, text, kind, choices, expectedImpact, friction, answerableByResearch, knowledgeKey
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? QuestionKind.singleChoice.rawValue
        choices = try container.decodeIfPresent([String].self, forKey: .choices) ?? []
        expectedImpact = try container.decodeIfPresent(Double.self, forKey: .expectedImpact) ?? 0
        friction = try container.decodeIfPresent(Double.self, forKey: .friction) ?? 0.25
        answerableByResearch = try container.decodeIfPresent(Bool.self, forKey: .answerableByResearch) ?? false
        knowledgeKey = try container.decodeIfPresent(String.self, forKey: .knowledgeKey)
    }
}

extension AIDecisionResponse.OptionDTO {
    enum CodingKeys: String, CodingKey {
        case id, name, summary, scores, failedConstraints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        scores = try container.decodeIfPresent([String: Double].self, forKey: .scores) ?? [:]
        failedConstraints = try container.decodeIfPresent([String].self, forKey: .failedConstraints) ?? []
    }
}

// MARK: - Tolerant decoding
//
// A backend that omits an optional field must never fail the whole response.
// Every nested type decodes missing values into safe defaults; the validator
// then decides whether what survived is usable.

extension AIDecisionResponse.Understanding {
    enum CodingKeys: String, CodingKey { case restatement, knownContext, whatMatters }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restatement = try c.decodeIfPresent(String.self, forKey: .restatement) ?? ""
        knownContext = try c.decodeIfPresent([String].self, forKey: .knownContext) ?? []
        whatMatters = try c.decodeIfPresent([String].self, forKey: .whatMatters) ?? []
    }
}

extension AIDecisionResponse.Preliminary {
    enum CodingKeys: String, CodingKey { case optionId, rationale }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try c.decodeIfPresent(String.self, forKey: .optionId) ?? ""
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
    }
}

extension AIDecisionResponse.ResearchRequest {
    enum CodingKeys: String, CodingKey { case level, topics }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decodeIfPresent(String.self, forKey: .level) ?? ResearchLevel.none.rawValue
        topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
    }
}

extension AIDecisionResponse.CriterionDTO {
    enum CodingKeys: String, CodingKey { case id, name, weight, rationale }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 0
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
    }
}

extension AIDecisionResponse.ReasonDTO {
    enum CodingKeys: String, CodingKey { case title, detail }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

extension AIDecisionResponse.RecommendationDTO {
    enum CodingKeys: String, CodingKey { case optionId, headline, reasons }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try c.decodeIfPresent(String.self, forKey: .optionId) ?? ""
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
        reasons = try c.decodeIfPresent([AIDecisionResponse.ReasonDTO].self, forKey: .reasons) ?? []
    }
}

extension AIDecisionResponse.TradeOffDTO {
    enum CodingKeys: String, CodingKey { case gaining, givingUp }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gaining = try c.decodeIfPresent(String.self, forKey: .gaining) ?? ""
        givingUp = try c.decodeIfPresent(String.self, forKey: .givingUp) ?? ""
    }
}

extension AIDecisionResponse.RiskDTO {
    enum CodingKeys: String, CodingKey { case title, detail, severity }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? RiskSeverity.medium.rawValue
    }
}

extension AIDecisionResponse.AssumptionDTO {
    enum CodingKeys: String, CodingKey { case statement, impactIfWrong }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statement = try c.decodeIfPresent(String.self, forKey: .statement) ?? ""
        impactIfWrong = try c.decodeIfPresent(String.self, forKey: .impactIfWrong) ?? ""
    }
}

extension AIDecisionResponse.ResearchDTO {
    enum CodingKeys: String, CodingKey { case claim, sourceTitle, sourceUrl, retrievedAt, verified }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claim = try c.decodeIfPresent(String.self, forKey: .claim) ?? ""
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        retrievedAt = try c.decodeIfPresent(String.self, forKey: .retrievedAt)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
    }
}

extension AIDecisionResponse.ConflictDTO {
    enum CodingKeys: String, CodingKey { case topic, detail }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}
