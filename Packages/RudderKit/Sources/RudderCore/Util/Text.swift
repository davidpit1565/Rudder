import Foundation

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Caps text coming from outside the app so a hostile or broken response cannot
    /// blow up layout or memory.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + "…"
    }

    /// True when the string carries no visible content.
    var isBlank: Bool { trimmed.isEmpty }
}

extension Optional where Wrapped == String {
    var trimmedOrNil: String? {
        guard let value = self?.trimmed, !value.isEmpty else { return nil }
        return value
    }
}

extension Array where Element == String {
    /// Trims, drops empties, de-duplicates and caps a list of strings from outside the app.
    func cleaned(limit: Int, maximumLength: Int = 400) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in self {
            let value = item.trimmed
            guard !value.isEmpty, !seen.contains(value) else { continue }
            seen.insert(value)
            result.append(value.truncated(to: maximumLength))
            if result.count == limit { break }
        }
        return result
    }
}
