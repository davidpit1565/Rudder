import XCTest
@testable import RudderCore

final class ReadinessEngineTests: XCTestCase {

    private func input(
        options: Int = 2,
        criteria: Int = 3,
        coverage: Double = 0.8,
        research: ResearchLevel = .none,
        researchAttempted: Bool = true,
        conflicts: Bool = false,
        question: QuestionCandidate? = nil,
        margin: Double = 0.2
    ) -> ReadinessInput {
        ReadinessInput(
            viableOptionCount: options,
            criteriaCount: criteria,
            evidenceCoverage: coverage,
            requestedResearchLevel: research,
            researchAttempted: researchAttempted,
            hasUnresolvedConflicts: conflicts,
            questionPlan: QuestionPlan(next: question, suppressed: [], remainingBudget: 3),
            margin: margin
        )
    }

    func testReadyWhenNothingIsMissing() {
        XCTAssertEqual(ReadinessEngine.assess(input()).state, .ready)
    }

    func testResearchComesBeforeQuestions() {
        let candidate = QuestionCandidate(id: "q", text: "?", expectedImpact: 0.9)
        let assessment = ReadinessEngine.assess(
            input(research: .deep, researchAttempted: false, question: candidate)
        )
        XCTAssertEqual(assessment.state, .needsResearch, "Look it up before asking the user")
    }

    func testAskOnlyAfterResearchHasBeenTried() {
        let candidate = QuestionCandidate(id: "q", text: "?", expectedImpact: 0.9)
        let assessment = ReadinessEngine.assess(input(research: .deep, researchAttempted: true, question: candidate))
        XCTAssertEqual(assessment.state, .needsOneQuestion)
    }

    func testNoViableOptionsIsNotEnoughToDecide() {
        let assessment = ReadinessEngine.assess(input(options: 0))
        XCTAssertEqual(assessment.state, .notEnoughToDecide)
        XCTAssertFalse(assessment.missing.isEmpty, "The user must be told exactly what is missing")
    }

    func testNoCriteriaIsNotEnoughToDecide() {
        XCTAssertEqual(ReadinessEngine.assess(input(criteria: 0)).state, .notEnoughToDecide)
    }

    func testThinEvidenceRefusesToRecommend() {
        let assessment = ReadinessEngine.assess(input(coverage: 0.1))
        XCTAssertEqual(assessment.state, .notEnoughToDecide)
    }

    func testConflictingInformationIsNamedInWhatIsMissing() {
        let assessment = ReadinessEngine.assess(input(coverage: 0.1, conflicts: true))
        XCTAssertEqual(assessment.state, .notEnoughToDecide)
        XCTAssertTrue(assessment.missing.contains { $0.lowercased().contains("contradict") })
    }
}
