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

    /// Strips one trailing period, for text meant to be embedded mid-sentence
    /// (e.g. "...giving up X to get Y.") rather than shown standalone — a
    /// model reply can still send a complete sentence despite being asked for
    /// a fragment, and this keeps that from reading as "X. to get Y.".
    var withoutTrailingPeriod: String {
        hasSuffix(".") ? String(dropLast()) : self
    }
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
