import Foundation
import Observation
import RudderCore

/// A direction RUDDER already has before it finishes — shown so the user gets
/// something useful in the first few seconds rather than a spinner.
public struct PreliminaryDirection: Equatable, Sendable {
    public let optionName: String
    public let rationale: String
}

/// Drives one decision from raw text to a saved choice.
///
/// The pipeline is guarded by `DecisionFlowMachine`, so an impossible sequence
/// (a recommendation that never got stress-tested, analysis before the readiness
/// check) is a programming error that fails loudly in debug rather than shipping.
@MainActor
@Observable
public final class DecisionCoordinator {

    public enum Phase: Equatable {
        case idle
        case working(DecisionFlowState)
        case asking(QuestionCandidate)
        case insufficient(missing: [String], partial: DecisionResult?)
        case finished(DecisionResult)
        case failed(RudderServiceError)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var preliminary: PreliminaryDirection?
    public private(set) var prompt: String = ""
    public private(set) var questionsAsked: [String] = []
    public private(set) var decisionID = UUID()
    /// True once the user has chosen, so the screen stops offering to choose again.
    public private(set) var chosenOptionID: String?

    private var machine = DecisionFlowMachine()
    private var answers: [DecisionAnalysisRequest.Answer] = []
    private var classification: DecisionClassifier.Classification?
    private var budget: DecisionBudget?
    private var researchAttempted = false
    private var modelCallsUsed = 0
    private var task: Task<Void, Never>?

    private let service: DecisionAnalysisService
    private let analytics: AnalyticsService
    private let memoryProvider: @MainActor () -> [MemoryEntry]

    public init(
        service: DecisionAnalysisService,
        analytics: AnalyticsService = NoOpAnalyticsService(),
        memoryProvider: @escaping @MainActor () -> [MemoryEntry] = { [] }
    ) {
        self.service = service
        self.analytics = analytics
        self.memoryProvider = memoryProvider
    }

    public var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    public var result: DecisionResult? {
        switch phase {
        case .finished(let result): return result
        case .insufficient(_, let partial): return partial
        default: return nil
        }
    }

    // MARK: - Running

    public func start(prompt raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return }

        cancel()
        reset()
        prompt = trimmed

        let classification = DecisionClassifier.classify(trimmed)
        self.classification = classification
        budget = ResearchPolicy.budget(
            complexity: classification.complexity,
            category: classification.category,
            requestedLevel: classification.researchLevel
        )

        analytics.track(
            .decisionStarted,
            properties: [
                .category: classification.category.rawValue,
                .complexity: classification.complexity.rawValue
            ]
        )

        advance(to: .understanding)
        run()
    }

    public func answer(_ text: String, to question: QuestionCandidate) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answers.append(.init(questionId: question.id, answer: trimmed))
        questionsAsked.append(question.id)
        analytics.track(.questionAnswered)
        // The machine moves ASK -> READINESS CHECK inside `handle`, once there is
        // something new to check.
        run()
    }

    /// The user can always decline to answer — RUDDER then continues and says
    /// plainly what it had to assume.
    public func skipQuestion(_ question: QuestionCandidate) {
        questionsAsked.append(question.id)
        answers.append(.init(questionId: question.id, answer: "(not answered)"))
        run()
    }

    public func retry() {
        guard case .failed = phase else { return }
        machine = DecisionFlowMachine(state: .failed)
        advance(to: .start)
        advance(to: .understanding)
        run()
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func reset() {
        machine = DecisionFlowMachine()
        answers = []
        questionsAsked = []
        preliminary = nil
        researchAttempted = false
        modelCallsUsed = 0
        chosenOptionID = nil
        decisionID = UUID()
        phase = .idle
    }

    private func run() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.performAnalysis()
        }
    }

    private func performAnalysis() async {
        guard let classification, let budget else { return }

        let request = DecisionAnalysisRequest(
            prompt: prompt,
            answers: answers,
            knownPreferences: memoryProvider().filter(\.isEnabled).map(\.statement),
            classification: classification,
            budget: budget,
            questionsAlreadyAsked: questionsAsked.count
        )

        modelCallsUsed += 1

        do {
            let validated = try await service.analyse(request)
            guard !Task.isCancelled else { return }
            handle(validated)
        } catch let error as RudderServiceError {
            guard error != .cancelled, !Task.isCancelled else { return }
            fail(with: error)
        } catch {
            guard !Task.isCancelled else { return }
            fail(with: .unknown)
        }
    }

    // MARK: - Readiness

    private func handle(_ response: ValidatedAIResponse) {
        if let id = response.preliminaryOptionID,
           let option = response.options.first(where: { $0.id == id }),
           let rationale = response.preliminaryRationale,
           !rationale.isEmpty {
            preliminary = PreliminaryDirection(optionName: option.name, rationale: rationale)
        }

        if !response.research.isEmpty {
            analytics.track(.researchUsed, properties: [.researchLevel: response.researchLevel.rawValue])
        }

        // Is the answer already stable? If so, nothing more is worth asking.
        let stability = StabilityEngine.analyse(options: response.options, criteria: response.criteria)
        let alreadyStable = stability.strength == .strong && response.recommendedOptionID != nil

        let plan = QuestionEngine.plan(
            candidates: response.questions,
            complexity: response.complexity,
            alreadyAskedIDs: Set(questionsAsked),
            knownKeys: MemoryEngine.knownKeys(from: memoryProvider()),
            decisionIsAlreadyStable: alreadyStable
        )

        let readiness = ReadinessEngine.assess(
            ReadinessInput(
                viableOptionCount: response.options.filter { !$0.isEliminated }.count,
                criteriaCount: response.criteria.count,
                evidenceCoverage: DecisionAssembler.evidenceCoverage(response),
                requestedResearchLevel: response.researchLevel,
                researchAttempted: researchAttempted || response.researchLevel == .none || !response.research.isEmpty,
                hasUnresolvedConflicts: !response.conflicts.isEmpty,
                questionPlan: plan,
                margin: DecisionEngine.evaluate(options: response.options, criteria: response.criteria).margin
            )
        )

        advance(to: .readinessCheck)

        switch readiness.state {
        case .needsResearch:
            guard !researchAttempted else {
                // The backend asked for research twice; continue with what we have
                // rather than looping.
                finish(with: response)
                return
            }
            researchAttempted = true
            advance(to: .research)
            run()

        case .needsOneQuestion:
            // The budget is a hard ceiling, not a suggestion: a decision cannot
            // keep buying model calls by asking one more thing.
            guard let question = plan.next, modelCallsUsed < (budget?.maximumModelCalls ?? 1) else {
                finish(with: response)
                return
            }
            advance(to: .ask)
            analytics.track(.questionShown)
            phase = .asking(question)

        case .notEnoughToDecide:
            advance(to: .insufficient)
            // A partial answer is still shown when it is genuinely useful.
            let partial = response.recommendedOptionID == nil ? nil : DecisionAssembler.assemble(response)
            phase = .insufficient(missing: readiness.missing, partial: partial)

        case .ready:
            finish(with: response)
        }
    }

    private func finish(with response: ValidatedAIResponse) {
        advance(to: .analyze)
        advance(to: .stressTest)
        advance(to: .selfChallenge)

        let result = DecisionAssembler.assemble(response)

        advance(to: .recommendation)
        phase = .finished(result)

        analytics.track(
            .recommendationShown,
            properties: [
                .category: result.category.rawValue,
                .strength: result.strength.rawValue,
                .questionsAsked: String(questionsAsked.count),
                .researchLevel: result.researchLevel.rawValue
            ]
        )
    }

    private func fail(with error: RudderServiceError) {
        if machine.canTransition(to: .failed) {
            _ = try? machine.transition(to: .failed)
        }
        phase = .failed(error)
    }

    /// Records a state change and keeps `phase` in step with the machine.
    private func advance(to state: DecisionFlowState) {
        do {
            try machine.transition(to: state)
        } catch {
            // An illegal transition means the pipeline logic is wrong, not the input.
            assertionFailure("Illegal decision flow transition: \(error)")
            return
        }
        if state.progressTitle != nil {
            phase = .working(state)
        }
    }

    // MARK: - Choosing

    /// The user's choice, whatever it is. RUDDER does not argue, confirm or persuade.
    public func makeChoice(optionID: String) -> DecisionRecord? {
        guard case .finished(let result) = phase else {
            guard case .insufficient(_, .some(let partial)) = phase else { return nil }
            return record(from: partial, optionID: optionID)
        }
        return record(from: result, optionID: optionID)
    }

    private func record(from result: DecisionResult, optionID: String) -> DecisionRecord {
        chosenOptionID = optionID

        if machine.canTransition(to: .userChoice) { _ = try? machine.transition(to: .userChoice) }
        if machine.canTransition(to: .saved) { _ = try? machine.transition(to: .saved) }

        if let recommended = result.recommendedOptionID, recommended != optionID {
            analytics.track(.recommendationOverridden, properties: [.strength: result.strength.rawValue])
        }
        analytics.track(.decisionCompleted, properties: [.strength: result.strength.rawValue])

        return DecisionRecord(
            id: decisionID,
            title: DecisionTitle.make(from: prompt, result: result),
            prompt: prompt,
            result: result,
            chosenOptionID: optionID,
            chosenAt: Date()
        )
    }
}

/// Short, recognisable titles for the history list.
public enum DecisionTitle {
    public static func make(from prompt: String, result: DecisionResult) -> String {
        let names = result.options.map(\.name)
        if names.count == 2 {
            return "\(names[0]) vs \(names[1])"
        }
        if names.count > 2 {
            return "\(names[0]) vs \(names.count - 1) others"
        }
        let cleaned = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
    }
}
