import Foundation
import RudderCore
@testable import RudderFlow

/// Replays scripted responses so the whole pipeline can be exercised without a
/// network or a model.
final class MockAnalysisService: DecisionAnalysisService, @unchecked Sendable {
    enum Step {
        case respond(AIDecisionResponse)
        case fail(RudderServiceError)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [DecisionAnalysisRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    convenience init(response: AIDecisionResponse) {
        self.init(steps: [.respond(response)])
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func lastRequest() -> DecisionAnalysisRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    private func nextStep(for request: DecisionAnalysisRequest) -> Step? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    func analyse(_ request: DecisionAnalysisRequest) async throws -> ValidatedAIResponse {
        let step = nextStep(for: request)

        switch step {
        case .respond(let response):
            do {
                return try AIResponseValidator.validate(response)
            } catch {
                throw RudderServiceError.invalidResponse
            }
        case .fail(let error):
            throw error
        case nil:
            throw RudderServiceError.invalidResponse
        }
    }
}

enum Responses {
    /// A clean, decidable decision with a dominant winner.
    static func ready(
        recommended: String = "air",
        strengthStyle: StrengthStyle = .dominant
    ) -> AIDecisionResponse {
        let options: [AIDecisionResponse.OptionDTO]
        // Criteria weights vary with the style: a decision is only genuinely split
        // when what the options are good at is weighted about equally.
        var criteria: [AIDecisionResponse.CriterionDTO] = [
            .init(id: "portability", name: "Portability", weight: 0.5),
            .init(id: "power", name: "Power", weight: 0.3),
            .init(id: "price", name: "Price", weight: 0.2)
        ]

        switch strengthStyle {
        case .dominant:
            options = [
                .init(id: "air", name: "MacBook Air", scores: ["portability": 0.95, "power": 0.7, "price": 0.85]),
                .init(id: "pro", name: "MacBook Pro", scores: ["portability": 0.35, "power": 0.9, "price": 0.3])
            ]
        case .split:
            criteria = [
                .init(id: "portability", name: "Portability", weight: 0.4),
                .init(id: "power", name: "Power", weight: 0.4),
                .init(id: "price", name: "Price", weight: 0.2)
            ]
            options = [
                .init(id: "air", name: "MacBook Air", scores: ["portability": 0.95, "power": 0.35, "price": 0.9]),
                .init(id: "pro", name: "MacBook Pro", scores: ["portability": 0.45, "power": 0.99, "price": 0.4])
            ]
        case .tied:
            options = [
                .init(id: "air", name: "MacBook Air", scores: ["portability": 0.6, "power": 0.6, "price": 0.6]),
                .init(id: "pro", name: "MacBook Pro", scores: ["portability": 0.6, "power": 0.6, "price": 0.6])
            ]
        }

        return AIDecisionResponse(
            decisionStatus: "ready",
            category: "technology",
            complexity: "medium",
            understanding: .init(restatement: "Choosing a laptop", knownContext: ["Carries it daily"], whatMatters: ["Portability"]),
            researchNeeded: .init(level: "none"),
            criteria: criteria,
            options: options,
            recommendation: .init(
                optionId: recommended,
                headline: "Best fit for you",
                reasons: [.init(title: "Lighter", detail: "You carry it every day.")]
            ),
            research: [
                .init(
                    claim: "The Air is lighter.",
                    sourceTitle: "Apple",
                    sourceUrl: "https://www.apple.com/macbook-air/specs/",
                    retrievedAt: ISO8601DateFormatter().string(from: Date()),
                    verified: true
                )
            ]
        )
    }

    enum StrengthStyle { case dominant, split, tied }

    /// Wants one thing from the user, plus one thing it could look up itself and
    /// one thing that does not matter.
    static func askingOneQuestion() -> AIDecisionResponse {
        // Split, not dominant: a question is only worth asking when the answer
        // could still move the result.
        var response = ready(strengthStyle: .split)
        response.decisionStatus = "needs_one_question"
        response.complexity = "complex"
        response.requiredQuestions = [
            .init(id: "relocate", text: "Would you relocate?", kind: "single_choice", choices: ["Yes", "No"], expectedImpact: 0.9, friction: 0.2),
            .init(id: "price", text: "What does it cost today?", expectedImpact: 0.8, friction: 0.5, answerableByResearch: true),
            .init(id: "colour", text: "Favourite colour?", expectedImpact: 0.02, friction: 0.1)
        ]
        response.preliminaryRecommendation = .init(optionId: "air", rationale: "Portability is doing most of the work.")
        return response
    }

    static func needingResearch() -> AIDecisionResponse {
        var response = ready()
        response.decisionStatus = "needs_research"
        response.researchNeeded = .init(level: "deep", topics: ["current pricing"])
        response.research = []
        return response
    }

    /// Nothing is known about any option: no responsible recommendation exists.
    static func notEnoughInformation() -> AIDecisionResponse {
        AIDecisionResponse(
            decisionStatus: "ready",
            category: "other",
            complexity: "medium",
            understanding: .init(restatement: "Choosing between two things I know nothing about"),
            researchNeeded: .init(level: "none"),
            criteria: [
                .init(id: "a", name: "Cost", weight: 0.5),
                .init(id: "b", name: "Quality", weight: 0.5)
            ],
            options: [
                .init(id: "one", name: "One"),
                .init(id: "two", name: "Two")
            ]
        )
    }
}
