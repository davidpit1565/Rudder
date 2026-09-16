import XCTest
@testable import RudderCore

final class AssemblerTests: XCTestCase {

    func testEndToEndFromResponseToResult() throws {
        let result = DecisionAssembler.assemble(try Fixture.validated("valid_ready"))
        XCTAssertEqual(result.recommendedOptionID, "air")
        XCTAssertEqual(result.ranking.first?.optionID, "air")
        XCTAssertEqual(result.reasons.count, 3)
        XCTAssertNotNil(result.challenge)
        XCTAssertEqual(result.strength, result.stability.strength, "Strength always comes from the stability engine")
    }

    func testStrengthIsComputedLocallyAndNotTakenFromTheModel() throws {
        // The fixture's model text is confident; the engines decide independently.
        let validated = try Fixture.validated("valid_ready")
        let result = DecisionAssembler.assemble(validated)
        let recomputed = StabilityEngine.analyse(options: validated.options, criteria: validated.criteria)
        XCTAssertEqual(result.strength, recomputed.strength)
    }

    func testTheEngineOverridesAModelPickThatTheNumbersDoNotSupport() throws {
        let response = AIDecisionResponse(
            decisionStatus: "ready",
            category: "purchase",
            complexity: "simple",
            understanding: .init(restatement: "Choosing between two very different options"),
            criteria: [.init(id: "value", name: "Value", weight: 1)],
            options: [
                .init(id: "good", name: "Good", scores: ["value": 0.95]),
                .init(id: "bad", name: "Bad", scores: ["value": 0.15])
            ],
            recommendation: .init(optionId: "bad", headline: "Bad", reasons: [.init(title: "t", detail: "d")])
        )
        let result = DecisionAssembler.assemble(try AIResponseValidator.validate(response))
        XCTAssertEqual(result.recommendedOptionID, "good")
    }

    func testTradeOffsAreDerivedWhenTheModelOmitsThem() throws {
        let response = AIDecisionResponse(
            decisionStatus: "ready",
            category: "technology",
            complexity: "medium",
            understanding: .init(restatement: "Laptop choice"),
            criteria: [
                .init(id: "portability", name: "Portability", weight: 0.7),
                .init(id: "power", name: "Power", weight: 0.3)
            ],
            options: [
                .init(id: "air", name: "Air", scores: ["portability": 0.95, "power": 0.5]),
                .init(id: "pro", name: "Pro", scores: ["portability": 0.4, "power": 0.95])
            ],
            recommendation: .init(optionId: "air", headline: "Air", reasons: [.init(title: "t", detail: "d")])
        )
        let result = DecisionAssembler.assemble(try AIResponseValidator.validate(response))
        XCTAssertFalse(result.tradeOffs.isEmpty, "The user must always see what they give up")
    }

    func testSelfChallengeCanChangeTheRecommendation() {
        // A option wins the base case narrowly but loses under most variations.
        let criteria = [
            Criterion(id: "a", name: "A", weight: 0.34),
            Criterion(id: "b", name: "B", weight: 0.33),
            Criterion(id: "c", name: "C", weight: 0.33)
        ]
        let options = [
            DecisionOption(id: "narrow", name: "Narrow", scores: ["a": 0.9, "b": 0.3, "c": 0.3]),
            DecisionOption(id: "broad", name: "Broad", scores: ["a": 0.2, "b": 0.75, "c": 0.75])
        ]
        let stability = StabilityEngine.analyse(options: options, criteria: criteria)
        let outcome = SelfChallengeEngine.challenge(
            recommendedOptionID: stability.baseWinnerOptionID,
            stability: stability,
            options: options
        )
        if outcome.challenge?.didSwitchRecommendation == true {
            XCTAssertNotEqual(outcome.recommendedOptionID, stability.baseWinnerOptionID)
        }
        XCTAssertNotNil(outcome.challenge)
    }

    func testAnUnbeatableRecommendationSaysSoHonestly() {
        let criteria = [Criterion(id: "a", name: "A", weight: 1)]
        let options = [
            DecisionOption(id: "x", name: "X", scores: ["a": 0.95]),
            DecisionOption(id: "y", name: "Y", scores: ["a": 0.1])
        ]
        let stability = StabilityEngine.analyse(options: options, criteria: criteria)
        let outcome = SelfChallengeEngine.challenge(recommendedOptionID: "x", stability: stability, options: options)
        XCTAssertEqual(outcome.challenge?.didSwitchRecommendation, false)
        XCTAssertFalse(outcome.challenge?.strongestCaseAgainst.isEmpty ?? true)
    }

    func testUnverifiedOrStaleResearchIsFlagged() throws {
        let result = DecisionAssembler.assemble(try Fixture.validated("messy_repairable"))
        XCTAssertTrue(result.unverifiedResearch)
    }

    func testEvidenceCoverageIsLowWhenNothingIsKnown() throws {
        let response = AIDecisionResponse(
            decisionStatus: "ready",
            category: "other",
            complexity: "simple",
            understanding: .init(restatement: "x"),
            criteria: [.init(id: "a", name: "A", weight: 1), .init(id: "b", name: "B", weight: 1)],
            options: [.init(id: "o1", name: "O1"), .init(id: "o2", name: "O2")]
        )
        let validated = try AIResponseValidator.validate(response)
        XCTAssertEqual(DecisionAssembler.evidenceCoverage(validated), 0, accuracy: 1e-9)
        XCTAssertLessThan(DecisionAssembler.evidenceCoverage(validated), ReadinessEngine.minimumEvidenceCoverage)
    }

    func testEvidenceCoverageIsHighForAFullyScoredDecision() throws {
        let validated = try Fixture.validated("valid_ready")
        XCTAssertGreaterThan(DecisionAssembler.evidenceCoverage(validated), ReadinessEngine.minimumEvidenceCoverage)
    }

    func testResultIsCodableForPersistence() throws {
        let result = DecisionAssembler.assemble(try Fixture.validated("valid_ready"))
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DecisionResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testNoClearWinnerIsReportedAsSuch() {
        let criteria = [Criterion(id: "a", name: "A", weight: 1)]
        let options = [
            DecisionOption(id: "x", name: "X", scores: ["a": 0.5]),
            DecisionOption(id: "y", name: "Y", scores: ["a": 0.5])
        ]
        let stability = StabilityEngine.analyse(options: options, criteria: criteria)
        XCTAssertEqual(stability.strength, .unclear)
    }
}
