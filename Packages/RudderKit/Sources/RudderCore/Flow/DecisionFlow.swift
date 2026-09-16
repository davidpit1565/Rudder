import Foundation

/// The states a decision moves through. Every state that is shown to the user
/// reflects work that is actually happening — there is no decorative loading.
public enum DecisionFlowState: String, Codable, CaseIterable, Sendable {
    case start
    case understanding
    case readinessCheck = "readiness_check"
    case research
    case ask
    case insufficient
    case analyze
    case stressTest = "stress_test"
    case selfChallenge = "self_challenge"
    case recommendation
    case userChoice = "user_choice"
    case saved
    case failed

    /// Copy shown while the state is active. nil when the state has no waiting UI.
    public var progressTitle: String? {
        switch self {
        case .start: return nil
        case .understanding: return "Understanding your decision"
        case .readinessCheck: return "Working out what I still need"
        case .research: return "Checking the information"
        case .ask: return nil
        case .insufficient: return nil
        case .analyze: return "Analyzing your decision"
        case .stressTest: return "Stress-testing my recommendation"
        case .selfChallenge: return "Trying to prove myself wrong"
        case .recommendation, .userChoice, .saved, .failed: return nil
        }
    }

    public var progressSubtitle: String? {
        switch self {
        case .understanding: return "I'm figuring out what matters before I analyze it."
        case .research: return "Looking up what I can, so I don't have to ask you."
        case .stressTest: return "Checking whether it survives a change in priorities."
        case .selfChallenge: return "Looking for the strongest case against it."
        default: return nil
        }
    }
}

public enum DecisionFlowError: Error, Equatable, Sendable {
    case illegalTransition(from: DecisionFlowState, to: DecisionFlowState)
}

/// Guards the pipeline against impossible states — e.g. a recommendation that
/// never went through stress testing.
public struct DecisionFlowMachine: Sendable {
    public private(set) var state: DecisionFlowState
    public private(set) var history: [DecisionFlowState]

    public init(state: DecisionFlowState = .start) {
        self.state = state
        self.history = [state]
    }

    public static func allowedTransitions(from state: DecisionFlowState) -> Set<DecisionFlowState> {
        switch state {
        case .start:
            return [.understanding, .failed]
        case .understanding:
            return [.readinessCheck, .failed]
        case .readinessCheck:
            return [.research, .ask, .analyze, .insufficient, .failed]
        case .research:
            return [.readinessCheck, .analyze, .failed]
        case .ask:
            return [.readinessCheck, .failed]
        case .insufficient:
            // The user can supply what is missing, or abandon.
            return [.ask, .research, .readinessCheck, .failed]
        case .analyze:
            return [.stressTest, .failed]
        case .stressTest:
            return [.selfChallenge, .failed]
        case .selfChallenge:
            return [.recommendation, .failed]
        case .recommendation:
            return [.userChoice, .failed]
        case .userChoice:
            return [.saved, .recommendation, .failed]
        case .saved:
            return []
        case .failed:
            // Retrying restarts the pipeline from the beginning.
            return [.start, .understanding]
        }
    }

    public func canTransition(to next: DecisionFlowState) -> Bool {
        Self.allowedTransitions(from: state).contains(next)
    }

    @discardableResult
    public mutating func transition(to next: DecisionFlowState) throws -> DecisionFlowState {
        guard canTransition(to: next) else {
            throw DecisionFlowError.illegalTransition(from: state, to: next)
        }
        state = next
        history.append(next)
        return next
    }

    /// Maps a readiness assessment onto the next state, so the readiness check is
    /// the only place that decides what happens next.
    public static func next(for readiness: ReadinessState) -> DecisionFlowState {
        switch readiness {
        case .ready: return .analyze
        case .needsResearch: return .research
        case .needsOneQuestion: return .ask
        case .notEnoughToDecide: return .insufficient
        }
    }
}
