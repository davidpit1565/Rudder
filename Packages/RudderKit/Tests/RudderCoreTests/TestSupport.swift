import Foundation
import XCTest
@testable import RudderCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            Bundle.module.url(forResource: name, withExtension: "json")
        ].compactMap { $0 }

        if let url = candidates.first {
            return try Data(contentsOf: url)
        }
        // Fallback for environments where resources are not bundled.
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: path)
    }

    static func response(_ name: String) throws -> AIDecisionResponse {
        try JSONDecoder().decode(AIDecisionResponse.self, from: data(name))
    }

    static func validated(_ name: String) throws -> ValidatedAIResponse {
        try AIResponseValidator.validate(try response(name))
    }
}

extension XCTestCase {
    func makeCriteria(_ pairs: [(String, Double)]) -> [Criterion] {
        pairs.map { Criterion(id: $0.0, name: $0.0.capitalized, weight: $0.1) }
    }

    func makeOption(_ id: String, _ scores: [String: Double], failed: [String] = []) -> DecisionOption {
        DecisionOption(id: id, name: id.capitalized, scores: scores, failedConstraints: failed)
    }
}
