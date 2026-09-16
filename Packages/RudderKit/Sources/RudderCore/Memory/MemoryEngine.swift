import Foundation

/// A preference RUDDER has learned from the user's actual decisions.
/// Stored only after the user says yes.
public struct MemoryEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// Stable key so the same preference is not proposed twice, e.g. "convenience>price".
    public let key: String
    /// User-facing wording. Always behavioural, never an identity claim.
    public var statement: String
    public var evidenceCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        key: String,
        statement: String,
        evidenceCount: Int,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.key = key
        self.statement = statement
        self.evidenceCount = evidenceCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEnabled = isEnabled
    }
}

/// A preference RUDDER would like to remember, pending the user's consent.
public struct MemoryCandidate: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let statement: String
    public let evidenceCount: Int
}

/// Learns from completed decisions rather than from an onboarding quiz.
///
/// A pattern is only proposed once it has been seen more than once, and only if
/// the wording passes `MemorySafety`.
///
/// Outcomes count. A decision the user said went badly is not evidence for the
/// preference it expressed, and one they said went well counts double — so
/// telling RUDDER how it went genuinely changes what it learns.
public enum MemoryEngine {

    /// A pattern needs this much evidence before it is worth asking about.
    public static let minimumEvidence = 2

    /// Looks at what the user chose versus what they gave up, and finds criteria
    /// they repeatedly favoured.
    public static func candidates(
        from records: [DecisionRecord],
        existing: [MemoryEntry] = [],
        minimumEvidence: Int = MemoryEngine.minimumEvidence
    ) -> [MemoryCandidate] {
        var favouredOver: [String: Int] = [:]   // "convenience>price" -> count
        var names: [String: (String, String)] = [:]

        for record in records {
            guard let chosen = record.chosenOption else { continue }
            // A choice the user regretted should not teach RUDDER to repeat it.
            guard record.outcome?.rating != .notGreat else { continue }
            let weight = record.outcome?.rating == .great ? 2 : 1

            let criteria = record.result.criteria
            guard criteria.count > 1 else { continue }

            let alternatives = record.result.options.filter { $0.id != chosen.id && !$0.isEliminated }
            guard !alternatives.isEmpty else { continue }

            for alternative in alternatives {
                // Which criteria did the chosen option win on, and which did it lose on?
                let won = criteria.filter { chosen.score(for: $0.id) - alternative.score(for: $0.id) > 0.15 }
                let lost = criteria.filter { alternative.score(for: $0.id) - chosen.score(for: $0.id) > 0.15 }
                for winner in won {
                    for loser in lost {
                        let key = "\(normalise(winner.name))>\(normalise(loser.name))"
                        favouredOver[key, default: 0] += weight
                        names[key] = (winner.name, loser.name)
                    }
                }
            }
        }

        let existingKeys = Set(existing.map(\.key))

        return favouredOver
            .filter { $0.value >= minimumEvidence && !existingKeys.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .compactMap { key, count in
                guard let (winner, loser) = names[key] else { return nil }
                let statement = "You often prioritize \(winner.lowercased()) over \(loser.lowercased())."
                guard MemorySafety.isSafe(statement) else { return nil }
                return MemoryCandidate(key: key, statement: statement, evidenceCount: count)
            }
    }

    /// Consent-gated write. Throws rather than storing anything unsafe.
    public static func accept(_ candidate: MemoryCandidate, now: Date = Date()) throws(MemorySafetyError) -> MemoryEntry {
        try MemorySafety.validate(candidate.statement)
        return MemoryEntry(
            key: candidate.key,
            statement: candidate.statement,
            evidenceCount: candidate.evidenceCount,
            createdAt: now,
            updatedAt: now
        )
    }

    /// The keys the question engine treats as already known, so RUDDER does not ask
    /// about something it has already learned.
    public static func knownKeys(from memory: [MemoryEntry]) -> Set<String> {
        Set(memory.filter(\.isEnabled).flatMap { entry -> [String] in
            let parts = entry.key.split(separator: ">").map(String.init)
            return [entry.key] + parts
        })
    }

    static func normalise(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
