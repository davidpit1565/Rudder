import Foundation
import SwiftData
import RudderCore

/// Decision data: what the user told RUDDER about one specific decision.
@Model
final class StoredDecision {
    @Attribute(.unique) var id: UUID
    var title: String
    var prompt: String
    var createdAt: Date
    var updatedAt: Date
    var chosenOptionID: String?
    var chosenAt: Date?
    var needsReview: Bool

    @Relationship(deleteRule: .cascade, inverse: \StoredDecisionResult.decision)
    var result: StoredDecisionResult?

    @Relationship(deleteRule: .cascade, inverse: \StoredOutcome.decision)
    var outcome: StoredOutcome?

    init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        chosenOptionID: String? = nil,
        chosenAt: Date? = nil,
        needsReview: Bool = false
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.chosenOptionID = chosenOptionID
        self.chosenAt = chosenAt
        self.needsReview = needsReview
    }
}

/// The analysis itself, stored as the encoded domain model.
///
/// Keeping it as one encoded payload means the analysis schema can evolve without
/// a store migration for every field, and the domain model stays the single
/// source of truth for criteria, options, stability and research.
@Model
final class StoredDecisionResult {
    var payload: Data
    var schemaVersion: Int
    var decision: StoredDecision?

    init(payload: Data, schemaVersion: Int = 1) {
        self.payload = payload
        self.schemaVersion = schemaVersion
    }
}

/// Outcome data: what happened afterwards. Separate from the decision so it can
/// be deleted on its own.
@Model
final class StoredOutcome {
    var ratingRaw: String
    var note: String?
    var recordedAt: Date
    var decision: StoredDecision?

    init(ratingRaw: String, note: String? = nil, recordedAt: Date = Date()) {
        self.ratingRaw = ratingRaw
        self.note = note
        self.recordedAt = recordedAt
    }
}

/// Memory data: general preferences learned across decisions. Never written
/// without consent, never joined back to a single decision.
@Model
final class StoredMemoryEntry {
    @Attribute(.unique) var key: String
    var id: UUID
    var statement: String
    var evidenceCount: Int
    var createdAt: Date
    var updatedAt: Date
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        key: String,
        statement: String,
        evidenceCount: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.key = key
        self.statement = statement
        self.evidenceCount = evidenceCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEnabled = isEnabled
    }
}

// MARK: - Mapping

extension StoredDecision {
    func toDomain() -> DecisionRecord? {
        guard let payload = result?.payload,
              let decoded = try? JSONDecoder.decide.decode(DecisionResult.self, from: payload)
        else { return nil }

        return DecisionRecord(
            id: id,
            title: title,
            prompt: prompt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            result: decoded,
            chosenOptionID: chosenOptionID,
            chosenAt: chosenAt,
            outcome: outcome?.toDomain(),
            needsReview: needsReview
        )
    }
}

extension StoredOutcome {
    func toDomain() -> Outcome? {
        guard let rating = Outcome.Rating(rawValue: ratingRaw) else { return nil }
        return Outcome(rating: rating, note: note, recordedAt: recordedAt)
    }
}

extension StoredMemoryEntry {
    func toDomain() -> MemoryEntry {
        MemoryEntry(
            id: id,
            key: key,
            statement: statement,
            evidenceCount: evidenceCount,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isEnabled: isEnabled
        )
    }
}

// Computed rather than shared instances: JSONDecoder and JSONEncoder are not
// Sendable, and a stored static would be shared mutable state.
extension JSONDecoder {
    static var decide: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var decide: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
