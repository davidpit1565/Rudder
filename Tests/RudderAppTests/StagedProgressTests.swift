import XCTest
import RudderCore
@testable import Rudder

/// `StagedProgress.stages()` decides what the working screen shows while a
/// decision's single network call is in flight -- it must only ever claim a
/// stage is active once its real, documented threshold has actually passed,
/// and never claim completion the response hasn't actually confirmed.
final class StagedProgressTests: XCTestCase {

    func testATrivialDecisionNeverShowsALookingUpStage() {
        let stages = StagedProgress.stages(researchLevel: .none, elapsed: 50)
        XCTAssertFalse(stages.contains { $0.id == "research" }, "No research was requested, so there is nothing to honestly show here")
    }

    func testAResearchedDecisionStartsOnUnderstanding() {
        let stages = StagedProgress.stages(researchLevel: .deep, elapsed: 0)
        XCTAssertEqual(stages.map(\.status), [.active, .pending, .pending])
    }

    func testAResearchedDecisionMovesToLookingUpAfterTheOpeningBeat() {
        let stages = StagedProgress.stages(researchLevel: .light, elapsed: StagedProgress.openingBeatSeconds)
        XCTAssertEqual(stages.map(\.status), [.done, .active, .pending])
    }

    func testAResearchedDecisionMovesToAnalyzingOnlyAfterTheRealResearchCeiling() {
        let justBefore = StagedProgress.stages(
            researchLevel: .deep,
            elapsed: StagedProgress.openingBeatSeconds + StagedProgress.researchCeilingSeconds - 1
        )
        XCTAssertEqual(justBefore.map(\.status), [.done, .active, .pending], "Must not claim analysis started before the backend's own research cap")

        let atCeiling = StagedProgress.stages(
            researchLevel: .deep,
            elapsed: StagedProgress.openingBeatSeconds + StagedProgress.researchCeilingSeconds
        )
        XCTAssertEqual(atCeiling.map(\.status), [.done, .done, .active])
    }

    func testATrivialDecisionMovesStraightToAnalyzingAfterTheOpeningBeat() {
        let stages = StagedProgress.stages(researchLevel: .none, elapsed: StagedProgress.openingBeatSeconds)
        XCTAssertEqual(stages.map(\.id), ["understanding", "analyze"])
        XCTAssertEqual(stages.map(\.status), [.done, .active])
    }

    func testElapsedTimeFarBeyondEveryThresholdStillStopsAtTheLastStage() {
        // However long the real call actually takes, this must never invent a
        // stage past what it can know exists.
        let stages = StagedProgress.stages(researchLevel: .deep, elapsed: 10_000)
        XCTAssertEqual(stages.last?.status, .active)
        XCTAssertEqual(stages.filter { $0.status == .pending }.count, 0)
    }
}
