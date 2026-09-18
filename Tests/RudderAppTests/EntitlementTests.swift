import XCTest
import RudderCore
@testable import Rudder

/// What Free gets, and when the paywall may appear.
@MainActor
final class EntitlementTests: XCTestCase {

    func testTheFirstDecisionIsNeverBlocked() {
        XCTAssertTrue(
            FeatureAccess.allowsDeepDecision(
                isPro: false,
                completedDecisionCount: 0,
                deepDecisionsThisMonth: 99
            ),
            "Nobody meets a paywall before RUDDER has been useful once"
        )
    }

    func testFreeUsersGetNoRecurringDeepDecisionAllowanceAfterTheFirst() {
        // Beyond the one always-free first decision, Free has no standing monthly
        // allowance -- the try-before-you-buy mechanism is the Pro trial, not a
        // recurring free quota a casual user could settle into permanently.
        XCTAssertEqual(FeatureAccess.freeDeepDecisionsPerMonth, 0)
        XCTAssertFalse(
            FeatureAccess.allowsDeepDecision(isPro: false, completedDecisionCount: 4, deepDecisionsThisMonth: 0)
        )
    }

    func testProIsNeverLimited() {
        XCTAssertTrue(FeatureAccess.allowsDeepDecision(isPro: true, completedDecisionCount: 100, deepDecisionsThisMonth: 100))
    }

    func testEntitlementStatesThatGrantAccess() {
        XCTAssertTrue(SubscriptionService.Entitlement.subscribed(expires: nil, isInGracePeriod: false).grantsPro)
        XCTAssertTrue(SubscriptionService.Entitlement.subscribed(expires: nil, isInGracePeriod: true).grantsPro)
        XCTAssertTrue(SubscriptionService.Entitlement.billingRetry(expires: nil).grantsPro)
    }

    func testEntitlementStatesThatDoNot() {
        XCTAssertFalse(SubscriptionService.Entitlement.notSubscribed.grantsPro)
        XCTAssertFalse(SubscriptionService.Entitlement.expired(on: nil).grantsPro)
        XCTAssertFalse(SubscriptionService.Entitlement.unknown.grantsPro, "Unknown must never be treated as Pro")
        XCTAssertFalse(SubscriptionService.Entitlement.checking.grantsPro)
    }

    func testUnresolvedEntitlementIsDistinguishableFromNotSubscribed() {
        // The paywall shows a loading state rather than a false negative.
        XCTAssertFalse(SubscriptionService.Entitlement.unknown.isResolved)
        XCTAssertFalse(SubscriptionService.Entitlement.checking.isResolved)
        XCTAssertTrue(SubscriptionService.Entitlement.notSubscribed.isResolved)
    }
}

@MainActor
final class DecisionPresentationTests: XCTestCase {

    private func result(optionNames: [String]) -> DecisionResult {
        let criteria = [Criterion(id: "a", name: "A", weight: 1)]
        let options = optionNames.enumerated().map {
            DecisionOption(id: "o\($0.offset)", name: $0.element, scores: ["a": 0.5])
        }
        return DecisionResult(
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
            strength: .moderate,
            stability: .empty
        )
    }

    func testSearchMatchesTitlePromptOptionsAndCriteria() {
        let record = DecisionRecord(
            title: "MacBook Air vs MacBook Pro",
            prompt: "Which laptop should I buy?",
            result: result(optionNames: ["MacBook Air", "MacBook Pro"])
        )
        XCTAssertTrue(record.matches("macbook"))
        XCTAssertTrue(record.matches("LAPTOP"))
        XCTAssertTrue(record.matches(""))
        XCTAssertFalse(record.matches("bicycle"))
    }

    func testRelativeDatesReadNaturally() {
        XCTAssertEqual(Date().decideRelativeDescription, "Today")
        XCTAssertEqual(Date().addingTimeInterval(-86_400).decideRelativeDescription, "Yesterday")
        XCTAssertEqual(Date().addingTimeInterval(-86_400 * 3).decideRelativeDescription, "3 days ago")
    }

    func testOutcomeIsOnlyAskedAboutOnceThereIsAnAnswerToGive() {
        var record = DecisionRecord(title: "t", prompt: "p", result: result(optionNames: ["A", "B"]), chosenOptionID: "o0")
        record.chosenAt = Date()
        XCTAssertFalse(record.isReadyForOutcome, "Never immediately after deciding")

        record.chosenAt = Date().addingTimeInterval(-60 * 60 * 24 * 10)
        XCTAssertTrue(record.isReadyForOutcome)
    }

    func testResearchBackedDecisionsGoStaleButOthersDoNot() {
        var researched = DecisionRecord(title: "t", prompt: "p", result: result(optionNames: ["A", "B"]))
        researched.result.researchLevel = .deep
        researched.createdAt = Date().addingTimeInterval(-60 * 60 * 24 * 100)
        XCTAssertTrue(researched.shouldReview)

        var reasoned = researched
        reasoned.result.researchLevel = .none
        XCTAssertFalse(reasoned.shouldReview)
    }
}
