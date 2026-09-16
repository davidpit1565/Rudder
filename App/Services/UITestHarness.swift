#if DEBUG
import Foundation
import RudderCore
import RudderFlow

/// Test-only scaffolding, compiled out of Release entirely.
///
/// It exists so the XCUITest suite can drive the *real* screens, the real
/// pipeline, the real engines and the real store through flows that would
/// otherwise need a deployed backend and a paid model call — a question round,
/// a no-clear-winner result, a malformed response, a research failure.
///
/// What it replaces is exactly one thing: the network call. Everything the user
/// would see is produced by the same code that runs in production. There is no
/// switch, flag or build setting that reaches this in a shipping build; the
/// whole file is inside `#if DEBUG`, and `Tests/RudderAppTests` asserts that.
enum UITestHarness {
    static let scenarioArgument = "-RudderUITestScenario"
    static let resetArgument = "-RudderUITestResetStore"

    enum Scenario: String {
        /// Nothing worth asking: straight to a Strong recommendation.
        case straightforward
        /// One thing only the user can answer, then a recommendation.
        case oneQuestion
        /// Two options that stay level however the priorities move.
        case noClearWinner
        /// A response that cannot be validated — the app must fail honestly.
        case invalidResponse
        /// The analysis lands, but nothing could be verified.
        case researchFailure
        /// No connection at all.
        case offline
    }

    static var scenario: Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: scenarioArgument),
              arguments.indices.contains(index + 1)
        else { return nil }
        return Scenario(rawValue: arguments[index + 1])
    }

    static var isActive: Bool { scenario != nil }

    static var shouldResetStore: Bool {
        ProcessInfo.processInfo.arguments.contains(resetArgument)
    }

    /// The scripted stand-in for the network, or nil when the app is running normally.
    static func analysisService() -> DecisionAnalysisService? {
        guard let scenario else { return nil }
        return ScriptedAnalysisService(scenario: scenario)
    }
}

/// Replays a scripted exchange in place of the backend. Everything downstream —
/// validation, readiness, the question engine, stability, self-challenge — runs
/// for real against what it returns.
private struct ScriptedAnalysisService: DecisionAnalysisService {
    let scenario: UITestHarness.Scenario

    func analyse(_ request: DecisionAnalysisRequest) async throws -> ValidatedAIResponse {
        // A short delay so the working states are actually rendered and can be
        // observed, rather than being skipped in the same frame.
        try? await Task.sleep(nanoseconds: 150_000_000)

        switch scenario {
        case .offline:
            throw RudderServiceError.offline

        case .invalidResponse:
            throw RudderServiceError.invalidResponse

        case .oneQuestion where request.answers.isEmpty:
            return try AIResponseValidator.validate(Self.askingResponse())

        case .oneQuestion, .straightforward:
            return try AIResponseValidator.validate(Self.recommendationResponse(researchVerified: true))

        case .researchFailure:
            return try AIResponseValidator.validate(Self.recommendationResponse(researchVerified: false))

        case .noClearWinner:
            return try AIResponseValidator.validate(Self.tiedResponse())
        }
    }

    // MARK: Scripted payloads

    private static func criteria() -> [AIDecisionResponse.CriterionDTO] {
        [
            .init(id: "portability", name: "Portability", weight: 0.5, rationale: "You carry it every day."),
            .init(id: "power", name: "Power", weight: 0.3, rationale: nil),
            .init(id: "price", name: "Price", weight: 0.2, rationale: nil)
        ]
    }

    private static func recommendationResponse(researchVerified: Bool) -> AIDecisionResponse {
        AIDecisionResponse(
            decisionStatus: "ready",
            category: "technology",
            complexity: "medium",
            understanding: .init(
                restatement: "You're choosing between a MacBook Air and a MacBook Pro for everyday work.",
                knownContext: ["Carries the laptop every day"],
                whatMatters: ["Portability", "Enough power for the work"]
            ),
            researchNeeded: .init(level: "light"),
            criteria: criteria(),
            options: [
                .init(
                    id: "air",
                    name: "MacBook Air",
                    summary: "Lighter, fanless, cheaper.",
                    scores: ["portability": 0.95, "power": 0.7, "price": 0.85]
                ),
                .init(
                    id: "pro",
                    name: "MacBook Pro",
                    summary: "Faster, heavier, more expensive.",
                    scores: ["portability": 0.35, "power": 0.92, "price": 0.3]
                )
            ],
            recommendation: .init(
                optionId: "air",
                headline: "Best fit for you",
                reasons: [
                    .init(title: "It's the one you'll actually carry", detail: "You move with it daily and the Air is lighter."),
                    .init(title: "Fast enough for your work", detail: "What you do sits well inside what the Air handles."),
                    .init(title: "Leaves budget on the table", detail: "You keep several hundred for storage or a display.")
                ]
            ),
            risks: [.init(title: "Heavier work later", detail: "If your work shifts to video, the Air will feel tight.", severity: "medium")],
            assumptions: [.init(statement: "Your work is documents and photos, not long video exports.", impactIfWrong: "The Pro becomes the better choice.")],
            research: [
                .init(
                    claim: "The Air weighs about 1.24 kg against 1.55 kg for the 14-inch Pro.",
                    sourceTitle: researchVerified ? "Apple technical specifications" : nil,
                    sourceUrl: researchVerified ? "https://www.apple.com/macbook-air/specs/" : nil,
                    retrievedAt: researchVerified ? ISO8601DateFormatter().string(from: Date()) : nil,
                    verified: researchVerified
                )
            ],
            whatCouldMakeMeWrong: ["If you start exporting long video, the Pro wins."]
        )
    }

    private static func askingResponse() -> AIDecisionResponse {
        var response = recommendationResponse(researchVerified: true)
        response.decisionStatus = "needs_one_question"
        response.complexity = "complex"
        // Deliberately three candidates: only the first can reach the user. The
        // second is something the system could look up, the third cannot move
        // the result.
        response.requiredQuestions = [
            .init(
                id: "video",
                text: "Do you edit video, or mostly photos and documents?",
                kind: "single_choice",
                choices: ["Mostly photos and documents", "A lot of video"],
                expectedImpact: 0.9,
                friction: 0.2,
                answerableByResearch: false
            ),
            .init(id: "price", text: "What do these cost today?", expectedImpact: 0.8, friction: 0.5, answerableByResearch: true),
            .init(id: "colour", text: "What colour do you prefer?", expectedImpact: 0.02, friction: 0.1)
        ]
        response.preliminaryRecommendation = .init(optionId: "air", rationale: "Portability is doing most of the work here.")
        // Level the options so the answer genuinely matters — a decision that is
        // already stable would (correctly) suppress the question.
        response.criteria = [
            .init(id: "portability", name: "Portability", weight: 0.4, rationale: nil),
            .init(id: "power", name: "Power", weight: 0.4, rationale: nil),
            .init(id: "price", name: "Price", weight: 0.2, rationale: nil)
        ]
        response.options = [
            .init(id: "air", name: "MacBook Air", summary: nil, scores: ["portability": 0.95, "power": 0.35, "price": 0.9]),
            .init(id: "pro", name: "MacBook Pro", summary: nil, scores: ["portability": 0.45, "power": 0.99, "price": 0.4])
        ]
        return response
    }

    private static func tiedResponse() -> AIDecisionResponse {
        var response = recommendationResponse(researchVerified: true)
        response.options = [
            .init(id: "air", name: "MacBook Air", summary: "Lighter.", scores: ["portability": 0.6, "power": 0.6, "price": 0.6]),
            .init(id: "pro", name: "MacBook Pro", summary: "Faster.", scores: ["portability": 0.6, "power": 0.6, "price": 0.6])
        ]
        return response
    }
}
#endif
