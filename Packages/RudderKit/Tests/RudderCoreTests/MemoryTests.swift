import XCTest
@testable import RudderCore

final class MemoryTests: XCTestCase {

    private func record(chosen: String, convenience: (Double, Double), price: (Double, Double)) -> DecisionRecord {
        let criteria = [
            Criterion(id: "convenience", name: "Convenience", weight: 0.5),
            Criterion(id: "price", name: "Price", weight: 0.5)
        ]
        let options = [
            DecisionOption(id: "a", name: "A", scores: ["convenience": convenience.0, "price": price.0]),
            DecisionOption(id: "b", name: "B", scores: ["convenience": convenience.1, "price": price.1])
        ]
        let stability = StabilityEngine.analyse(options: options, criteria: criteria)
        let result = DecisionResult(
            understanding: .init(restatement: "x"),
            category: .purchase,
            complexity: .simple,
            criteria: criteria,
            options: options,
            ranking: DecisionEngine.evaluate(options: options, criteria: criteria).ranking,
            recommendedOptionID: "a",
            headline: "A",
            reasons: [],
            tradeOffs: [],
            strength: stability.strength,
            stability: stability
        )
        return DecisionRecord(title: "t", prompt: "p", result: result, chosenOptionID: chosen)
    }

    func testAPatternNeedsMoreThanOneDecisionBeforeItIsProposed() {
        let one = [record(chosen: "a", convenience: (0.9, 0.3), price: (0.3, 0.9))]
        XCTAssertTrue(MemoryEngine.candidates(from: one).isEmpty)

        let two = one + [record(chosen: "a", convenience: (0.9, 0.3), price: (0.3, 0.9))]
        let candidates = MemoryEngine.candidates(from: two)
        XCTAssertEqual(candidates.first?.key, "convenience>price")
        XCTAssertEqual(candidates.first?.statement, "You often prioritize convenience over price.")
    }

    func testAlreadyStoredPreferencesAreNotProposedAgain() {
        let records = [
            record(chosen: "a", convenience: (0.9, 0.3), price: (0.3, 0.9)),
            record(chosen: "a", convenience: (0.9, 0.3), price: (0.3, 0.9))
        ]
        let existing = [MemoryEntry(key: "convenience>price", statement: "You often prioritize convenience over price.", evidenceCount: 2)]
        XCTAssertTrue(MemoryEngine.candidates(from: records, existing: existing).isEmpty)
    }

    func testDecisionsWithNoChoiceTeachNothing() {
        let unfinished = DecisionRecord(
            title: "t",
            prompt: "p",
            result: record(chosen: "a", convenience: (0.9, 0.3), price: (0.3, 0.9)).result
        )
        XCTAssertTrue(MemoryEngine.candidates(from: [unfinished, unfinished]).isEmpty)
    }

    func testAcceptingACandidateProducesAnEnabledEntry() throws {
        let candidate = MemoryCandidate(key: "k", statement: "You often prioritize speed over cost.", evidenceCount: 3)
        let entry = try MemoryEngine.accept(candidate)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(entry.evidenceCount, 3)
    }

    func testIdentityClaimsAreRejected() {
        XCTAssertFalse(MemorySafety.isSafe("You are a convenience-oriented person."))
        XCTAssertFalse(MemorySafety.isSafe("You're an impulsive buyer."))
        XCTAssertFalse(MemorySafety.isSafe("Your personality suggests you avoid risk."))
    }

    func testBehaviouralObservationsAreAllowed() {
        XCTAssertTrue(MemorySafety.isSafe("You often prioritize convenience over price."))
        XCTAssertTrue(MemorySafety.isSafe("You usually choose the simpler option."))
    }

    func testSensitiveInferencesAreRejected() {
        XCTAssertFalse(MemorySafety.isSafe("You often choose options that reduce anxiety."))
        XCTAssertFalse(MemorySafety.isSafe("You prefer decisions that fit your religion."))
        XCTAssertFalse(MemorySafety.isSafe("You avoid options that conflict with your medication."))
    }

    func testOverlongStatementsAreRejected() {
        XCTAssertFalse(MemorySafety.isSafe(String(repeating: "x", count: 500)))
        XCTAssertFalse(MemorySafety.isSafe("   "))
    }

    func testAcceptThrowsRatherThanStoringAnUnsafeStatement() {
        let candidate = MemoryCandidate(key: "k", statement: "You are a risk taker.", evidenceCount: 5)
        XCTAssertThrowsError(try MemoryEngine.accept(candidate))
    }

    func testKnownKeysCoverBothSidesOfAPreference() {
        let entry = MemoryEntry(key: "convenience>price", statement: "You often prioritize convenience over price.", evidenceCount: 2)
        let keys = MemoryEngine.knownKeys(from: [entry])
        XCTAssertTrue(keys.contains("convenience>price"))
        XCTAssertTrue(keys.contains("convenience"))
        XCTAssertTrue(keys.contains("price"))
    }

    func testDisabledMemoryIsNotUsed() {
        let entry = MemoryEntry(key: "a>b", statement: "s", evidenceCount: 2, isEnabled: false)
        XCTAssertTrue(MemoryEngine.knownKeys(from: [entry]).isEmpty)
    }
}

/// Outcome learning: what the user says happened changes what RUDDER learns.
final class OutcomeLearningTests: XCTestCase {

    private func record(outcome: Outcome.Rating?) -> DecisionRecord {
        let criteria = [
            Criterion(id: "convenience", name: "Convenience", weight: 0.5),
            Criterion(id: "price", name: "Price", weight: 0.5)
        ]
        let options = [
            DecisionOption(id: "a", name: "A", scores: ["convenience": 0.9, "price": 0.3]),
            DecisionOption(id: "b", name: "B", scores: ["convenience": 0.3, "price": 0.9])
        ]
        let stability = StabilityEngine.analyse(options: options, criteria: criteria)
        let result = DecisionResult(
            understanding: .init(restatement: "x"),
            category: .purchase,
            complexity: .simple,
            criteria: criteria,
            options: options,
            ranking: DecisionEngine.evaluate(options: options, criteria: criteria).ranking,
            recommendedOptionID: "a",
            headline: "A",
            reasons: [],
            tradeOffs: [],
            strength: stability.strength,
            stability: stability
        )
        return DecisionRecord(
            title: "t",
            prompt: "p",
            result: result,
            chosenOptionID: "a",
            chosenAt: Date(),
            outcome: outcome.map { Outcome(rating: $0) }
        )
    }

    func testADecisionTheUserRegrettedTeachesNothing() {
        let regretted = [record(outcome: .notGreat), record(outcome: .notGreat)]
        XCTAssertTrue(
            MemoryEngine.candidates(from: regretted).isEmpty,
            "RUDDER must not learn to repeat a choice the user said went badly"
        )
    }

    func testOneGoodOutcomeIsWorthTwoUnratedDecisions() {
        // Unrated: one decision is not yet enough evidence.
        XCTAssertTrue(MemoryEngine.candidates(from: [record(outcome: nil)]).isEmpty)
        // Confirmed by the user: the same single decision now counts.
        let confirmed = MemoryEngine.candidates(from: [record(outcome: .great)])
        XCTAssertEqual(confirmed.first?.key, "convenience>price")
        XCTAssertEqual(confirmed.first?.evidenceCount, 2)
    }

    func testAMixedOutcomeStillCountsOnce() {
        XCTAssertTrue(MemoryEngine.candidates(from: [record(outcome: .mixed)]).isEmpty)
        XCTAssertFalse(MemoryEngine.candidates(from: [record(outcome: .mixed), record(outcome: .mixed)]).isEmpty)
    }

    func testRegretCancelsOutAGoodOutcome() {
        let mixed = [record(outcome: .great), record(outcome: .notGreat)]
        let candidates = MemoryEngine.candidates(from: mixed)
        XCTAssertEqual(candidates.first?.evidenceCount, 2, "Only the good one counts, and it counts double")
    }
}
