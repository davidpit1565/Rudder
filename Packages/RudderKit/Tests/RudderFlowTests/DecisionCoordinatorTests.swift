import XCTest
import RudderCore
@testable import RudderFlow

@MainActor
final class DecisionCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        _ service: MockAnalysisService,
        memory: [MemoryEntry] = []
    ) -> DecisionCoordinator {
        DecisionCoordinator(service: service, memoryProvider: { memory })
    }

    /// Waits for the pipeline to settle rather than for a fixed time.
    ///
    /// `ignoring` is the phase the coordinator was in before the action under
    /// test, so answering a question waits for the *next* state rather than
    /// returning immediately on the one still on screen.
    private func settle(
        _ coordinator: DecisionCoordinator,
        ignoring previous: DecisionCoordinator.Phase? = nil,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        // Phase is checked before the deadline, not after: otherwise a phase that
        // settles during the final sleep can still report failure if the deadline
        // happens to pass in that same window.
        while true {
            let phase = coordinator.phase
            let isSettled: Bool
            switch phase {
            case .idle, .working: isSettled = false
            default: isSettled = true
            }
            if isSettled, phase != previous { return }
            guard Date() < deadline else {
                XCTFail("Pipeline did not settle: \(phase)")
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Happy path

    func testAStraightforwardDecisionReachesARecommendationWithoutAskingAnything() async throws {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)

        coordinator.start(prompt: "MacBook Air or MacBook Pro?")
        try await settle(coordinator)

        guard case .finished(let result) = coordinator.phase else {
            return XCTFail("Expected a recommendation, got \(coordinator.phase)")
        }
        XCTAssertEqual(result.recommendedOptionID, "air")
        XCTAssertTrue(coordinator.questionsAsked.isEmpty, "Zero questions is a successful outcome")
        XCTAssertEqual(service.requestCount, 1, "One model call for a simple decision")
    }

    func testStrengthComesFromTheEngineNotTheModel() async throws {
        let service = MockAnalysisService(response: Responses.ready(strengthStyle: .dominant))
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Laptop?")
        try await settle(coordinator)

        guard case .finished(let result) = coordinator.phase else { return XCTFail() }
        XCTAssertEqual(result.strength, .strong)
        XCTAssertEqual(result.strength, result.stability.strength)
    }

    func testASplitDecisionIsNotPresentedAsStrong() async throws {
        let service = MockAnalysisService(response: Responses.ready(strengthStyle: .split))
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Laptop?")
        try await settle(coordinator)

        guard case .finished(let result) = coordinator.phase else { return XCTFail() }
        XCTAssertNotEqual(result.strength, .strong)
        XCTAssertFalse(result.stability.flips.isEmpty)
    }

    func testATiedDecisionIsReportedAsUnclear() async throws {
        let service = MockAnalysisService(response: Responses.ready(strengthStyle: .tied))
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Laptop?")
        try await settle(coordinator)

        guard case .finished(let result) = coordinator.phase else { return XCTFail() }
        XCTAssertEqual(result.strength, .unclear)
        XCTAssertFalse(result.hasClearWinner)
    }

    // MARK: Questions

    func testOnlyTheQuestionWorthAskingReachesTheUser() async throws {
        let service = MockAnalysisService(steps: [
            .respond(Responses.askingOneQuestion()),
            .respond(Responses.ready())
        ])
        let coordinator = makeCoordinator(service)

        coordinator.start(prompt: "Should I take this job offer in another city?")
        try await settle(coordinator)

        guard case .asking(let question) = coordinator.phase else {
            return XCTFail("Expected one question, got \(coordinator.phase)")
        }
        XCTAssertEqual(question.id, "relocate", "Researchable and trivial questions are never asked")
        XCTAssertNotNil(coordinator.preliminary, "A direction is offered before the question")

        let asking = coordinator.phase
        coordinator.answer("Yes", to: question)
        try await settle(coordinator, ignoring: asking)

        guard case .finished = coordinator.phase else {
            return XCTFail("Expected a recommendation, got \(coordinator.phase)")
        }
        XCTAssertEqual(coordinator.questionsAsked, ["relocate"])
        XCTAssertEqual(service.lastRequest()?.answers.first?.answer, "Yes")
    }

    func testAQuestionCanBeDeclinedAndThePipelineContinues() async throws {
        let service = MockAnalysisService(steps: [
            .respond(Responses.askingOneQuestion()),
            .respond(Responses.ready())
        ])
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Job offer?")
        try await settle(coordinator)

        guard case .asking(let question) = coordinator.phase else { return XCTFail() }
        let asking = coordinator.phase
        coordinator.skipQuestion(question)
        try await settle(coordinator, ignoring: asking)

        guard case .finished = coordinator.phase else {
            return XCTFail("Declining must not dead-end, got \(coordinator.phase)")
        }
    }

    func testTheSameQuestionIsNeverAskedTwice() async throws {
        let service = MockAnalysisService(steps: [
            .respond(Responses.askingOneQuestion()),
            .respond(Responses.askingOneQuestion())
        ])
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Job offer?")
        try await settle(coordinator)

        guard case .asking(let question) = coordinator.phase else { return XCTFail() }
        let asking = coordinator.phase
        coordinator.answer("Yes", to: question)
        try await settle(coordinator, ignoring: asking)

        // The backend asked again; the question engine refuses to repeat itself.
        if case .asking(let second) = coordinator.phase {
            XCTAssertNotEqual(second.id, question.id)
        }
        XCTAssertEqual(coordinator.questionsAsked.count, 1)
    }

    func testAPreferenceAlreadyInMemoryIsNotAskedAbout() async throws {
        var response = Responses.askingOneQuestion()
        response.requiredQuestions = [
            .init(
                id: "pref",
                text: "Do you care more about convenience or price?",
                expectedImpact: 0.9,
                friction: 0.2,
                answerableByResearch: false,
                knowledgeKey: "convenience>price"
            )
        ]
        let service = MockAnalysisService(steps: [.respond(response)])
        let memory = [MemoryEntry(key: "convenience>price", statement: "You often prioritize convenience over price.", evidenceCount: 3)]
        let coordinator = makeCoordinator(service, memory: memory)

        coordinator.start(prompt: "Which plan should I pick?")
        try await settle(coordinator)

        if case .asking = coordinator.phase {
            XCTFail("RUDDER already knows this")
        }
        XCTAssertEqual(service.lastRequest()?.knownPreferences.count, 1)
    }

    // MARK: Research

    func testResearchIsRequestedOnceAndNeverLoops() async throws {
        let service = MockAnalysisService(steps: [
            .respond(Responses.needingResearch()),
            .respond(Responses.needingResearch()),
            .respond(Responses.ready())
        ])
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Which car should I buy?")
        try await settle(coordinator)

        guard case .finished = coordinator.phase else {
            return XCTFail("Expected the pipeline to finish rather than loop, got \(coordinator.phase)")
        }
        XCTAssertLessThanOrEqual(service.requestCount, 2, "A second research request must not restart the loop")
    }

    func testTrivialDecisionsDoNotBuyResearch() async throws {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Pizza or pasta tonight?")
        try await settle(coordinator)

        XCTAssertEqual(service.lastRequest()?.researchLevel, ResearchLevel.none.rawValue)
        XCTAssertEqual(service.lastRequest()?.maximumResearchCalls, 0)
    }

    func testExpensiveDecisionsGetTheDeepBudget() async throws {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Which car should I buy for €28,000?")
        try await settle(coordinator)

        XCTAssertEqual(service.lastRequest()?.researchLevel, ResearchLevel.deep.rawValue)
        XCTAssertEqual(service.lastRequest()?.questionCeiling, 5)
    }

    // MARK: Not enough information

    func testNothingKnownMeansNoRecommendation() async throws {
        let service = MockAnalysisService(response: Responses.notEnoughInformation())
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Should I pick one or two?")
        try await settle(coordinator)

        guard case .insufficient(let missing, _) = coordinator.phase else {
            return XCTFail("Expected an honest refusal, got \(coordinator.phase)")
        }
        XCTAssertFalse(missing.isEmpty, "The user must be told what is missing")
    }

    // MARK: Failures

    func testAnOfflineFailureIsReportedAndRetryable() async throws {
        let service = MockAnalysisService(steps: [.fail(.offline), .respond(Responses.ready())])
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Laptop?")
        try await settle(coordinator)

        guard case .failed(let error) = coordinator.phase else { return XCTFail() }
        XCTAssertEqual(error, .offline)
        XCTAssertTrue(error.isRetryable)

        coordinator.retry()
        try await settle(coordinator)
        guard case .finished = coordinator.phase else { return XCTFail("Retry must recover") }
    }

    func testAMalformedResponseSurfacesAsAFailureNotACrash() async throws {
        var broken = Responses.ready()
        broken.decisionStatus = "nonsense"
        let service = MockAnalysisService(steps: [.respond(broken)])
        let coordinator = makeCoordinator(service)

        coordinator.start(prompt: "Laptop?")
        try await settle(coordinator)

        guard case .failed(let error) = coordinator.phase else { return XCTFail() }
        XCTAssertEqual(error, .invalidResponse)
    }

    func testCancellingLeavesNoResult() async throws {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "Laptop?")
        coordinator.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)

        if case .finished = coordinator.phase {
            XCTFail("A cancelled decision must not complete")
        }
    }

    // MARK: Input handling

    func testEmptyAndTinyInputIsIgnored() {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)

        coordinator.start(prompt: "")
        coordinator.start(prompt: "  ")
        coordinator.start(prompt: "hm")
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(service.requestCount, 0)
    }

    func testAVeryLongPromptIsStillAccepted() async throws {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: String(repeating: "I need to decide something important. ", count: 400))
        try await settle(coordinator)

        guard case .finished = coordinator.phase else { return XCTFail() }
    }

    // MARK: Choosing

    func testChoosingTheRecommendationProducesASavableRecord() async throws {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "MacBook Air or MacBook Pro?")
        try await settle(coordinator)

        let record = coordinator.makeChoice(optionID: "air")
        XCTAssertEqual(record?.chosenOptionID, "air")
        XCTAssertEqual(record?.followedRecommendation, true)
        XCTAssertEqual(record?.title, "MacBook Air vs MacBook Pro")
        XCTAssertNotNil(record?.chosenAt)
    }

    func testOverridingTheRecommendationIsRecordedWithoutArgument() async throws {
        let service = MockAnalysisService(response: Responses.ready())
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "MacBook Air or MacBook Pro?")
        try await settle(coordinator)

        let record = coordinator.makeChoice(optionID: "pro")
        XCTAssertEqual(record?.chosenOptionID, "pro")
        XCTAssertEqual(record?.followedRecommendation, false)
        XCTAssertEqual(coordinator.chosenOptionID, "pro")
    }

    func testAChoiceCanStillBeMadeWhenInformationWasThin() async throws {
        var thin = Responses.notEnoughInformation()
        // One known fact out of four: below the bar for a responsible recommendation.
        thin.options[0].scores = ["a": 0.9]
        thin.recommendation = .init(optionId: "one", headline: "One", reasons: [.init(title: "t", detail: "d")])
        let service = MockAnalysisService(steps: [.respond(thin)])
        let coordinator = makeCoordinator(service)
        coordinator.start(prompt: "One or two?")
        try await settle(coordinator)

        guard case .insufficient(_, let partial) = coordinator.phase else {
            return XCTFail("Expected insufficient, got \(coordinator.phase)")
        }
        XCTAssertNotNil(partial, "A useful partial answer is still offered")
        XCTAssertNotNil(coordinator.makeChoice(optionID: "one"))
    }
}

/// Cost control that actually holds, rather than a number in a struct.
@MainActor
final class BudgetEnforcementTests: XCTestCase {

    private func settle(_ coordinator: DecisionCoordinator, ignoring previous: DecisionCoordinator.Phase? = nil) async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let phase = coordinator.phase
            let isSettled: Bool
            switch phase {
            case .idle, .working: isSettled = false
            default: isSettled = true
            }
            if isSettled, phase != previous { return }
            guard Date() < deadline else {
                XCTFail("Pipeline did not settle: \(phase)")
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testABacklogOfQuestionsCannotOutspendTheBudget() async throws {
        // A backend that keeps asking for one more thing, forever.
        let steps = (0..<12).map { index -> MockAnalysisService.Step in
            var response = Responses.askingOneQuestion()
            response.requiredQuestions = [
                .init(
                    id: "q\(index)",
                    text: "Question \(index)?",
                    kind: "free_text",
                    choices: [],
                    expectedImpact: 0.9,
                    friction: 0.1,
                    answerableByResearch: false
                )
            ]
            return .respond(response)
        }
        let service = MockAnalysisService(steps: steps)
        let coordinator = DecisionCoordinator(service: service, memoryProvider: { [] })

        coordinator.start(prompt: "Should I take this job offer in another city?")
        try await settle(coordinator)

        // Answer whatever it asks, as many times as it will let us.
        for _ in 0..<12 {
            guard case .asking(let question) = coordinator.phase else { break }
            let asking = coordinator.phase
            coordinator.answer("Yes", to: question)
            try await settle(coordinator, ignoring: asking)
        }

        guard case .finished = coordinator.phase else {
            return XCTFail("The pipeline must land on an answer, not keep asking: \(coordinator.phase)")
        }

        let budget = ResearchPolicy.budget(complexity: .complex, category: .career)
        XCTAssertLessThanOrEqual(
            service.requestCount,
            budget.maximumModelCalls,
            "A decision must never buy more model calls than its budget allows"
        )
        XCTAssertLessThanOrEqual(coordinator.questionsAsked.count, budget.questionCeiling)
    }
}
