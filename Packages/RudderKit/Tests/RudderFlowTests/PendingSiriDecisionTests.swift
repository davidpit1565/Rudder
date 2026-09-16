import XCTest
@testable import RudderFlow

final class PendingSiriDecisionTests: XCTestCase {

    // Async, not @MainActor: the Linux XCTest runner generates a synchronous
    // `allTests` dispatch table, which cannot call a main-actor-isolated test
    // method under Swift 6's strict concurrency. An async test avoids that by
    // hopping onto the main actor itself via `await`.

    func testConsumeReturnsTheStoredPromptOnce() async {
        let holder = await PendingSiriDecision()
        await holder.set("Should I take this job?")

        let first = await holder.consume()
        XCTAssertEqual(first, "Should I take this job?")

        let second = await holder.consume()
        XCTAssertNil(second, "a consumed prompt must not replay on a later check")
    }

    func testConsumeWithNothingPendingReturnsNil() async {
        let holder = await PendingSiriDecision()
        let result = await holder.consume()
        XCTAssertNil(result)
    }

    func testANewerPromptReplacesAnUnconsumedOne() async {
        let holder = await PendingSiriDecision()
        await holder.set("Should I take this job?")
        await holder.set("Which apartment should I choose?")

        let result = await holder.consume()
        XCTAssertEqual(result, "Which apartment should I choose?")
    }
}
