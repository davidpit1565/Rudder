import XCTest
@testable import RudderCore

final class ClassifierTests: XCTestCase {

    func testTrivialDecisionsGetNoResearch() {
        let classification = DecisionClassifier.classify("Pizza or pasta tonight?")
        XCTAssertEqual(classification.complexity, .simple)
        XCTAssertEqual(classification.researchLevel, .none)
    }

    func testHighStakesPurchasesGetDeepResearch() {
        let classification = DecisionClassifier.classify("Which car should I buy?")
        XCTAssertEqual(classification.complexity, .complex)
        XCTAssertEqual(classification.researchLevel, .deep)
    }

    func testLaptopChoiceIsATechnologyDecision() {
        let classification = DecisionClassifier.classify("MacBook Air or MacBook Pro for photo editing?")
        XCTAssertEqual(classification.category, .technology)
        XCTAssertEqual(classification.researchLevel, .light)
    }

    func testJobOffersAreCareerDecisions() {
        let classification = DecisionClassifier.classify("Should I take this job offer?")
        XCTAssertEqual(classification.category, .career)
        XCTAssertEqual(classification.complexity, .complex)
    }

    func testApartmentChoiceIsAHomeDecision() {
        XCTAssertEqual(DecisionClassifier.classify("Which apartment should I choose?").category, .home)
    }

    func testSubscriptionCancellation() {
        XCTAssertEqual(DecisionClassifier.classify("Should I cancel this subscription?").category, .subscription)
    }

    func testMoneyAmountsRaiseTheStakes() {
        let plain = DecisionClassifier.classify("Which headphones should I get?")
        let expensive = DecisionClassifier.classify("Which headphones should I get for €1,200?")
        XCTAssertGreaterThanOrEqual(expensive.complexity.questionCeiling, plain.complexity.questionCeiling)
    }

    func testSmallAmountsDoNotRaiseTheStakes() {
        XCTAssertFalse(DecisionClassifier.containsSignificantAmount("it costs 4 dollars"))
        XCTAssertTrue(DecisionClassifier.containsSignificantAmount("about 3k"))
        XCTAssertTrue(DecisionClassifier.containsSignificantAmount("$2,500"))
    }

    func testManyOptionsRaiseComplexity() {
        let classification = DecisionClassifier.classify("Berlin or Lisbon or Athens or Porto or Vienna?")
        XCTAssertGreaterThanOrEqual(classification.optionCountHint, 4)
        XCTAssertNotEqual(classification.complexity, .simple)
    }

    func testEmptyInputDoesNotCrash() {
        let classification = DecisionClassifier.classify("")
        XCTAssertEqual(classification.category, .other)
        XCTAssertEqual(classification.complexity, .simple)
    }

    func testVeryLongInputIsHandled() {
        let text = String(repeating: "I am trying to decide something important. ", count: 500)
        XCTAssertNotNil(DecisionClassifier.classify(text))
    }

    func testEmojiAndNonLatinInputDoNotCrash() {
        XCTAssertNotNil(DecisionClassifier.classify("🤔 מה לבחור? 🚗"))
    }
}
