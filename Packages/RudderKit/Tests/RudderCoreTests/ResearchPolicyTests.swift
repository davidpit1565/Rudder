import XCTest
@testable import RudderCore

final class ResearchPolicyTests: XCTestCase {

    func testSimpleLifeDecisionsSpendNothing() {
        let budget = ResearchPolicy.budget(complexity: .simple, category: .lifePlanning)
        XCTAssertEqual(budget.researchLevel, .none)
        XCTAssertEqual(budget.maximumResearchCalls, 0)
        XCTAssertEqual(budget.questionCeiling, 1)
    }

    func testComplexPurchasesGetTheFullPipeline() {
        let budget = ResearchPolicy.budget(complexity: .complex, category: .purchase)
        XCTAssertEqual(budget.researchLevel, .deep)
        XCTAssertEqual(budget.maximumResearchCalls, 6)
        XCTAssertEqual(budget.questionCeiling, 5)
        XCTAssertEqual(budget.maximumModelCalls, 6)
    }

    func testFactDrivenCategoriesAlwaysGetAtLeastLightResearch() {
        let budget = ResearchPolicy.budget(complexity: .simple, category: .technology)
        XCTAssertEqual(budget.researchLevel, .light)
    }

    func testTheModelCanRequestLessResearchButNeverMore() {
        let reduced = ResearchPolicy.budget(complexity: .complex, category: .purchase, requestedLevel: .light)
        XCTAssertEqual(reduced.researchLevel, .light)

        let inflated = ResearchPolicy.budget(complexity: .simple, category: .lifePlanning, requestedLevel: .deep)
        XCTAssertEqual(inflated.researchLevel, .none, "A model cannot talk its way into a bigger budget")
    }

    func testBudgetsAreBoundedAtEveryLevel() {
        for complexity in DecisionComplexity.allCases {
            for category in DecisionCategory.allCases {
                let budget = ResearchPolicy.budget(complexity: complexity, category: category)
                XCTAssertLessThanOrEqual(budget.maximumResearchCalls, 6)
                XCTAssertLessThanOrEqual(budget.maximumModelCalls, 6)
                XCTAssertLessThanOrEqual(budget.questionCeiling, 5)
            }
        }
    }
}
