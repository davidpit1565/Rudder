import Foundation
import RudderCore

/// The small slice of a decision the Home Screen widget needs. Deliberately not
/// the full `DecisionRecord` -- the widget extension is a separate process with
/// its own memory budget, and it has no reason to see criteria, research notes,
/// or anything else that isn't shown on the widget face.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let strengthTitle: String
    public let updatedAt: Date

    public init(title: String, subtitle: String, strengthTitle: String, updatedAt: Date) {
        self.title = title
        self.subtitle = subtitle
        self.strengthTitle = strengthTitle
        self.updatedAt = updatedAt
    }

    /// The most recent decision, or nil when there isn't one yet -- the widget
    /// shows its own empty state rather than a snapshot file that doesn't exist.
    public static func make(from decisions: [DecisionRecord]) -> WidgetSnapshot? {
        guard let latest = decisions.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        let chosen = latest.chosenOption?.name ?? latest.result.recommendedOption?.name
        return WidgetSnapshot(
            title: latest.title,
            subtitle: chosen ?? "Not decided yet",
            strengthTitle: latest.result.strength.title,
            updatedAt: latest.updatedAt
        )
    }
}
