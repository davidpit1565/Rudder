import Foundation

/// Bridges a decision prompt from a Siri/Shortcuts invocation into the running app.
///
/// An App Intent runs out-of-process from the SwiftUI view hierarchy, so there is
/// no direct call path from its `perform()` into `HomeView`. This holds the prompt
/// just long enough for the app to read it once after launch or foreground, then
/// clears it -- a stale prompt must never resurface on an unrelated later launch.
@MainActor
public final class PendingSiriDecision {
    public static let shared = PendingSiriDecision()

    private var prompt: String?

    init() {}

    public func set(_ prompt: String) {
        self.prompt = prompt
    }

    /// Returns the pending prompt once, clearing it so it cannot be replayed.
    public func consume() -> String? {
        defer { prompt = nil }
        return prompt
    }
}
