import XCTest
@testable import RudderCore

/// A follow-up response has no repair/validation layer of its own (unlike
/// AIDecisionResponse) -- it's a much smaller contract, so tolerant decoding
/// is tested directly against the wire shape rather than through fixtures.
final class FollowUpContractTests: XCTestCase {

    func testAWellFormedResponseDecodes() throws {
        let json = """
        {
            "answer": "The Air still fits better here.",
            "needsResearch": false,
            "suggestedNewDecisionPrompt": null,
            "durablePreference": null
        }
        """
        let decoded = try JSONDecoder().decode(FollowUpResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.answer, "The Air still fits better here.")
        XCTAssertFalse(decoded.needsResearch)
        XCTAssertNil(decoded.suggestedNewDecisionPrompt)
        XCTAssertNil(decoded.durablePreference)
    }

    func testAResearchRedirectAndDurablePreferenceDecodeTogether() throws {
        let json = """
        {
            "answer": "I'd need current prices to answer that well.",
            "needsResearch": true,
            "suggestedNewDecisionPrompt": "Compare current pricing for the MacBook Air vs Pro.",
            "durablePreference": { "statement": "You prioritize portability over raw performance." }
        }
        """
        let decoded = try JSONDecoder().decode(FollowUpResponseDTO.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.needsResearch)
        XCTAssertEqual(decoded.suggestedNewDecisionPrompt, "Compare current pricing for the MacBook Air vs Pro.")
        XCTAssertEqual(decoded.durablePreference?.statement, "You prioritize portability over raw performance.")
    }

    func testMissingOptionalFieldsDecodeToSafeDefaultsRatherThanFailing() throws {
        let json = #"{ "answer": "Still the Air." }"#
        let decoded = try JSONDecoder().decode(FollowUpResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.answer, "Still the Air.")
        XCTAssertFalse(decoded.needsResearch)
        XCTAssertNil(decoded.suggestedNewDecisionPrompt)
        XCTAssertNil(decoded.durablePreference)
    }

    func testACompletelyEmptyObjectDecodesRatherThanThrowing() throws {
        let decoded = try JSONDecoder().decode(FollowUpResponseDTO.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.answer, "")
        XCTAssertFalse(decoded.needsResearch)
    }

    func testADurablePreferenceMissingItsStatementDecodesToAnEmptyOneRatherThanFailing() throws {
        let json = #"{ "answer": "ok", "durablePreference": {} }"#
        let decoded = try JSONDecoder().decode(FollowUpResponseDTO.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.durablePreference?.statement, "")
    }
}
