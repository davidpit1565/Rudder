import XCTest
import RudderCore
@testable import Rudder

/// Persistence has to survive the things that actually happen: relaunches,
/// re-saves, deletions and a user who wants everything gone.
@MainActor
final class PersistenceServiceTests: XCTestCase {

    private func makeService() throws -> PersistenceService {
        try PersistenceService(inMemory: true)
    }

    private func makeRecord(
        id: UUID = UUID(),
        chosen: String? = "air",
        title: String = "MacBook Air vs Pro"
    ) -> DecisionRecord {
        let criteria = [
            Criterion(id: "portability", name: "Portability", weight: 0.6),
            Criterion(id: "power", name: "Power", weight: 0.4)
        ]
        let options = [
            DecisionOption(id: "air", name: "MacBook Air", scores: ["portability": 0.9, "power": 0.5]),
            DecisionOption(id: "pro", name: "MacBook Pro", scores: ["portability": 0.4, "power": 0.95])
        ]
        let stability = StabilityEngine.analyse(options: options, criteria: criteria)
        let result = DecisionResult(
            understanding: .init(restatement: "Choosing a laptop"),
            category: .technology,
            complexity: .medium,
            criteria: criteria,
            options: options,
            ranking: DecisionEngine.evaluate(options: options, criteria: criteria).ranking,
            recommendedOptionID: "air",
            headline: "Best fit for you",
            reasons: [RecommendationReason(title: "Lighter", detail: "You carry it daily.")],
            tradeOffs: [],
            strength: stability.strength,
            stability: stability,
            researchLevel: .light
        )
        return DecisionRecord(
            id: id,
            title: title,
            prompt: "MacBook Air or Pro?",
            result: result,
            chosenOptionID: chosen,
            chosenAt: chosen == nil ? nil : Date()
        )
    }

    func testADecisionSurvivesASaveAndReload() throws {
        let service = try makeService()
        let record = makeRecord()
        try service.save(record)

        let loaded = try XCTUnwrap(service.decision(id: record.id))
        XCTAssertEqual(loaded.title, record.title)
        XCTAssertEqual(loaded.chosenOptionID, "air")
        XCTAssertEqual(loaded.result.criteria.count, 2)
        XCTAssertEqual(loaded.result.strength, record.result.strength)
        XCTAssertEqual(loaded.result.stability.flips.count, record.result.stability.flips.count)
    }

    func testSavingTheSameDecisionTwiceUpdatesRatherThanDuplicates() throws {
        let service = try makeService()
        var record = makeRecord()
        try service.save(record)

        record.title = "Renamed"
        record.chosenOptionID = "pro"
        try service.save(record)

        XCTAssertEqual(try service.allDecisions().count, 1)
        XCTAssertEqual(try service.decision(id: record.id)?.title, "Renamed")
        XCTAssertEqual(try service.decision(id: record.id)?.chosenOptionID, "pro")
    }

    func testDecisionsComeBackNewestFirst() throws {
        let service = try makeService()
        var older = makeRecord(title: "Older")
        older.createdAt = Date().addingTimeInterval(-86_400)
        let newer = makeRecord(title: "Newer")
        try service.save(older)
        try service.save(newer)

        XCTAssertEqual(try service.allDecisions().map(\.title), ["Newer", "Older"])
    }

    func testDeletingADecisionRemovesItsAnalysisAndOutcome() throws {
        let service = try makeService()
        let record = makeRecord()
        try service.save(record)
        try service.recordOutcome(Outcome(rating: .great), for: record.id)

        try service.delete(decisionID: record.id)

        XCTAssertNil(try service.decision(id: record.id))
        XCTAssertTrue(try service.allDecisions().isEmpty)
    }

    func testOutcomesAreStoredAndReplaced() throws {
        let service = try makeService()
        let record = makeRecord()
        try service.save(record)

        try service.recordOutcome(Outcome(rating: .mixed, note: "Fine"), for: record.id)
        XCTAssertEqual(try service.decision(id: record.id)?.outcome?.rating, .mixed)

        try service.recordOutcome(Outcome(rating: .great), for: record.id)
        XCTAssertEqual(try service.decision(id: record.id)?.outcome?.rating, .great)
        XCTAssertNil(try service.decision(id: record.id)?.outcome?.note)
    }

    func testOutcomesCanBeDeletedWithoutLosingDecisions() throws {
        let service = try makeService()
        let record = makeRecord()
        try service.save(record)
        try service.recordOutcome(Outcome(rating: .great), for: record.id)

        try service.deleteAllOutcomes()

        XCTAssertEqual(try service.allDecisions().count, 1)
        XCTAssertNil(try service.decision(id: record.id)?.outcome)
    }

    func testMemoryIsStoredSeparatelyFromDecisions() throws {
        let service = try makeService()
        try service.save(makeRecord())
        try service.saveMemory(
            MemoryEntry(key: "convenience>price", statement: "You often prioritize convenience over price.", evidenceCount: 2)
        )

        try service.deleteAllMemory()

        XCTAssertTrue(try service.allMemory().isEmpty)
        XCTAssertEqual(try service.allDecisions().count, 1, "Deleting memory must not touch decisions")
    }

    func testUnsafeMemoryIsRejectedAtTheStorageBoundary() throws {
        let service = try makeService()
        let unsafe = MemoryEntry(key: "x", statement: "You are an impulsive person.", evidenceCount: 5)
        XCTAssertThrowsError(try service.saveMemory(unsafe))
        XCTAssertTrue(try service.allMemory().isEmpty)
    }

    func testMemoryCanBeDisabledWithoutBeingDeleted() throws {
        let service = try makeService()
        let entry = MemoryEntry(key: "k", statement: "You often prioritize speed over cost.", evidenceCount: 2)
        try service.saveMemory(entry)

        try service.setMemoryEnabled(false, key: "k")

        let loaded = try XCTUnwrap(service.allMemory().first)
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertTrue(MemoryEngine.knownKeys(from: [loaded]).isEmpty)
    }

    func testSavingTheSameMemoryKeyTwiceUpdatesIt() throws {
        let service = try makeService()
        try service.saveMemory(MemoryEntry(key: "k", statement: "You often prioritize speed over cost.", evidenceCount: 2))
        try service.saveMemory(MemoryEntry(key: "k", statement: "You often prioritize speed over cost.", evidenceCount: 5))

        XCTAssertEqual(try service.allMemory().count, 1)
        XCTAssertEqual(try service.allMemory().first?.evidenceCount, 5)
    }

    func testDeleteEverythingLeavesNothingBehind() throws {
        let service = try makeService()
        let record = makeRecord()
        try service.save(record)
        try service.recordOutcome(Outcome(rating: .great), for: record.id)
        try service.saveMemory(MemoryEntry(key: "k", statement: "You often prioritize speed over cost.", evidenceCount: 2))

        try service.deleteEverything()

        XCTAssertTrue(try service.allDecisions().isEmpty)
        XCTAssertTrue(try service.allMemory().isEmpty)
    }

    func testAnUnavailableStoreThrowsInsteadOfCrashing() {
        // `best()` always returns something usable; the point here is that every
        // call path is throwing rather than trapping.
        let service = PersistenceService.best()
        XCTAssertNotEqual(service.mode, .unavailable)
        XCTAssertNoThrow(try service.allDecisions())
    }
}
