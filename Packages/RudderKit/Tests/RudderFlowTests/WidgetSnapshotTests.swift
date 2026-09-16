import XCTest
import RudderCore
@testable import RudderFlow

final class WidgetSnapshotTests: XCTestCase {

    private func record(
        title: String,
        optionNames: [String],
        chosenOptionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> DecisionRecord {
        let criteria = [Criterion(id: "a", name: "A", weight: 1)]
        let options = optionNames.enumerated().map {
            DecisionOption(id: "o\($0.offset)", name: $0.element, scores: ["a": 0.5])
        }
        let result = DecisionResult(
            understanding: .init(restatement: "x"),
            category: .other,
            complexity: .simple,
            criteria: criteria,
            options: options,
            ranking: DecisionEngine.evaluate(options: options, criteria: criteria).ranking,
            recommendedOptionID: options.first?.id,
            headline: "",
            reasons: [],
            tradeOffs: [],
            strength: .strong,
            stability: .empty
        )
        return DecisionRecord(
            title: title,
            prompt: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            result: result,
            chosenOptionID: chosenOptionID
        )
    }

    func testNoDecisionsProducesNoSnapshot() {
        XCTAssertNil(WidgetSnapshot.make(from: []))
    }

    func testTakesTheMostRecentDecisionByCreationDate() {
        let older = record(title: "Older", optionNames: ["A"], createdAt: Date(timeIntervalSince1970: 0))
        let newer = record(title: "Newer", optionNames: ["A"], createdAt: Date(timeIntervalSince1970: 1000))

        let snapshot = WidgetSnapshot.make(from: [older, newer])

        XCTAssertEqual(snapshot?.title, "Newer")
    }

    func testUsesTheChosenOptionOverTheRecommendationWhenBothExist() {
        let decision = record(
            title: "Laptop",
            optionNames: ["MacBook Air", "MacBook Pro"],
            chosenOptionID: "o1"
        )

        let snapshot = WidgetSnapshot.make(from: [decision])

        XCTAssertEqual(snapshot?.subtitle, "MacBook Pro")
    }

    func testFallsBackToTheRecommendationWhenNothingWasChosenYet() {
        let decision = record(title: "Laptop", optionNames: ["MacBook Air", "MacBook Pro"])

        let snapshot = WidgetSnapshot.make(from: [decision])

        XCTAssertEqual(snapshot?.subtitle, "MacBook Air")
    }

    func testCarriesTheStrengthTitleThrough() {
        let decision = record(title: "Laptop", optionNames: ["MacBook Air"])

        let snapshot = WidgetSnapshot.make(from: [decision])

        XCTAssertEqual(snapshot?.strengthTitle, DecisionStrength.strong.title)
    }
}
