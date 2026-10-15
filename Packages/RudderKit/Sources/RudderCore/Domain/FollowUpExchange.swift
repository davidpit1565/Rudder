import Foundation

/// One question-and-answer pair in a follow-up conversation about an
/// already-finished decision. Kept separate from `DecisionRecord`: a
/// follow-up is a conversation about the decision, not part of its analysis.
public struct FollowUpExchange: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var question: String
    public var answer: String
    public var askedAt: Date
    /// Set when answering well really needed research this call couldn't do --
    /// a ready-to-use prompt for starting a new decision with that context.
    public var suggestedNewDecisionPrompt: String?
    /// Set when this exchange revealed a preference worth remembering, pending
    /// the user's explicit consent -- never written to Memory on its own.
    public var durablePreferenceStatement: String?

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        askedAt: Date = Date(),
        suggestedNewDecisionPrompt: String? = nil,
        durablePreferenceStatement: String? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.askedAt = askedAt
        self.suggestedNewDecisionPrompt = suggestedNewDecisionPrompt
        self.durablePreferenceStatement = durablePreferenceStatement
    }
}
