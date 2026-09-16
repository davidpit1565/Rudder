import XCTest
@testable import RudderCore

final class FlowTests: XCTestCase {

    func testHappyPathRunsEndToEnd() throws {
        var machine = DecisionFlowMachine()
        try machine.transition(to: .understanding)
        try machine.transition(to: .readinessCheck)
        try machine.transition(to: .research)
        try machine.transition(to: .readinessCheck)
        try machine.transition(to: .ask)
        try machine.transition(to: .readinessCheck)
        try machine.transition(to: .analyze)
        try machine.transition(to: .stressTest)
        try machine.transition(to: .selfChallenge)
        try machine.transition(to: .recommendation)
        try machine.transition(to: .userChoice)
        try machine.transition(to: .saved)
        XCTAssertEqual(machine.state, .saved)
    }

    func testARecommendationCannotSkipStressTesting() {
        var machine = DecisionFlowMachine(state: .analyze)
        XCTAssertThrowsError(try machine.transition(to: .recommendation)) { error in
            XCTAssertEqual(
                error as? DecisionFlowError,
                .illegalTransition(from: .analyze, to: .recommendation)
            )
        }
    }

    func testAnalysisCannotStartBeforeTheReadinessCheck() {
        var machine = DecisionFlowMachine(state: .understanding)
        XCTAssertThrowsError(try machine.transition(to: .analyze))
    }

    func testSelfChallengeAlwaysPrecedesTheRecommendation() {
        for state in DecisionFlowState.allCases {
            let allowed = DecisionFlowMachine.allowedTransitions(from: state)
            if allowed.contains(.recommendation) {
                XCTAssertTrue(
                    state == .selfChallenge || state == .userChoice,
                    "\(state) must not be able to reach a recommendation directly"
                )
            }
        }
    }

    func testSavedIsTerminal() {
        XCTAssertTrue(DecisionFlowMachine.allowedTransitions(from: .saved).isEmpty)
        var machine = DecisionFlowMachine(state: .saved)
        XCTAssertThrowsError(try machine.transition(to: .start))
    }

    func testEveryStateCanFailSafely() {
        for state in DecisionFlowState.allCases where state != .failed && state != .saved {
            XCTAssertTrue(
                DecisionFlowMachine.allowedTransitions(from: state).contains(.failed),
                "\(state) must be able to fail without getting stuck"
            )
        }
    }

    func testFailureCanBeRetried() throws {
        var machine = DecisionFlowMachine(state: .failed)
        try machine.transition(to: .start)
        XCTAssertEqual(machine.state, .start)
    }

    func testReadinessMapsOntoExactlyOneNextState() {
        XCTAssertEqual(DecisionFlowMachine.next(for: .ready), .analyze)
        XCTAssertEqual(DecisionFlowMachine.next(for: .needsResearch), .research)
        XCTAssertEqual(DecisionFlowMachine.next(for: .needsOneQuestion), .ask)
        XCTAssertEqual(DecisionFlowMachine.next(for: .notEnoughToDecide), .insufficient)
    }

    func testEveryReadinessOutcomeIsReachableFromTheReadinessCheck() {
        let allowed = DecisionFlowMachine.allowedTransitions(from: .readinessCheck)
        for readiness in ReadinessState.allCases {
            XCTAssertTrue(allowed.contains(DecisionFlowMachine.next(for: readiness)))
        }
    }

    func testProgressCopyNeverShowsAQuestionCounter() {
        for state in DecisionFlowState.allCases {
            let copy = [state.progressTitle, state.progressSubtitle].compactMap { $0 }.joined(separator: " ")
            XCTAssertFalse(copy.lowercased().contains("question 1"))
            XCTAssertFalse(copy.lowercased().contains(" of 5"))
        }
    }

    func testAskingHasNoWaitingUI() {
        // The question screen is a real screen, not a loading state.
        XCTAssertNil(DecisionFlowState.ask.progressTitle)
        XCTAssertNil(DecisionFlowState.recommendation.progressTitle)
    }

    func testHistoryRecordsThePathTaken() throws {
        var machine = DecisionFlowMachine()
        try machine.transition(to: .understanding)
        try machine.transition(to: .readinessCheck)
        XCTAssertEqual(machine.history, [.start, .understanding, .readinessCheck])
    }
}
