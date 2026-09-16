import Foundation
import SwiftData
import RudderCore

/// Local-first storage. Nothing here needs a network or an account: history and
/// memory work fully offline, and deletion is real deletion.
@MainActor
final class PersistenceService {
    enum StorageError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Storage isn't available on this device right now."
        }
    }

    /// nil when even an in-memory store could not be created. Every call then
    /// throws `StorageError.unavailable` instead of trapping, so the app degrades
    /// rather than crashing.
    private let container: ModelContainer?

    /// How the store was opened, so the UI can tell the user when nothing will be saved.
    enum Mode: Equatable {
        case onDisk
        case inMemory
        case unavailable
    }

    let mode: Mode

    private func requireContext() throws -> ModelContext {
        guard let container else { throw StorageError.unavailable }
        return container.mainContext
    }

    static var schema: Schema {
        Schema([
            StoredDecision.self,
            StoredDecisionResult.self,
            StoredOutcome.self,
            StoredMemoryEntry.self
        ])
    }

    init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: Self.schema, configurations: [configuration])
        mode = inMemory ? .inMemory : .onDisk
    }

    private init(unavailable: Bool) {
        container = nil
        mode = .unavailable
    }

    /// Opens the best store available: on disk, then in memory, then none.
    static func best() -> PersistenceService {
        if let onDisk = try? PersistenceService(inMemory: false) { return onDisk }
        if let inMemory = try? PersistenceService(inMemory: true) { return inMemory }
        return PersistenceService(unavailable: true)
    }

    // MARK: - Decisions

    func save(_ record: DecisionRecord) throws {
        let context = try requireContext()
        let id = record.id
        let descriptor = FetchDescriptor<StoredDecision>(predicate: #Predicate { $0.id == id })
        let existing = try context.fetch(descriptor).first

        let payload = try JSONEncoder.decide.encode(record.result)
        let stored = existing ?? StoredDecision(id: record.id, title: record.title, prompt: record.prompt)

        stored.title = record.title
        stored.prompt = record.prompt
        stored.createdAt = record.createdAt
        stored.updatedAt = Date()
        stored.chosenOptionID = record.chosenOptionID
        stored.chosenAt = record.chosenAt
        stored.needsReview = record.needsReview

        if let result = stored.result {
            result.payload = payload
        } else {
            let result = StoredDecisionResult(payload: payload)
            result.decision = stored
            stored.result = result
            context.insert(result)
        }

        if existing == nil { context.insert(stored) }
        try context.save()
    }

    func allDecisions() throws -> [DecisionRecord] {
        let context = try requireContext()
        let descriptor = FetchDescriptor<StoredDecision>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap { $0.toDomain() }
    }

    func decision(id: UUID) throws -> DecisionRecord? {
        let context = try requireContext()
        let descriptor = FetchDescriptor<StoredDecision>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first?.toDomain()
    }

    func recordChoice(decisionID: UUID, optionID: String, at date: Date = Date()) throws {
        let context = try requireContext()
        guard let stored = try storedDecision(id: decisionID) else { return }
        stored.chosenOptionID = optionID
        stored.chosenAt = date
        stored.updatedAt = date
        try context.save()
    }

    func delete(decisionID: UUID) throws {
        let context = try requireContext()
        guard let stored = try storedDecision(id: decisionID) else { return }
        context.delete(stored)
        try context.save()
    }

    func deleteAllDecisions() throws {
        let context = try requireContext()
        try context.delete(model: StoredDecision.self)
        try context.delete(model: StoredDecisionResult.self)
        try context.delete(model: StoredOutcome.self)
        try context.save()
    }

    // MARK: - Outcomes

    func recordOutcome(_ outcome: Outcome, for decisionID: UUID) throws {
        let context = try requireContext()
        guard let stored = try storedDecision(id: decisionID) else { return }
        if let existing = stored.outcome {
            existing.ratingRaw = outcome.rating.rawValue
            existing.note = outcome.note
            existing.recordedAt = outcome.recordedAt
        } else {
            let new = StoredOutcome(
                ratingRaw: outcome.rating.rawValue,
                note: outcome.note,
                recordedAt: outcome.recordedAt
            )
            new.decision = stored
            stored.outcome = new
            context.insert(new)
        }
        stored.updatedAt = Date()
        try context.save()
    }

    func deleteAllOutcomes() throws {
        let context = try requireContext()
        try context.delete(model: StoredOutcome.self)
        try context.save()
    }

    // MARK: - Memory

    func allMemory() throws -> [MemoryEntry] {
        let context = try requireContext()
        let descriptor = FetchDescriptor<StoredMemoryEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    /// Consent-gated: the caller must already have a yes from the user, and the
    /// statement is re-validated here so nothing unsafe can reach the store.
    func saveMemory(_ entry: MemoryEntry) throws {
        let context = try requireContext()
        try MemorySafety.validate(entry.statement)
        let key = entry.key
        let descriptor = FetchDescriptor<StoredMemoryEntry>(predicate: #Predicate { $0.key == key })
        if let existing = try context.fetch(descriptor).first {
            existing.statement = entry.statement
            existing.evidenceCount = entry.evidenceCount
            existing.updatedAt = Date()
            existing.isEnabled = entry.isEnabled
        } else {
            context.insert(
                StoredMemoryEntry(
                    id: entry.id,
                    key: entry.key,
                    statement: entry.statement,
                    evidenceCount: entry.evidenceCount,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    isEnabled: entry.isEnabled
                )
            )
        }
        try context.save()
    }

    func setMemoryEnabled(_ isEnabled: Bool, key: String) throws {
        let context = try requireContext()
        let descriptor = FetchDescriptor<StoredMemoryEntry>(predicate: #Predicate { $0.key == key })
        guard let entry = try context.fetch(descriptor).first else { return }
        entry.isEnabled = isEnabled
        entry.updatedAt = Date()
        try context.save()
    }

    func deleteMemory(key: String) throws {
        let context = try requireContext()
        let descriptor = FetchDescriptor<StoredMemoryEntry>(predicate: #Predicate { $0.key == key })
        guard let entry = try context.fetch(descriptor).first else { return }
        context.delete(entry)
        try context.save()
    }

    func deleteAllMemory() throws {
        let context = try requireContext()
        try context.delete(model: StoredMemoryEntry.self)
        try context.save()
    }

    // MARK: - Everything

    func deleteEverything() throws {
        let context = try requireContext()
        try context.delete(model: StoredMemoryEntry.self)
        try context.delete(model: StoredOutcome.self)
        try context.delete(model: StoredDecisionResult.self)
        try context.delete(model: StoredDecision.self)
        try context.save()
    }

    private func storedDecision(id: UUID) throws -> StoredDecision? {
        let context = try requireContext()
        let descriptor = FetchDescriptor<StoredDecision>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }
}
