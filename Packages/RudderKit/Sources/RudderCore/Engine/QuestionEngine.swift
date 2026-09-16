import Foundation

public enum QuestionKind: String, Codable, CaseIterable, Sendable {
    case singleChoice = "single_choice"
    case multipleChoice = "multiple_choice"
    case freeText = "free_text"
}

/// A question the analysis *would like* to ask. Most of these never reach the user.
public struct QuestionCandidate: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var text: String
    public var kind: QuestionKind
    public var choices: [String]
    /// How much the answer could move the recommendation, 0...1.
    public var expectedImpact: Double
    /// How much effort the answer costs the user, 0...1.
    public var friction: Double
    /// True when the system could find this out itself instead of asking.
    public var answerableByResearch: Bool
    /// Key into what the system already knows (context or memory).
    public var knowledgeKey: String?

    public init(
        id: String,
        text: String,
        kind: QuestionKind = .singleChoice,
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
        self.expectedImpact = min(max(expectedImpact, 0), 1)
        self.friction = min(max(friction, 0), 1)
        self.answerableByResearch = answerableByResearch
        self.knowledgeKey = knowledgeKey
    }

    /// Question Value = Expected Decision Impact − User Friction. Internal only; never shown.
    public var value: Double { expectedImpact - friction }
}

public enum QuestionSuppressionReason: String, Codable, Sendable {
    case decisionAlreadyStable = "decision_already_stable"
    case answerableByResearch = "answerable_by_research"
    case alreadyKnown = "already_known"
    case alreadyAsked = "already_asked"
    case lowImpact = "low_impact"
    case frictionExceedsValue = "friction_exceeds_value"
    case budgetExhausted = "budget_exhausted"
    case supersededByBetterQuestion = "superseded_by_better_question"
}

public struct SuppressedQuestion: Hashable, Codable, Sendable, Identifiable {
    public var id: String { questionID }
    public let questionID: String
    public let reason: QuestionSuppressionReason
}

public struct QuestionPlan: Hashable, Codable, Sendable {
    /// At most one question — RUDDER asks one thing at a time and re-checks readiness after.
    public let next: QuestionCandidate?
    public let suppressed: [SuppressedQuestion]
    public let remainingBudget: Int

    public var shouldAsk: Bool { next != nil }
}

/// Decides whether a question is allowed to reach the user.
///
///     Can the system know this?          yes -> research / existing context, don't ask
///     Can it change the recommendation?  no  -> don't ask
///     Is the value worth the friction?   no  -> continue with explicit uncertainty
public enum QuestionEngine {

    public struct Policy: Sendable {
        /// Below this, an answer cannot move the recommendation enough to be worth asking.
        public var minimumImpact: Double
        /// A question must be worth more than it costs.
        public var minimumValue: Double

        public init(minimumImpact: Double = 0.35, minimumValue: Double = 0.05) {
            self.minimumImpact = minimumImpact
            self.minimumValue = minimumValue
        }

        public static let `default` = Policy()
    }

    public static func plan(
        candidates: [QuestionCandidate],
        complexity: DecisionComplexity,
        alreadyAskedIDs: Set<String> = [],
        knownKeys: Set<String> = [],
        decisionIsAlreadyStable: Bool = false,
        policy: Policy = .default
    ) -> QuestionPlan {
        let budget = max(0, complexity.questionCeiling - alreadyAskedIDs.count)

        // Zero questions is a successful outcome: if the recommendation already
        // holds up, nothing is worth asking.
        if decisionIsAlreadyStable {
            return QuestionPlan(
                next: nil,
                suppressed: candidates.map { SuppressedQuestion(questionID: $0.id, reason: .decisionAlreadyStable) },
                remainingBudget: budget
            )
        }

        if budget == 0 {
            return QuestionPlan(
                next: nil,
                suppressed: candidates.map { SuppressedQuestion(questionID: $0.id, reason: .budgetExhausted) },
                remainingBudget: 0
            )
        }

        var suppressed: [SuppressedQuestion] = []
        var eligible: [QuestionCandidate] = []

        for candidate in candidates {
            if alreadyAskedIDs.contains(candidate.id) {
                suppressed.append(.init(questionID: candidate.id, reason: .alreadyAsked))
            } else if let key = candidate.knowledgeKey, knownKeys.contains(key) {
                suppressed.append(.init(questionID: candidate.id, reason: .alreadyKnown))
            } else if candidate.answerableByResearch {
                suppressed.append(.init(questionID: candidate.id, reason: .answerableByResearch))
            } else if candidate.expectedImpact < policy.minimumImpact {
                suppressed.append(.init(questionID: candidate.id, reason: .lowImpact))
            } else if candidate.value < policy.minimumValue {
                suppressed.append(.init(questionID: candidate.id, reason: .frictionExceedsValue))
            } else {
                eligible.append(candidate)
            }
        }

        eligible.sort { lhs, rhs in
            if abs(lhs.value - rhs.value) > 1e-9 { return lhs.value > rhs.value }
            return lhs.id < rhs.id
        }

        guard let next = eligible.first else {
            return QuestionPlan(next: nil, suppressed: suppressed, remainingBudget: budget)
        }

        suppressed.append(
            contentsOf: eligible.dropFirst().map {
                SuppressedQuestion(questionID: $0.id, reason: .supersededByBetterQuestion)
            }
        )

        return QuestionPlan(next: next, suppressed: suppressed, remainingBudget: budget)
    }
}
