import XCTest
import RudderCore
import RudderFlow
@testable import Rudder

/// The whole journey through the real app layer: a decision is analysed, chosen,
/// saved, found again in history, given an outcome, and turned into a learned
/// preference that reaches the next decision.
///
/// The UI suite walks the same path on screen; this covers the two legs it
/// cannot reach without a real purchase — Decision Memory, which is Pro — and
/// pins the behaviour that has to hold regardless of rendering.
@MainActor
final class EndToEndTests: XCTestCase {

    private var persistence: PersistenceService!
    private var environment: AppEnvironment!
    private var service: StubAnalysisService!

    override func setUp() async throws {
        persistence = try PersistenceService(inMemory: true)
        environment = AppEnvironment(persistence: persistence)
        service = StubAnalysisService()
    }

    override func tearDown() async throws {
        persistence = nil
        environment = nil
        service = nil
    }

    private func makeCoordinator() -> DecisionCoordinator {
        DecisionCoordinator(
            service: service,
            memoryProvider: { [weak environment] in environment?.memory ?? [] }
        )
    }

    private func settle(_ coordinator: DecisionCoordinator, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // Phase is checked before the deadline, not after: otherwise a phase that
        // settles during the final sleep can still report failure if the deadline
        // happens to pass in that same window.
        while true {
            switch coordinator.phase {
            case .idle, .working:
                guard Date() < deadline else {
                    XCTFail("The pipeline did not settle: \(coordinator.phase)")
                    return
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            default:
                return
            }
        }
    }

    // MARK: The journey

    func testADecisionGoesFromPromptToHistory() async throws {
        let coordinator = makeCoordinator()
        coordinator.start(prompt: "MacBook Air or MacBook Pro?")
        try await settle(coordinator)

        guard case .finished(let result) = coordinator.phase else {
            return XCTFail("Expected a recommendation, got \(coordinator.phase)")
        }
        XCTAssertEqual(result.recommendedOptionID, "air")
        XCTAssertEqual(result.strength, .strong)

        let record = try XCTUnwrap(coordinator.makeChoice(optionID: "air"))
        environment.save(record)

        XCTAssertEqual(environment.decisions.count, 1)
        XCTAssertEqual(environment.decisions.first?.chosenOption?.name, "MacBook Air")
        XCTAssertEqual(environment.visibleDecisions.first?.title, "MacBook Air vs MacBook Pro")
    }

    func testAnOutcomeIsStoredAgainstTheDecisionAndCanBeRemovedAlone() async throws {
        let coordinator = makeCoordinator()
        coordinator.start(prompt: "MacBook Air or MacBook Pro?")
        try await settle(coordinator)
        let record = try XCTUnwrap(coordinator.makeChoice(optionID: "air"))
        environment.save(record)

        environment.recordOutcome(Outcome(rating: .great), for: record)
        XCTAssertEqual(environment.decisions.first?.outcome?.rating, .great)

        environment.deleteAllOutcomes()
        XCTAssertNil(environment.decisions.first?.outcome)
        XCTAssertEqual(environment.decisions.count, 1, "Deleting outcomes must not delete decisions")
    }

    func testDataSurvivesARestartAndDeletionIsReal() async throws {
        let coordinator = makeCoordinator()
        coordinator.start(prompt: "MacBook Air or MacBook Pro?")
        try await settle(coordinator)
        let record = try XCTUnwrap(coordinator.makeChoice(optionID: "air"))
        environment.save(record)

        // A second environment over the same store is what a relaunch looks like.
        let reopened = AppEnvironment(persistence: persistence)
        XCTAssertEqual(reopened.decisions.count, 1)
        XCTAssertEqual(reopened.decisions.first?.result.criteria.count, record.result.criteria.count)
        XCTAssertEqual(reopened.decisions.first?.result.strength, record.result.strength)

        reopened.delete(record)
        XCTAssertTrue(reopened.decisions.isEmpty)
        XCTAssertTrue(AppEnvironment(persistence: persistence).decisions.isEmpty)
    }

    // MARK: Memory

    func testALearnedPreferenceReachesTheNextDecision() async throws {
        // Two decisions that express the same preference, both confirmed as good.
        for _ in 0..<2 {
            let coordinator = makeCoordinator()
            coordinator.start(prompt: "MacBook Air or MacBook Pro?")
            try await settle(coordinator)
            let record = try XCTUnwrap(coordinator.makeChoice(optionID: "air"))
            environment.save(record)
            environment.recordOutcome(Outcome(rating: .great), for: record)
        }

        let candidates = MemoryEngine.candidates(from: environment.decisions)
        let candidate = try XCTUnwrap(candidates.first, "A repeated, confirmed pattern should be worth proposing")
        XCTAssertTrue(candidate.statement.hasPrefix("You often prioritize"))

        // Consent, then storage.
        try persistence.saveMemory(try MemoryEngine.accept(candidate))
        environment.reload()
        XCTAssertEqual(environment.memory.count, 1)

        // The next decision carries it, so RUDDER does not ask about it again.
        let next = makeCoordinator()
        next.start(prompt: "Which tablet should I get?")
        try await settle(next)
        XCTAssertEqual(service.lastRequest?.knownPreferences, [candidate.statement])
    }

    func testADisabledPreferenceIsNotSentAnywhere() async throws {
        let entry = MemoryEntry(key: "a>b", statement: "You often prioritize speed over cost.", evidenceCount: 3)
        try persistence.saveMemory(entry)
        try persistence.setMemoryEnabled(false, key: entry.key)
        environment.reload()

        let coordinator = makeCoordinator()
        coordinator.start(prompt: "Which tablet should I get?")
        try await settle(coordinator)

        XCTAssertEqual(service.lastRequest?.knownPreferences, [])
    }

    func testMemoryIsNotProposedWithoutPro() async throws {
        for _ in 0..<3 {
            let coordinator = makeCoordinator()
            coordinator.start(prompt: "MacBook Air or MacBook Pro?")
            try await settle(coordinator)
            let record = try XCTUnwrap(coordinator.makeChoice(optionID: "air"))
            environment.save(record)
        }

        XCTAssertFalse(environment.isPro)
        XCTAssertNil(environment.pendingMemoryCandidate, "Decision Memory is a Pro feature and must stay gated")
        XCTAssertFalse(MemoryEngine.candidates(from: environment.decisions).isEmpty, "…but the pattern is there to offer once they subscribe")
    }

    // MARK: Limits

    func testTheFirstDecisionIsNeverBlockedByTheFreeLimit() {
        XCTAssertTrue(environment.canStartDecision(complexity: .complex))
    }

    func testHistoryIsCappedForFreeWithoutDeletingAnything() async throws {
        for index in 0..<(FeatureAccess.freeHistoryLimit + 3) {
            let coordinator = makeCoordinator()
            coordinator.start(prompt: "Decision number \(index)?")
            try await settle(coordinator)
            let record = try XCTUnwrap(coordinator.makeChoice(optionID: "air"))
            environment.save(record)
        }

        XCTAssertEqual(environment.visibleDecisions.count, FeatureAccess.freeHistoryLimit)
        XCTAssertTrue(environment.hasHiddenHistory)
        XCTAssertEqual(
            environment.decisions.count,
            FeatureAccess.freeHistoryLimit + 3,
            "Nothing is deleted — it is only out of view until Pro"
        )
    }

    // MARK: Failures

    func testAFailedAnalysisSavesNothing() async throws {
        service.failure = .serverUnavailable
        let coordinator = makeCoordinator()
        coordinator.start(prompt: "MacBook Air or MacBook Pro?")
        try await settle(coordinator)

        guard case .failed = coordinator.phase else { return XCTFail("Expected a failure") }
        XCTAssertNil(coordinator.makeChoice(optionID: "air"))
        XCTAssertTrue(environment.decisions.isEmpty)
    }
}

/// Stands in for the network so the app layer can be exercised end to end.
private final class StubAnalysisService: DecisionAnalysisService, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastRequest: DecisionAnalysisRequest?
    var failure: RudderServiceError?

    var lastRequest: DecisionAnalysisRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequest
    }

    private func record(_ request: DecisionAnalysisRequest) -> RudderServiceError? {
        lock.lock()
        defer { lock.unlock() }
        _lastRequest = request
        return failure
    }

    func analyse(_ request: DecisionAnalysisRequest) async throws -> ValidatedAIResponse {
        if let failure = record(request) { throw failure }

        let response = AIDecisionResponse(
            decisionStatus: "ready",
            category: "technology",
            complexity: "medium",
            understanding: .init(restatement: "You're choosing a laptop."),
            researchNeeded: .init(level: "none"),
            criteria: [
                .init(id: "convenience", name: "Convenience", weight: 0.6),
                .init(id: "price", name: "Price", weight: 0.4)
            ],
            // Dominant enough on convenience to stay Strong across every
            // StabilityEngine scenario (weight variations, equal weights, the
            // priority swap, weakening the winner — verified by simulation before
            // relying on it here: hold rate 1.0, margin 0.45), while still losing
            // on price — the trade-off the memory tests below need to learn
            // "prioritizes convenience over price" from. A version dominant on
            // both criteria fixed Strong but left no trade-off, so memory could
            // never find a preference to learn; this fixture satisfies both.
            options: [
                .init(id: "air", name: "MacBook Air", scores: ["convenience": 0.98, "price": 0.55]),
                .init(id: "pro", name: "MacBook Pro", scores: ["convenience": 0.1, "price": 0.75])
            ],
            recommendation: .init(
                optionId: "air",
                headline: "Best fit for you",
                reasons: [.init(title: "Lighter", detail: "You carry it every day.")]
            )
        )
        return try AIResponseValidator.validate(response)
    }
}
