import XCTest
@testable import RudderCore

final class DecisionEngineTests: XCTestCase {

    func testWeightsAreNormalised() {
        let criteria = makeCriteria([("a", 2), ("b", 2), ("c", 4)])
        let weights = DecisionEngine.normalisedWeights(for: criteria)
        XCTAssertEqual(weights.values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(weights["c"]!, 0.5, accuracy: 1e-9)
    }

    func testZeroWeightsFallBackToEqualImportance() {
        let criteria = makeCriteria([("a", 0), ("b", 0)])
        let weights = DecisionEngine.normalisedWeights(for: criteria)
        XCTAssertEqual(weights["a"]!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(weights["b"]!, 0.5, accuracy: 1e-9)
    }

    func testNegativeWeightsAreClampedNotPropagated() {
        let criteria = [Criterion(id: "a", name: "A", weight: -5), Criterion(id: "b", name: "B", weight: 1)]
        let weights = DecisionEngine.normalisedWeights(for: criteria)
        XCTAssertEqual(weights["a"]!, 0, accuracy: 1e-9)
        XCTAssertEqual(weights["b"]!, 1, accuracy: 1e-9)
    }

    func testRankingPrefersTheOptionThatWinsOnWhatMatters() {
        let criteria = makeCriteria([("portability", 0.8), ("power", 0.2)])
        let options = [
            makeOption("air", ["portability": 0.9, "power": 0.5]),
            makeOption("pro", ["portability": 0.4, "power": 0.95])
        ]
        let evaluation = DecisionEngine.evaluate(options: options, criteria: criteria)
        XCTAssertEqual(evaluation.winner?.optionID, "air")
        XCTAssertGreaterThan(evaluation.margin, 0)
    }

    func testMissingScoreIsTreatedAsUnknownMidpoint() {
        let option = makeOption("x", ["a": 0.9])
        XCTAssertEqual(option.score(for: "b"), 0.5, accuracy: 1e-9)
    }

    func testScoresOutsideRangeAreClampedWhenRead() {
        let option = DecisionOption(id: "x", name: "X", scores: ["a": 4, "b": -2])
        XCTAssertEqual(option.score(for: "a"), 1, accuracy: 1e-9)
        XCTAssertEqual(option.score(for: "b"), 0, accuracy: 1e-9)
    }

    func testHardConstraintsEliminateOptions() {
        let criteria = makeCriteria([("price", 1)])
        let options = [
            makeOption("cheap", ["price": 0.9], failed: ["Over your budget"]),
            makeOption("ok", ["price": 0.4])
        ]
        let evaluation = DecisionEngine.evaluate(options: options, criteria: criteria)
        XCTAssertEqual(evaluation.ranking.count, 1)
        XCTAssertEqual(evaluation.winner?.optionID, "ok")
        XCTAssertEqual(evaluation.eliminated.first?.optionID, "cheap")
    }

    func testRankingIsDeterministicForIdenticalScores() {
        let criteria = makeCriteria([("a", 1)])
        let options = [makeOption("zebra", ["a": 0.5]), makeOption("apple", ["a": 0.5])]
        let first = DecisionEngine.evaluate(options: options, criteria: criteria).ranking.map(\.optionID)
        let second = DecisionEngine.evaluate(options: options.reversed(), criteria: criteria).ranking.map(\.optionID)
        XCTAssertEqual(first, second)
    }

    func testTradeOffsNameWhatYouGiveUp() {
        let criteria = makeCriteria([("portability", 0.7), ("power", 0.3)])
        let air = makeOption("air", ["portability": 0.95, "power": 0.5])
        let pro = makeOption("pro", ["portability": 0.4, "power": 0.95])
        let tradeOffs = DecisionEngine.tradeOffs(winner: air, runnerUp: pro, criteria: criteria)
        XCTAssertEqual(tradeOffs.count, 1)
        XCTAssertTrue(tradeOffs[0].givingUp.contains("Power"))
    }

    func testNoTradeOffWhenTheWinnerDominates() {
        let criteria = makeCriteria([("a", 1), ("b", 1)])
        let winner = makeOption("w", ["a": 0.9, "b": 0.9])
        let loser = makeOption("l", ["a": 0.2, "b": 0.2])
        XCTAssertTrue(DecisionEngine.tradeOffs(winner: winner, runnerUp: loser, criteria: criteria).isEmpty)
    }

    func testEmptyInputsDoNotCrash() {
        let evaluation = DecisionEngine.evaluate(options: [], criteria: [])
        XCTAssertTrue(evaluation.ranking.isEmpty)
        XCTAssertNil(evaluation.winner)
        XCTAssertEqual(evaluation.margin, 1, accuracy: 1e-9)
    }
}
