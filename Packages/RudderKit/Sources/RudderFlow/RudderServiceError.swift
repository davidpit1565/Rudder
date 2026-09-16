import Foundation

/// Every failure the user can actually hit, with copy that says what happened
/// and what they can do — never a raw error string.
public enum RudderServiceError: LocalizedError, Equatable {
    case offline
    case notConfigured
    case timedOut
    case rateLimited
    case serverUnavailable
    case invalidResponse
    case cancelled
    case unknown

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "You're offline"
        case .notConfigured:
            return "RUDDER isn't connected yet"
        case .timedOut:
            return "That took too long"
        case .rateLimited:
            return "Too many decisions at once"
        case .serverUnavailable:
            return "I couldn't complete the analysis"
        case .invalidResponse:
            return "I couldn't complete the analysis"
        case .cancelled:
            return "Cancelled"
        case .unknown:
            return "Something went wrong"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .offline:
            return "A new decision needs a connection. Your saved decisions are still here."
        case .notConfigured:
            return "The analysis service isn't configured in this build."
        case .timedOut:
            return "Try again — it's usually quicker."
        case .rateLimited:
            return "Give it a moment and try again."
        case .serverUnavailable, .invalidResponse, .unknown:
            return "Try again. If it keeps happening, it's on my side, not yours."
        case .cancelled:
            return nil
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .cancelled, .notConfigured: return false
        default: return true
        }
    }
}
