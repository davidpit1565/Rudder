import XCTest

/// End-to-end checks against the running app.
///
/// These drive the real screens, the real pipeline and the real store. Only the
/// network call is scripted, via a DEBUG-only harness, so flows that would
/// otherwise need a deployed backend — a question round, a tie, a malformed
/// response — can be walked start to finish.
///
///     xcodebuild test -scheme Rudder -destination 'platform=iOS Simulator,name=iPhone 16'
///
/// XCUIElement is main-actor isolated, so the whole case runs there.
@MainActor
final class RudderUITests: XCTestCase {

    private enum ID {
        static let startDecision = "decide.start"
        static let decisionInput = "decide.input"
        static let makeDecision = "decide.make"
        static let chooseSomethingElse = "decide.chooseOther"
        static let continueAfterQuestion = "decide.question.continue"
        static let doneWithDecision = "decide.done"
        static let tryAgain = "decide.retry"
        static let historyRow = "decide.historyRow"
        static func optionRow(_ id: String) -> String { "decide.option.\(id)" }
    }

    private var app: XCUIApplication!

    /// Finds an element whose accessibility label *contains* this text.
    ///
    /// Screens combine related views into one accessibility element — the
    /// recommendation header reads as one sentence to VoiceOver — so matching on
    /// an exact label would fail even when the words are plainly on screen.
    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    private func hasText(_ text: String) -> Bool {
        element(containing: text).exists
    }

    @discardableResult
    private func waitForText(
        _ text: String,
        timeout: TimeInterval = 30,
        _ message: String? = nil
    ) -> Bool {
        let found = element(containing: text).waitForExistence(timeout: timeout)
        XCTAssertTrue(found, message ?? "Expected “\(text)” on screen")
        return found
    }

    /// Taps a control that pushes a new screen, and reports precisely which of
    /// two things failed if the destination never shows up.
    ///
    /// Four fix attempts targeting the interaction itself — a shorter wait, a
    /// retry-tap, a longer wait, and a tap at a fixed coordinate inside the
    /// visible text rather than the frame's center — all failed identically on
    /// every CI device, and a nav-bar-first diagnostic then proved the push
    /// itself never starts (the tap never reaches the NavigationLink at all).
    /// That is consistent with the control existing in the accessibility tree
    /// (so `waitForExistence` passes) while sitting below the fold in a
    /// `ScrollView` that never auto-scrolls it into view — a coordinate tap
    /// bypasses XCUITest's own scroll-into-view behavior entirely, which is
    /// exactly the failure mode observed. This scrolls until the control is
    /// genuinely `isHittable` before using a real `tap()`, and — since four
    /// blind interaction guesses is enough — reports the control's frame
    /// against the window and the full accessibility hierarchy if it still
    /// isn't, rather than guessing a sixth time.
    private func tapToNavigate(
        _ button: XCUIElement,
        expectingNavigationBar navigationBarTitle: String,
        expecting text: String,
        timeout: TimeInterval = 30
    ) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), "The control to tap must exist first")

        var scrollAttempts = 0
        while !button.isHittable && scrollAttempts < 10 {
            app.swipeUp()
            scrollAttempts += 1
        }

        guard button.isHittable else {
            return XCTFail(
                "\"\(button.label)\" exists but was never hittable, even after scrolling. "
                + "Button frame: \(button.frame), window frame: \(app.windows.firstMatch.frame). "
                + "Hierarchy:\n\(app.debugDescription)"
            )
        }

        button.tap()

        guard app.navigationBars[navigationBarTitle].waitForExistence(timeout: 8) else {
            return XCTFail(
                "The push to \"\(navigationBarTitle)\" never started: the nav bar title never changed, "
                + "so the tap did not reach the NavigationLink at all. "
                + "Button frame: \(button.frame), window frame: \(app.windows.firstMatch.frame). "
                + "Hierarchy:\n\(app.debugDescription)"
            )
        }
        XCTAssertTrue(
            waitForText(text, timeout: timeout),
            "The push to \"\(navigationBarTitle)\" started (the nav bar title changed) but its content never rendered."
        )
    }

    private var historyRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: ID.historyRow)
    }

    /// A vertical-axis TextField can surface as a text view rather than a text
    /// field, so it is addressed by identifier across either type.
    private var decisionInput: XCUIElement {
        app.descendants(matching: .any).matching(identifier: ID.decisionInput).firstMatch
    }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: Launching

    /// - Parameters:
    ///   - scenario: which scripted exchange the app should serve.
    ///   - reset: clears the store first. Left off to test that data survives a relaunch.
    ///   - contentSize: a Dynamic Type category to launch under.
    private func launch(
        scenario: String? = nil,
        reset: Bool = true,
        contentSize: String? = nil
    ) {
        app.launchArguments = []
        if let scenario {
            app.launchArguments += ["-RudderUITestScenario", scenario]
        }
        if reset {
            app.launchArguments += ["-RudderUITestResetStore"]
        }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
    }

    private func startDecision(_ text: String = "MacBook Air or MacBook Pro?") {
        let input = decisionInput
        XCTAssertTrue(input.waitForExistence(timeout: 20), "The decision input should be the first thing on screen")
        input.tap()
        input.typeText(text)

        let decide = app.buttons[ID.startDecision]
        XCTAssertTrue(decide.isEnabled, "Decide should be enabled once there is something to decide")
        decide.tap()
    }

    // MARK: Home

    func testHomeAsksTheOneQuestionThatMatters() {
        launch()
        waitForText("What are you deciding?", timeout: 20)
        XCTAssertTrue(app.buttons[ID.startDecision].exists)
    }

    func testTheDecideButtonIsDisabledUntilThereIsSomethingToDecide() {
        launch()
        let decide = app.buttons[ID.startDecision]
        XCTAssertTrue(decide.waitForExistence(timeout: 20))
        XCTAssertFalse(decide.isEnabled)

        let input = decisionInput
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("Which laptop?")
        XCTAssertTrue(decide.isEnabled)
    }

    func testAnExampleFillsTheField() {
        launch()
        let example = app.buttons["Which laptop should I buy?"]
        XCTAssertTrue(example.waitForExistence(timeout: 20))
        example.tap()
        XCTAssertEqual(decisionInput.value as? String, "Which laptop should I buy?")
    }

    func testThereAreExactlyThreePlaces() {
        launch()
        XCTAssertTrue(app.tabBars.buttons["Decide"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Decisions"].exists)
        XCTAssertTrue(app.tabBars.buttons["Profile"].exists)
        XCTAssertEqual(app.tabBars.buttons.count, 3, "No chat tab, no dashboard")
    }

    // MARK: The whole flow

    func testADecisionRunsFromHomeToHistory() {
        launch(scenario: "straightforward")
        startDecision()

        // Answer first: the recommendation, why, the trade-off, the strength.
        waitForText("My recommendation: MacBook Air")
        XCTAssertTrue(hasText("Why it fits you"))
        XCTAssertTrue(hasText("Decision strength: Strong"))
        XCTAssertTrue(hasText("What could make me wrong?"))

        // Nothing was asked, because nothing needed asking.
        XCTAssertFalse(hasText("One thing I need to know"))

        app.buttons[ID.makeDecision].tap()

        waitForText("You chose", timeout: 10)
        XCTAssertTrue(hasText("Your choice is yours."))

        app.buttons[ID.doneWithDecision].tap()

        // It is in history, with what was chosen and how strong it was.
        app.tabBars.buttons["Decisions"].tap()
        let row = historyRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The decision should be in history")
        XCTAssertTrue(row.label.contains("MacBook Air vs MacBook Pro"), "Got: \(row.label)")
        XCTAssertTrue(row.label.contains("Strong"), "Got: \(row.label)")
    }

    func testTheAnalysisIsOneTapAwayAndShowsItsSources() {
        launch(scenario: "straightforward")
        startDecision()
        waitForText("My recommendation: MacBook Air")

        tapToNavigate(app.buttons["See analysis"], expectingNavigationBar: "Analysis", expecting: "What you told me")
        XCTAssertTrue(hasText("What I judged it on"))
        XCTAssertTrue(hasText("How the options compare"))
        XCTAssertTrue(hasText("What I checked"))
    }

    /// Isolates whether *any* presentation (not just "See analysis") can appear
    /// from this exact screen, inside DecisionFlowView's fullScreenCover.
    ///
    /// "See analysis" has now failed identically as a NavigationLink, as
    /// .navigationDestination(isPresented:), and as .sheet(isPresented:) --
    /// three mechanisms with nothing in common except where they're triggered
    /// from. "Choose something else" opens its own, already-shipped .sheet
    /// from this identical screen, needs no scrolling (it lives in the fixed
    /// bottom bar), and no test has ever exercised it. If it fails too, the
    /// bug isn't in "See analysis" at all -- it's that no presentation can be
    /// triggered from anywhere inside this fullScreenCover in this
    /// environment, and the real fix is to stop presenting new screens from
    /// here rather than trying a fourth presentation mechanism.
    func testChoosingSomethingElseOpensTheOptionsSheet() {
        launch(scenario: "straightforward")
        startDecision()
        waitForText("My recommendation: MacBook Air")

        app.buttons[ID.chooseSomethingElse].tap()

        XCTAssertTrue(
            waitForText("Your options", timeout: 10),
            "Choosing something else should open the options sheet"
        )
    }

    // MARK: Questions

    func testExactlyOneQuestionIsAskedAndNeverCounted() {
        launch(scenario: "oneQuestion")
        startDecision("Should I get the Air or the Pro for my work?")

        waitForText("One thing I need to know")

        // A direction is already on offer before the question is answered.
        XCTAssertTrue(hasText("I already have a direction"))

        // No counter, anywhere.
        XCTAssertFalse(hasText("Question 1"))
        XCTAssertFalse(hasText(" of 5"))

        // Only the question the system cannot answer itself is shown.
        XCTAssertTrue(hasText("Do you edit video"))
        XCTAssertFalse(hasText("What do these cost today?"))
        XCTAssertFalse(hasText("What colour do you prefer?"))

        app.buttons["Mostly photos and documents"].tap()
        app.buttons[ID.continueAfterQuestion].tap()

        waitForText("My recommendation: MacBook Air")
    }

    func testAQuestionCanBeDeclinedWithoutDeadEnding() {
        launch(scenario: "oneQuestion")
        startDecision()
        waitForText("One thing I need to know")

        app.buttons["I'd rather not say"].tap()
        waitForText("My recommendation: MacBook Air")
    }

    // MARK: Honest outcomes

    func testNoClearWinnerIsSaidRatherThanManufactured() {
        launch(scenario: "noClearWinner")
        startDecision()

        waitForText("There isn't a clear winner")
        XCTAssertTrue(hasText("Decision strength: Unclear"))
        XCTAssertFalse(app.buttons[ID.makeDecision].exists, "There is nothing to recommend, so nothing to confirm")
        XCTAssertTrue(app.buttons["Choose for me anyway"].exists)
    }

    func testUnverifiedResearchIsDeclaredOnTheRecommendation() {
        launch(scenario: "researchFailure")
        startDecision()

        waitForText("My recommendation: MacBook Air")
        XCTAssertTrue(
            hasText("couldn't verify"),
            "A recommendation built on unverified research has to say so"
        )
    }

    func testAnInvalidResponseFailsHonestlyAndCanBeRetried() {
        launch(scenario: "invalidResponse")
        startDecision()

        waitForText("I couldn't complete the analysis")
        XCTAssertTrue(app.buttons[ID.tryAgain].exists)
        XCTAssertFalse(hasText("My recommendation:"), "A broken response must never render as an answer")
    }

    func testBeingOfflineIsExplainedNotFaked() {
        launch(scenario: "offline")
        startDecision()

        waitForText("You're offline")
        XCTAssertFalse(hasText("My recommendation:"))
    }

    // MARK: The user's call

    func testOverridingTheRecommendationIsNotArguedWith() {
        launch(scenario: "straightforward")
        startDecision()
        waitForText("My recommendation: MacBook Air")

        app.buttons[ID.chooseSomethingElse].tap()
        let proRow = app.descendants(matching: .any).matching(identifier: ID.optionRow("pro")).firstMatch
        XCTAssertTrue(proRow.waitForExistence(timeout: 10), "The other options should be listed")
        proRow.tap()

        waitForText("You chose", timeout: 10)
        XCTAssertTrue(hasText("MacBook Pro"))
        XCTAssertTrue(hasText("You're giving up"))
        XCTAssertTrue(hasText("Your choice is yours."))

        // No second-guessing anywhere on the screen.
        XCTAssertFalse(hasText("Are you sure"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'accept'")).count, 0)
    }

    // MARK: Persistence and deletion

    func testADecisionSurvivesRelaunching() {
        launch(scenario: "straightforward")
        startDecision()
        waitForText("My recommendation: MacBook Air")
        app.buttons[ID.makeDecision].tap()
        XCTAssertTrue(app.buttons[ID.doneWithDecision].waitForExistence(timeout: 10))
        app.buttons[ID.doneWithDecision].tap()

        app.terminate()
        launch(scenario: "straightforward", reset: false)

        app.tabBars.buttons["Decisions"].tap()
        XCTAssertTrue(
            historyRows.firstMatch.waitForExistence(timeout: 20),
            "A saved decision must still be there after a restart"
        )
    }

    func testADecisionCanBeDeleted() {
        launch(scenario: "straightforward")
        startDecision()
        waitForText("My recommendation: MacBook Air")
        app.buttons[ID.makeDecision].tap()
        XCTAssertTrue(app.buttons[ID.doneWithDecision].waitForExistence(timeout: 10))
        app.buttons[ID.doneWithDecision].tap()

        app.tabBars.buttons["Decisions"].tap()
        XCTAssertTrue(historyRows.firstMatch.waitForExistence(timeout: 10))
        historyRows.firstMatch.tap()

        app.buttons["Delete this decision"].tap()
        app.buttons["Delete"].tap()

        waitForText("Your decisions will appear here.", timeout: 10)
    }

    func testEverythingCanBeDeletedFromProfile() {
        launch(scenario: "straightforward")
        startDecision()
        waitForText("My recommendation: MacBook Air")
        app.buttons[ID.makeDecision].tap()
        XCTAssertTrue(app.buttons[ID.doneWithDecision].waitForExistence(timeout: 10))
        app.buttons[ID.doneWithDecision].tap()

        app.tabBars.buttons["Profile"].tap()
        waitForText("Your data", timeout: 10)

        // Each kind of data can be deleted on its own.
        XCTAssertTrue(app.buttons["Delete all Decision Memory"].exists)
        XCTAssertTrue(app.buttons["Delete all outcomes"].exists)
        XCTAssertTrue(app.buttons["Delete all decisions"].exists)

        app.buttons["Delete everything"].tap()
        app.buttons["Delete"].tap()

        app.tabBars.buttons["Decisions"].tap()
        waitForText("Your decisions will appear here.", timeout: 10)
    }

    // MARK: Empty states and Pro

    func testEmptyHistoryExplainsItself() {
        launch()
        app.tabBars.buttons["Decisions"].tap()
        waitForText("Your decisions will appear here.", timeout: 20)
    }

    func testProfileOffersThePlanAndTheDataControls() {
        launch()
        app.tabBars.buttons["Profile"].tap()
        waitForText("Your plan", timeout: 20)
        XCTAssertTrue(hasText("Decision Memory"))
        XCTAssertTrue(hasText("Your data"))
    }

    func testThePaywallOnlyClaimsWhatProActuallyChanges() {
        launch()
        app.tabBars.buttons["Profile"].tap()
        waitForText("Your plan", timeout: 20)
        app.buttons["See Pro"].firstMatch.tap()

        waitForText("Make better decisions, with less effort.", timeout: 10)
        XCTAssertTrue(app.buttons["Restore Purchases"].exists, "App Review requires this, and so does anyone reinstalling")

        // Claims of exclusive Pro capability the app cannot support must not be
        // here. "stress testing" legitimately appears in the honest disclosure
        // below — the analysis itself does not change with Pro — so the test
        // checks for the old, unsupported marketing framing, not for the phrase.
        XCTAssertFalse(hasText("Advanced analysis"))
        XCTAssertFalse(hasText("unlimited AI"))
        XCTAssertTrue(
            hasText("The analysis is the same either way"),
            "Pro must not imply a better analysis than Free gets"
        )
    }

    // MARK: Accessibility and small screens

    func testTheFlowStillWorksAtTheLargestAccessibilityTextSize() {
        launch(scenario: "straightforward", contentSize: "UICTContentSizeCategoryAccessibilityXXXL")

        let input = decisionInput
        XCTAssertTrue(input.waitForExistence(timeout: 20))

        let decide = app.buttons[ID.startDecision]
        XCTAssertTrue(decide.exists)
        XCTAssertTrue(decide.isHittable, "The primary action must stay reachable at the largest text size")

        input.tap()
        input.typeText("Air or Pro?")
        decide.tap()

        waitForText("My recommendation: MacBook Air")
        let makeDecision = app.buttons[ID.makeDecision]
        XCTAssertTrue(makeDecision.exists)
        XCTAssertTrue(makeDecision.isHittable, "The decision must still be makeable at the largest text size")
    }

    func testTheKeyboardDoesNotCoverThePrimaryAction() {
        launch()
        let input = decisionInput
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("Which laptop should I buy?")

        let decide = app.buttons[ID.startDecision]
        XCTAssertTrue(decide.isHittable, "The CTA has to stay above the keyboard")
    }
}
