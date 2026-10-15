import Foundation

/// The structured response RUDDER's backend returns for a follow-up question
/// on an already-finished decision. Mirrors `FollowUpResponseSchema` in
/// Backend/src/schema.ts. Deliberately separate from `AIDecisionResponse`: a
/// follow-up answers from context already computed, it does not re-analyse.
public struct FollowUpResponseDTO: Codable, Hashable, Sendable {
    public var answer: String
    public var needsResearch: Bool
    public var suggestedNewDecisionPrompt: String?
    public var durablePreference: DurablePreference?

    public struct DurablePreference: Codable, Hashable, Sendable {
        public var statement: String

        public init(statement: String) {
            self.statement = statement
        }
    }

    public init(
        answer: String,
        needsResearch: Bool = false,
        suggestedNewDecisionPrompt: String? = nil,
        durablePreference: DurablePreference? = nil
    ) {
        self.answer = answer
        self.needsResearch = needsResearch
        self.suggestedNewDecisionPrompt = suggestedNewDecisionPrompt
        self.durablePreference = durablePreference
    }

    // Tolerant decoding: a missing optional field must never fail the whole
    // response, same reasoning as AIDecisionResponse in AIContract.swift.
    enum CodingKeys: String, CodingKey {
        case answer, needsResearch, suggestedNewDecisionPrompt, durablePreference
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
        needsResearch = try container.decodeIfPresent(Bool.self, forKey: .needsResearch) ?? false
        suggestedNewDecisionPrompt = try container.decodeIfPresent(String.self, forKey: .suggestedNewDecisionPrompt)
        durablePreference = try container.decodeIfPresent(DurablePreference.self, forKey: .durablePreference)
    }
}

extension FollowUpResponseDTO.DurablePreference {
    enum CodingKeys: String, CodingKey { case statement }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statement = try container.decodeIfPresent(String.self, forKey: .statement) ?? ""
    }
}
