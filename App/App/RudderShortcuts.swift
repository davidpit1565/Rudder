import AppIntents
import RudderFlow

/// "Hey Siri, ask Rudder what to decide" -- hands the spoken or typed prompt
/// straight to the home screen instead of making the user retype it once the
/// app is open. `PendingSiriDecision` (RudderFlow, unit tested) is the only
/// thing this intent touches: it cannot reach into the view hierarchy directly
/// since it runs out-of-process from SwiftUI.
struct StartDecisionIntent: AppIntent {
    // `let`, not `var`: under Swift 6 strict concurrency a stored, mutable
    // `static var` is flagged as unsafe shared global state even for Sendable
    // types. These are all `{ get }`-only AppIntent requirements, so `let`
    // satisfies the protocol and removes the warning-as-error entirely.
    static let title: LocalizedStringResource = "Start a Decision"
    static let description = IntentDescription(
        "Tells Rudder what you're deciding so it can start researching right away."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "What are you deciding?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingSiriDecision.shared.set(prompt)
        return .result()
    }
}

struct RudderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDecisionIntent(),
            // A free-form String parameter can't be embedded inline in a phrase --
            // App Intents' build-time metadata processor only allows AppEntity/AppEnum
            // there ("Invalid parameter type", a real error caught by CI). `prompt`
            // has no default, so App Intents asks "What are you deciding?" itself
            // after the app opens -- one extra step versus a single utterance, but
            // it still works with no further wiring needed.
            phrases: [
                "Start a decision with \(.applicationName)",
                "Ask \(.applicationName) what to decide"
            ],
            shortTitle: "Start a Decision",
            systemImageName: "arrow.triangle.branch"
        )
    }
}
