import XCTest
@testable import RudderCore

final class QuestionEngineTests: XCTestCase {

    private func candidate(
        _ id: String,
        impact: Double,
        friction: Double = 0.2,
        research: Bool = false,
        key: String? = nil
    ) -> QuestionCandidate {
        QuestionCandidate(
            id: id,
            text: "Question \(id)?",
            expectedImpact: impact,
            friction: friction,
            answerableByResearch: research,
            knowledgeKey: key
        )
    }

    func testNothingIsAskedWhenTheDecisionIsAlreadyStable() {
        let plan = QuestionEngine.plan(
            candidates: [candidate("a", impact: 0.9)],
            complexity: .complex,
            decisionIsAlreadyStable: true
        )
        XCTAssertFalse(plan.shouldAsk)
        XCTAssertEqual(plan.suppressed.first?.reason, .decisionAlreadyStable)
    }

    func testQuestionsTheSystemCanResearchAreNeverAsked() {
        let plan = QuestionEngine.plan(
            candidates: [candidate("price", impact: 0.9, research: true)],
            complexity: .complex
        )
        XCTAssertFalse(plan.shouldAsk)
        XCTAssertEqual(plan.suppressed.first?.reason, .answerableByResearch)
    }

    func testAlreadyKnownInformationIsNotAskedAgain() {
        let plan = QuestionEngine.plan(
            candidates: [candidate("pref", impact: 0.9, key: "convenience>price")],
            complexity: .complex,
            knownKeys: ["convenience>price"]
        )
        XCTAssertFalse(plan.shouldAsk)
        XCTAssertEqual(plan.suppressed.first?.reason, .alreadyKnown)
    }

    func testLowImpactQuestionsAreNotAsked() {
        let plan = QuestionEngine.plan(candidates: [candidate("colour", impact: 0.05)], complexity: .complex)
        XCTAssertFalse(plan.shouldAsk)
        XCTAssertEqual(plan.suppressed.first?.reason, .lowImpact)
    }

    func testAQuestionThatCostsMoreThanItIsWorthIsNotAsked() {
        let plan = QuestionEngine.plan(
            candidates: [candidate("spreadsheet", impact: 0.5, friction: 0.9)],
            complexity: .complex
        )
        XCTAssertFalse(plan.shouldAsk)
        XCTAssertEqual(plan.suppressed.first?.reason, .frictionExceedsValue)
    }

    func testOnlyOneQuestionIsEverOfferedAtATime() {
        let plan = QuestionEngine.plan(
            candidates: [
                candidate("a", impact: 0.6),
                candidate("b", impact: 0.9),
                candidate("c", impact: 0.8)
            ],
            complexity: .complex
        )
        XCTAssertEqual(plan.next?.id, "b", "The highest-value question wins")
        XCTAssertEqual(plan.suppressed.filter { $0.reason == .supersededByBetterQuestion }.count, 2)
    }

    func testCeilingsMatchComplexity() {
        XCTAssertEqual(DecisionComplexity.simple.questionCeiling, 1)
        XCTAssertEqual(DecisionComplexity.medium.questionCeiling, 3)
        XCTAssertEqual(DecisionComplexity.complex.questionCeiling, 5)
    }

    func testBudgetIsExhaustedAfterTheCeiling() {
        let plan = QuestionEngine.plan(
            candidates: [candidate("a", impact: 0.9)],
            complexity: .simple,
            alreadyAskedIDs: ["previous"]
        )
        XCTAssertFalse(plan.shouldAsk)
        XCTAssertEqual(plan.suppressed.first?.reason, .budgetExhausted)
        XCTAssertEqual(plan.remainingBudget, 0)
    }

    func testTheSameQuestionIsNeverAskedTwice() {
        let plan = QuestionEngine.plan(
            candidates: [candidate("a", impact: 0.9)],
            complexity: .complex,
            alreadyAskedIDs: ["a"]
        )
        XCTAssertFalse(plan.shouldAsk)
        XCTAssertEqual(plan.suppressed.first?.reason, .alreadyAsked)
    }

    func testAHighValueQuestionOnlyTheUserCanAnswerIsAsked() {
        let plan = QuestionEngine.plan(
            candidates: [candidate("relocate", impact: 0.9, friction: 0.2)],
            complexity: .complex
        )
        XCTAssertEqual(plan.next?.id, "relocate")
    }

    func testNoCandidatesMeansNoQuestion() {
        XCTAssertFalse(QuestionEngine.plan(candidates: [], complexity: .complex).shouldAsk)
    }
}
