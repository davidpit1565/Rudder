import XCTest
import RudderCore
@testable import RudderFlow

final class DecisionTitleTests: XCTestCase {

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

    func testTwoOptionsBecomeAVersusTitle() {
        let title = DecisionTitle.make(from: "Which laptop?", result: result(optionNames: ["MacBook Air", "MacBook Pro"]))
        XCTAssertEqual(title, "MacBook Air vs MacBook Pro")
    }

    func testManyOptionsAreSummarised() {
        let title = DecisionTitle.make(from: "Where to?", result: result(optionNames: ["Paris", "Rome", "Lisbon"]))
        XCTAssertEqual(title, "Paris vs 2 others")
    }

    func testASingleOptionFallsBackToThePrompt() {
        let title = DecisionTitle.make(from: "Should I cancel Netflix?", result: result(optionNames: ["Cancel"]))
        XCTAssertEqual(title, "Should I cancel Netflix?")
    }

    func testAVeryLongPromptIsTruncatedForTheList() {
        let long = String(repeating: "decision ", count: 40)
        let title = DecisionTitle.make(from: long, result: result(optionNames: ["Only"]))
        XCTAssertLessThanOrEqual(title.count, 61)
    }

}

final class ConfigurationTests: XCTestCase {

    private struct StubInfo: InfoValueProviding {
        var values: [String: String] = [:]
        func infoValue(forKey key: String) -> String? { values[key] }
    }

    func testOnlyHttpsUrlsAreAccepted() {
        let info = StubInfo(values: [
            "RudderAPIBaseURL": "https://api.rudder.app",
            "RudderPrivacyPolicyURL": "http://rudder.app/privacy",
            "RudderTermsURL": "  ",
            "RudderSupportURL": "not a url"
        ])
        let configuration = AppConfiguration(info: info)

        XCTAssertEqual(configuration.apiBaseURL?.absoluteString, "https://api.rudder.app")
        XCTAssertNil(configuration.privacyPolicyURL, "Plaintext HTTP is never used")
        XCTAssertNil(configuration.termsURL)
        XCTAssertNil(configuration.supportURL)
        XCTAssertTrue(configuration.isBackendConfigured)
    }

    func testAnUnconfiguredBuildSaysSoRatherThanGuessing() {
        let configuration = AppConfiguration(info: StubInfo())
        XCTAssertFalse(configuration.isBackendConfigured)
    }

    func testTheSchemeWithoutAHostIsNotAUrl() {
        // Exactly what an unconfigured build produces: the xcconfig assembles
        // "https://" + an empty host. It must read as "not connected", not as a
        // reachable endpoint.
        let configuration = AppConfiguration(
            info: StubInfo(values: [
                "RudderAPIBaseURL": "https://",
                "RudderPrivacyPolicyURL": "https://",
            ])
        )
        XCTAssertFalse(configuration.isBackendConfigured)
        XCTAssertNil(configuration.apiBaseURL)
        XCTAssertNil(configuration.privacyPolicyURL)
    }

}

final class ReachabilityTests: XCTestCase {

    func testUpdatesYieldTheCurrentValueThenChanges() async throws {
        let reachability = Reachability.shared

        let task = Task { () -> [Bool] in
            var received: [Bool] = []
            for await connected in reachability.updates {
                received.append(connected)
                if received.count == 2 { break }
            }
            return received
        }

        // Give the stream a moment to deliver the initial value before changing it.
        try await Task.sleep(nanoseconds: 20_000_000)
        reachability.simulate(connected: false)
        let received = await task.value

        XCTAssertEqual(received.first, true, "The current value arrives immediately")
        XCTAssertEqual(received.last, false, "A change is delivered to listeners")
        XCTAssertFalse(reachability.isConnected)

        reachability.simulate(connected: true)
        XCTAssertTrue(reachability.isConnected)
    }

    func testRepeatedIdenticalUpdatesDoNotChurnListeners() {
        let reachability = Reachability.shared
        reachability.simulate(connected: true)
        reachability.simulate(connected: true)
        XCTAssertTrue(reachability.isConnected)
    }
}
