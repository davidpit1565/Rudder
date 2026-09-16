import XCTest
@testable import RudderCore

final class StabilityEngineTests: XCTestCase {

    func testDominantOptionIsStrong() {
        let criteria = makeCriteria([("a", 0.5), ("b", 0.3), ("c", 0.2)])
        let options = [
            makeOption("winner", ["a": 0.95, "b": 0.9, "c": 0.85]),
            makeOption("loser", ["a": 0.3, "b": 0.35, "c": 0.4])
        ]
        let report = StabilityEngine.analyse(options: options, criteria: criteria)
        XCTAssertEqual(report.strength, .strong)
        XCTAssertEqual(report.baseWinnerOptionID, "winner")
        XCTAssertTrue(report.flips.isEmpty)
        XCTAssertEqual(report.holdRate, 1, accuracy: 1e-9)
    }

    func testOptionsThatSplitTheCriteriaAreNotStrong() {
        let criteria = makeCriteria([("portability", 0.5), ("power", 0.5)])
        let options = [
            makeOption("air", ["portability": 0.95, "power": 0.45]),
            makeOption("pro", ["portability": 0.45, "power": 0.92])
        ]
        let report = StabilityEngine.analyse(options: options, criteria: criteria)
        XCTAssertNotEqual(report.strength, .strong)
        XCTAssertFalse(report.flips.isEmpty, "A split decision must expose what would flip it")
    }

    func testDeadHeatIsUnclear() {
        let criteria = makeCriteria([("a", 1)])
        let options = [makeOption("x", ["a": 0.5]), makeOption("y", ["a": 0.5])]
        let report = StabilityEngine.analyse(options: options, criteria: criteria)
        XCTAssertEqual(report.strength, .unclear)
    }

    func testSingleViableOptionIsTheOnlyChoice() {
        let criteria = makeCriteria([("a", 1)])
        let options = [makeOption("only", ["a": 0.6]), makeOption("out", ["a": 0.9], failed: ["Over budget"])]
        let report = StabilityEngine.analyse(options: options, criteria: criteria)
        XCTAssertEqual(report.strength, .strong)
        XCTAssertEqual(report.baseWinnerOptionID, "only")
    }

    func testFlipsAreOrderedByHowLikelyTheyAre() {
        let criteria = makeCriteria([("a", 0.6), ("b", 0.4)])
        let options = [
            makeOption("x", ["a": 0.8, "b": 0.3]),
            makeOption("y", ["a": 0.55, "b": 0.85])
        ]
        let report = StabilityEngine.analyse(options: options, criteria: criteria)
        guard report.flips.count > 1 else { return }
        for index in 1..<report.flips.count {
            XCTAssertLessThanOrEqual(report.flips[index - 1].distance, report.flips[index].distance)
        }
    }

    func testFlipLabelsAreUserFacingSentences() {
        let criteria = makeCriteria([("portability", 0.6), ("power", 0.4)])
        let options = [
            makeOption("air", ["portability": 0.9, "power": 0.4]),
            makeOption("pro", ["portability": 0.4, "power": 0.95])
        ]
        let report = StabilityEngine.analyse(options: options, criteria: criteria)
        for flip in report.flips {
            XCTAssertTrue(flip.label.hasPrefix("If "), "Flip label should read as a condition: \(flip.label)")
            XCTAssertFalse(flip.label.contains("weight"), "No MCDA vocabulary in user-facing copy")
        }
    }

    func testEmptyInputIsUnclearRatherThanCrashing() {
        XCTAssertEqual(StabilityEngine.analyse(options: [], criteria: []).strength, .unclear)
        XCTAssertEqual(StabilityEngine.analyse(options: [makeOption("a", [:])], criteria: []).strength, .unclear)
    }

    func testStrengthNeverReportsANumericConfidence() {
        // Decision strength is a three-way judgement, by design.
        XCTAssertEqual(Set(DecisionStrength.allCases.map(\.title)), ["Strong", "Moderate", "Unclear"])
    }
}
