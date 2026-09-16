import Foundation

/// Privacy-conscious by construction: the event vocabulary is closed, and no
/// event carries decision content, free text or anything identifying.
public enum AnalyticsEvent: String, Sendable {
    case decisionStarted = "decision_started"
    case decisionCompleted = "decision_completed"
    case questionShown = "question_shown"
    case questionAnswered = "question_answered"
    case researchUsed = "research_used"
    case recommendationShown = "recommendation_shown"
    case recommendationOverridden = "recommendation_overridden"
    case decisionSaved = "decision_saved"
    case outcomeRecorded = "outcome_recorded"
    case paywallShown = "paywall_shown"
    case subscriptionStarted = "subscription_started"
    case memoryProposed = "memory_proposed"
    case memoryAccepted = "memory_accepted"
}

/// Only these keys may accompany an event, and only with these value types.
public enum AnalyticsProperty: String, Sendable {
    case category
    case complexity
    case strength
    case researchLevel = "research_level"
    case questionsAsked = "questions_asked"
    case durationBucket = "duration_bucket"
    case source
}

public protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent, properties: [AnalyticsProperty: String])
}

extension AnalyticsService {
    public func track(_ event: AnalyticsEvent) { track(event, properties: [:]) }
}

/// The shipping default: nothing leaves the device.
///
/// Wiring in a real provider means changing three things together — this type,
/// the App Privacy answers in AppStore/privacy.md, and the privacy manifest in
/// App/Resources/PrivacyInfo.xcprivacy. Changing only the first would make the
/// app's declared data practices false.
public struct NoOpAnalyticsService: AnalyticsService {
    public init() {}

    public func track(_ event: AnalyticsEvent, properties: [AnalyticsProperty: String]) {
        #if DEBUG
        let rendered = properties.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " ")
        print("[analytics] \(event.rawValue) \(rendered)")
        #endif
    }
}
