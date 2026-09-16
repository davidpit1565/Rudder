import Foundation

public enum MemorySafetyViolation: Hashable, Sendable, CustomStringConvertible {
    case identityClaim(String)
    case sensitiveTopic(String)
    case empty
    case tooLong(Int)

    public var description: String {
        switch self {
        case .identityClaim(let phrase): return "identity claim: '\(phrase)'"
        case .sensitiveTopic(let term): return "sensitive topic: '\(term)'"
        case .empty: return "empty statement"
        case .tooLong(let length): return "statement is \(length) characters"
        }
    }
}

/// RUDDER learns *behaviour patterns*, never *who someone is*.
///
/// Allowed:  "You often prioritize convenience over price."
/// Rejected: "You are a convenience-oriented person."
public enum MemorySafety {

    public static let maximumStatementLength = 160

    /// Phrasings that turn an observation into a personality label.
    static let identityPhrases = [
        "you are a", "you are an", "you're a", "you're an",
        "you tend to be a", "your personality", "you seem to be a",
        "as someone who is", "you are the kind of person", "you are the type of person"
    ]

    /// Topics RUDDER must never infer or store, whatever the decision was about.
    static let sensitiveTerms = [
        // health & mental health
        "diagnos", "depress", "anxiety", "anxious disorder", "adhd", "autis", "bipolar",
        "therapy", "therapist", "medication", "prescription", "illness", "disorder",
        "disability", "symptom", "treatment", "addict",
        // protected characteristics
        "religion", "religious", "faith", "church", "mosque", "synagogue",
        "ethnicity", "race", "racial", "sexual orientation", "gay", "lesbian",
        "transgender", "pregnan", "fertility", "political", "voting", "party affiliation",
        "immigration status", "criminal record"
    ]

    public static func validate(_ statement: String) throws(MemorySafetyError) {
        let trimmed = statement.trimmed
        guard !trimmed.isEmpty else { throw MemorySafetyError(violations: [.empty]) }

        var violations: [MemorySafetyViolation] = []
        if trimmed.count > maximumStatementLength {
            violations.append(.tooLong(trimmed.count))
        }

        let lowered = trimmed.lowercased()
        for phrase in identityPhrases where lowered.contains(phrase) {
            violations.append(.identityClaim(phrase))
        }
        for term in sensitiveTerms where lowered.contains(term) {
            violations.append(.sensitiveTopic(term))
        }

        guard violations.isEmpty else { throw MemorySafetyError(violations: violations) }
    }

    public static func isSafe(_ statement: String) -> Bool {
        do {
            try validate(statement)
            return true
        } catch {
            return false
        }
    }
}

public struct MemorySafetyError: Error, Hashable, Sendable {
    public let violations: [MemorySafetyViolation]
}
