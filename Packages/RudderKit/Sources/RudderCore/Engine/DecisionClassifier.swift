import Foundation

/// Classifies a free-text decision into a category and a complexity band, which
/// together set the research budget, the model budget and the question ceiling.
///
/// This runs on-device before anything is sent anywhere, so an obviously trivial
/// decision never pays for deep research.
public enum DecisionClassifier {

    struct CategorySignature {
        let category: DecisionCategory
        let keywords: [String]
        let baseComplexity: DecisionComplexity
    }

    static let signatures: [CategorySignature] = [
        .init(category: .career, keywords: ["job", "offer", "career", "quit", "resign", "promotion", "employer", "salary", "role", "internship", "freelance"], baseComplexity: .complex),
        .init(category: .home, keywords: ["apartment", "flat", "house", "rent", "mortgage", "move to", "relocate", "relocation", "neighbourhood", "neighborhood", "lease"], baseComplexity: .complex),
        .init(category: .education, keywords: ["degree", "university", "college", "course", "study", "bootcamp", "masters", "master's", "phd", "certification"], baseComplexity: .complex),
        .init(category: .finance, keywords: ["invest", "loan", "insurance", "pension", "savings", "refinance", "mortgage rate", "credit card"], baseComplexity: .complex),
        .init(category: .technology, keywords: ["laptop", "macbook", "iphone", "phone", "computer", "camera", "headphones", "monitor", "gpu", "tablet", "software", "framework", "database"], baseComplexity: .medium),
        .init(category: .travel, keywords: ["flight", "hotel", "trip", "holiday", "vacation", "airbnb", "itinerary", "travel"], baseComplexity: .medium),
        .init(category: .subscription, keywords: ["subscription", "cancel", "renew", "plan", "membership", "tier"], baseComplexity: .medium),
        .init(category: .purchase, keywords: ["buy", "purchase", "car", "bike", "mattress", "sofa", "worth it", "price"], baseComplexity: .medium),
        .init(category: .lifePlanning, keywords: ["should i", "gym", "hobby", "habit", "routine", "relationship", "weekend"], baseComplexity: .simple)
    ]

    /// Low-stakes, instantly-answerable decisions. Deep research here is waste.
    static let trivialKeywords = [
        "pizza", "pasta", "lunch", "dinner", "breakfast", "coffee", "tea",
        "film tonight", "movie tonight", "what to watch", "which shirt", "what to wear"
    ]

    /// Signals of a high-value, hard-to-reverse decision.
    static let highStakesKeywords = [
        "car", "house", "apartment", "mortgage", "job", "offer", "relocate", "relocation",
        "degree", "university", "invest", "pension", "surgery", "contract", "salary"
    ]

    public struct Classification: Hashable, Sendable {
        public let category: DecisionCategory
        public let complexity: DecisionComplexity
        public let researchLevel: ResearchLevel
        public let optionCountHint: Int

        public init(
            category: DecisionCategory,
            complexity: DecisionComplexity,
            researchLevel: ResearchLevel,
            optionCountHint: Int
        ) {
            self.category = category
            self.complexity = complexity
            self.researchLevel = researchLevel
            self.optionCountHint = optionCountHint
        }
    }

    public static func classify(_ text: String) -> Classification {
        let normalised = text.lowercased()
        let words = normalised.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wordCount = words.count

        var category: DecisionCategory = .other
        var complexity: DecisionComplexity = wordCount > 40 ? .medium : .simple

        for signature in signatures where signature.keywords.contains(where: { normalised.contains($0) }) {
            category = signature.category
            complexity = signature.baseComplexity
            break
        }

        let optionCountHint = estimatedOptionCount(in: normalised)

        if trivialKeywords.contains(where: { normalised.contains($0) }) {
            complexity = .simple
        } else if highStakesKeywords.contains(where: { normalised.contains($0) }) {
            complexity = .complex
        } else if optionCountHint > 3, complexity == .simple {
            complexity = .medium
        }

        // Money amounts push a decision up a band — it is worth more care.
        if containsSignificantAmount(normalised), complexity != .complex {
            complexity = complexity == .simple ? .medium : .complex
        }

        let researchLevel: ResearchLevel
        switch complexity {
        case .simple: researchLevel = .none
        case .medium: researchLevel = .light
        case .complex: researchLevel = .deep
        }

        return Classification(
            category: category,
            complexity: complexity,
            researchLevel: researchLevel,
            optionCountHint: optionCountHint
        )
    }

    static func estimatedOptionCount(in text: String) -> Int {
        let separators = [" or ", " vs ", " vs. ", " versus ", ","]
        var count = 1
        for separator in separators {
            count += text.components(separatedBy: separator).count - 1
        }
        return min(count, 12)
    }

    static func containsSignificantAmount(_ text: String) -> Bool {
        // Matches 1000 / 1,000 / 1000€ / $2500 / 3k and up.
        let pattern = #"(?:[$€£]\s?\d[\d,.]*)|(?:\d[\d,.]*\s?(?:k\b|€|\$|£|eur|usd|gbp))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else { return false }
        let digits = text[matchRange].filter(\.isNumber)
        guard let value = Double(digits) else { return false }
        return text[matchRange].lowercased().contains("k") || value >= 500
    }
}
